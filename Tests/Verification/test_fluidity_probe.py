import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import fluidity_probe as probe  # noqa: E402


class AttributeTests(unittest.TestCase):
    def test_hitches_go_to_the_action_just_before_them(self):
        result = probe.attribute([(10, 'open'), (10.5, 'close')],
                                 [(10.05, 8), (10.2, 8), (10.6, 16), (10.9, 8), (12, 8), (10.1, 50)])
        self.assertEqual(result['open']['hitches'], 2)
        self.assertEqual(result['open']['first_100ms'], 1)
        self.assertEqual(result['close']['hitches'], 2)
        self.assertEqual(result['close']['worst_ms'], 16)


if __name__ == '__main__':
    unittest.main()
