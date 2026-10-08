import copy
import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script'))
import performance_experiments as perf


class PerformanceExperimentsTests(unittest.TestCase):
    def test_frame_write_counters_report_real_deltas_and_reject_resets(self):
        self.assertEqual(perf.frame_write_delta('posWrites=12 sizeWrites=3', 'posWrites=19 sizeWrites=5'),
                         {'daemon_completed_position_writes': 7, 'daemon_completed_size_writes': 2})
        for after in ('posWrites=11 sizeWrites=3', 'posWrites=19', 'posWrites=19.5 sizeWrites=5'):
            with self.subTest(after=after), self.assertRaises(RuntimeError):
                perf.frame_write_delta('posWrites=12 sizeWrites=3', after)

    def log(self, **changes):
        record = {'case': 'accepted-read', 'operations': 32, 'errors': 0,
                  'output': {'accepted': 32, 'reads': 32}, 'metrics': {'elapsed_ms': 20}}
        record.update(changes)
        return 'Test run with 1 test in 1 suite passed\nDEFI_PERF_JSON ' + json.dumps(record)

    def test_complete_work_and_error_detection(self):
        self.assertEqual(perf.parse_trial(self.log(), perf.SMOKE)['operations'], 32)
        for changes in ({'operations': 0}, {'operations': 31}, {'errors': 1}, {'errors': False},
                        {'output': {}}, {'metrics': {}}, {'metrics': {'elapsed_ms': float('nan')}}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                perf.parse_trial(self.log(**changes), perf.SMOKE)

    def test_missing_partial_and_zero_tests_fail(self):
        for log in ('Test run with 0 tests passed', 'Test run with 1 test passed',
                    self.log() + '\nDEFI_PERF_JSON {}', self.log().replace('1 test', '2 tests')):
            with self.subTest(log=log), self.assertRaises((RuntimeError, KeyError)):
                perf.parse_trial(log, perf.SMOKE)

    def test_comparison_requires_all_pairs_and_counts_runs(self):
        trial = perf.parse_trial(self.log(), perf.SMOKE)
        trials = [{**copy.deepcopy(trial), 'side': s, 'repeat': i} for i in range(1, 6) for s in 'AB']
        self.assertEqual(perf.summarize(trials)['accepted-read/elapsed_ms']['A']['median'], 20)
        with self.assertRaises(RuntimeError):
            perf.summarize(trials[:-1])

    def test_explicit_inputs_do_not_recurse_build_or_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for name in ('Sources', 'Tests', 'dist', '.build'):
                (source / name).mkdir()
                (source / name / 'payload').write_text(name)
            (source / 'Package.swift').write_text('manifest')
            self.assertEqual(set(perf.files(source)), {'Sources/payload', 'Tests/payload', 'Package.swift'})
            (source / 'Tests/link').symlink_to(source / 'dist')
            with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
                perf.files(source)

    def test_native_restore_after_checkpoint_start_failure(self):
        import desktop_session
        import desktop_lock
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            fixture = Mock()
            fixture.ask.return_value = {'nativeFocus': {'available': True, 'pid': 42}}
            args = SimpleNamespace(a=output / 'a.app', b=output / 'b.app', final_bundle=None,
                                   workload=['ordinary'], a_source=output, b_source=output)
            def checkpoint(path):
                path.mkdir()
                (path / 'ready').touch()
            with patch.object(desktop_lock, 'inherited_lock', return_value=1), \
                    patch.object(perf, 'Fixture', return_value=fixture), \
                    patch.object(perf, 'sha', return_value='digest'), \
                    patch.object(perf, 'verified_bundle_source', return_value={'verification_sha256': 'source'}), \
                    patch.object(perf, 'run') as run, \
                    patch.object(desktop_session, 'checkpoint', side_effect=checkpoint), \
                    patch.object(desktop_session, 'start', side_effect=RuntimeError('start failed')), \
                    patch.object(desktop_session, 'command', return_value='monitors=1['), \
                    patch.object(desktop_session, 'restore') as restore, \
                    patch.object(desktop_session, 'daemon_count', return_value=1), \
                    self.assertRaisesRegex(RuntimeError, 'start failed'):
                perf.native_compare(args, output)
            restore.assert_called_once_with(output / 'checkpoint')
            installs = [call.args[0] for call in run.call_args_list if '--install-staged' in call.args[0]]
            self.assertEqual(installs, [[perf.ROOT / 'script/build_and_run.sh', '--install-staged',
                                        output / 'original.app', '--verify']])

    def test_snapshot_isolated_and_drift_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, artifacts = root / 'source', root / 'dist'
            for name in ('Sources', 'Tests', '.build', 'dist'):
                (source / name).mkdir(parents=True)
                (source / name / 'payload').write_text(name)
            (source / 'Package.swift').write_text('manifest')
            target = artifacts / 'snapshot'
            with patch.object(perf, 'ART', artifacts):
                perf.snapshot(source, target)
                self.assertEqual(perf.frozen(target)['sha256'], perf.identity(perf.files(source)))
                self.assertFalse((target / '.build').exists())
                self.assertFalse((target / 'dist').exists())
                payload = target / 'Sources/payload'
                payload.chmod(0o644)
                payload.write_text('changed')
                with self.assertRaisesRegex(RuntimeError, 'changed'):
                    perf.frozen(target)

    def owned(self):
        fixtures = [SimpleNamespace(application_id=f'fixture.{i}', process=SimpleNamespace(pid=42 + i))
                    for i in range(4)]
        expected = [(i, name, 100 + i * 2 + j) for i in range(4)
                    for j, name in enumerate(('main', 'sibling'))]
        reports = [{'completed': 2, 'pending': 0, 'active': i == 0, 'frontmostPID': 42,
                    'windows': [{'id': name, 'windowNumber': 100 + i * 2 + j, 'key': i == j == 0,
                                 'frame': [i * 200 + j * 100, 0, 100, 100]}
                                for j, name in enumerate(('main', 'sibling'))]} for i in range(4)]
        state = {'workspaces': [{'active': True, 'id': 'empty', 'windowCount': 8,
                                'applications': [f'fixture.{i}' for i in range(4)]},
                               {'active': False, 'id': 'other', 'windowCount': 1,
                                'applications': ['foreign']}]}
        status = 'focused=100 axPending=false focusPending=false animating=false drift=0[] settling=0 '
        return fixtures, expected, state, reports, status

    def test_owned_readiness_requires_every_identity_and_exact_membership(self):
        fixtures, expected, state, reports, status = self.owned()
        observation, _ = perf.owned_observation(fixtures, expected, 'empty', status, state, reports, set(range(100, 108)))
        self.assertEqual(observation, {'focus': [0, 'main'], 'windows': [
            [0, 'main', [0, 0, 100, 100]], [0, 'sibling', [100, 0, 100, 100]],
            [1, 'main', [200, 0, 100, 100]], [1, 'sibling', [300, 0, 100, 100]],
            [2, 'main', [400, 0, 100, 100]], [2, 'sibling', [500, 0, 100, 100]],
            [3, 'main', [600, 0, 100, 100]], [3, 'sibling', [700, 0, 100, 100]]]})
        for failure in ('zero', 'undiscovered', 'foreign', 'wrong-workspace', 'other-membership', 'replaced-id'):
            broken_state, broken_reports = copy.deepcopy(state), copy.deepcopy(reports)
            discovered = set(range(100, 108))
            if failure == 'zero':
                broken_state['workspaces'][0]['windowCount'] = 0
            elif failure == 'undiscovered':
                discovered.remove(107)
            elif failure == 'foreign':
                broken_state['workspaces'][0]['applications'].append('foreign')
            elif failure == 'wrong-workspace':
                broken_state['workspaces'][0]['id'] = 'elsewhere'
            elif failure == 'other-membership':
                broken_state['workspaces'][1]['applications'].append('fixture.0')
            else:
                broken_reports[3]['windows'][1]['windowNumber'] = 999
            with self.subTest(failure=failure), self.assertRaises(RuntimeError):
                perf.owned_observation(fixtures, expected, 'empty', status, broken_state, broken_reports, discovered)
        with self.assertRaises(RuntimeError):
            perf.owned_observation(fixtures, [], 'empty', status, state, reports, set())

    def test_command_completion_does_not_replace_native_focus_or_frame_verification(self):
        fixtures, expected, state, reports, status = self.owned()
        for failure in ('key', 'active', 'frontmost', 'frame', 'pending', 'settling'):
            broken_reports, broken_status = copy.deepcopy(reports), status
            if failure == 'key':
                broken_reports[0]['windows'][0]['key'] = False
            elif failure == 'active':
                broken_reports[0]['active'] = False
            elif failure == 'frontmost':
                broken_reports[0]['frontmostPID'] = 999
            elif failure == 'frame':
                broken_reports[0]['windows'][0]['frame'][2] = 0
            elif failure == 'pending':
                broken_status = status.replace('focusPending=false', 'focusPending=true')
            else:
                broken_status = status.replace('settling=0 ', 'settling=1 ')
            with self.subTest(failure=failure), self.assertRaises(RuntimeError):
                perf.owned_observation(fixtures, expected, 'empty', broken_status, state,
                                       broken_reports, set(range(100, 108)))

    def test_native_focus_poll_waits_for_activation_and_times_out_without_it(self):
        import desktop_session
        fixtures, expected, state, reports, status = self.owned()
        clock = Clock()
        def report():
            value = copy.deepcopy(reports[0])
            value['active'] = clock.now >= .15
            return value
        fixtures[0].ask = report
        for i in range(1, 4):
            fixtures[i].ask = lambda i=i: reports[i]
        def command(*args):
            if args[0] == 'status':
                return status
            if args[0] == 'trace':
                return 'window-snapshot mode=full ms=1 discovered=8[100,101,102,103,104,105,106,107] total=8'
            return json.dumps({'monitors': [state]})
        with patch.object(desktop_session, 'command', side_effect=command), \
                patch.object(perf.time, 'monotonic', clock.read), patch.object(perf.time, 'sleep', clock.sleep):
            observed, _ = perf.wait_owned(fixtures, expected, 'empty', set(), timeout=1)
            self.assertEqual(observed['focus'], [0, 'main'])
            self.assertGreaterEqual(clock.now, .45)
            fixtures[0].ask = lambda: {**reports[0], 'active': False}
            with self.assertRaisesRegex(RuntimeError, 'did not converge'):
                perf.wait_owned(fixtures, expected, 'empty', set(), timeout=.2)

    def test_native_creation_barriers_freeze_insertion_before_next_create(self):
        import desktop_session
        import ribbon_stress
        clock, discovered, created, events, diagnostics = Clock(), set(), [], [], []
        fixtures = [SimpleNamespace(application_id=f'fixture.{i}', process=SimpleNamespace(pid=42 + i))
                    for i in range(4)]
        selected = [None]
        def ask(i, operation='report', **fields):
            events.append(operation)
            if operation == 'create':
                if created:
                    self.assertIn(created[-1][2], discovered)
                    self.assertEqual(selected[0], created[-1][2])
                created.append((i, fields['id'], 100 + len(created)))
                if selected[0] is None:
                    selected[0] = created[-1][2]
            windows = [{'id': name, 'windowNumber': number, 'key': number == selected[0],
                        'frame': [number - 100, 0, 100, 100]}
                       for owner, name, number in created if owner == i]
            return {'windows': windows, 'completed': len(windows), 'pending': 0,
                    'active': any(w['key'] for w in windows),
                    'frontmostPID': 42 + next((owner for owner, _, number in created if number == selected[0]), 0)}
        for i, fixture in enumerate(fixtures):
            fixture.ask = lambda operation='report', i=i, **fields: ask(i, operation, **fields)
        def command(*args):
            events.append(' '.join(args))
            if args[0] == 'workspace':
                return 'ok'
            if args[0] == 'focus-column':
                if args[1] in ('first', 'last'):
                    self.assertIn(created[-1][2], discovered)
                    selected[0] = created[-1 if args[1] == 'last' else 0][2]
                else:
                    selected[0] += 1 if args[1] == 'right' else -1
                    diagnostics.append(self.diagnostic(command=' '.join(args), windowID=selected[0],
                                                       generation=11 + len(diagnostics),
                                                       uptimeSeconds=101 + len(diagnostics), expectedWindowCount=0))
                    clock.sleep(.008)
                return 'ok'
            if args[0] == 'status':
                return f'focused={selected[0]} axPending=false focusPending=false animating=false drift=0[] settling=0 posWrites={len(diagnostics)} sizeWrites=0 '
            if args[0] == 'trace':
                discovered.update(row[2] for row in created)
                return ('window-snapshot mode=full ms=1 discovered=8[' + ','.join(map(str, sorted(discovered))) + '] total=8\n'
                        + '\n'.join(f"command-plan cg={r['generation']} windows=0" for r in diagnostics))
            return json.dumps({'monitors': [{'id': 3, 'workspaces': [
                {'id': 'empty', 'kind': 'named', 'active': True, 'windowCount': len(created),
                 'applications': sorted({f'fixture.{i}' for i, _, _ in created})}]}]})
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(desktop_session, 'command', side_effect=command), \
                patch.object(ribbon_stress, 'wait_for_settlement', return_value='displayHz=120'), \
                patch.object(perf, 'diagnostic_marker', return_value=({'sessionID': 'owned-session', 'uptimeSeconds': 100}, 10)), \
                patch.object(perf, 'diagnostic_records', side_effect=lambda _: list(diagnostics)), \
                patch.object(perf.time, 'monotonic', clock.read), patch.object(perf.time, 'sleep', clock.sleep):
            trial = perf.native_trial(fixtures, ['ordinary'], Path(directory))
            evidence = json.loads((Path(directory) / 'readiness.json').read_text())
            driver = [json.loads(line) for line in (Path(directory) / 'ordinary-driver.jsonl').read_text().splitlines()]
        self.assertEqual(trial['participation'], {'ordinary': [0, 0, 0, 0, 0, 0]})
        self.assertEqual(trial['records'][0]['output']['focus'], [0, 'main'])
        self.assertEqual(trial['records'][0]['metrics']['daemon_completed_position_writes'], 6)
        self.assertEqual(trial['records'][0]['metrics']['daemon_completed_size_writes'], 0)
        first, last = events.index('focus-column right'), len(events) - 1 - events[::-1].index('focus-column left')
        self.assertEqual(events[first:last + 1], ['focus-column right', 'focus-column left'] * 3)
        for row, offset in zip(driver, [0, .15, .30, .45, .60, .75]):
            self.assertAlmostEqual(row['beganAt'] - driver[0]['beganAt'], offset)
        self.assertEqual([row['created'] for row in evidence['barriers']], [
            [0, 'main', 100], [0, 'sibling', 101], [1, 'main', 102], [1, 'sibling', 103],
            [2, 'main', 104], [2, 'sibling', 105], [3, 'main', 106], [3, 'sibling', 107]])
        self.assertEqual(evidence['initial']['focus'], [0, 'main'])
        self.assertEqual(evidence['barriers'][-1]['ownedWindowIDs'], list(range(100, 108)))

    def test_native_initial_mismatch_rejects_before_timing(self):
        import desktop_session
        import ribbon_stress
        fixtures = [Mock() for _ in range(4)]
        for i, fixture in enumerate(fixtures):
            fixture.ask.return_value = {'windows': [{'id': 'main', 'windowNumber': 100 + i * 2},
                                                   {'id': 'sibling', 'windowNumber': 101 + i * 2}]}
        state = {'monitors': [{'id': 3, 'workspaces': [
            {'id': 'empty', 'kind': 'named', 'active': True, 'windowCount': 0}]}]}
        initial = {'focus': [0, 'sibling'], 'windows': [[0, 'main', [0, 0, 100, 100]]]}
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(desktop_session, 'command', return_value=json.dumps(state)), \
                patch.object(ribbon_stress, 'wait_for_settlement', return_value='displayHz=120'), \
                patch.object(perf, 'wait_owned', return_value=(initial, [])), \
                patch.object(perf, 'drive_commands', side_effect=AssertionError('Timing began before initial validation')):
            with self.assertRaisesRegex(RuntimeError, 'Initial native focus or frames differ'):
                perf.native_trial(fixtures, ['burst'], Path(directory), expected_initial={'focus': [0, 'main']})
            evidence = json.loads((Path(directory) / 'readiness.json').read_text())
        self.assertEqual(evidence['initial'], {'focus': [0, 'sibling'], 'windows': [[0, 'main', [0, 0, 100, 100]]]})

    def test_fixed_cadence_has_only_commands_and_does_not_add_reply_duration(self):
        clock, calls = Clock(), []
        def send(*args):
            calls.append(args)
            clock.sleep(.008)
        with patch.object(perf.time, 'monotonic', clock.read), patch.object(perf.time, 'sleep', clock.sleep):
            start, driver = perf.drive_commands(['right', 'left', 'cycle-width'], .03, send)
        self.assertEqual(start, 0)
        self.assertEqual(calls, [('focus-column', 'right'), ('focus-column', 'left'), ('cycle-width', 'next')])
        for value, expected in zip([row['beganAt'] for row in driver], [0, .03, .06]):
            self.assertAlmostEqual(value, expected)
        self.assertAlmostEqual(driver[-1]['repliedAt'], .068)

    def test_reply_deadline_and_start_jitter_reject_workload(self):
        for reply_delay, jitter, message in ((.031, 0, 'reply missed'), (0, .01, 'start missed')):
            clock, driver, sent = Clock(), [], []
            def sleep(seconds):
                clock.sleep(seconds + jitter)
            def send(*args):
                sent.append(args)
                clock.sleep(reply_delay)
            with self.subTest(message=message), patch.object(perf.time, 'monotonic', clock.read), \
                    patch.object(perf.time, 'sleep', sleep), self.assertRaisesRegex(RuntimeError, message):
                perf.drive_commands(['right', 'left'], .03, send, driver)
            if reply_delay:
                self.assertEqual(sent, [('focus-column', 'right')])
                self.assertEqual(driver[0]['repliedAt'], .031)
            else:
                self.assertEqual(sent, [])

    def diagnostic(self, **changes):
        record = {'kind': 'command', 'schemaVersion': 1, 'sessionID': 'owned-session',
                  'uptimeSeconds': 101, 'command': 'focus-column right', 'generation': 11,
                  'windowID': 101, 'workspaceID': 'empty', 'monitorID': 3,
                  'expectedWindowCount': 2, 'expectsFocus': True, 'outcome': 'completed',
                  'convergenceMS': 4, 'focusMS': 2}
        record.update(changes)
        return record

    def validate(self, records, **changes):
        options = {'records': records, 'marker': {'sessionID': 'owned-session', 'uptimeSeconds': 100},
                   'generation': 10, 'commands': ['right'], 'targets': [101],
                   'workspace': 'empty', 'monitor': 3, 'trace': 'command-plan cg=11 windows=2',
                   'expected_counts': [2]}
        options.update(changes)
        return perf.validate_diagnostics(**options)

    def test_diagnostics_are_session_sequence_generation_and_target_bound(self):
        record = self.diagnostic()
        records = [self.diagnostic(sessionID='old-session'), self.diagnostic(uptimeSeconds=99), record]
        self.assertEqual(self.validate(records), ([record], [2]))
        for changes in ({'command': 'focus-column left'}, {'generation': 12}, {'windowID': 999},
                        {'workspaceID': 'other'}, {'monitorID': 4}, {'expectedWindowCount': True},
                        {'expectedWindowCount': 0}, {'expectsFocus': False}, {'outcome': 'no-op'},
                        {'outcome': 'superseded'}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.validate([self.diagnostic(**changes)])
        with self.assertRaisesRegex(RuntimeError, 'extra'):
            self.validate([record, self.diagnostic(generation=12)])
        with self.assertRaisesRegex(RuntimeError, 'frozen'):
            self.validate([record], expected_counts=[3])

    def test_width_uses_exact_visible_participation_and_focus_only_zero_is_valid(self):
        width = self.diagnostic(command='cycle-width next', expectsFocus=False)
        self.assertEqual(self.validate([width], commands=['cycle-width']), ([width], [2]))
        with self.assertRaises(RuntimeError):
            self.validate([self.diagnostic(command='cycle-width next', expectsFocus=False, expectedWindowCount=0)],
                          commands=['cycle-width'], trace='command-plan cg=11 windows=0', expected_counts=[0])
        focus_only = self.diagnostic(expectedWindowCount=0)
        self.assertEqual(self.validate([focus_only], trace='command-plan cg=11 windows=0', expected_counts=[0]),
                         ([focus_only], [0]))

    def test_diagnostic_reader_waits_for_complete_lines_without_hiding_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'diagnostics.jsonl'
            path.write_text(json.dumps(self.diagnostic()) + '\n{"kind":')
            self.assertEqual(perf.diagnostic_records(Path(directory)), [self.diagnostic()])
            path.write_text('{invalid}\n')
            with self.assertRaises(json.JSONDecodeError):
                perf.diagnostic_records(Path(directory))

    def preparation(self, directory):
        from verify import bundle_digest
        root, bundle = Path(directory) / 'source', Path(directory) / 'run/staged/Defi.app'
        (root / 'Sources').mkdir(parents=True)
        (root / 'Tests').mkdir()
        (root / 'Package.swift').write_text('manifest')
        (root / 'Sources/main.swift').write_text('source')
        bundle.mkdir(parents=True)
        (bundle / 'payload').write_text('binary')
        names = b'Package.swift\0Sources/main.swift\0'
        digest = hashlib.sha256()
        for name in (b'Package.swift', b'Sources/main.swift'):
            digest.update(name + b'\0')
            digest.update(hashlib.sha256((root / name.decode()).read_bytes()).digest())
        source = {'commit': '1f698cd', 'sha256': digest.hexdigest()}
        record = {'mode': 'local', 'status': 'passed', 'root': str(root), 'source': source,
                  'bundle': str(bundle), 'bundle_sha256': bundle_digest(bundle)}
        metadata = bundle.parent.parent / 'result.json'
        metadata.write_text(json.dumps(record))
        return root, bundle, metadata, record, names

    def test_native_provenance_requires_verified_binding_and_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root, bundle, metadata, record, _ = self.preparation(directory)
            result = perf.verified_bundle_source(bundle)
            self.assertEqual(result, {'verification_sha256': record['source']['sha256'], 'result': str(metadata)})
            (bundle / 'payload').write_text('changed binary')
            with self.assertRaisesRegex(RuntimeError, 'bundle changed'):
                perf.verified_bundle_source(bundle)
            metadata.unlink()
            with self.assertRaisesRegex(RuntimeError, 'Prepare verified bundles'):
                perf.verified_bundle_source(bundle, root)

    def test_stage_only_metadata_requires_success_and_source_equality(self):
        with tempfile.TemporaryDirectory() as directory:
            root, bundle, metadata, record, _ = self.preparation(directory)
            record.pop('mode')
            record.pop('status')
            record.update(preparation='passed', source_after=record['source'], stage_exit_code=0,
                          stage_command=[str(root / 'script/build_and_run.sh'), '--stage'])
            metadata.write_text(json.dumps(record))
            self.assertEqual(perf.verified_bundle_source(bundle)['verification_sha256'], record['source']['sha256'])
            for changes in ({'stage_exit_code': 1}, {'stage_exit_code': False}, {'source_after': {}},
                            {'preparation': 'failed'}, {'stage_command': ['unrelated']}, {'bundle': str(root)}):
                metadata.write_text(json.dumps({**record, **changes}))
                with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                    perf.verified_bundle_source(bundle)

    def test_explicit_snapshot_must_match_linked_verified_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root, bundle, metadata, record, names = self.preparation(directory)
            artifacts = Path(directory) / 'snapshots'
            snapshot = artifacts / 'linked'
            with patch.object(perf, 'ART', artifacts):
                perf.snapshot(root, snapshot)
            with patch.object(perf.subprocess, 'check_output', return_value=names):
                result = perf.verified_bundle_source(bundle, snapshot)
                self.assertEqual(result['snapshot_sha256'], json.loads((snapshot / 'snapshot.json').read_text())['sha256'])
                (root / 'Sources/main.swift').write_text('unrelated source')
                with self.assertRaisesRegex(RuntimeError, 'not bound'):
                    perf.verified_bundle_source(bundle, snapshot)
            with patch.object(perf, 'ART', artifacts):
                unrelated = artifacts / 'unrelated'
                perf.snapshot(root, unrelated)
            (root / 'Sources/main.swift').write_text('source')
            with patch.object(perf.subprocess, 'check_output', return_value=names), \
                    self.assertRaisesRegex(RuntimeError, 'not bound'):
                perf.verified_bundle_source(bundle, unrelated)

    def test_new_snapshot_excludes_generated_cache_and_legacy_manifest_stays_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, _, _, _ = self.preparation(directory)
            (root / 'Tests/__pycache__').mkdir()
            (root / 'Tests/__pycache__/test.pyc').write_bytes(b'old-cache')
            (root / 'Tests/.DS_Store').write_bytes(b'metadata')
            (root / 'Sources/module.pyc').write_bytes(b'cache')
            legacy_files = perf.files(root, version=1)
            (root / 'snapshot.json').write_text(json.dumps({'files': legacy_files, 'sha256': perf.identity(legacy_files)}))
            self.assertEqual(perf.frozen(root)['files']['Tests/__pycache__/test.pyc'], hashlib.sha256(b'old-cache').hexdigest())
            artifacts, snapshot = Path(directory) / 'snapshots', Path(directory) / 'snapshots/new'
            with patch.object(perf, 'ART', artifacts):
                perf.snapshot(root, snapshot)
            self.assertEqual(set(perf.frozen(snapshot)['files']), {'Package.swift', 'Sources/main.swift'})
            self.assertFalse((snapshot / 'Tests/__pycache__').exists())
            (root / 'Tests/__pycache__/test.pyc').write_bytes(b'changed-cache')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                perf.frozen(root)
            (snapshot / 'Tests').chmod(0o755)
            (snapshot / 'Tests/__pycache__').mkdir()
            (snapshot / 'Tests/__pycache__/new.pyc').write_bytes(b'new-cache')
            self.assertEqual(perf.frozen(snapshot)['version'], 2)
            manifest = json.loads((root / 'snapshot.json').read_text())
            manifest['version'] = 3
            (root / 'snapshot.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(RuntimeError, 'Unknown snapshot version'):
                perf.frozen(root)


class Clock:
    def __init__(self):
        self.now = 0

    def read(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


if __name__ == '__main__':
    unittest.main()
