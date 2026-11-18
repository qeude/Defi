#!/usr/bin/env python3
"""Fluidity probe: A/B comparison of Defi builds per user action on the real display.
Fixture windows only: column and workspace navigation, window open and close, app launch and
quit, activation (Command-Tab's native path), Overview and cheatsheet. Screen capture cannot judge
120 Hz: a light Instruments recording (Hitches and Points of Interest, ~30 MB) attached to the daemon
gives the compositor's renders, and Defi's `motion` signposts say when something animates.
Per action and trial: share of render gaps <= 10 ms inside animations, worst gap (spikes over
SYSTEM_SPIKE_MS, which macOS shows with Defi stopped, are counted apart), hitches, daemon CPU and
wakeups (proc_pid_rusage), AX writes; per trial: idle CPU, idle wakeups and memory.
Builds alternate ABBA... so drift hits both; run A against A first to learn each metric's noise.
Usage (under the desktop lock): script/fluidity_probe.py OUT --bundle LABEL=path [...] [--trials N]
Restores the original bundle and session."""
import argparse, ctypes, datetime, glob, json, os, re, shutil, statistics, subprocess, sys, time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import desktop_fixtures as pe  # noqa: E402

SYSTEM_SPIKE_MS = 30
SMOOTH_MS = 10
IDLE_S = 10


class RUsage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired', 'resident', 'footprint')] + \
        [('rest', ctypes.c_uint64 * 32)]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


_libc = ctypes.CDLL('/usr/lib/libSystem.dylib')
_timebase = Timebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))


def usage(pid):
    """CPU ms, wakeups and footprint MiB of a process, read without spawning one."""
    info = RUsage()
    if _libc.proc_pid_rusage(int(pid), 2, ctypes.byref(info)):
        raise OSError(f'proc_pid_rusage {pid}')
    ticks = (info.user + info.system) * _timebase.numer / _timebase.denom
    return {'cpu_ms': ticks / 1e6, 'wakeups': info.idle_wakeups + info.interrupt_wakeups,
            'footprint_mib': info.footprint / 2 ** 20, 'resident_mib': info.resident / 2 ** 20}


def rows(path):
    """An exported xctrace table's rows as dicts, resolving its id/ref sharing."""
    root = ET.parse(path).getroot()
    ids, columns = {}, [c.findtext('mnemonic') for c in root.iter('col')]
    for row in root.iter('row'):
        for element in row.iter():
            if 'id' in element.attrib:
                ids[element.attrib['id']] = element
        values = [ids[e.attrib['ref']] if 'ref' in e.attrib else e for e in row]
        yield dict(zip(columns, values))


def motion_windows(signposts):
    """Union of [begin, end] spans from ('begin'|'end', key, seconds) signposts, sorted by time."""
    spans, open_at = [], {}
    for at, edge, key in sorted(signposts):
        if edge == 'begin':
            open_at.setdefault(key, at)
        elif key in open_at:
            spans.append((open_at.pop(key), at))
    merged = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def render_gaps(windows, renders):
    """Per window, ms gaps from its start to each render inside it, with the ms offset of each
    gap's end from the window start; renders merged within 2 ms."""
    renders = sorted(renders)
    merged = [t for i, t in enumerate(renders) if i == 0 or t - renders[i - 1] > .002]
    result = []
    for start, end in windows:
        inside = [t for t in merged if start <= t <= end]
        # The motion's end closes the last gap: renders that stop early are missing frames.
        points = [start] + inside + ([end] if not inside or end - inside[-1] > .002 else [])
        result.append((start, [((b - a) * 1e3, (b - start) * 1e3) for a, b in zip(points, points[1:])]))
    return result


def owner(marks, at):
    """The action whose mark is the latest at or before `at`."""
    name = None
    for when, action in marks:
        if when > at:
            break
        name = action
    return name


def attribute(marks, windows, renders, hitches):
    """Per action: render gaps inside its animations and hitches after its mark.
    `marks` are (seconds, action); everything shares one clock."""
    marks = sorted(marks, key=lambda mark: mark[0])
    # A None mark ends the workload: fixture teardown after it belongs to no action.
    result = {action: {'events': 0, 'gaps': 0, 'smooth': 0, 'spikes': 0, 'worst_ms': 0.0, 'hitches': 0,
                       'animations': 0} for _, action in marks if action is not None}
    for _, action in marks:
        if action is not None:
            result[action]['events'] += 1
    for start, gaps in render_gaps(windows, renders):
        action = owner(marks, start)
        if action is None:
            continue
        entry = result[action]
        entry['animations'] += 1
        for gap, offset in gaps:
            if gap > SMOOTH_MS:
                entry.setdefault('late_at_ms', []).append(round(offset))
            if gap > SYSTEM_SPIKE_MS:
                entry['spikes'] += 1
                continue
            entry['gaps'] += 1
            entry['smooth'] += gap <= SMOOTH_MS
            entry['worst_ms'] = round(max(entry['worst_ms'], gap), 2)
    for start, duration in hitches:
        action = owner(marks, start)
        if action and duration <= SYSTEM_SPIKE_MS:
            result[action]['hitches'] += 1
    return result


def scenario(out, label, rounds, on_ready, only=None):
    """Runs the workload; returns marks and per-action CPU, wakeups and AX writes."""
    marks, costs = [], {}
    pid = daemon_pid()

    def counters():
        status = pe.command('status')
        snapshots = re.search(r'\bsnapshots=(\d+)/(\d+)/(\d+)', status)
        return {'ax_writes': sum(int(re.search(r'\b' + f + r'=(\d+)', status).group(1)) for f in ('posWrites', 'sizeWrites')),
                'full_snapshots': int(snapshots.group(1)), 'snapshots': int(snapshots.group(2)),
                'inventories': int(re.search(r'\bappInventories=(\d+)', status).group(1))}

    def act(name, body, pause):
        counted = counters()
        before = usage(pid)
        marks.append((time.time(), name))
        body()
        time.sleep(pause)
        after = usage(pid)  # before the status read, whose cost is not the action's
        entry = costs.setdefault(name, {'cpu_ms': 0.0, 'wakeups': 0})
        entry['cpu_ms'] += after['cpu_ms'] - before['cpu_ms']
        entry['wakeups'] += after['wakeups'] - before['wakeups']
        for key, value in counters().items():
            entry[key] = entry.get(key, 0) + value - counted[key]

    def go(name, *args, pause=.9):
        act(name, lambda: subprocess.run([str(pe.CLI), *args], check=True, capture_output=True), pause)

    fixture = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-fixture.jsonl')
    other = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-other.jsonl')
    try:
        fixture.ask()
        other.ask()
        pe.activate(fixture.process.pid)
        monitor = json.loads(pe.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)
        pe.command('workspace', empty['id'])
        time.sleep(1)
        expected, discovered = [], set()
        for n in range(5):
            report = fixture.ask('create', id=f'w{n}')
            expected.append((0, f'w{n}', next(w['windowNumber'] for w in report['windows'] if w['id'] == f'w{n}')))
            pe.wait_owned([fixture], expected, empty['id'], discovered)
        pe.command('focus-column', 'first')
        time.sleep(1.5)
        on_ready()

        def launch_and_quit():
            holder = {}

            def launch():
                launched = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-launch-{len(marks)}.jsonl')
                launched.ask()  # registered with LaunchServices: activation can find it
                pe.activate(launched.process.pid)
                launched.ask('create', id='only')
                holder['app'] = launched
            act('launch', launch, 1.5)
            act('quit', lambda: holder['app'].close(), 1.2)

        for _ in range(rounds):
            if only == 'overview':
                for _ in range(8):
                    go('overview-open', 'toggle-overview', pause=1)
                    go('overview-close', 'toggle-overview', pause=1)
                continue
            if only == 'window':
                for n in range(4):
                    act('open', lambda n=n: fixture.ask('create', id=f'extra{n}-{time.time()}'), 1.2)
                for window in [w for w in fixture.ask()['windows'] if str(w['id']).startswith('extra')]:
                    act('close', lambda w=window: fixture.ask('close', id=w['id']), 1.2)
                continue
            if only == 'workspace':
                for direction in ['down', 'up'] * 4:
                    go('workspace', 'focus-workspace', direction)
                continue
            if only == 'cheatsheet':
                for _ in range(8):
                    go('cheatsheet-open', 'toggle-cheatsheet', pause=.8)
                    go('cheatsheet-close', 'toggle-cheatsheet', pause=.8)
                continue
            for direction in ['right'] * 3 + ['left'] * 3:
                go('column', 'focus-column', direction)
            if only == 'column':
                continue
            for direction in ['down', 'up'] * 2:
                go('workspace', 'focus-workspace', direction)
            for n in range(2):
                act('open', lambda n=n: fixture.ask('create', id=f'extra{n}-{time.time()}'), 1.2)
            for window in [w for w in fixture.ask()['windows'] if str(w['id']).startswith('extra')]:
                act('close', lambda w=window: fixture.ask('close', id=w['id']), 1.2)
            launch_and_quit()
            pe.activate(other.process.pid)
            other.ask('create', id=f'activate-{time.time()}')
            time.sleep(1.2)
            for target in [fixture.process.pid, other.process.pid] * 2:
                act('activate', lambda t=target: pe.activate(t), .9)
            pe.activate(fixture.process.pid)
            time.sleep(.6)
            for _ in range(2):
                go('overview-open', 'toggle-overview', pause=1)
                go('overview-close', 'toggle-overview', pause=1)
                go('cheatsheet-open', 'toggle-cheatsheet', pause=.8)
                go('cheatsheet-close', 'toggle-cheatsheet', pause=.8)
        return marks, costs
    finally:
        marks.append((time.time(), None))
        other.close()
        fixture.close()


def daemon_pid():
    pids = subprocess.run(['pgrep', '-x', 'defi-daemon'], capture_output=True, text=True).stdout.split()
    if len(pids) != 1:
        raise RuntimeError(f'expected one defi-daemon, found {pids}')
    return pids[0]


def export(trace, schema, path):
    path.write_bytes(subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
                                     f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                                    capture_output=True, check=True).stdout)


def analyze(directory, marks):
    toc = ET.parse(directory / 'toc.xml').getroot()
    base = datetime.datetime.fromisoformat(next(toc.iter('start-date')).text.replace('Z', '+00:00')).timestamp()
    signposts = []
    for row in rows(directory / 'signposts.xml'):
        message = row['message'].get('fmt') or ''
        match = re.match(r'(begin|end) (\S+ \d+)', message)
        if match:
            signposts.append((int(row['time'].text) / 1e9 + base, match.group(1), match.group(2)))
    by_display = {}
    for row in rows(directory / 'renders.xml'):
        by_display.setdefault(row['display'].get('fmt'), []).append(int(row['start'].text) / 1e9 + base)
    windows = motion_windows(signposts)

    def inside(times):
        return sum(any(a <= t <= b for a, b in windows) for t in times)
    renders = max(by_display.values(), key=inside) if by_display else []
    hitches = {}
    for row in rows(directory / 'hitches.xml'):
        hitches[int(row['start'].text)] = int(row['duration'].text) / 1e6
    return attribute(marks, windows, renders, [(start / 1e9 + base, ms) for start, ms in hitches.items()]), len(signposts)


def remove_new_ktraces(existing):
    for path in set(glob.glob(os.environ.get('TMPDIR', '/tmp') + '/instruments*.ktrace')) - existing:
        if subprocess.run(['lsof', path], capture_output=True).returncode != 0:
            os.remove(path)


def profile_summary(path, top=60):
    """Self and inclusive sample counts per function, and inclusive counts of Defi's own functions."""
    root = ET.parse(path).getroot()
    binaries = {b.get('id'): b.get('name') for b in root.iter('binary') if b.get('id')}
    names, owned = {}, set()
    for frame in root.iter('frame'):
        if frame.get('id'):
            names[frame.get('id')] = frame.get('name') or frame.get('addr') or '?'
            binary = frame.find('binary')
            if binary is not None and binaries.get(binary.get('ref') or binary.get('id')) == 'defi-daemon':
                owned.add(frame.get('id'))
    stacks = {b.get('id'): b for b in root.iter('tagged-backtrace') if b.get('id')}
    leaf, total, own = {}, {}, {}
    for row in root.iter('row'):
        stack = row.find('tagged-backtrace')
        if stack is not None and stack.get('ref'):
            stack = stacks.get(stack.get('ref'))
        if stack is None:
            continue
        ids = [f.get('ref') or f.get('id') for f in stack.iter('frame')]
        if not ids:
            continue
        leaf[names.get(ids[0], '?')] = leaf.get(names.get(ids[0], '?'), 0) + 1
        for name in {names.get(i, '?') for i in ids}:
            total[name] = total.get(name, 0) + 1
        for name in {names[i] for i in ids if i in owned and 'thunk' not in names[i]}:
            own[name] = own.get(name, 0) + 1
    order = lambda d: sorted(d.items(), key=lambda x: -x[1])[:top]
    return {'samples': sum(leaf.values()), 'self': order(leaf), 'inclusive': order(total), 'defi': order(own, )}


def trial(out, label, rounds, only=None, profile=False):
    directory, trace = out / label, out / f'{label}.trace'
    directory.mkdir()
    pid = daemon_pid()
    recorders = []
    existing = set(glob.glob(os.environ.get('TMPDIR', '/tmp') + '/instruments*.ktrace'))

    def start_trace():
        instruments = ['Time Profiler'] if profile else ['Hitches', 'Points of Interest']
        recorders.append(subprocess.Popen(['xcrun', 'xctrace', 'record',
                                           *[a for i in instruments for a in ('--instrument', i)], '--attach', pid,
                                           '--output', str(trace)],
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
        for line in recorders[0].stdout:
            if 'Starting recording' in line:
                break
        time.sleep(2)

    try:
        marks, costs = scenario(out, label, rounds, start_trace, only)
    finally:
        for recorder in recorders:
            recorder.send_signal(2)  # never KILL: a killed recorder leaves its ktrace behind
            try:
                recorder.wait(timeout=120)
            except subprocess.TimeoutExpired:
                recorder.terminate()
                recorder.wait()
        remove_new_ktraces(existing)
    if profile:
        try:
            export(trace, 'time-profile', directory / 'profile.xml')
            summary = profile_summary(directory / 'profile.xml')
        finally:
            shutil.rmtree(trace, ignore_errors=True)
            remove_new_ktraces(existing)
            pass  # profile.xml kept for callee analysis; delete it once read
        summary['costs'] = costs
        (directory / 'profile.json').write_text(json.dumps(summary, indent=1))
        return {'label': label, 'profile': str(directory / 'profile.json'), 'actions': costs}
    try:
        (directory / 'toc.xml').write_bytes(subprocess.run(
            ['xcrun', 'xctrace', 'export', '--input', str(trace), '--toc'], capture_output=True, check=True).stdout)
        export(trace, 'hitches-renders', directory / 'renders.xml')
        export(trace, 'hitches', directory / 'hitches.xml')
        export(trace, 'os-signpost', directory / 'signposts.xml')
    finally:
        shutil.rmtree(trace, ignore_errors=True)
        remove_new_ktraces(existing)
    (directory / 'marks.json').write_text(json.dumps(marks))
    actions, signposts = analyze(directory, marks)
    for name, cost in costs.items():
        actions.setdefault(name, {}).update({k: round(v, 1) for k, v in cost.items()})
    for name in ('renders.xml', 'hitches.xml', 'signposts.xml'):
        (directory / name).unlink()
    time.sleep(3)
    before, started = usage(pid), time.monotonic()
    time.sleep(IDLE_S)
    after = usage(pid)
    elapsed = time.monotonic() - started
    result = {'label': label, 'signposts': signposts,
              'idle_cpu_pct': round((after['cpu_ms'] - before['cpu_ms']) / elapsed / 10, 3),
              'idle_wakeups_per_s': round((after['wakeups'] - before['wakeups']) / elapsed, 1),
              'footprint_mib': round(after['footprint_mib'], 1), 'resident_mib': round(after['resident_mib'], 1),
              'actions': actions}
    (directory / 'result.json').write_text(json.dumps(result, indent=1))
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--trials', type=int, default=2, help='trials per build, alternating ABBA')
    p.add_argument('--rounds', type=int, default=1, help='workload repetitions per trial')
    p.add_argument('--only', choices=['column', 'overview', 'cheatsheet', 'workspace', 'window'], help='one action only')
    p.add_argument('--profile', action='store_true', help='Time Profiler instead of render gaps')
    args = p.parse_args()
    if not pe.locked():
        p.error('run under script/desktop_lock.sh --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    installed = Path.home() / 'Applications/Defi.app'
    original = out / 'original.app'
    pe.run(['ditto', installed, original])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])
    bundles = [b.split('=', 1) for b in args.bundle]

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        pe.session('start')
        pe.wait_for_quiet_alerts()

    checkpoint = out / 'checkpoint'
    pe.session('checkpoint', checkpoint)
    pe.session('start')
    results = []
    try:
        for index in range(args.trials):
            order = bundles if index % 2 == 0 else bundles[::-1]
            for label, path in order:
                install(Path(path).resolve())
                pe.wait_for_idle()
                result = trial(out, f'{label}-{index}', args.rounds, args.only, args.profile)
                result['build'] = label
                results.append(result)
                print(json.dumps(result), flush=True)
                (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        try:
            install(original)
            # Kept when the reinstall fails: it is the only copy to retry from.
            shutil.rmtree(original, ignore_errors=True)
        finally:
            pe.session('restore', checkpoint)
            print('daemons', pe.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
