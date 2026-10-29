#!/usr/bin/env python3
"""Build cleanup (preview by default); system temp cleanup requires its own mode."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
from xml.parsers.expat import ExpatError
from local_build import inherited_lock, run_child, validate_path, worktree_lock


ARTIFACT_NAME = re.compile(r"CtrlX-[0-9]+\.[0-9]+\.[0-9]+(?P<configuration>-Debug)?\.(?P<platform>ipa|dmg)")
RELEASE_DIRECTORY = re.compile(r"v?[0-9]+\.[0-9]+\.[0-9]+")
PUBLISH_REPORT = re.compile(r"publish-report(?:-[0-9]+)?\.json")
RETAINED_MARKER = ".ctrlx-retained.json"
RETAINED_GROUPS = {
    "verification": re.compile(r"upstream-browser-proof\.[A-Za-z0-9_-]+"),
    "install-backup": re.compile(r"(?:macOS-install-backup|mac-install-backup|mac-install)\.[A-Za-z0-9_-]+"),
}
RETAINED_COUNT = 2
LOW_SPACE_BYTES = 20 * 1024 ** 3
COMPLETED_MARKER = ".ctrlx-cleanup-ready"
COMPLETED_ARTIFACT_DIRS = (".build-local/app-backups", ".build-local/diagnostics")
COMPILATION_CACHE_DIRS = (
    "Build/Intermediates.noindex",
    "CompilationCache.noindex",
    "ModuleCache.noindex",
    "SDKExplicitPrecompiledModules",
    "SDKStatCaches.noindex",
)
PACKAGE_TRIPLE = re.compile(r"(?:arm64|x86_64)-apple-macosx")
TEST_CACHE_DIRS = (
    "Intermediates.noindex", "CompilationCache.noindex", "ModuleCache.noindex",
    "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex", "PCH",
)
DEEP_CACHE_DIRS = (
    ".build-local/DerivedData",
    ".build-local/SourcePackages",
    ".build-local/package-ios",
    ".build-local/package-macos",
    ".build-local/agent-browser",
    ".build-local/cef-browser-probe",
    ".build-local/agent-browser-engine",
    ".build",
    "CtrlxPackage/.build",
)
SIGNING_CLONE_IDS = (
    "com.jicezeng.ctrlx.macos",
    "com.ctrlx.embedded-acceptance",
    "com.ctrlx.extensions-acceptance",
    "com.ctrlx.experimental.browser-probe",
)
SIGNING_CLONE_NAME = re.compile(r"code_sign_clone\.[A-Za-z0-9]{6}")
SYSTEM_TEMP_MIN_AGE = 24 * 60 * 60


def validate_system_temp_path(root, path):
    validate_path(root, path)
    if root.is_symlink() or root.stat().st_uid != os.getuid():
        raise ValueError(f"Not a current-user temporary directory: {root}")
    relative = path.relative_to(root)
    for count in range(1, len(relative.parts) + 1):
        child = root.joinpath(*relative.parts[:count])
        if child.exists() and child.stat().st_uid != os.getuid():
            raise ValueError(f"Not owned by the current user: {child}")


def system_temp_root():
    if sys.platform != "darwin" or os.getuid() == 0:
        raise ValueError("system-temp requires macOS and a non-root user")
    # TMPDIR may be inherited from an updater and point inside its staging copy.
    temporary = Path(subprocess.check_output(
        ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True, timeout=10,
    ).strip()).resolve(strict=True)
    root = temporary.parent
    if temporary.name != "T" or root.parent.parent != Path("/private/var/folders"):
        raise ValueError(f"Unrecognized macOS user temporary directory: {temporary}")
    validate_system_temp_path(root, temporary)
    return root


def temp_path_alias(value):
    return re.sub(r"(?<!/private)/var/folders/", "/private/var/folders/", value)


def system_temp_activity():
    """Inspection failure must abort cleanup, never look like an idle machine."""
    commands = subprocess.check_output(
        ["/bin/ps", "-ww", "-axo", "pid=,command="], text=True, timeout=10,
    )
    opened = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-Fpn"], text=True, capture_output=True, timeout=40,
    )
    if opened.returncode or opened.stderr.strip() or not opened.stdout.startswith("p"):
        raise ValueError(f"Cannot inspect open temporary files; keeping caches: {opened.stderr.strip()}")
    if not commands.strip():
        raise ValueError("Cannot inspect running processes; keeping temporary caches")
    paths = [temp_path_alias(row[1:]) for row in opened.stdout.splitlines() if row.startswith("n/")]
    paths.extend(temp_path_alias(str(Path(value).absolute())) for value in
                 (os.getcwd(), os.environ.get("TMPDIR", "/tmp")))
    return paths, [temp_path_alias(row) for row in commands.splitlines()]


def temp_path_in_use(path, activity):
    opened, commands = activity
    prefix = str(path)
    return any(value == prefix or value.startswith(prefix + "/") for value in opened) \
        or any(prefix in command for command in commands)


def temp_tree_is_old(path, cutoff):
    if path.lstat().st_mtime >= cutoff:
        return False
    if path.is_dir() and not path.is_symlink():
        return all(temp_tree_is_old(child, cutoff) for child in path.iterdir())
    return True


def system_temp_targets(root, activity, now):
    cutoff = now - SYSTEM_TEMP_MIN_AGE
    targets = []
    for identifier in SIGNING_CLONE_IDS:
        parent = root / "X" / f"{identifier}.code_sign_clone"
        validate_system_temp_path(root, parent)
        if not parent.is_dir():
            continue
        inactive = []
        for path in sorted(parent.iterdir()):
            if not SIGNING_CLONE_NAME.fullmatch(path.name):
                continue
            validate_system_temp_path(root, path)
            if not path.is_dir():
                continue
            children = list(path.iterdir())
            if len(children) != 1 or not children[0].name.endswith(".app.bundle"):
                print(f"Keeping unrecognized signing clone: {path}")
                continue
            info = children[0] / "Contents/Info.plist"
            validate_system_temp_path(root, info)
            try:
                with info.open("rb") as source:
                    identity = plistlib.load(source)
            except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
                print(f"Keeping unreadable signing clone {path}: {error}", file=sys.stderr)
                continue
            if not isinstance(identity, dict) or identity.get("CFBundleIdentifier") != identifier:
                print(f"Keeping signing clone with unexpected identity: {path}")
                continue
            if temp_path_in_use(path, activity):
                print(f"Skipping active system temporary directory: {path}")
                continue
            inactive.append((path.stat().st_mtime_ns, path))
        # Active clones are extra; always keep two other recent copies per ID.
        for modified, path in sorted(inactive, reverse=True)[RETAINED_COUNT:]:
            if modified / 1e9 < cutoff:
                targets.append(path)

    derived = root / "T/ctrlx-e2e-derived-data"
    validate_system_temp_path(root, derived)
    if derived.is_dir():
        if temp_path_in_use(derived, activity):
            print(f"Skipping active system temporary directory: {derived}")
        elif derived.stat().st_mtime < cutoff:
            # Preserve installable products, dependency downloads and test logs.
            for name in (*COMPILATION_CACHE_DIRS, "Index.noindex"):
                path = derived / name
                validate_system_temp_path(root, path)
                if path.is_dir() and temp_tree_is_old(path, cutoff):
                    targets.append(path)
    return targets


def clean_system_temp(apply):
    root = system_temp_root()
    print(f"Current-user system temporary root: {root}")
    print("Keep active directories, copies newer than 24 hours and two inactive signing clones per bundle ID.")
    print("Stop E2E builds/tests before applying cleanup of their legacy temporary compilation caches.")
    with contextlib.ExitStack() as locks:
        if apply:
            # This scope is shared across worktrees, so its cleanup lock is too.
            path = root / "T/ctrlx-system-temp-cleanup.lock"
            validate_system_temp_path(root, path)
            lock = locks.enter_context(path.open("a+"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError("Another system-temp cleanup is running") from error
        targets = system_temp_targets(root, system_temp_activity(), time.time())
        if apply and targets:
            # Recheck after inspecting the clone bundles, immediately before deletion.
            current = set(system_temp_targets(root, system_temp_activity(), time.time()))
            targets = [path for path in targets if path in current]
        for path in targets:
            validate_system_temp_path(root, path)
        clean(root, targets, apply)


def check_space(path):
    free = shutil.disk_usage(path).free
    print(f"Available build space at {path}: {free / 1024 ** 3:.1f} GiB", flush=True)
    if free < LOW_SPACE_BYTES:
        print("WARNING: Less than 20 GiB available; packaging may run out of space. "
              "Clean unused caches before building. --save-space only cleans after success.",
              file=sys.stderr)


def retained_group(root, path):
    validate_path(root, path)
    if path.parent == root / ".build-local" and path.is_dir():
        for group, pattern in RETAINED_GROUPS.items():
            if pattern.fullmatch(path.name):
                return group
    raise ValueError(f"Not a recognized worktree-local verification copy or install backup: {path}")


def lock_artifact(root, path, locks, create=False):
    marker = path / RETAINED_MARKER
    validate_path(root, marker)
    lock = locks.enter_context(marker.open("a+" if create else "r"))
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    # A cleanup could have removed the directory after open(), before flock().
    if not marker.exists() or os.fstat(lock.fileno()).st_ino != marker.stat().st_ino:
        raise ValueError(f"Artifact was removed or replaced: {path}")
    lock.seek(0)
    return lock


def retained_targets(root, locks, report_unmanaged=False):
    build = root / ".build-local"
    validate_path(root, build)
    if not build.is_dir():
        return []
    groups = {group: [] for group in RETAINED_GROUPS}
    for path in sorted(build.iterdir()):
        if not any(pattern.fullmatch(path.name) for pattern in RETAINED_GROUPS.values()):
            continue
        validate_path(root, path)
        if not path.is_dir():
            continue
        group = retained_group(root, path)
        marker = path / RETAINED_MARKER
        validate_path(root, marker)
        if not marker.exists():
            if report_unmanaged:
                print(f"Keeping unmanaged artifact (no completion record): {path}")
            continue
        try:
            lock = lock_artifact(root, path, locks)
        except BlockingIOError:
            print(f"Skipping active artifact: {path}")
            continue
        try:
            record = json.load(lock)
        except ValueError:
            print(f"Keeping unreadable artifact record: {path}", file=sys.stderr)
            continue
        expected = {"version": 1, "worktree": str(root), "group": group, "status": "completed"}
        if record != expected:
            print(f"Keeping incomplete or unrecognized artifact: {path}")
            continue
        groups[group].append((marker.stat().st_mtime_ns, path))
    # The lock covers cooperating runners; also preserve apps launched directly.
    if not any(len(entries) > RETAINED_COUNT for entries in groups.values()):
        return []
    try:
        processes = subprocess.check_output(["ps", "-ww", "-axo", "pid=,command="], text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Keeping retained artifacts: cannot check running processes: {error}", file=sys.stderr)
        return []
    commands = [row.split(None, 1)[1] for row in processes.splitlines()
                if len(row.split(None, 1)) == 2 and row.split(None, 1)[0] != str(os.getpid())]
    targets = []
    for entries in groups.values():
        inactive = []
        for entry in sorted(entries, reverse=True):
            path = entry[1]
            if any(str(path) in command for command in commands):
                print(f"Skipping running artifact: {path}")
            else:
                inactive.append(path)
        # Active/failed/unmanaged artifacts never evict a known-good backup.
        targets.extend(inactive[RETAINED_COUNT:])
    return targets


@contextlib.contextmanager
def managed_artifact(root, path):
    """Keep failed workflows; mark complete only after all consumers finish."""
    group = retained_group(root, path)
    with contextlib.ExitStack() as locks:
        try:
            lock = lock_artifact(root, path, locks, create=True)
        except BlockingIOError as error:
            raise ValueError(f"Artifact is already in use: {path}") from error
        record = {"version": 1, "worktree": str(root), "group": group, "status": "incomplete"}

        def write_record():
            lock.seek(0)
            lock.truncate()
            json.dump(record, lock)
            lock.flush()

        # Invalidate any previous success before rerunning a fixture or installer.
        write_record()
        try:
            yield
        except BaseException:
            print(f"Keeping failed artifact for investigation: {path}", file=sys.stderr)
            raise
        record["status"] = "completed"
        write_record()
    print(f"Completed artifact: {path}")


def use_artifact(root, path, command):
    """Opt in a known disposable directory; keep failures and hold its use lock."""
    if not command:
        raise ValueError("use-artifact requires a command after --")
    try:
        with managed_artifact(root, path):
            descriptor = inherited_lock(root)
            if descriptor is None:
                subprocess.run(command).check_returncode()
            else:
                run_child(command, descriptor)
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    with worktree_lock(root), contextlib.ExitStack() as locks:
        clean(root, retained_targets(root, locks), apply=True)
    return 0


def artifact_targets(root, current):
    dist = root / "dist"
    validate_path(root, current)
    match = ARTIFACT_NAME.fullmatch(current.name)
    if current.parent != dist or not match or not current.is_file():
        raise ValueError("--artifact must be an existing dist/CtrlX-<version>[-Debug].ipa or .dmg")
    for suffix in (".sha256", ".manifest.json"):
        metadata = Path(str(current) + suffix)
        validate_path(root, metadata)
        if not metadata.is_file():
            raise ValueError("Current artifact is missing integrity metadata; no pruning performed")
    candidates = [
        path for path in dist.iterdir()
        if ARTIFACT_NAME.fullmatch(path.name)
        and ARTIFACT_NAME.fullmatch(path.name).groupdict() == match.groupdict()
        and path.is_file() and not path.is_symlink() and path != current
    ]
    candidates.sort(key=lambda path: (path.stat().st_mtime_ns, path.name), reverse=True)
    targets = []
    # Always keep the just-built artifact plus the newest other package.
    for artifact in candidates[1:]:
        for suffix in ("", ".sha256", ".manifest.json", ".previous"):
            path = Path(str(artifact) + suffix)
            validate_path(root, path)
            if path.exists():
                if not path.is_file():
                    raise ValueError(f"Expected an artifact file: {path}")
                targets.append(path)
    return targets


def packaging_cache_targets(root, artifact, save_space=False):
    platform = "macOS" if artifact.suffix == ".dmg" else "iOS"
    return derived_cache_targets(root, root / ".build-local/DerivedData" / platform, save_space)


def derived_cache_targets(root, derived, save_space=False):
    targets = [derived / "Index.noindex"]
    # Packaging explicitly uses the shared -clonedSourcePackagesDirPath.
    # Old manual builds may have left a second dependency copy in DerivedData.
    shared = root / ".build-local/SourcePackages"
    validate_path(root, shared)
    checkouts = shared / "checkouts"
    validate_path(root, checkouts)
    if checkouts.is_dir() and any(checkouts.iterdir()):
        targets.append(derived / "SourcePackages")
    if save_space:
        targets.extend(derived / name for name in COMPILATION_CACHE_DIRS)
    for path in targets:
        validate_path(root, path)
    return [path for path in targets if path.exists()]


def test_cache_targets(root, save_space=False, idle=False):
    build = root / "CtrlxPackage/.build"
    validate_path(root, build)
    if not build.is_dir():
        return []
    targets = [build / "out/v5", build / "out/Index.noindex"]
    if save_space or idle:
        targets.extend(build / "out" / name for name in TEST_CACHE_DIRS)
    for triple in sorted(build.iterdir()):
        if not PACKAGE_TRIPLE.fullmatch(triple.name):
            continue
        validate_path(root, triple)
        for configuration in ("debug", "release"):
            marker = build / f".buildSystem_{configuration}"
            validate_path(root, marker)
            if idle or (marker.is_file() and marker.read_text().strip() == "swiftbuild"):
                targets.append(triple / configuration)
    for path in targets:
        validate_path(root, path)
    return [path for path in targets if path.exists()]


def idle_targets(root):
    targets = test_cache_targets(root, idle=True)
    derived = root / ".build-local/DerivedData"
    validate_path(root, derived)
    if derived.is_dir():
        targets += derived_cache_targets(root, derived, save_space=True)
        for platform in sorted(derived.iterdir()):
            validate_path(root, platform)
            if platform.is_dir() and platform not in targets:
                targets += derived_cache_targets(root, platform, save_space=True)
    return targets


def receipt_targets(root, locks):
    releases = root / "dist/qcloud-release"
    validate_path(root, releases)
    if not releases.is_dir():
        return []
    targets = []
    for stage in sorted(releases.iterdir()):
        if not RELEASE_DIRECTORY.fullmatch(stage.name):
            continue
        validate_path(root, stage)
        if not stage.is_dir():
            continue
        lock_path = stage / "publish.lock"
        validate_path(root, lock_path)
        if lock_path.exists():
            lock = locks.enter_context(lock_path.open("r"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(f"Skipping active publication: {stage}")
                continue
        reports = [path for path in stage.iterdir() if PUBLISH_REPORT.fullmatch(path.name)]
        for path in reports:
            validate_path(root, path)
        if not reports:
            continue
        latest = max(reports, key=lambda path: (path.stat().st_mtime_ns, path.name))
        try:
            report = json.loads(latest.read_text())
        except (OSError, ValueError) as error:
            print(f"Skipping unreadable publication report {latest}: {error}", file=sys.stderr)
            continue
        if not isinstance(report, dict) or report.get("status") not in ("published", "already published; verified"):
            continue
        version = stage.name[1:] if stage.name.startswith("v") else stage.name
        artifact = f"CtrlX-{version}.dmg"
        checksum = report.get("sha256", "")
        if report.get("version") != version or report.get("artifact") != artifact \
                or not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            continue
        public = stage / f"public-{artifact}"
        validate_path(root, public)
        if not public.is_file():
            continue
        digest = hashlib.sha256()
        with public.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != checksum:
            print(f"Keeping mismatched public download for investigation: {public}", file=sys.stderr)
            continue
        targets.append(public)
    return targets


def deep_targets(root):
    targets = [root / name for name in DEEP_CACHE_DIRS]
    for path in targets:
        validate_path(root, path)
    return [path for path in targets if path.exists()]


def completed_targets(root):
    targets = []
    for name in COMPLETED_ARTIFACT_DIRS:
        parent = root / name
        validate_path(root, parent)
        if not parent.is_dir():
            continue
        for directory in sorted(parent.iterdir()):
            marker = directory / COMPLETED_MARKER
            if not directory.is_dir() or not marker.is_file():
                continue
            validate_path(root, directory)
            validate_path(root, marker)
            targets.append(directory)
    return targets


def clean(root, targets, apply):
    # Validate the entire plan before deleting anything.
    for path in targets:
        validate_path(root, path)
    for path in targets:
        print(f"{'Removing' if apply else 'Would remove'}: {path}", flush=True)
        if apply:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    if not targets:
        print("Nothing to clean.")
    elif not apply:
        print("Preview only. Re-run with --yes to delete these listed paths.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prune = modes.add_parser("prune", help="Keep two packages per platform/configuration and clean packaging leftovers")
    prune.add_argument("--artifact", type=Path, help="Just-built package to protect; omit for App-only builds")
    prune.add_argument("--platform", choices=("iOS", "macOS"), help="Also clean that local packaging DerivedData")
    prune.add_argument("--save-space", action="store_true", help="Also remove platform compilation caches; keep products and downloads")
    prune.add_argument("--yes", action="store_true", help="Delete the listed old packages")
    receipts = modes.add_parser("receipts", help="Remove verified public DMG copies; keep publication reports")
    receipts.add_argument("--yes", action="store_true", help="Delete the listed verified copies")
    retained = modes.add_parser("retained", help="Keep the two latest completed verification copies and install backups per kind")
    retained.add_argument("--yes", action="store_true", help="Delete only recorded, completed artifacts that are not in use")
    use = modes.add_parser("use-artifact", help="Run with an artifact use lock; on success, prune to two completed copies per kind")
    use.add_argument("--path", required=True, type=Path, help="Recognized .build-local verification or backup directory")
    use.add_argument("command", nargs=argparse.REMAINDER, help="Command after --; must finish using the artifact before returning")
    housekeeping = modes.add_parser("housekeeping", help="Clean completed backups/diagnostics and verified downloads; keep build caches")
    housekeeping.add_argument("--yes", action="store_true", help="Delete the listed completed artifacts")
    deep = modes.add_parser("deep", help="Remove build caches; preserve dist, signing config and user data")
    deep.add_argument("--yes", action="store_true", help="Delete the listed caches")
    tests = modes.add_parser("tests", help="Remove obsolete native backend outputs and test indexes; keep swiftbuild caches")
    tests.add_argument("--save-space", action="store_true", help="Also remove test compilation caches; keep products and downloads")
    tests.add_argument("--yes", action="store_true", help="Delete the listed test caches")
    idle = modes.add_parser("idle", help="Remove compilation caches in an idle worktree; keep signed apps, packages and downloads")
    idle.add_argument("--yes", action="store_true", help="Delete the listed caches after stopping this worktree's builds and installs")
    temporary = modes.add_parser("system-temp", help="Clean stale CtrlX signing clones and legacy E2E compilation caches in macOS user temp")
    temporary.add_argument("--yes", action="store_true", help="Delete the listed inactive, allowlisted system temporary caches")
    space = modes.add_parser("check-space", help="Warn when less than 20 GiB is available; never delete anything")
    space.add_argument("--path", required=True, type=Path, help="Existing build-volume directory to check")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    git_root = Path(subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True,
    ).strip()).resolve()
    if root != git_root:
        raise ValueError("Cleanup script must live in a Git worktree root's scripts directory")
    if args.mode == "check-space":
        check_space(args.path)
        return
    if args.mode == "system-temp":
        clean_system_temp(args.yes)
        return
    if args.mode == "use-artifact":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        return use_artifact(root, args.path.absolute(), command)
    with contextlib.ExitStack() as locks:
        if args.yes:
            locks.enter_context(worktree_lock(root))
        if args.mode in ("deep", "idle", "tests"):
            print("Stop builds, packaging and device installs in this worktree before deleting caches.")
            if args.mode == "deep":
                print("Built installable apps will be removed; IPA/DMG files in dist are preserved.")
                targets = deep_targets(root)
            elif args.mode == "idle":
                targets = idle_targets(root)
                targets += retained_targets(root, locks, report_unmanaged=True)
                targets += receipt_targets(root, locks)
            else:
                targets = test_cache_targets(root, args.save_space)
        elif args.mode == "prune":
            if args.save_space and not args.platform:
                raise ValueError("--save-space requires --platform")
            if not args.artifact and not args.platform:
                raise ValueError("prune requires --artifact or --platform")
            artifact = args.artifact.absolute() if args.artifact else None
            targets = artifact_targets(root, artifact) if artifact else []
            if args.platform:
                if artifact and args.platform != ("macOS" if artifact.suffix == ".dmg" else "iOS"):
                    raise ValueError("--platform does not match the artifact")
                targets += derived_cache_targets(root, root / ".build-local/DerivedData" / args.platform, args.save_space)
            targets += receipt_targets(root, locks)
            targets += retained_targets(root, locks)
            targets += completed_targets(root)
        elif args.mode == "retained":
            targets = retained_targets(root, locks, report_unmanaged=True)
        elif args.mode == "housekeeping":
            targets = receipt_targets(root, locks) + completed_targets(root)
        else:
            targets = receipt_targets(root, locks)
        clean(root, targets, args.yes)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
