#!/usr/bin/env python3
"""First-use setup must not expire while the user handles system authorization."""
import unittest
from unittest.mock import Mock, patch

from integration import wait_for


class WaitPolicyTests(unittest.TestCase):
    def test_interactive_setup_has_no_automatic_deadline(self):
        predicate = Mock(side_effect=[False, False, 'loaded'])
        with patch('integration.time.monotonic', side_effect=AssertionError('no deadline')), \
                patch('integration.time.sleep') as sleep:
            self.assertEqual(wait_for(predicate, timeout=None), 'loaded')
            self.assertEqual(sleep.call_count, 2)

    def test_automated_checks_still_time_out(self):
        with patch('integration.time.monotonic', side_effect=[0, 1, 16]), \
                patch('integration.time.sleep'):
            with self.assertRaisesRegex(AssertionError, 'Timed out'):
                wait_for(lambda: False)

    def test_closed_browser_failure_is_not_swallowed(self):
        with self.assertRaisesRegex(AssertionError, 'Browser exited'):
            wait_for(Mock(side_effect=AssertionError('Browser exited')), timeout=None)


if __name__ == '__main__':
    unittest.main()
