import io
from pathlib import Path
import signal
import subprocess
import types
import unittest
from unittest.mock import Mock, patch

import smoke


class SmokeRunnerTests(unittest.TestCase):
    def run_fake(self, output, returncode=0, interruption=None, chrome_control=False):
        process = Mock(pid=43210, returncode=returncode)
        process.communicate.return_value = (output, None)
        if interruption is not None:
            process.communicate.side_effect = [interruption, (output, None)]
        with patch.object(smoke.subprocess, "Popen", return_value=process) as popen, \
             patch.object(smoke.os, "killpg") as killpg, \
             patch.object(smoke.sys, "stdout", types.SimpleNamespace(buffer=io.BytesIO())), \
             patch.object(smoke.sys, "stderr", io.StringIO()):
            result = smoke.run(Path("/test/Probe"), timeout=1, chrome_control=chrome_control)
        return result, popen, killpg

    def test_requires_explicit_pass_and_successful_exit(self):
        result, popen, killpg = self.run_fake(b"[probe] native-smoke=PASS\n")
        self.assertEqual(result, 0)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(popen.call_args.args[0], ["/test/Probe", "--probe-smoke-test"])
        killpg.assert_not_called()

    def test_existing_browser_relaunch_is_not_a_pass(self):
        self.assertEqual(self.run_fake(b"Opening in existing browser session.\n")[0], 1)

    def test_renderer_ready_without_completed_navigation_is_not_a_pass(self):
        output = (b"[probe] embedded-parent=verified size=1120x692\n"
                  b"[probe] before-browse main=1 fixture=1\n"
                  b"[probe] renderer-ready browser=1\n")
        self.assertEqual(self.run_fake(output)[0], 1)

    def test_loaded_fixture_without_clean_shutdown_is_not_a_pass(self):
        self.assertEqual(self.run_fake(b"[probe] fixture-load=PASS\n")[0], 1)

    def test_failed_exit_overrides_pass_marker(self):
        self.assertEqual(self.run_fake(b"[probe] native-smoke=PASS\n", returncode=1)[0], 1)

    def test_chrome_control_does_not_count_as_embedded_success(self):
        self.assertEqual(self.run_fake(b"[probe] chrome-control-smoke=PASS\n")[0], 1)

    def test_control_requires_its_own_marker_and_explicit_flag(self):
        result, popen, _ = self.run_fake(b"[probe] chrome-control-smoke=PASS\n", chrome_control=True)
        self.assertEqual(result, 0)
        self.assertIn("--probe-chrome-control", popen.call_args.args[0])
        self.assertEqual(self.run_fake(b"[probe] native-smoke=PASS\n", chrome_control=True)[0], 1)

    def test_timeout_only_stops_owned_process_group(self):
        result, _, killpg = self.run_fake(b"timeout", interruption=subprocess.TimeoutExpired("probe", 1))
        self.assertEqual(result, 1)
        killpg.assert_called_once_with(43210, signal.SIGKILL)

    def test_interruption_also_cleans_up(self):
        result, _, killpg = self.run_fake(b"interrupted", interruption=KeyboardInterrupt())
        self.assertEqual(result, 1)
        killpg.assert_called_once_with(43210, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
