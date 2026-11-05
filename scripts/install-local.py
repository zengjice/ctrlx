#!/usr/bin/env python3
"""Build/sign and install CtrlX locally; never publish or uninstall user data."""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import local_build as build
from local_build import app_info, verify_app


ROOT = Path(__file__).resolve().parent.parent
MAC_APP = Path("/Applications/CtrlX.app")
SPEC = importlib.util.spec_from_file_location("clean_build", ROOT / "scripts/clean-build.py")
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


def run(*arguments, **kwargs):
    return subprocess.run([str(arg) for arg in arguments], check=True, **kwargs)


@contextlib.contextmanager
def install_lock(path):
    if path.is_symlink():
        raise ValueError(f"Refusing symlink lock: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError(f"Another local installation is running: {path}") from error
        yield


def app_processes(app):
    # Match the installed main executable, not same-named isolated test apps/helpers.
    output = run("/bin/ps", "-ww", "-axo", "pid=,uid=,comm=", capture_output=True, text=True, timeout=10).stdout
    executable = str(app / "Contents/MacOS/CtrlX")
    matches = []
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[2] == executable:
            if int(fields[1]) != os.getuid():
                raise ValueError("CtrlX is running under another user; existing App was not replaced.")
            matches.append(int(fields[0]))
    return matches


def quit_mac(app):
    if not app_processes(app):
        return
    # A timeout never authorizes a forced kill or replacing a running executable.
    # AppShutdownDelegate allows 30 seconds for cleanup; leave time for AppKit exit.
    deadline = time.monotonic() + 45
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", f'tell application "{app}" to quit'],
                                capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("CtrlX Quit request timed out after 45 seconds; existing App was not replaced.") from error
    while app_processes(app):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"CtrlX did not finish cleanup; existing App was not replaced. {result.stderr.strip()}")
        time.sleep(0.25)


def launch_mac(app):
    run("/usr/bin/open", "-a", app)
    deadline = time.monotonic() + 15
    while not app_processes(app):
        if time.monotonic() >= deadline:
            raise RuntimeError("New App was installed but launch could not be confirmed; rollback backup was kept.")
        time.sleep(0.25)


def replace_mac(source, info, backup, target):
    # Same-volume staging allows rename/rollback without ever merging App bundles.
    with tempfile.TemporaryDirectory(prefix=".ctrlx-install.", dir=target.parent) as temporary:
        stage = Path(temporary)
        incoming = stage / "CtrlX.app"
        previous = stage / "previous.app"
        run("/usr/bin/ditto", source, incoming)
        verify_app(incoming, "macos", info)
        quit_mac(target)
        if target.exists():
            run("/usr/bin/ditto", target, backup / "CtrlX.app")
        try:
            if target.exists():
                target.rename(previous)
            incoming.rename(target)
            verify_app(target, "macos", info)
        except BaseException:
            if target.exists() and not incoming.exists():
                target.rename(incoming)
            if previous.exists():
                previous.rename(target)
            raise
    # Never roll back a potentially running new App. Keep the backup on launch failure.
    launch_mac(target)


def install_mac(root, source, info, target=MAC_APP):
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise ValueError(f"Refusing non-directory installation target: {target}")
    if target.exists():
        previous_id = app_info(target, "macos").get("CFBundleIdentifier")
        if previous_id != info['CFBundleIdentifier'] and (previous_id, info['CFBundleIdentifier']) != (
                'com.jicezeng.ctrlx.macos', 'com.gravtice.ctrlx.macos'):
            raise ValueError("Installed App has a different bundle ID; refusing to replace it.")
    backup = Path(tempfile.mkdtemp(prefix="mac-install-backup.", dir=root / ".build-local"))
    print(f"Rollback backup: {backup}", flush=True)
    with storage.managed_artifact(root, backup):
        replace_mac(source, info, backup, target)


def install_ios(app, info, device, initial_preferences=None):
    if initial_preferences is not None:
        if initial_preferences.is_symlink() or not initial_preferences.is_file():
            raise ValueError('Initial preferences must be a regular plist file.')
        if not isinstance(plistlib.loads(initial_preferences.read_bytes()), dict):
            raise ValueError('Initial preferences must contain a dictionary.')
        result = run('/usr/bin/xcrun', 'devicectl', 'device', 'info', 'apps', '--device', device,
                     '--include-all-apps', '--bundle-id', info['CFBundleIdentifier'], '--json-output', '-',
                     capture_output=True, text=True)
        if any(item['bundleIdentifier'] == info['CFBundleIdentifier']
               for item in json.loads(result.stdout)['result']['apps']):
            raise ValueError('Initial preferences cannot overwrite an installed App; its data was retained.')
    run("/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", device,
        "--timeout", "180", app)
    if initial_preferences is not None:
        run('/usr/bin/xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device,
            '--source', initial_preferences.resolve(), '--domain-type', 'appDataContainer',
            '--domain-identifier', info['CFBundleIdentifier'],
            '--destination', f"Library/Preferences/{info['CFBundleIdentifier']}.plist", '--timeout', '60')
    run("/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", device,
        "--timeout", "60", "--terminate-existing", info["CFBundleIdentifier"])


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    platforms = result.add_subparsers(dest="platform", required=True)
    for platform in ("macos", "ios"):
        command = platforms.add_parser(platform)
        command.add_argument("--skip-build", action="store_true", help="Install a recorded, signed App build; no DMG/IPA required")
        caches = command.add_mutually_exclusive_group()
        caches.add_argument("--save-space", action="store_true", help="Remove compilation caches only after installation/launch succeeds")
        command.set_defaults(save_space=False)
        if platform == "ios":
            caches.add_argument("--keep-build-cache", dest="save_space", action="store_false", help="Retain compilation caches for repeated iOS builds (default)")
            command.add_argument("--device", required=True, type=uuid.UUID, help="CoreDevice UUID from xcrun devicectl list devices")
            command.add_argument("--configuration", choices=("Release", "Debug"), default="Release")
            command.add_argument('--signing-mode', choices=('development', 'ad-hoc'),
                                 help='Override Local.xcconfig signing mode when building; Ad Hoc uses production APNs')
            command.add_argument('--initial-preferences', type=Path,
                                 help='Import a UserDefaults plist before first launch; refuses an already installed App')
        else:
            command.set_defaults(configuration="Release", device=None)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    root = ROOT
    git_root = run("git", "-C", root, "rev-parse", "--show-toplevel", capture_output=True, text=True).stdout.strip()
    if Path(git_root).resolve() != root:
        raise ValueError("Run the installer from a Git worktree's scripts directory.")
    if sys.platform != "darwin":
        raise ValueError("Local App installation requires macOS.")
    storage.validate_path(root, root / ".build-local")
    with contextlib.ExitStack() as locks:
        descriptor = locks.enter_context(build.worktree_lock(root))
        # All worktrees target the same Mac App / physical device, so serialize those too.
        target = "macos" if args.platform == "macos" else str(args.device)
        locks.enter_context(install_lock(Path.home() / "Library/Caches/CtrlX" / f"local-install-{target}.lock"))
        if args.platform == "ios":
            run("/usr/bin/xcrun", "devicectl", "device", "info", "details", "--device", args.device, "--timeout", "30")
        if not args.skip_build:
            command = ["bash", root / "scripts" / f"package-local-{args.platform}.sh", "--app-only"]
            if args.platform == "ios":
                command += ["--configuration", args.configuration]
                if args.signing_mode is not None:
                    command += ['--signing-mode', args.signing_mode]
                command.append("--save-space" if args.save_space else "--keep-build-cache")
            # Keep compile caches on install failure, even with --save-space.
            build.run_child(command, descriptor, defer_cleanup=True, cwd=root)
        app, info = build.built_app(root, args.platform, args.configuration)
        if args.platform == 'ios':
            result = run('/usr/bin/security', 'cms', '-D', '-i', app / 'embedded.mobileprovision',
                         capture_output=True)
            profile = plistlib.loads(result.stdout)
            if not profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
                raise ValueError('Local installation requires a development or Ad Hoc device profile.')
            environment = profile['Entitlements'].get('aps-environment', 'unconfigured')
            mode = 'development' if profile['Entitlements'].get('get-task-allow') else 'ad-hoc'
            if args.signing_mode is not None and mode != args.signing_mode:
                raise ValueError('Recorded App signing mode differs from --signing-mode; rebuild it.')
            print(f"iOS signing: {mode} · APNs: {environment} · profile: {profile['Name']}", flush=True)
        print(f"Installing {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) · "
              f"{info['CtrlXBuildStamp']} · {info['CtrlXSourceRevision']}\nApp: {app}", flush=True)
        if args.platform == "macos":
            install_mac(root, app, info)
        else:
            if args.initial_preferences is None:
                install_ios(app, info, str(args.device))
            else:
                install_ios(app, info, str(args.device), args.initial_preferences)
        print("Installed and launched. Applying worktree-local retention.", flush=True)
        command = [sys.executable, root / "scripts/clean-build.py", "prune",
                   "--platform", "macOS" if args.platform == "macos" else "iOS", "--yes"]
        if args.save_space:
            command.append("--save-space")
        build.run_child(command, descriptor, cwd=root)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Installation interrupted; incomplete backups are kept.", file=sys.stderr)
        sys.exit(130)
