#!/usr/bin/env python3
"""Worktree-local build cleanup. Preview by default; --yes enables deletion."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


ARTIFACT_NAME = re.compile(r"CtrlX-[0-9]+\.[0-9]+\.[0-9]+\.(ipa|dmg)")
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
        raise ValueError("--artifact must be an existing dist/CtrlX-<version>.ipa or .dmg")
    if not Path(str(current) + ".sha256").is_file() or not Path(str(current) + ".manifest.json").is_file():
        raise ValueError("Current artifact is missing integrity metadata; no pruning performed")
    candidates = [
        path for path in dist.iterdir()
        if ARTIFACT_NAME.fullmatch(path.name) and path.suffix == current.suffix
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
    prune = modes.add_parser("prune", help="Keep two local packages of one platform and their metadata")
    prune.add_argument("--artifact", required=True, type=Path, help="Just-built package to protect")
    prune.add_argument("--yes", action="store_true", help="Delete the listed old packages")
    deep = modes.add_parser("deep", help="Remove build caches; preserve dist, signing config and user data")
    deep.add_argument("--yes", action="store_true", help="Delete the listed caches")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    git_root = Path(subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True,
    ).strip()).resolve()
    if root != git_root:
        raise ValueError("Cleanup script must live in a Git worktree root's scripts directory")
    if args.mode == "deep":
        print("Stop builds, packaging and device installs in this worktree before deleting caches.")
        print("Built installable apps will be removed; IPA/DMG files in dist are preserved.")
        targets = deep_targets(root)
    else:
        targets = artifact_targets(root, args.artifact.absolute())
    clean(root, targets, args.yes)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
