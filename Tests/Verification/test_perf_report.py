import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import perf_report as perf  # noqa: E402


def status(**p95):
    fields = {'plan': 'inputPlan', 'write': 'inputWrite', 'observed': 'inputObserved',
              'converged': 'inputConverged', 'focus': 'inputFocus'}
    return ' '.join(f'{field}N/P50/P95/P99=120/1.00/{p95.get(key, 2.0):.2f}/9.00' for key, field in fields.items())


class CompareTests(unittest.TestCase):
    def rounds(self, *values):
        return [perf.parse_status(status(converged=v)) for v in values]

    def test_parses_daemon_status_fields(self):
        parsed = perf.parse_status('running x=1 ' + status(plan=3.5) + ' focusMs=1')
        self.assertEqual(parsed['plan'], {'n': 120, 'p50': 1.0, 'p95': 3.5, 'p99': 9.0})

    def test_flags_a_large_shift_with_separated_rounds(self):
        found = perf.compare(self.rounds(20, 21, 22), self.rounds(30, 31, 29))
        self.assertEqual(found, [('converged', 'p95', 21, 30)])

    def test_overlapping_rounds_are_noise(self):
        self.assertEqual(perf.compare(self.rounds(20, 21, 35), self.rounds(30, 31, 29)), [])

    def test_small_shifts_are_noise_even_when_separated(self):
        # 2.0 → 2.6 ms is 30 % but under the absolute floor; 20 → 24 ms is under the relative floor.
        self.assertEqual(perf.compare(self.rounds(2.0, 2.0), self.rounds(2.6, 2.6)), [])
        self.assertEqual(perf.compare(self.rounds(20, 20), self.rounds(24, 24)), [])

    def test_rounds_without_samples_are_ignored(self):
        rounds = self.rounds(20, 21)
        rounds.append(perf.parse_status(status(converged=0).replace('inputConvergedN/P50/P95/P99=120', 'inputConvergedN/P50/P95/P99=0')))
        self.assertEqual(perf.summary(rounds, 'converged', 'p95'), {'median': 20.5, 'min': 20, 'max': 21})
        with self.assertRaises(ValueError):
            perf.summary(rounds[2:], 'converged', 'p95')

    def test_improvements_read_base_to_candidate(self):
        builds = {'a': {'rounds': self.rounds(20, 21, 22)}, 'b': {'rounds': self.rounds(10, 11, 9)}}
        meta = {k: '' for k in ('measured_at', 'vm', 'guest', 'host', 'rounds', 'navigations', 'windows')}
        text, regressions = perf.report(meta, builds, 'a', 'b')
        self.assertEqual(regressions, [])
        self.assertIn('input to converged frame P95: 21.00 → 10.00 ms', text)

    def test_rounds_of_one_label_exclude_a_longer_label(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            for name in ('v0.8.0-1', 'v0.8.0-2', 'v0.8.0-3-gabc-1'):
                (out / f'{name}.status').write_text(status())
            self.assertEqual(len(perf.load_rounds(out, 'v0.8.0')), 2)
            self.assertEqual(len(perf.load_rounds(out, 'v0.8.0-3-gabc')), 1)

    def test_idle_cpu_is_a_percentage_of_ten_seconds(self):
        self.assertEqual(perf.parse_idle('1.50 1.60 20480'), {'idle_cpu_percent': 1.0, 'rss_mib': 20.0})


if __name__ == '__main__':
    unittest.main()
