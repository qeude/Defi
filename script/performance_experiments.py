#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'dist/verification/perf-hillclimb-20261008'
INPUTS = ('Sources', 'Tests', 'Package.swift', 'Package.resolved')
SMOKE = {'tests': 1, 'cases': {'accepted-read': {'operations': 32,
         'output': {'accepted': 32, 'reads': 32}, 'metrics': ['elapsed_ms']}},
         'env': {'DEFI_PERF_DELAY_MS': '1'}}
WORKLOADS = {'ordinary': (['right', 'left'] * 3, .15),
             'burst': (['right', 'right', 'left', 'left'] * 2, .03),
             'width': (['cycle-width'] * 3, .15), 'late-create': ([], 0)}


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_hash(bundle):
    return identity({str(p.relative_to(bundle)): sha(p) for p in bundle.rglob('*') if p.is_file()})


def files(root, version=2):
    if version not in (1, 2):
        raise RuntimeError('Unknown snapshot version')
    result = {}
    for name in INPUTS:
        path = root / name
        if not path.exists():
            if name == 'Package.resolved':
                continue
            raise RuntimeError('Missing input: ' + name)
        for item in [path, *sorted(path.rglob('*'))] if path.is_dir() else [path]:
            if version == 2 and any(part == '__pycache__' or part == '.DS_Store' or part.endswith('.pyc')
                                    for part in item.relative_to(root).parts):
                continue
            if item.is_symlink() or any(p in ('.build', 'dist') for p in item.relative_to(root).parts):
                raise RuntimeError('Unsafe snapshot input: ' + str(item))
            if item.is_file():
                result[str(item.relative_to(root))] = sha(item)
    return result


def identity(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def snapshot(source, destination):
    source, destination = source.resolve(), destination.resolve()
    if not destination.is_relative_to(ART.resolve()) or destination.is_relative_to(source / 'Sources') \
            or destination.is_relative_to(source / 'Tests'):
        raise RuntimeError('Snapshots must be outside inputs under ignored experiment artifacts')
    before = files(source)
    destination.mkdir(parents=True, exist_ok=False)
    for name in INPUTS:
        path = source / name
        if path.is_dir():
            shutil.copytree(path, destination / name,
                            ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
        elif path.exists():
            shutil.copy2(path, destination / name)
    if before != files(source) or before != files(destination):
        raise RuntimeError('Source changed during snapshot')
    save(destination / 'snapshot.json', {'version': 2, 'sha256': identity(before), 'files': before})
    for path in destination.rglob('*'):
        path.chmod(0o555 if path.is_dir() else 0o444)
    destination.chmod(0o555)
    return str(destination)


def frozen(path):
    manifest = json.loads((path / 'snapshot.json').read_text())
    if files(path, manifest.get('version', 1)) != manifest['files'] or identity(manifest['files']) != manifest['sha256']:
        raise RuntimeError('Immutable snapshot changed: ' + str(path))
    return manifest


def run(command, log=None, env=None, timeout=600):
    from desktop_lock import inherited_lock
    fd = inherited_lock()
    stream = log.open('w') if log else None
    try:
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env, text=True,
                                stdout=stream or subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                                pass_fds=() if fd is None else (fd,))
    finally:
        if stream:
            stream.close()
    raw = log.read_text() if log else result.stdout
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}; log={log}\n{raw[-2000:]}')
    return raw.strip()


def environment():
    return {'load': os.getloadavg(), 'cores': os.cpu_count(),
            'uptime': run(['uptime']),
            'top_cpu': run(['ps', '-axo', 'pid,pcpu,comm', '-r']).splitlines()[:11]}


def parse_trial(log, contract):
    summaries = re.findall(r'Test run with (\d+) tests?(?: in \d+ suites?)? passed', log)
    xctest = re.findall(r"^Test Case '.+' (passed|failed|skipped) ", log, re.M)
    started = re.findall(r"^Test Case '.+' started\.", log, re.M)
    count = sum(map(int, summaries)) + len(xctest)
    if count != contract['tests'] or count <= 0 or len(started) != len(xctest) \
            or any(x != 'passed' for x in xctest):
        raise RuntimeError('Zero matched, failed or incomplete tests')
    records = [json.loads(line.split('DEFI_PERF_JSON ', 1)[1]) for line in log.splitlines()
               if 'DEFI_PERF_JSON ' in line]
    if len(records) != len(contract['cases']) or {r['case'] for r in records} != set(contract['cases']):
        raise RuntimeError('Missing, duplicate or partial performance emitter')
    for record in records:
        expected = contract['cases'][record['case']]
        if type(record['errors']) is not int or type(record['operations']) is not int \
                or record['errors'] != 0 or record['operations'] != expected['operations'] \
                or record['operations'] <= 0 or record['output'] != expected['output']:
            raise RuntimeError('Errors, no work or incorrect output: ' + record['case'])
        if set(record['metrics']) != set(expected['metrics']) or any(
                type(v) not in (int, float) or not math.isfinite(v) or v < 0
                for v in record['metrics'].values()):
            raise RuntimeError('Invalid or incomplete metrics')
    return {'tests': count, 'operations': sum(r['operations'] for r in records),
            'errors': 0, 'records': records}


def summarize(trials):
    if [(t['side'], t['repeat']) for t in trials] != [(s, i) for i in range(1, 6) for s in 'AB']:
        raise RuntimeError('Incomplete alternating comparison')
    result = {}
    for record in trials[0]['records']:
        for metric in record['metrics']:
            values = {side: [next(r for r in t['records'] if r['case'] == record['case'])['metrics'][metric]
                             for t in trials if t['side'] == side] for side in 'AB'}
            result[record['case'] + '/' + metric] = {
                side: {'median': statistics.median(v), 'range': [min(v), max(v)]}
                for side, v in values.items()}
            result[record['case'] + '/' + metric]['paired_B_minus_A'] = [
                b - a for a, b in zip(values['A'], values['B'])]
    return result


def compare(args, output):
    contract = json.loads(args.contract.read_text()) if args.contract else SMOKE
    if not args.contract and args.filter != 'FrameGeometryReadTests/performanceAcceptedRead':
        raise RuntimeError('Supply a frozen --contract for this test adapter')
    manifests = {s: frozen(p) for s, p in zip('AB', (args.a, args.b))}
    unchanged = lambda m: {k: v for k, v in m['files'].items() if not k.startswith('Sources/')}
    if unchanged(manifests['A']) != unchanged(manifests['B']):
        raise RuntimeError('Tests and Package instrumentation must be identical before treatment')
    save(output / 'contract.json', {'filter': args.filter, 'warmups_per_side': 1,
                                   'order': 'A1B1A2B2A3B3A4B4A5B5', **contract})
    common = {s: ['--package-path', p, '--scratch-path', output / ('build-' + s), '-c', 'release',
                  '-Xswiftc', '-enable-testing']
              for s, p in zip('AB', (args.a, args.b))}
    binaries = {}
    for side in 'AB':
        run(['swift', 'build', *common[side], '--build-tests'], output / (side + '-build.log'))
        binpath = Path(run(['swift', 'build', *common[side], '--show-bin-path']))
        artifacts = sorted(p for p in binpath.rglob('*') if p.is_file() and
                           (p.parent.name == 'MacOS' or p.name.endswith('.xctest')))
        if not artifacts:
            raise RuntimeError('No test binary artifact')
        binaries[side] = {str(p): sha(p) for p in artifacts}
    save(output / 'builds.json', {'sources': manifests, 'binaries': binaries,
         'commands': {s: [str(v) for v in ['swift', 'build', *common[s], '--build-tests']] for s in 'AB'},
         'toolchain': run(['swift', '--version'])})
    env = {**os.environ, **contract.get('env', {}), 'DEFI_PERF_JSON': '1'}
    env['DEFI_E2E'] = '0'
    trials = []
    for repeat in range(6):
        for side in 'AB':
            load = environment()
            log = output / f'{side}{repeat}.log'
            start = time.monotonic()
            raw = run(['swift', 'test', *common[side], '--skip-build', '--filter', args.filter], log, env)
            trial = {**parse_trial(raw, contract), 'side': side, 'repeat': repeat,
                     'wall_ms': (time.monotonic() - start) * 1000, 'environment': load,
                     'artifacts': {str(log): sha(log)}}
            save(output / f'{side}{repeat}.json', trial)
            print(f'{side}{repeat}: tests={trial["tests"]} operations={trial["operations"]} errors={trial["errors"]}', flush=True)
            if repeat:
                trials.append(trial)
    for side, path in zip('AB', (args.a, args.b)):
        frozen(path)
        if any(sha(Path(p)) != digest for p, digest in binaries[side].items()):
            raise RuntimeError('Binary changed during comparison')
    save(output / 'comparison.json', {'trials': trials, 'summary': summarize(trials),
                                     'verdict': 'measurement only; parent decides applicability'})


class Fixture:
    def __init__(self, binary, log):
        contents = log.with_suffix('.app') / 'Contents'
        executable = contents / 'MacOS' / 'PerformanceFixture'
        executable.parent.mkdir(parents=True, exist_ok=False)
        shutil.copy2(binary, executable)
        self.application_id = 'com.quentin.defi.performancefixture.' + \
                              hashlib.sha256(str(log.resolve()).encode()).hexdigest()[:12]
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': self.application_id,
            'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'PerformanceFixture',
            'NSPrincipalClass': 'NSApplication'}))
        self.log = log.open('w')
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0

    def ask(self, command='report', **fields):
        self.sequence += 1
        self.process.stdin.write(json.dumps({'seq': self.sequence, 'command': command, **fields}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not self.selector.select(max(0, deadline - time.monotonic())):
                break
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('Fixture exited before completing operation')
            self.log.write(line)
            self.log.flush()
            report = json.loads(line)
            if report['errors'] or report.get('error'):
                raise RuntimeError('Fixture error: ' + line)
            if report.get('seq') == self.sequence:
                return report
        raise RuntimeError('Fixture response timed out')

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.log.close()


def settled(status):
    return all(token in status for token in
               ('axPending=false', 'focusPending=false', 'animating=false', 'drift=0[', 'settling=0 '))


def frame_write_delta(before, after):
    counts = {}
    for metric, field in (('daemon_completed_position_writes', 'posWrites'),
                          ('daemon_completed_size_writes', 'sizeWrites')):
        values = [re.search(r'\b' + field + r'=(\d+)(?=\s|$)', status) for status in (before, after)]
        if any(value is None for value in values):
            raise RuntimeError('Missing frame write counter: ' + field)
        change = int(values[1].group(1)) - int(values[0].group(1))
        if change < 0:
            raise RuntimeError('Frame write counter reset during workload')
        counts[metric] = change
    return counts


def owned_observation(fixtures, expected, workspace, status, state, reports, discovered,
                      require_focus=True, selected=None):
    windows = [(i, w) for i, report in enumerate(reports) for w in report['windows']]
    actual = [(i, w['id'], w['windowNumber']) for i, w in windows]
    owned_ids = {row[2] for row in expected}
    apps = {fixtures[i].application_id for i, _, _ in expected}
    active = next((w for w in state['workspaces'] if w['active']), None)
    if not expected or actual != sorted(expected) or len(owned_ids) != len(expected) \
            or not owned_ids.issubset(discovered) or active is None \
            or active['id'] != workspace or active['windowCount'] != len(expected) \
            or set(active['applications']) != apps \
            or any(apps.intersection(w['applications']) for w in state['workspaces'] if not w['active']):
        raise RuntimeError('Missed owned discovery, foreign window or workspace change')
    if sum(r['completed'] for r in reports) != len(expected) or any(r['pending'] for r in reports):
        raise RuntimeError('Incomplete fixture operations')
    match = re.search(r'\bfocused=(\d+)', status)
    focused = int(match.group(1)) if match else None
    target = next(((i, w) for i, w in windows if w['windowNumber'] == focused), None)
    if target is None or (selected is not None and focused != selected):
        raise RuntimeError('Wrong logical focus')
    i, window = target
    if require_focus and (not window['key'] or not reports[i]['active']
                          or reports[i]['frontmostPID'] != fixtures[i].process.pid):
        raise RuntimeError('Wrong native focus; command focus is only writer completion')
    if not settled(status):
        raise RuntimeError('Unsettled native frames')
    if any(not all(math.isfinite(v) for v in w['frame']) or min(w['frame'][2:]) <= 0 for _, w in windows):
        raise RuntimeError('Invalid native frame')
    return {'focus': [i, window['id']],
            'windows': [[i, w['id'], w['frame']] for i, w in windows]}, reports


def wait_owned(fixtures, expected, workspace, discovered, require_focus=True, selected=None, timeout=15):
    import desktop_session as session
    deadline, stable_since, previous = time.monotonic() + timeout, None, None
    error = 'No observation'
    while time.monotonic() < deadline:
        status = session.command('status')
        monitors = json.loads(session.command('list-workspaces', '--json'))['monitors']
        if len(monitors) != 1:
            raise RuntimeError('Frozen native workload requires one monitor')
        trace = session.command('trace')
        for group in re.findall(r'window-snapshot .*?discovered=\d+\[([\d,]*)\]', trace):
            discovered.update(int(value) for value in group.split(',') if value)
        reports = [fixture.ask() for fixture in fixtures]
        try:
            observation = owned_observation(fixtures, expected, workspace, status, monitors[0], reports,
                                            discovered, require_focus, selected)
        except RuntimeError as failure:
            error, stable_since, previous = str(failure), None, None
        else:
            now = time.monotonic()
            if observation[0] != previous:
                stable_since, previous = now, observation[0]
            if now - stable_since >= .30:
                return observation
        time.sleep(.05)
    raise RuntimeError(f'Owned readiness/native focus did not converge within {timeout}s: {error}')


def drive_commands(commands, interval, send, driver=None):
    start = time.monotonic()
    driver = [] if driver is None else driver
    tolerance = max(.005, interval * .20)
    for index, command in enumerate(commands):
        planned = start + index * interval
        time.sleep(max(0, planned - time.monotonic()))
        began = time.monotonic()
        if began - planned > tolerance or (driver and abs(began - driver[-1]['beganAt'] - interval) > tolerance):
            raise RuntimeError('Command start missed frozen cadence tolerance')
        row = {'command': command, 'plannedAt': planned, 'beganAt': began, 'repliedAt': None}
        driver.append(row)
        send(*(['cycle-width', 'next'] if command == 'cycle-width' else ['focus-column', command]))
        replied = row['repliedAt'] = time.monotonic()
        if replied > planned + interval:
            raise RuntimeError('Command reply missed frozen deadline; workload rejected')
    return start, driver


def diagnostic_records(directory):
    records = []
    for path in directory.glob('diagnostics*.jsonl'):
        for line in path.read_text().splitlines(keepends=True):
            if line.endswith('\n'):
                records.append(json.loads(line))
    return records


def diagnostic_marker(directory):
    import desktop_session as session
    previous = {(r['sessionID'], r['uptimeSeconds']) for r in diagnostic_records(directory)
                if r.get('kind') == 'marker'}
    session.command('diagnostic-mark')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        markers = [r for r in diagnostic_records(directory) if r.get('kind') == 'marker'
                   and (r['sessionID'], r['uptimeSeconds']) not in previous]
        if len(markers) == 1:
            marker = markers[0]
            generations = [int(g) for g in re.findall(r'command-start cg=(\d+)', marker['trace'])]
            if not generations:
                raise RuntimeError('Readiness has no real command generation')
            return marker, max(generations)
        if len(markers) > 1:
            raise RuntimeError('Extra diagnostic markers during workload setup')
        time.sleep(.05)
    raise RuntimeError('Missing workload diagnostic marker')


def validate_diagnostics(records, marker, generation, commands, targets, workspace, monitor,
                         trace, expected_counts=None):
    diagnostics = sorted((r for r in records if r.get('kind') == 'command'
                          and r.get('sessionID') == marker['sessionID']
                          and r.get('uptimeSeconds', 0) > marker['uptimeSeconds']),
                         key=lambda r: r['generation'])
    plans = {int(g): int(count) for g, count in
             re.findall(r'command-plan cg=(\d+) windows=(\d+)', trace)}
    if len(diagnostics) != len(commands) or len(targets) != len(commands):
        raise RuntimeError('Missing/extra command diagnostic records')
    counts = []
    for index, (record, command, target) in enumerate(zip(diagnostics, commands, targets)):
        current = generation + index + 1
        count = record.get('expectedWindowCount')
        if record.get('generation') != current \
                or record.get('command') != ('cycle-width next' if command == 'cycle-width' else 'focus-column ' + command) \
                or record.get('windowID') != target or record.get('workspaceID') != workspace \
                or record.get('monitorID') != monitor \
                or record.get('outcome') not in ('completed', 'superseded') \
                or type(count) is not int or not 0 <= count <= 8 \
                or plans.get(current) != count \
                or record.get('expectsFocus') is not (command != 'cycle-width') \
                or (command == 'cycle-width' and count == 0):
            raise RuntimeError('Wrong command sequence, ownership, generation or participation')
        counts.append(count)
    if expected_counts is not None and counts != expected_counts:
        raise RuntimeError('Command participation differs from frozen A warmup')
    if diagnostics and diagnostics[-1]['outcome'] != 'completed':
        raise RuntimeError('Final command did not complete')
    return diagnostics, counts


def native_trial(fixtures, workloads, output, expected_participation=None, expected_initial=None):
    import desktop_session as session
    from ribbon_stress import wait_for_settlement
    workspace_state = json.loads(session.command('list-workspaces', '--json'))
    if len(workspace_state['monitors']) != 1:
        raise RuntimeError('Frozen native workload requires one monitor')
    monitor = workspace_state['monitors'][0]
    empty = next((w for w in monitor['workspaces'] if w['kind'] == 'named' and w['windowCount'] == 0), None)
    empty = empty or next((w for w in monitor['workspaces'] if w['kind'] == 'trailing' and w['windowCount'] == 0), None)
    if empty is None:
        raise RuntimeError('No existing empty workspace')
    session.command('workspace', empty['id'])
    if 'displayHz=120' not in wait_for_settlement():
        raise RuntimeError('Frozen native workload requires 120 Hz')
    expected, discovered, readiness = [], set(), []
    for i, fixture in enumerate(fixtures):
        for name in ('main', 'sibling'):
            began = time.monotonic()
            report = fixture.ask('create', id=name)
            window = next(w for w in report['windows'] if w['id'] == name)
            expected.append((i, name, window['windowNumber']))
            wait_owned(fixtures, expected, empty['id'], discovered)
            session.command('focus-column', 'last')
            observed, _ = wait_owned(fixtures, expected, empty['id'], discovered,
                                     selected=window['windowNumber'])
            readiness.append({'created': [i, name, window['windowNumber']],
                              'elapsedMS': (time.monotonic() - began) * 1000,
                              'ownedWindowIDs': sorted(discovered.intersection(row[2] for row in expected)),
                              'observation': observed})
            save(output / 'readiness.json', {'barriers': readiness})
    if len(expected) != 8:
        raise RuntimeError('Frozen native workload requires eight owned windows')
    session.command('focus-column', 'last')
    wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[-1][2])
    session.command('focus-column', 'first')
    initial, _ = wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[0][2])
    save(output / 'readiness.json', {'barriers': readiness, 'initial': initial,
                                    'focusCommands': ['focus-column last', 'focus-column first']})
    if expected_initial is not None and initial != expected_initial:
        raise RuntimeError('Initial native focus or frames differ from frozen A warmup')
    records, participation = [], {}
    directory = Path.home() / 'Library/Logs/Defi/Diagnostics'
    current_index = 0
    for workload in workloads:
        commands, interval = WORKLOADS[workload]
        marker, generation = diagnostic_marker(directory)
        before_writes = session.command('status')
        targets = []
        for command in commands:
            if command == 'right':
                current_index += 1
            elif command == 'left':
                current_index -= 1
            if not 0 <= current_index < 8:
                raise RuntimeError('Frozen command would be a boundary no-op')
            targets.append(expected[current_index][2])
        driver = []
        try:
            start, driver = drive_commands(commands, interval, session.command, driver)
        finally:
            (output / (workload + '-driver.jsonl')).write_text(''.join(json.dumps(r) + '\n' for r in driver))
        if workload == 'late-create':
            report = fixtures[3].ask('delayed-create', id='late', delay=0.35)
            deadline = time.monotonic() + 10
            while not any(w['id'] == 'late' for w in report['windows']):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Missed delayed creation')
                time.sleep(.02)
                report = fixtures[3].ask()
            window = next(w for w in report['windows'] if w['id'] == 'late')
            expected.append((3, 'late', window['windowNumber']))
        final, reports = wait_owned(fixtures, expected, empty['id'], discovered,
                                    selected=targets[-1] if targets else None)
        end = time.monotonic()
        deadline = time.monotonic() + 5
        while True:
            raw = diagnostic_records(directory)
            matching = [r for r in raw if r.get('kind') == 'command'
                        and r.get('sessionID') == marker['sessionID']
                        and r.get('uptimeSeconds', 0) > marker['uptimeSeconds']]
            if len(matching) >= len(commands) or time.monotonic() >= deadline:
                break
            time.sleep(.05)
        diagnostics, counts = validate_diagnostics(raw, marker, generation, commands, targets,
                                                   empty['id'], monitor['id'], session.command('trace'),
                                                   None if expected_participation is None else expected_participation[workload])
        participation[workload] = counts
        metrics = {'native_verified_workload_ms': (end - start) * 1000,
                   'last_command_to_native_verified_ms': (end - (driver[-1]['beganAt'] if driver else start)) * 1000}
        metrics.update(frame_write_delta(before_writes, session.command('status')))
        if driver:
            metrics['command_burst_ms'] = (driver[-1]['repliedAt'] - driver[0]['beganAt']) * 1000
            metrics['last_command_reply_ms'] = (driver[-1]['repliedAt'] - driver[-1]['beganAt']) * 1000
            convergence = diagnostics[-1].get('convergenceMS')
            if type(convergence) not in (int, float) or not math.isfinite(convergence) or convergence < 0:
                raise RuntimeError('Missing final production convergence metric')
            metrics['diagnostic_convergence_ms'] = convergence
        save(output / (workload + '-observations.json'), {'initial': initial, 'final': final, 'fixtures': reports,
                                                        'nativeVerifiedAt': end, 'marker': marker})
        (output / (workload + '-diagnostics.jsonl')).write_text(''.join(json.dumps(r) + '\n' for r in diagnostics))
        records.append({'case': workload, 'operations': len(commands) or 1, 'errors': 0,
                        'metrics': metrics, 'output': final})
    return {'records': records, 'operations': sum(r['operations'] for r in records), 'errors': 0,
            'participation': participation, 'initial': initial}


def verified_bundle_source(bundle, source=None):
    from verify import bundle_digest
    metadata = bundle.parent.parent / 'result.json'
    try:
        record = json.loads(metadata.read_text())
    except (OSError, ValueError) as error:
        raise RuntimeError('Prepare verified bundles with python3 script/verify.py local --stage; missing result.json') from error
    root = Path(record.get('root', ''))
    stage_only = (record.get('preparation') == 'passed'
                  and type(record.get('stage_exit_code')) is int and record['stage_exit_code'] == 0
                  and record.get('source_after') == record.get('source')
                  and record.get('stage_command') == [str(root / 'script/build_and_run.sh'), '--stage'])
    valid = (record.get('mode') == 'local' and record.get('status') == 'passed') or \
            (record.get('mode') == 'full' and record.get('preparation') == 'passed') or stage_only
    if not valid or not root.is_absolute() or Path(record.get('bundle', '')).resolve() != bundle.resolve() \
            or record.get('bundle_sha256') != bundle_digest(bundle):
        raise RuntimeError('Invalid preparation or staged bundle changed since source verification')
    source_hash = record.get('source', {}).get('sha256')
    if not isinstance(source_hash, str) or not re.fullmatch('[0-9a-f]{64}', source_hash):
        raise RuntimeError('Missing verified source hash')
    provenance = {'verification_sha256': source_hash, 'result': str(metadata)}
    if source is not None:
        manifest = frozen(source)
        names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root)
        digest = hashlib.sha256()
        for name in sorted(set(names.split(b'\0')) - {b''}):
            path = root / os.fsdecode(name)
            digest.update(name + b'\0')
            digest.update(hashlib.sha256(path.read_bytes()).digest() if path.is_file() else b'missing')
        if digest.hexdigest() != source_hash or files(root, manifest.get('version', 1)) != manifest['files']:
            raise RuntimeError('Explicit snapshot is not bound to the verified bundle source; prepare verified bundles')
        provenance['snapshot_sha256'] = manifest['sha256']
    return provenance


def native_compare(args, output):
    import desktop_session as session
    from desktop_lock import inherited_lock
    if inherited_lock() is None:
        os.execv(sys.executable, [sys.executable, str(ROOT / 'script/desktop_lock.py'), '--wait',
                                 sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    installed = Path.home() / 'Applications/Defi.app'
    original = output / 'original.app'
    run(['ditto', installed, original])
    bundles = {'A': args.a.resolve(), 'B': args.b.resolve()}
    if len(set(args.workload)) != len(args.workload) or ('late-create' in args.workload and args.workload[-1] != 'late-create'):
        raise RuntimeError('Frozen workloads must be unique and late-create must run last')
    sources = {side: verified_bundle_source(bundle, getattr(args, side.lower() + '_source', None))
               for side, bundle in bundles.items()}
    final = args.final_bundle.resolve() if args.final_bundle else original
    for bundle in [*bundles.values(), final]:
        run([ROOT / 'script/check_signing.sh', installed, bundle])
    binary = output / 'PerformanceFixture'
    run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', binary])
    contract = {'workloads': {w: WORKLOADS[w] for w in args.workload},
         'processes': 4, 'windows': [2, 2, 2, 2], 'repeats': 5, 'keyboard_probe': 'deferred',
         'cadence': {'start_tolerance': 'max(5ms, interval * 0.20)', 'reply_deadline': 'planned start + interval'},
         'readiness': 'per-window owned discovery then explicit last focus; final first focus; native focus and frames stable for 300ms',
         'bundle_hashes': {s: bundle_hash(b) for s, b in bundles.items()}, 'sources': sources,
         'fixture_sha256': sha(binary), 'fixture_source_sha256': sha(ROOT / 'Tests/Fixtures/PerformanceFixture.swift'),
         'original_bundle_sha256': bundle_hash(original), 'final_bundle_sha256': bundle_hash(final)}
    config = Path.home() / '.config/defi/config.toml'
    contract['config_sha256'] = sha(config) if config.exists() else 'code defaults'
    save(output / 'contract.json', contract)
    fixtures, trials = [], []
    checkpoint = output / 'checkpoint'
    def install(bundle):
        run([ROOT / 'script/check_signing.sh', installed, bundle])
        run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while 'monitors=1[' not in session.command('status'):
            if time.monotonic() >= deadline:
                raise RuntimeError('Installed daemon did not discover the frozen monitor')
            time.sleep(.05)
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon')
    def interrupted(*_):
        raise KeyboardInterrupt()
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        fixtures.append(Fixture(binary, output / 'native-focus.jsonl'))
        initial_native = fixtures[0].ask('native-focus')['nativeFocus']
        if not initial_native['available']:
            raise RuntimeError('Public native focus read unavailable; checkpoint not attempted')
        fixtures[0].close()
        fixtures.clear()
        save(output / 'initial-native-focus.json', initial_native)
        session.checkpoint(checkpoint)
        session.start()
        for repeat in range(6):
            for side in 'AB':
                install(bundles[side])
                if bundle_hash(bundles[side]) != contract['bundle_hashes'][side] or \
                        (sha(config) if config.exists() else 'code defaults') != contract['config_sha256']:
                    raise RuntimeError('Bundle or configuration changed')
                trial_dir = output / f'{side}{repeat}'
                trial_dir.mkdir()
                load = environment()
                for i in range(4):
                    fixtures.append(Fixture(binary, trial_dir / f'fixture-{i}.jsonl'))
                trial = {**native_trial(fixtures, args.workload, trial_dir, contract.get('expected_participation'),
                                       contract.get('expected_initial')), 'side': side,
                         'repeat': repeat, 'environment': load}
                outputs = {r['case']: r['output'] for r in trial['records']}
                if side == 'A' and repeat == 0:
                    contract['expected_outputs'] = outputs
                    contract['expected_initial'] = trial['initial']
                    contract['expected_participation'] = trial['participation']
                    save(output / 'contract.json', contract)
                elif outputs != contract['expected_outputs']:
                    raise RuntimeError('Native focus or frames differ from frozen baseline outputs')
                print(f'{side}{repeat}: operations={trial["operations"]} errors={trial["errors"]}', flush=True)
                for fixture in fixtures:
                    fixture.close()
                fixtures.clear()
                trial['artifacts'] = {str(p): sha(p) for p in trial_dir.iterdir() if p.is_file()}
                save(output / f'{side}{repeat}.json', trial)
                if repeat:
                    trials.append(trial)
        if sources != {side: verified_bundle_source(bundle, getattr(args, side.lower() + '_source', None))
                       for side, bundle in bundles.items()}:
            raise RuntimeError('Source provenance changed during comparison')
        if any(bundle_hash(b) != contract['bundle_hashes'][s] for s, b in bundles.items()):
            raise RuntimeError('Bundle changed during comparison')
        save(output / 'comparison.json', {'trials': trials, 'summary': summarize(trials)})
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            cleanup_errors = []
            for fixture in fixtures:
                try:
                    fixture.close()
                except BaseException as error:
                    cleanup_errors.append(str(error))
            if (checkpoint / 'ready').exists():
                try:
                    if bundle_hash(final) != contract['final_bundle_sha256']:
                        raise RuntimeError('Final restoration bundle changed')
                    install(final)
                except BaseException as installation_error:
                    try:
                        session.restore(checkpoint)
                    except BaseException as restoration_error:
                        raise installation_error from restoration_error
                    raise
                else:
                    session.restore(checkpoint)
                observer = Fixture(binary, output / 'restored-native-focus.jsonl')
                try:
                    restored = observer.ask('native-focus')['nativeFocus']
                    if restored != initial_native or session.daemon_count() != 1:
                        raise RuntimeError('Native focus restoration incomplete')
                finally:
                    observer.close()
            if cleanup_errors:
                raise RuntimeError('Fixture cleanup failed: ' + '; '.join(cleanup_errors))
        finally:
            signal.signal(signal.SIGTERM, previous)


def main():
    parser = argparse.ArgumentParser(description='Compare frozen release and owned-window workloads.')
    commands = parser.add_subparsers(dest='command', required=True)
    snap = commands.add_parser('snapshot')
    snap.add_argument('name')
    snap.add_argument('--source', type=Path, default=ROOT)
    for name in ('compare', 'native-compare'):
        sub = commands.add_parser(name)
        sub.add_argument('a', type=Path)
        sub.add_argument('b', type=Path)
        sub.add_argument('--output', type=Path, required=True)
        if name == 'compare':
            sub.add_argument('--filter', required=True)
            sub.add_argument('--contract', type=Path)
        else:
            sub.add_argument('--final-bundle', type=Path)
            sub.add_argument('--a-source', type=Path)
            sub.add_argument('--b-source', type=Path)
            sub.add_argument('--workload', nargs='+', choices=WORKLOADS, default=list(WORKLOADS))
    args = parser.parse_args()
    if args.command == 'snapshot':
        print(snapshot(args.source, ART / 'snapshots' / args.name))
        return
    output = args.output.resolve()
    if not output.is_relative_to(ART.resolve()):
        parser.error('Use an output directory under ignored experiment artifacts')
    if args.command == 'native-compare':
        from desktop_lock import inherited_lock
        if inherited_lock() is None:
            os.execv(sys.executable, [sys.executable, str(ROOT / 'script/desktop_lock.py'), '--wait',
                                     sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    output.mkdir(parents=True, exist_ok=False)
    try:
        (compare if args.command == 'compare' else native_compare)(args, output)
    except BaseException as error:
        save(output / 'failure.json', {'error': str(error), 'type': type(error).__name__})
        raise
    print(output / 'comparison.json')


if __name__ == '__main__':
    main()
