import copy
import unittest

from qualify_display import qualify_native_interval


class NativeDisplayQualificationTests(unittest.TestCase):
    def setUp(self):
        condition = dict(screenDisplayID=7, screenMaximumFPS=120, contentsScale=2,
                         drawableWidth=764, drawableHeight=1658)
        self.initial = {
            'device': 'owned-device', 'udid': 'owned-udid', 'runtime': 'iOS-27', 'profile': 'standard',
            'displayMode': 'low-latency',
            'view': dict(visible=True, inputReady=True, displaySyncEnabled=False, width=382, height=829),
            'renderState': dict(appActive=True, windowMain=True, windowKey=True, **condition),
        }
        self.final = copy.deepcopy(self.initial)
        source, frames = [], []
        for index in range(3721):
            at = index / 60
            source.append(dict(sequence=index, sourceSequence=index, wordHex=f'{index:016x}',
                               copiedWordHex=f'{index:016x}', seedBefore=1, seedAfter=1,
                               sourceAt=at, copyReadyAt=at + .0002, receivedAt=at + .0004))
            frames.append(dict(id=index, sequence=index, sourceSequence=index,
                               submittedAt=at + .001, gpuStartedAt=at + .002, gpuEndedAt=at + .003,
                               gpuStatus=4, presentedAt=at + .015, presentationCallbackAt=at + .016,
                               **condition))
        self.final['sourceFrameTrace'] = dict(rows=source, droppedRows=0)
        self.final['renderLifecycle'] = dict(rows=frames, schemaVersion=3)

    def qualify(self, mode='low-latency'):
        return qualify_native_interval(self.initial, self.final, 1, 61,
                                       display_id=7, maximum_fps=120, mode=mode)

    def test_stable_correct_frames_pass_one_interval_only(self):
        result = self.qualify()
        self.assertTrue(result['passed'])
        self.assertEqual(result['positiveNativeFPS'], 60)
        self.assertAlmostEqual(result['sourceToNativeP95Ms'], 15)
        self.assertFalse(result['physicalPanelMeasured'])
        self.assertFalse(result['completeDisplayMatrixQualified'])

    def test_fast_frames_on_mixed_displays_cannot_pass(self):
        self.final['renderLifecycle']['rows'][120]['screenDisplayID'] = 8
        with self.assertRaisesRegex(ValueError, 'submission 120'):
            self.qualify()

    def test_both_modes_use_the_100ms_latency_budget(self):
        for mode in ('synchronized', 'low-latency'):
            for status in (self.initial, self.final):
                status['displayMode'] = mode
                status['view']['displaySyncEnabled'] = mode == 'synchronized'
            for latency, passed in ((.099, True), (.101, False)):
                with self.subTest(mode=mode, latency=latency):
                    for row in self.final['renderLifecycle']['rows']:
                        source_at = row['sequence'] / 60
                        row['presentedAt'] = source_at + latency
                        row['presentationCallbackAt'] = source_at + latency + .001
                    result = self.qualify(mode)
                    self.assertEqual(result['latencyTargetMs'], 100)
                    self.assertAlmostEqual(result['sourceToNativeP95Ms'], latency * 1000)
                    self.assertEqual(result['passed'], passed)

    def test_discarded_frames_cannot_inflate_fps(self):
        for kept_per_second in (54, 50, 49):
            with self.subTest(fps=kept_per_second):
                for row in self.final['renderLifecycle']['rows']:
                    row['presentedAt'] = (row['sequence'] / 60 + .015
                                          if row['sequence'] % 60 < kept_per_second else 0)
                result = self.qualify()
                self.assertEqual(result['positiveNativeFPS'], kept_per_second)
                self.assertEqual(result['minimumFPS'], 50)
                self.assertGreater(result['zeroPresentedCallbacks'], 0)
                self.assertEqual(result['passed'], kept_per_second >= 50)

    def test_short_diagnostic_cannot_become_qualification(self):
        with self.assertRaisesRegex(ValueError, '60 seconds'):
            qualify_native_interval(self.initial, self.final, 1, 5,
                                    display_id=7, maximum_fps=120, mode='low-latency')

    def test_corrupt_pixels_and_invalid_native_times_are_rejected(self):
        self.final['sourceFrameTrace']['rows'][120]['copiedWordHex'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'content differ'):
            self.qualify()
        self.final['sourceFrameTrace']['rows'][120]['copiedWordHex'] = f'{120:016x}'
        self.final['renderLifecycle']['rows'][120]['gpuEndedAt'] = 100
        with self.assertRaisesRegex(ValueError, 'chronology'):
            self.qualify()

    def test_unfinished_presentation_is_not_a_valid_sample(self):
        self.final['renderLifecycle']['rows'][120]['presentationCallbackAt'] = 0
        with self.assertRaisesRegex(ValueError, 'unfinished callback'):
            self.qualify()

    def test_requested_mode_must_match_runtime(self):
        with self.assertRaisesRegex(ValueError, 'requested mode'):
            self.qualify('synchronized')


if __name__ == '__main__':
    unittest.main()
