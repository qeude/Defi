#!/usr/bin/env python3
"""Fluidity probe: dropped frames per user action, measured by Instruments in the compositor.
Fixture windows only: column and workspace navigation, window open and close, app launch and
quit, activation (Command-Tab's native path), Overview and cheatsheet. Screen capture cannot judge 120 Hz: this attaches
Animation Hitches to the daemon and attributes each hitch to the action just before it.
Hitch counts are noisy: compare several --rounds.
Usage (under the desktop lock): script/fluidity_probe.py OUT --bundle LABEL=path [...] [--rounds N]
Restores the original bundle and session."""
import argparse, collections, datetime, glob, json, os, re, shutil, subprocess, sys, time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

TRACE_SECONDS = 45
# Render spikes over this are macOS's own, also seen with Defi stopped.
SYSTEM_SPIKE_MS = 30
WINDOW_S = .7


def rows(path):
    """An exported xctrace table's rows as dicts, resolving its id/ref sharing."""
    root = ET.parse(path).getroot()
    ids, columns = {}, [c.findtext('mnemonic') for c in root.iter('col')]
    for row in root.iter('row'):
        values = []
        for element in row:
            if 'ref' in element.attrib:
                element = ids[element.attrib['ref']]
            elif 'id' in element.attrib:
                ids[element.attrib['id']] = element
            values.append(element)
        yield dict(zip(columns, values))


def attribute(events, hitches, window=WINDOW_S):
    """Per action: events, hitches and hitch milliseconds in the window after each event, or
    until the next event if sooner. `events` and `hitches` are (seconds, ...) on one clock."""
    events = sorted(events)
    result = {}
    for action in {name for _, name in events}:
        result[action] = {'events': sum(name == action for _, name in events), 'hitches': 0, 'ms': 0.0, 'worst_ms': 0.0}
    for start, duration in hitches:
        owner = None
        for index, (at, name) in enumerate(events):
            end = min(at + window, events[index + 1][0] if index + 1 < len(events) else float('inf'))
            if at <= start < end:
                owner = name
                break
        if owner and duration <= SYSTEM_SPIKE_MS:
            entry = result[owner]
            entry['hitches'] += 1
            entry['ms'] += duration
            entry['worst_ms'] = max(entry['worst_ms'], duration)
            bin_ = 'first_100ms' if start - at < .1 else 'to_300ms' if start - at < .3 else 'later'
            entry[bin_] = entry.get(bin_, 0) + 1
    return result


def scenario(out, label, rounds, on_ready, only=None):
    events = []

    def mark(name):
        events.append((time.time(), name))

    def go(name, *args, pause=.9):
        mark(name)
        subprocess.run([str(session.CLI), *args], check=True, capture_output=True)
        time.sleep(pause)

    fixture = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-fixture.jsonl')
    other = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-other.jsonl')
    try:
        fixture.ask()
        other.ask()
        pe.activate(fixture.process.pid)
        monitor = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        time.sleep(1)
        expected, discovered = [], set()
        for n in range(5):
            report = fixture.ask('create', id=f'w{n}')
            expected.append((0, f'w{n}', next(w['windowNumber'] for w in report['windows'] if w['id'] == f'w{n}')))
            pe.wait_owned([fixture], expected, empty['id'], discovered)
        session.command('focus-column', 'first')
        time.sleep(1.5)
        on_ready()
        started = time.time()

        def launch_and_quit():
            mark('launch')
            launched = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-launch-{len(events)}.jsonl')
            launched.ask()  # registered with LaunchServices: activation can find it
            pe.activate(launched.process.pid)
            launched.ask('create', id='only')
            time.sleep(1.5)
            mark('quit')
            launched.close()
            time.sleep(1.2)

        for _ in range(rounds):
            if only == 'quit':
                for _ in range(6):
                    launch_and_quit()
                    pe.activate(fixture.process.pid)
                    time.sleep(.6)
                continue
            if only == 'overview':
                for _ in range(8):
                    go('overview-open', 'toggle-overview', pause=1)
                    go('overview-close', 'toggle-overview', pause=1)
                continue
            for direction in ['right'] * 3 + ['left'] * 3:
                go('column', 'focus-column', direction)
            if only == 'column':
                continue
            for direction in ['down', 'up'] * 2:
                go('workspace', 'focus-workspace', direction)
            for n in range(2):
                mark('open')
                fixture.ask('create', id=f'extra{n}-{time.time()}')
                time.sleep(1.2)
            for window in [w for w in fixture.ask()['windows'] if str(w['id']).startswith('extra')]:
                mark('close')
                fixture.ask('close', id=window['id'])
                time.sleep(1.2)
            launch_and_quit()
            pe.activate(other.process.pid)
            other.ask('create', id=f'activate-{time.time()}')
            time.sleep(1.2)
            for pid in [fixture.process.pid, other.process.pid] * 2:
                mark('activate')
                pe.activate(pid)
                time.sleep(.9)
            pe.activate(fixture.process.pid)
            time.sleep(.6)
            for _ in range(2):
                go('overview-open', 'toggle-overview', pause=1)
                go('overview-close', 'toggle-overview', pause=1)
                go('cheatsheet-open', 'toggle-cheatsheet', pause=.8)
                go('cheatsheet-close', 'toggle-cheatsheet', pause=.8)
        return events, time.time() - started
    finally:
        other.close()
        fixture.close()


def cpu_seconds(pid):
    text = subprocess.run(['ps', '-o', 'cputime=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    minutes, seconds = (text or '0:0').split(':')[-2:]
    return int(minutes) * 60 + float(seconds)


def analyze(directory, events):
    toc = ET.parse(directory / 'toc.xml').getroot()
    base = datetime.datetime.fromisoformat(next(toc.iter('start-date')).text.replace('Z', '+00:00')).timestamp()
    seen = {}
    for row in rows(directory / 'hitches.xml'):
        if 'defi' in (row['process'].get('fmt') or ''):
            seen[int(row['start'].text)] = int(row['duration'].text) / 1e6
    hitches = [(start / 1e9 + base, duration) for start, duration in seen.items()]
    return attribute(events, hitches)


def trace_trial(out, label, rounds, only=None, seconds=None):
    directory, trace = out / label, out / f'{label}.trace'
    directory.mkdir()
    pid = subprocess.run(['pgrep', 'defi-daemon'], capture_output=True, text=True).stdout.split()[0]
    recorders = []
    existing_traces = set(glob.glob(os.environ.get('TMPDIR', '/tmp') + '/instruments*.ktrace'))

    def start_trace():
        recorders.append(subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Animation Hitches',
                                           '--attach', pid, '--time-limit', f'{seconds or TRACE_SECONDS * rounds}s', '--output', str(trace)],
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
        # Attaching takes seconds: a scenario started before recording loses its first actions.
        for line in recorders[0].stdout:
            if 'Starting recording' in line:
                break
        time.sleep(2)

    before = cpu_seconds(pid)
    writes_before = int(re.search(r'posWrites=(\d+)', session.command('status')).group(1))
    try:
        events, elapsed = scenario(out, label, rounds, start_trace, only)
        cpu = cpu_seconds(pid) - before
        status = session.command('status')
    except BaseException:
        for recorder in recorders:
            recorder.terminate()
        raise
    finally:
        for recorder in recorders:
            recorder.wait()
    for path in set(glob.glob(os.environ.get('TMPDIR', '/tmp') + '/instruments*.ktrace')) - existing_traces:
        os.remove(path)
    (directory / 'toc.xml').write_bytes(subprocess.run(
        ['xcrun', 'xctrace', 'export', '--input', str(trace), '--toc'], capture_output=True).stdout)
    (directory / 'hitches.xml').write_bytes(subprocess.run(
        ['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
         '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'], capture_output=True).stdout)
    shutil.rmtree(trace)
    result = {'label': label, 'seconds': round(elapsed), 'daemon_cpu_s': round(cpu, 2),
              'rss_mib': int(subprocess.run(['ps', '-o', 'rss=', '-p', pid], capture_output=True, text=True).stdout) // 1024,
              'position_writes': int(re.search(r'posWrites=(\d+)', status).group(1)) - writes_before,
              'capture': re.search(r'windowCaptures=\S+', status).group(0),
              'actions': analyze(directory, events)}
    (directory / 'result.json').write_text(json.dumps(result, indent=1))
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--rounds', type=int, default=1)
    p.add_argument('--only', choices=['column', 'overview', 'quit'], help='a short trace of one action: finalizes in a minute')
    args = p.parse_args()
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    installed = Path.home() / 'Applications/Defi.app'
    original = out / 'original.app'
    pe.run(['ditto', installed, original])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        session.start()
        pe.wait_for_quiet_alerts()

    checkpoint = out / 'checkpoint'
    session.checkpoint(checkpoint)
    session.start()
    try:
        for label, path in (b.split('=', 1) for b in args.bundle):
            install(Path(path).resolve())
            pe.wait_for_idle()
            result = trace_trial(out, label, args.rounds, args.only, args.rounds * {'overview': 18, 'quit': 30, 'column': 7}[args.only] + 3 if args.only else None)
            print(json.dumps(result), flush=True)
    finally:
        try:
            install(original)
        finally:
            session.restore(checkpoint)
            print('daemons', session.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
