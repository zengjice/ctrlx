"""Internal helpers shared by local build, packaging, installation and cleanup."""
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
import signal
import subprocess
import sys
import tempfile
import zipfile


LOCK_ENV = "CTRLX_BUILD_LOCK_FD"
IDENTITY_KEYS = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                 "CtrlXBuildStamp", "CtrlXSourceRevision")


def validate_path(root, path):
    relative = path.relative_to(root)
    if not relative.parts or ".." in relative.parts:
        raise ValueError(f"Not a worktree-local target: {path}")
    for count in range(1, len(relative.parts) + 1):
        parent = root.joinpath(*relative.parts[:count])
        if parent.is_symlink():
            raise ValueError(f"Refusing a symlink target: {parent}")


def inherited_lock(root):
    value = os.environ.get(LOCK_ENV)
    if value is None:
        return None
    path = root / ".build-local/operation.lock"
    validate_path(root, path)
    try:
        descriptor = int(value)
        opened, expected = os.fstat(descriptor), path.stat()
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise ValueError("Inherited build lock belongs to another worktree.")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return descriptor
    except OSError as error:
        raise ValueError("Invalid inherited build lock.") from error


@contextlib.contextmanager
def worktree_lock(root):
    borrowed = inherited_lock(root)
    if borrowed is not None:
        yield borrowed  # The outer operation owns the lock; never unlock it here.
        return
    path = root / ".build-local/operation.lock"
    validate_path(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError(f"Another build, install or cleanup is running in {root}") from error
        yield lock.fileno()


def run_child(command, descriptor, defer_cleanup=False, **kwargs):
    environment = dict(os.environ, **{LOCK_ENV: str(descriptor)})
    if defer_cleanup:
        environment["CTRLX_DEFER_BUILD_CLEANUP"] = "1"
    return subprocess.run([str(arg) for arg in command], env=environment,
                          pass_fds=(descriptor,), check=True, **kwargs)


def app_path(root, platform, configuration):
    if platform not in ("macos", "ios") or configuration not in ("Release", "Debug"):
        raise ValueError("Unsupported App platform/configuration.")
    if platform == "macos" and configuration != "Release":
        raise ValueError("Local Mac packaging supports Release only.")
    folder = "macOS" if platform == "macos" else "iOS"
    product = "Release" if platform == "macos" else f"{configuration}-iphoneos"
    return root / f".build-local/DerivedData/{folder}/Build/Products/{product}/CtrlX.app"


def app_info(app, platform):
    with (app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")).open("rb") as source:
        return plistlib.load(source)


def verify_app(app, platform, expected=None):
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"Expected a real App directory: {app}")
    info = app_info(app, platform)
    if (info.get("CFBundleExecutable") != "CtrlX"
            or info.get("DTPlatformName") != ("macosx" if platform == "macos" else "iphoneos")):
        raise ValueError(f"Not a CtrlX {platform} build: {app}")
    for key in IDENTITY_KEYS:
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError(f"Missing build identity {key}: {app}")
        if expected is not None and info[key] != expected[key]:
            raise ValueError(f"App build identity mismatch ({key}): {app}")
    if platform == "ios":
        extension = app / "PlugIns/CtrlxNotificationExtension.appex"
        if not (app / "embedded.mobileprovision").is_file() or not (extension / "embedded.mobileprovision").is_file():
            raise ValueError("Missing signed app/notification extension profiles; build the device App first.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return info


def app_record_path(root, platform, configuration):
    app = app_path(root, platform, configuration)
    record = Path(str(app) + ".build.json")
    validate_path(root, app)
    validate_path(root, record)
    return record


def invalidate_app(root, platform, configuration):
    app_record_path(root, platform, configuration).unlink(missing_ok=True)


def record_app(root, platform, configuration, stamp, revision):
    app = app_path(root, platform, configuration)
    record = app_record_path(root, platform, configuration)
    info = verify_app(app, platform)
    if info["CtrlXBuildStamp"] != stamp or info["CtrlXSourceRevision"] != revision:
        raise ValueError("Signed App does not match this build's stamp/revision.")
    data = {"schema": 1, "worktree": str(root), "platform": platform, "configuration": configuration,
            "identity": {key: info[key] for key in IDENTITY_KEYS}}
    with tempfile.TemporaryDirectory(prefix=".app-record.", dir=record.parent) as temporary:
        staged = Path(temporary) / record.name
        staged.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(staged, record)


def built_app(root, platform, configuration):
    record = app_record_path(root, platform, configuration)
    if not record.is_file():
        raise ValueError("No completed App build record. Run again without --skip-build.")
    data = json.loads(record.read_text())
    expected = {"schema": 1, "worktree": str(root), "platform": platform, "configuration": configuration}
    if not isinstance(data, dict) or any(data.get(key) != value for key, value in expected.items()):
        raise ValueError("App build record has a different worktree/platform/configuration.")
    identity = data.get("identity", {})
    if not isinstance(identity, dict) or set(identity) != set(IDENTITY_KEYS):
        raise ValueError("Invalid App build identity record.")
    app = app_path(root, platform, configuration)
    return app, verify_app(app, platform, identity)


def publish_package(root, staged, artifact):
    """Validate before replacing; retain/restore the old package and all sidecars."""
    if artifact.parent != root / "dist" or not re.fullmatch(r"CtrlX-\d+\.\d+\.\d+(?:-Debug)?\.(?:dmg|ipa)", artifact.name):
        raise ValueError("Expected a versioned CtrlX package in this worktree's dist directory.")
    if staged.name != artifact.name or staged == artifact:
        raise ValueError("Package must be staged separately with the final file name.")
    pairs = [(Path(str(staged) + suffix), Path(str(artifact) + suffix))
             for suffix in ("", ".sha256", ".manifest.json")]
    for source, target in pairs:
        validate_path(root, source)
        validate_path(root, target)
        if not source.is_file() or (target.exists() and not target.is_file()):
            raise ValueError(f"Expected regular package files: {source}, {target}")
    manifest = json.loads(pairs[2][0].read_text())
    digest = hashlib.sha256()
    with staged.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if (not isinstance(manifest, dict) or manifest.get("artifact") != artifact.name or manifest.get("sha256") != digest.hexdigest()
            or pairs[1][0].read_text().split()[:1] != [digest.hexdigest()]):
        raise ValueError("Staged package integrity metadata does not match.")
    if artifact.suffix == ".ipa":
        with zipfile.ZipFile(staged) as archive:
            if archive.testzip() is not None:
                raise ValueError("Staged IPA failed its CRC check.")
    artifact.parent.mkdir(exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=".package-replace.", dir=artifact.parent))
    replaced = []
    keep_backup = False
    try:
        for _, target in pairs:
            if target.exists():
                os.link(target, backup / target.name)
        try:
            for source, target in pairs:
                os.replace(source, target)
                replaced.append(target)
        except BaseException:
            try:
                for target in reversed(replaced):
                    previous = backup / target.name
                    if previous.exists():
                        os.replace(previous, target)
                    else:
                        target.unlink()
            except OSError as error:
                keep_backup = True
                raise RuntimeError(f"Package rollback failed; old files retained at {backup}") from error
            raise
    finally:
        if not keep_backup:
            shutil.rmtree(backup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("lock-held")
    runner = modes.add_parser("run")
    runner.add_argument("command", nargs=argparse.REMAINDER)
    for name in ("invalidate-app", "record-app"):
        command = modes.add_parser(name)
        command.add_argument("--platform", choices=("macos", "ios"), required=True)
        command.add_argument("--configuration", choices=("Release", "Debug"), default="Release")
        if name == "record-app":
            command.add_argument("--stamp", required=True)
            command.add_argument("--revision", required=True)
    publish = modes.add_parser("publish-package")
    publish.add_argument("--staged", type=Path, required=True)
    publish.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.mode == "lock-held":
        return 0 if inherited_lock(root) is not None else 1
    with worktree_lock(root) as descriptor:
        if args.mode == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                raise ValueError("Missing command after --")
            run_child(command, descriptor)
        elif args.mode == "invalidate-app":
            invalidate_app(root, args.platform, args.configuration)
        elif args.mode == "record-app":
            record_app(root, args.platform, args.configuration, args.stamp, args.revision)
        else:
            publish_package(root, args.staged.absolute(), args.artifact.absolute())
    return 0


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode > 0 else 128 - error.returncode)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
