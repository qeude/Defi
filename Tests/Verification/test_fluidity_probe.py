import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import fluidity_probe as probe  # noqa: E402


class AttributeTests(unittest.TestCase):
    def test_overlapping_motions_merge_and_unmatched_ends_are_ignored(self):
        windows = probe.motion_windows([(1, 'begin', 'ribbon 1'), (1.1, 'begin', 'overview 0'),
                                        (1.2, 'end', 'ribbon 1'), (1.3, 'end', 'overview 0'),
                                        (2, 'end', 'ribbon 1'), (3, 'begin', 'ribbon 1'), (3.2, 'end', 'ribbon 1')])
        self.assertEqual(windows, [(1, 1.3), (3, 3.2)])

    def test_gaps_count_inside_motions_for_the_action_before_them(self):
        renders = [10.008, 10.0085, 10.016, 10.036, 10.044, 10.1, 11.008, 11.05]
        result = probe.attribute([(9.99, 'open'), (10.9, 'close')], [(10, 10.05), (11, 11.06)], renders,
                                 [(10.02, 20), (11.01, 45)])
        # open: 8, 8, 20, 8, then 6 ms to the motion's end (the duplicate render merges);
        # close: 8 ms, a 42 ms spike, then 10 ms to the end.
        self.assertEqual((result['open']['gaps'], result['open']['smooth']), (5, 4))
        self.assertEqual(result['open']['worst_ms'], 20)
        self.assertEqual(result['open']['hitches'], 1)
        self.assertEqual((result['close']['gaps'], result['close']['spikes']), (2, 1))
        self.assertEqual(result['close']['hitches'], 0)
        # First render, from the mark: 10 ms before the motion plus its first 8 ms gap; 100 + 8 ms.
        self.assertEqual((result['open']['first_ms'], result['close']['first_ms']), ([18.0], [108.0]))

    def test_a_motion_without_renders_is_one_gap_and_teardown_belongs_to_no_action(self):
        result = probe.attribute([(9.99, 'open'), (10.5, None)], [(10, 10.02), (10.6, 10.7)], [],
                                 [(10.01, 10), (10.65, 12)])
        self.assertEqual((result['open']['gaps'], result['open']['worst_ms']), (1, 20))
        self.assertNotIn('first_ms', result['open'])  # no render, no first render
        self.assertEqual(result['open']['hitches'], 1)
        self.assertNotIn(None, result)

    def test_first_render_comes_from_the_merged_series_the_cadence_uses(self):
        # The render 0.5 ms after the start merges into the one before it: the first is at +16 ms.
        result = probe.attribute([(9.99, 'open')], [(10, 10.05)], [9.9995, 10.0005, 10.016], [])
        self.assertEqual(result['open']['first_ms'], [26.0])

if __name__ == '__main__':
    unittest.main()
