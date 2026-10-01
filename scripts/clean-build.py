#!/usr/bin/env python3
"""Worktree-local build cleanup. Preview by default; --yes enables deletion."""
import argparse
import contextlib
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


ARTIFACT_NAME = re.compile(r"CtrlX-[0-9]+\.[0-9]+\.[0-9]+(?P<configuration>-Debug)?\.(?P<platform>ipa|dmg)")
RELEASE_DIRECTORY = re.compile(r"v?[0-9]+\.[0-9]+\.[0-9]+")
PUBLISH_REPORT = re.compile(r"publish-report(?:-[0-9]+)?\.json")
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


def validate_path(root, path):
    relative = path.relative_to(root)
    if not relative.parts or ".." in relative.parts:
        raise ValueError(f"Not a worktree-local cleanup target: {path}")
    for count in range(1, len(relative.parts) + 1):
        parent = root.joinpath(*relative.parts[:count])
        if parent.is_symlink():
            raise ValueError(f"Refusing a symlink cleanup target: {parent}")


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


def packaging_cache_targets(root, artifact):
    platform = "macOS" if artifact.suffix == ".dmg" else "iOS"
    derived = root / ".build-local/DerivedData" / platform
    targets = [derived / "Index.noindex"]
    # Packaging explicitly uses the shared -clonedSourcePackagesDirPath.
    # Old manual builds may have left a second dependency copy in DerivedData.
    shared = root / ".build-local/SourcePackages"
    validate_path(root, shared)
    if shared.is_dir():
        targets.append(derived / "SourcePackages")
    for path in targets:
        validate_path(root, path)
    return [path for path in targets if path.exists()]


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
        print("Preview only. Re-run with --yes to delete these rebuildable files.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prune = modes.add_parser("prune", help="Keep two packages per platform/configuration and clean packaging leftovers")
    prune.add_argument("--artifact", required=True, type=Path, help="Just-built package to protect")
    prune.add_argument("--platform", choices=("iOS", "macOS"), help="Also clean that local packaging DerivedData")
    prune.add_argument("--yes", action="store_true", help="Delete the listed old packages")
    receipts = modes.add_parser("receipts", help="Remove verified public DMG copies; keep publication reports")
    receipts.add_argument("--yes", action="store_true", help="Delete the listed verified copies")
    deep = modes.add_parser("deep", help="Remove build caches; preserve dist, signing config and user data")
    deep.add_argument("--yes", action="store_true", help="Delete the listed caches")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    git_root = Path(subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True,
    ).strip()).resolve()
    if root != git_root:
        raise ValueError("Cleanup script must live in a Git worktree root's scripts directory")
    with contextlib.ExitStack() as locks:
        if args.mode == "deep":
            print("Stop builds, packaging and device installs in this worktree before deleting caches.")
            print("Built installable apps will be removed; IPA/DMG files in dist are preserved.")
            targets = deep_targets(root)
        elif args.mode == "prune":
            artifact = args.artifact.absolute()
            targets = artifact_targets(root, artifact)
            if args.platform:
                expected = "macOS" if artifact.suffix == ".dmg" else "iOS"
                if args.platform != expected:
                    raise ValueError("--platform does not match the artifact")
                targets += packaging_cache_targets(root, artifact)
            targets += receipt_targets(root, locks)
        else:
            targets = receipt_targets(root, locks)
        clean(root, targets, args.yes)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
