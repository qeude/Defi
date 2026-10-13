from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import border_sync_probe as probe

WINDOW = (7, 4, 34, 1977, 1360)  # ring x0..1985 y30..1398
EDGES = [[10, 3, 0, 30, 1985, 24], [11, 3, 0, 1374, 1985, 24],
         [12, 3, 0, 54, 24, 1320], [13, 3, 1961, 54, 24, 1320]]


def moved(edges, dx):
    return [[i, layer, x + dx, y, w, h] for i, layer, x, y, w, h in edges]


class BorderSyncProbeTests(unittest.TestCase):
    def test_ring_groups_four_edges_and_matches_exact_outset(self):
        (ring,) = probe.group_rings(EDGES + [[40, 0, 100, 100, 800, 600]])
        self.assertEqual(ring['rect'], (0, 30, 1985, 1398))
        self.assertTrue(ring['active'])
        self.assertEqual(probe.match_ring(ring['rect'], [WINDOW]), (7, 0))

    def test_stale_ring_reports_move_distance(self):
        moved_window = (7, 4 + 296, 34, 1977, 1360)
        self.assertEqual(probe.match_ring((0, 30, 1985, 1398), [moved_window]), (7, 296))
        self.assertIsNone(probe.match_ring((0, 30, 1985, 1398), []))

    def test_stale_ring_keeps_previous_window_over_nearer_neighbour(self):
        neighbour = (8, 100, 34, 1977, 1360)
        self.assertEqual(probe.match_ring((0, 30, 1985, 1398), [neighbour, (7, 300, 34, 1977, 1360)], 7), (7, 296))

    def test_summary_measures_desync_duration_and_percentiles(self):
        states = [{'t': 0.0, 'n': 0, 'apps': [list(WINDOW)], 'edges': EDGES},
                  {'t': 1.0, 'n': 250, 'apps': [[7, 300, 34, 1977, 1360]], 'edges': EDGES},
                  {'t': 1.1, 'n': 275, 'apps': [[7, 300, 34, 1977, 1360]], 'edges': moved(EDGES, 296)}]
        result = probe.summarize(states, 2.0, 500)
        window = result['windows']['7']
        self.assertEqual((window['samples'], window['error_pt_max']), (500, 296))
        self.assertEqual((window['desync_ms'], window['longest_desync_ms']), (100.0, 100.0))
        # 25 of 500 samples were stale: below the 5% tail, so p95 stays 0 while max shows it
        self.assertEqual((window['error_pt_p50'], window['error_pt_p95']), (0, 0))
        self.assertEqual(result['rings'], 1)

    def test_status_deltas_cover_scalar_and_pair_fields(self):
        before = probe.parse_status('borders=3 borderSurfaceMiB=3.50 axReads=10/2 posWrites=5 id=9')
        after = probe.parse_status('borders=3 borderSurfaceMiB=4.00 axReads=15/2 posWrites=9')
        delta = probe.status_delta(before, after)
        self.assertEqual(delta['axReads']['delta'], [5.0, 0.0])
        self.assertEqual((delta['posWrites']['delta'], delta['borderSurfaceMiB']['delta']), (4.0, 0.5))


if __name__ == '__main__':
    unittest.main()
