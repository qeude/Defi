from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import motion_probe as probe

APP = (100, 100, 800, 600)
DISPLAYS = [[0, 0, 2560, 1440]]
TRACE = '''\
100.000 submit g=1 source=command-animation windows=2[7,8] animated=2[7,8] parked=0 springMs=125
100.010 phase g=1 kind=parking windows=1
100.200 complete g=1 applied=4 frames=16 ms=200
100.210 slow g=1 pid=709 windows=1 ms=30 setup=0 position=30 geometry=0 wait=0 reset=0 phase=motion
100.220 clock g=1 displayPulses=15 displayGapMs=8.5 timerSteps=0
100.230 cadence g=1 frames=16 submittedSteps=15 appliedIntermediateWrites=1 maxGapMs=9.1 waitMs=0
101.000 submit g=2 source=command-layout-animation windows=1[7] animated=1[7] parked=0 springMs=125
101.100 complete g=2 applied=1 frames=1 ms=100
102.000 submit g=3 source=workspace-command windows=2[7,8] animated=0[] parked=1 springMs=0
102.050 complete g=3 applied=1 frames=1 ms=50
103.000 parking-deferred-start g=3 windows=1
103.100 parking-deferred-complete g=3 applied=1 stale=0
'''


def state(t, edges, apps=((7, 1) + APP,)):
    return {'t': t, 'apps': [list(a) for a in apps], 'edges': edges}


class MotionProbeTests(unittest.TestCase):
    def test_edge_attachment_follows_ring_but_not_body_or_strays(self):
        self.assertTrue(probe.attached((96, 96, 808, 4), [APP]))
        self.assertTrue(probe.attached((896, 100, 4, 600), [APP]))
        self.assertFalse(probe.attached((1500, 100, 4, 600), [APP]))
        self.assertFalse(probe.attached((300, 300, 4, 200), [APP]))

    def test_episodes_split_detached_from_edge_strip_and_measure_duration(self):
        attached_edge, stray, strip = [9, 3, 96, 96, 808, 4], [9, 3, 1500, 100, 4, 600], [9, 3, 2556, 100, 4, 600]
        top_offscreen_left, hidden = [9, 3, -700, 30, 1985, 4], [9, 3, 3241, 100, 4, 600]
        states = [state(0.0, [attached_edge]), state(1.0, [stray]), state(1.2, [attached_edge, hidden]),
                  state(1.5, [strip]), state(1.7, [top_offscreen_left])]
        episodes = probe.detached_episodes(states, 2.0, DISPLAYS)
        self.assertEqual([(e['kind'], e['start'], e['ms']) for e in episodes],
                         [('detached', 1.0, 200.0), ('edge-strip', 1.5, 200.0),
                          ('detached', 1.7, 300.0)])

    def test_border_lag_counts_lead_and_lag_and_stuck(self):
        track = [(10.0, 0, 30), (10.010, 100, 30), (10.020, 200, 30)]
        top = lambda x: (x - probe.BORDER, 26)
        self.assertEqual(probe.border_lag_ms(top(200), 10.025, track), 0.0)
        self.assertAlmostEqual(probe.border_lag_ms(top(100), 10.025, track), 5.0)   # lags one sample
        self.assertAlmostEqual(probe.border_lag_ms(top(150), 10.015, track), 5.0)   # passed between samples
        self.assertAlmostEqual(probe.border_lag_ms(top(200), 10.012, track), 8.0)   # leads the window
        self.assertIsNone(probe.border_lag_ms(top(900), 10.025, track))

    def test_trace_phase_attribution(self):
        gens, deferred = probe.build_generations(probe.parse_trace(TRACE))
        marks = [100.0, 100.2, 101.0, 101.1, 102.0, 102.05]
        phases = [probe.classify(t, gens, deferred, marks) for t in
                  (100.005, 100.1, 101.05, 102.01, 102.5, 103.05, 100.9, 100.4, 110.0)]
        self.assertEqual(phases, ['focus-animation', 'parking', 'layout-animation', 'workspace-switch',
                                  'workspace-switch', 'parking', 'other', 'other', 'rest'])

    def test_trace_aggregates(self):
        aggregates = probe.trace_aggregates(probe.parse_trace(TRACE))
        self.assertEqual((aggregates['slow_motion_by_pid'], aggregates['max_display_gap_ms'],
                          aggregates['max_cadence_gap_ms']), ({'709': 1}, 8.5, 9.1))

    def test_stalls_and_backward_steps_in_one_generation(self):
        # origin x=0 at submit; a 60 ms hole, one 5 pt step back, then the final 400 after `complete`
        track = [(9.9, 0, 0), (10.010, 50, 0), (10.020, 100, 0), (10.080, 300, 0), (10.090, 295, 0),
                 (10.100, 380, 0), (10.170, 400, 0)]
        motion = probe.window_motion(track, 10.0, 10.150, 11.0)
        self.assertEqual((motion['frames'], motion['stalls'], motion['max_gap_ms'], motion['backward_steps']),
                         (5, 1, 60.0, 1))
        self.assertEqual((motion['settle_ms'], motion['start_lag_ms'], motion['overshoot_pt']), (20.0, 10.0, 0))

    def test_sub_pixel_tail_and_stationary_windows_are_not_stalls(self):
        tail = [(9.9, 0, 0), (10.01, 100, 0), (10.02, 199, 0), (10.10, 200, 0)]
        self.assertEqual(probe.window_motion(tail, 10.0, 10.2, 11.0)['stalls'], 0)
        self.assertIsNone(probe.window_motion([(9.9, 5, 5), (10.05, 6, 5)], 10.0, 10.2, 11.0))

    def test_analyze_attributes_a_detached_border_and_ribbon_stall(self):
        ring = [9, 3, 96, 96, 808, 4]
        states = [{'t': 99.9, 'apps': [[7, 709, 100, 100, 800, 600]], 'edges': [ring]}]
        for t, x in ((100.005, 150), (100.02, 200), (100.10, 400), (100.11, 600)):
            states.append({'t': t, 'apps': [[7, 709, x, 100, 800, 600]], 'edges': [[9, 3, 96, 96, 808, 4]]})
        states.append({'t': 100.5, 'apps': [[7, 709, 600, 100, 800, 600]], 'edges': [[9, 3, 96, 96, 808, 4]]})
        report = probe.analyze(states, 101.0, DISPLAYS, probe.parse_trace(TRACE), {'709': 'com.apple.finder'})
        detached = report['detached_borders']
        self.assertEqual((detached['episodes_over_50ms'], detached['by_phase']), (1, {'focus-animation': 1}))
        overall = report['ribbon']['overall']
        self.assertEqual((overall['windows'], overall['stalls'], overall['max_gap_ms']), (1, 1, 80.0))
        self.assertIn('com.apple.finder', report['ribbon']['by_app'])

    def test_soak_scenario_matches_the_reference_script(self):
        steps = probe.soak_steps()
        self.assertEqual(len(steps), 78)
        self.assertEqual(steps[0], (('focus-column', 'right'), 0.35))
        self.assertEqual(steps[-1], (('focus-column', 'left'), 0.12 + 1.5))
        self.assertEqual(sum(1 for command, _ in steps if command[0] == 'workspace'), 12)

    def test_repeat_summary_reports_median_and_range(self):
        def report(episodes, stalls):
            return {'detached_borders': {'episodes_over_50ms': episodes, 'total_ms': 10 * episodes},
                    'ribbon': {'overall': {'stalls_per_s': stalls, 'p95_max_gap_ms': 30, 'backward_steps': 0}},
                    'border_lag': {'lag_p95_ms': 9, 'lagging_over_17ms_ms': 0, 'stuck_ms': 0}}
        summary = probe.repeat_summary([report(1, 0.5), report(5, 0.1), report(3, 0.2)])
        self.assertEqual(summary['detached_episodes_over_50ms'], {'median': 3, 'min': 1, 'max': 5})
        self.assertEqual(summary['ribbon_stalls_per_s']['median'], 0.2)


if __name__ == '__main__':
    unittest.main()
