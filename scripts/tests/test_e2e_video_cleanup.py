#!/usr/bin/env python3
"""Unit tests for e2e_video_cleanup.py.

Run: python3 scripts/tests/test_e2e_video_cleanup.py
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e_video_cleanup as vc

NOW = datetime(2026, 7, 2, 12, 0, 0, tzinfo=timezone.utc)


class AssetPRNumber(unittest.TestCase):
    def test_parses_pr_number(self):
        self.assertEqual(vc.asset_pr_number("pr626-subagent-stop-ignored-failing.mp4"), 626)

    def test_parses_pr_number_without_label(self):
        self.assertEqual(vc.asset_pr_number("pr622-window-description-sync.mp4"), 622)

    def test_rejects_non_video_extension(self):
        self.assertIsNone(vc.asset_pr_number("pr626-notes.txt"))

    def test_rejects_missing_prefix(self):
        self.assertIsNone(vc.asset_pr_number("subagent-stop-ignored.mp4"))

    def test_rejects_bare_pr_number(self):
        self.assertIsNone(vc.asset_pr_number("pr626.mp4"))


class Eligibility(unittest.TestCase):
    def closed_at(self, days_ago):
        return (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_merged_past_grace_is_eligible(self):
        self.assertTrue(vc.is_eligible("MERGED", self.closed_at(4), 3, NOW))

    def test_closed_past_grace_is_eligible(self):
        self.assertTrue(vc.is_eligible("CLOSED", self.closed_at(4), 3, NOW))

    def test_open_is_never_eligible(self):
        self.assertFalse(vc.is_eligible("OPEN", None, 3, NOW))

    def test_merged_within_grace_is_not_eligible(self):
        self.assertFalse(vc.is_eligible("MERGED", self.closed_at(2), 3, NOW))

    def test_boundary_just_past_grace(self):
        just_past = NOW - timedelta(days=3, minutes=1)
        self.assertTrue(
            vc.is_eligible("MERGED", just_past.strftime("%Y-%m-%dT%H:%M:%SZ"), 3, NOW)
        )

    def test_missing_closed_at_is_not_eligible(self):
        self.assertFalse(vc.is_eligible("CLOSED", None, 3, NOW))


BODY = """## 🎬 E2E Video Proof

Fix verification: the scenario passes.

- **▶ [Subagent Stop Ignored (passing)](https://github.com/example/ctrlx-results/releases/download/e2e-videos/pr626-subagent-stop-ignored-passing.mp4)** — 3s (speedup), 23 steps

_Ephemeral release asset(s) on example/ctrlx-results (`e2e-videos` prerelease) — not part of any repo's git history; may be deleted after review._"""

URL = (
    "https://github.com/example/ctrlx-results/releases/download/"
    "e2e-videos/pr626-subagent-stop-ignored-passing.mp4"
)

BODY_WITH_HINT = """## 🎬 E2E Video Proof

Fix verification: the scenario passes.

- **▶ [Subagent Stop Ignored (passing)](https://github.com/example/ctrlx-results/releases/download/e2e-videos/pr626-subagent-stop-ignored-passing.mp4)** — 3s (speedup), 23 steps
  - watch: `./scripts/e2e-watch-video.sh pr626-subagent-stop-ignored-passing.mp4`

_Ephemeral release asset(s) on example/ctrlx-results (`e2e-videos` prerelease) — not part of any repo's git history; may be deleted after review._"""


class RewriteComment(unittest.TestCase):
    def test_strikes_link_and_appends_note(self):
        new_body = vc.rewrite_comment(BODY, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertTrue(new_body.endswith(vc.DELETED_NOTE))

    def test_untouched_urls_stay_linked(self):
        two_links = BODY + (
            "\n- **▶ [Other](https://github.com/example/ctrlx-results/"
            "releases/download/e2e-videos/pr626-other.mp4)** — 5s"
        )
        new_body = vc.rewrite_comment(two_links, [URL])
        self.assertIn("[Other](", new_body)
        self.assertIn("~~Subagent Stop Ignored (passing)~~", new_body)

    def test_no_matching_url_returns_none(self):
        self.assertIsNone(vc.rewrite_comment(BODY, ["https://example.com/nope.mp4"]))

    def test_rewrite_is_idempotent(self):
        once = vc.rewrite_comment(BODY, [URL])
        self.assertIsNone(vc.rewrite_comment(once, [URL]))

    def test_note_appended_once_for_multiple_links(self):
        other_url = (
            "https://github.com/example/ctrlx-results/releases/download/"
            "e2e-videos/pr626-other.mp4"
        )
        two_links = BODY + f"\n- **▶ [Other]({other_url})** — 5s"
        new_body = vc.rewrite_comment(two_links, [URL, other_url])
        self.assertEqual(new_body.count(vc.DELETED_NOTE), 1)

    def test_strikes_watch_hint_alongside_link(self):
        new_body = vc.rewrite_comment(BODY_WITH_HINT, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertIn(
            "  - watch: ~~`./scripts/e2e-watch-video.sh "
            "pr626-subagent-stop-ignored-passing.mp4`~~",
            new_body,
        )

    def test_watch_hint_rewrite_is_idempotent(self):
        once = vc.rewrite_comment(BODY_WITH_HINT, [URL])
        self.assertIsNone(vc.rewrite_comment(once, [URL]))

    def test_no_hint_line_still_strikes_link_only(self):
        # Comments without watch-hint (pre-watch-hint format) still get struck.
        new_body = vc.rewrite_comment(BODY, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertNotIn("watch:", new_body)


class GroupAssets(unittest.TestCase):
    def test_groups_by_pr_and_skips_non_matching(self):
        assets = [
            "pr622-window-description-sync.mp4",
            "pr622-cursor-style-changes.mp4",
            "pr626-subagent-stop-ignored-failing.mp4",
            "README.md",
        ]
        self.assertEqual(
            vc.group_assets_by_pr(assets),
            {
                622: [
                    "pr622-window-description-sync.mp4",
                    "pr622-cursor-style-changes.mp4",
                ],
                626: ["pr626-subagent-stop-ignored-failing.mp4"],
            },
        )


class RepositoryConfiguration(unittest.TestCase):
    def test_missing_targets_fail_before_github_calls(self):
        for env in ({}, {"RESULTS_REPO": "test/results"}, {"GITHUB_REPOSITORY": "test/ctrlx"}):
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), patch.object(vc, "run_gh") as gh:
                with self.assertRaises(SystemExit) as raised:
                    vc.main(["--dry-run"])
                self.assertEqual(raised.exception.code, 2)
                gh.assert_not_called()

    def test_invalid_targets_fail_before_github_calls(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(vc, "run_gh") as gh:
            with self.assertRaises(SystemExit):
                vc.main(["--repo", "https://github.com/test/ctrlx", "--results-repo", "test/results"])
            gh.assert_not_called()

    def test_ci_targets_come_from_the_current_repository_and_explicit_results_setting(self):
        env = {"GITHUB_REPOSITORY": "test/ctrlx", "RESULTS_REPO": "test/results",
               "GITHUB_ACTIONS": "true", "RESULTS_REPO_TOKEN": "test-token"}
        with patch.dict(os.environ, env, clear=True), patch.object(vc, "list_release_assets", return_value=[]) as assets:
            self.assertEqual(vc.main(["--dry-run"]), 0)
            assets.assert_called_once_with("test/results", "e2e-videos", "test-token")

    def test_cli_targets_override_environment(self):
        env = {"GITHUB_REPOSITORY": "env/ctrlx", "RESULTS_REPO": "env/results"}
        with patch.dict(os.environ, env, clear=True), \
             patch.object(vc, "list_release_assets", return_value=["pr1-smoke.mp4"]) as assets, \
             patch.object(vc, "pr_state", return_value={"state": "OPEN", "closedAt": None}) as pr:
            self.assertEqual(vc.main(["--repo", "cli/ctrlx", "--results-repo", "cli/results", "--dry-run"]), 0)
            assets.assert_called_once_with("cli/results", "e2e-videos", None)
            pr.assert_called_once_with("cli/ctrlx", 1)


class VideoScriptConfiguration(unittest.TestCase):
    def test_generated_watch_command_preserves_upload_destination(self):
        source_scripts = Path(__file__).resolve().parents[1]
        for inherited_repo, release_tag in ((None, "e2e-videos"),
                                            (None, "proof-$take"),
                                            ("other/results", "proof-$take")):
            with self.subTest(repo=inherited_repo, tag=release_tag), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts = root / "scripts"
                scripts.mkdir()
                for name in ("e2e-attach-video.sh", "e2e-watch-video.sh", "e2e-video-player.html"):
                    shutil.copyfile(source_scripts / name, scripts / name)
                    (scripts / name).chmod(0o755)
                video_dir = root / "smoke"
                video_dir.mkdir()
                (video_dir / "video.mp4").write_bytes(b"test video")
                tools = root / "tools"
                tools.mkdir()
                log = root / "calls.jsonl"
                stub_source = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["VIDEO_TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, *args]) + "\\n")
if tool == "gh" and args[:2] in (["release", "view"], ["release", "upload"]):
    pass
elif tool == "gh" and args[:1] == ["api"]:
    print("42")
elif tool == "gh" and args == ["auth", "token"]:
    print("test-token")
elif tool == "curl":
    sys.stdin.read()
    print("Location: https://example.invalid/video.mp4?token=test")
elif tool == "open":
    pass
else:
    sys.exit(99)
"""
                for tool in ("gh", "jq", "curl", "open"):
                    stub = tools / tool
                    stub.write_text(stub_source)
                    stub.chmod(0o755)
                temporary_files = root / "tmp"
                temporary_files.mkdir()
                env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                           TMPDIR=str(temporary_files), VIDEO_TEST_LOG=str(log))
                env.pop("RESULTS_REPO", None)
                if inherited_repo is not None:
                    env["RESULTS_REPO"] = inherited_repo
                upload = subprocess.run(
                    ["bash", str(scripts / "e2e-attach-video.sh"), "--pr", "1",
                     "--results-repo", "test/results", "--release-tag", release_tag,
                     "--no-comment", str(video_dir)],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(upload.returncode, 0, upload.stdout + upload.stderr)
                hint = re.search(r"  - watch: `([^`\n]+)`", upload.stdout)
                self.assertIsNotNone(hint, upload.stdout)
                command = hint.group(1)
                watch = subprocess.run(["bash", "-c", command], cwd=root, env=env,
                                       capture_output=True, text=True, timeout=10)
                self.assertEqual(watch.returncode, 0, watch.stdout + watch.stderr)
                self.assertIn("Playing pr1-smoke.mp4", watch.stdout)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                uploads = [call for call in calls if call[:3] == ["gh", "release", "upload"]]
                self.assertEqual(len(uploads), 1)
                self.assertEqual(uploads[0][3], release_tag)
                self.assertEqual(uploads[0][-3:], ["--repo", "test/results", "--clobber"])
                self.assertEqual(
                    [call for call in calls if call[:2] == ["gh", "api"]],
                    [["gh", "api", f"repos/test/results/releases/tags/{release_tag}",
                      "--jq", '.assets[] | select(.name == "pr1-smoke.mp4") | .id']],
                )
                launcher = temporary_files / "ctrlx-e2e" / "watch-pr1-smoke.mp4.html"
                self.assertIn(["open", str(launcher)], calls)
                self.assertIn("https%3A%2F%2Fexample.invalid%2Fvideo.mp4", launcher.read_text())
                url = f"https://github.com/test/results/releases/download/{release_tag}/pr1-smoke.mp4"
                cleaned = vc.rewrite_comment(upload.stdout, [url])
                self.assertIn(f"  - watch: ~~`{command}`~~", cleaned)
                self.assertIsNone(vc.rewrite_comment(cleaned, [url]))

    def test_report_results_directory_is_shared_across_worktrees(self):
        source = Path(__file__).resolve().parents[1] / "e2e-report.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "primary"
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            shutil.copyfile(source, scripts / source.name)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".git" / "info" / "exclude").write_text("/.worktrees/\n")
            subprocess.run(["git", "-C", str(root), "add", "scripts"], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Test",
                            "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false",
                            "commit", "-qm", "Fixture"], check=True)
            linked = root / ".worktrees" / "linked"
            subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach",
                            str(linked), "HEAD"], check=True, capture_output=True)
            for checkout in (root, linked):
                with self.subTest(checkout=checkout):
                    result = subprocess.run(["bash", str(checkout / "scripts" / source.name), "--help"],
                                            cwd=linked, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(f"default: {(root.parent / 'CtrlxTestResults').resolve()}", result.stdout)

    def test_missing_results_repo_fails_without_external_writes(self):
        source_scripts = Path(__file__).resolve().parents[1]
        for name, arguments in (("e2e-attach-video.sh", ["smoke"]),
                                ("e2e-watch-video.sh", ["pr1-smoke"]),
                                ("e2e-report.sh", [])):
            with self.subTest(script=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts = root / "scripts"
                scripts.mkdir()
                shutil.copyfile(source_scripts / name, scripts / name)
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                tools = root / "tools"
                tools.mkdir()
                marker = root / "external-call"
                for tool in ("gh", "jq", "curl"):
                    stub = tools / tool
                    stub.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 99\n")
                    stub.chmod(0o755)
                env = dict(os.environ, RESULTS_REPO="", RESULTS_REPO_URL="",
                           PATH=f"{tools}:{os.environ['PATH']}", TMPDIR=str(root / "tmp"))
                result = subprocess.run(["bash", str(scripts / name), *arguments],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no upstream default", result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse((root / "tmp").exists())


if __name__ == "__main__":
    unittest.main()
