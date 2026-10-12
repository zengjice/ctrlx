import copy
import unittest

from display_conditions import require_fixed_display


class DisplayConditionTests(unittest.TestCase):
    def setUp(self):
        self.condition = dict(screenDisplayID=7, screenMaximumFPS=120, contentsScale=2,
                              drawableWidth=764, drawableHeight=1658)
        self.initial = {'renderState': self.condition.copy()}
        self.final = {'renderState': self.condition.copy(), 'renderLifecycle': {
            'schemaVersion': 3, 'rows': [dict(id=i, submittedAt=float(i), **self.condition) for i in range(5)]}}

    def check(self):
        return require_fixed_display(self.initial, self.final, 1, 4, display_id=7, maximum_fps=120)

    def test_complete_fixed_display_interval(self):
        result = self.check()
        self.assertEqual(result['submissionsChecked'], 3)
        self.assertTrue(result['maximumFPSIsNotMeasuredRefreshCadence'])

    def test_endpoint_migration_like_r1074_is_rejected(self):
        self.final['renderState']['screenDisplayID'] = 8
        self.final['renderState']['screenMaximumFPS'] = 60
        with self.assertRaisesRegex(ValueError, 'endpoints'):
            self.check()

    def test_move_away_and_back_is_rejected_even_with_equal_endpoints(self):
        original = copy.deepcopy(self.final)
        for field, value in [('screenDisplayID', 8), ('screenMaximumFPS', 60),
                             ('contentsScale', 1), ('drawableWidth', 382), ('drawableHeight', 829)]:
            with self.subTest(field=field):
                self.final = copy.deepcopy(original)
                self.final['renderLifecycle']['rows'][2][field] = value
                with self.assertRaisesRegex(ValueError, 'submission 2'):
                    self.check()

    def test_unknown_frame_display_is_rejected(self):
        del self.final['renderLifecycle']['rows'][2]['screenDisplayID']
        with self.assertRaisesRegex(ValueError, 'Missing'):
            self.check()

    def test_frame_queued_before_interval_on_another_display_is_rejected(self):
        earlier = self.final['renderLifecycle']['rows'][0]
        earlier['screenDisplayID'] = 8
        earlier['presentedAt'] = 1.01
        with self.assertRaisesRegex(ValueError, 'submission 0'):
            self.check()

    def test_old_schema_does_not_silently_qualify(self):
        self.final['renderLifecycle']['schemaVersion'] = 2
        with self.assertRaisesRegex(ValueError, 'schema 3'):
            self.check()

    def test_wrong_requested_screen_does_not_silently_qualify(self):
        with self.assertRaisesRegex(ValueError, 'requested condition'):
            require_fixed_display(self.initial, self.final, 1, 4, display_id=8, maximum_fps=120)

    def test_truncated_history_is_rejected(self):
        self.final['renderLifecycle']['rows'].pop(0)
        with self.assertRaisesRegex(ValueError, 'complete interval'):
            self.check()

    def test_unfinished_interval_is_rejected(self):
        self.final['renderLifecycle']['rows'].pop()
        with self.assertRaisesRegex(ValueError, 'complete interval'):
            self.check()

    def test_missing_submission_is_rejected(self):
        del self.final['renderLifecycle']['rows'][2]
        with self.assertRaisesRegex(ValueError, 'missing or unordered'):
            self.check()


if __name__ == '__main__':
    unittest.main()
