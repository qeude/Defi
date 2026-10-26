#!/usr/bin/env python3
"""Native tab probe: does a native tab group stay one column? Two fixture applications on an empty
workspace, A focused; A then opens a tab, switches tabs, opens another, closes the visible and a hidden
tab, and opens a separate window with the same title. Per step it records the workspace window count,
whether the other application's window moved, Defi's submit sources and overlay presentations.
Usage (under the desktop lock): script/native_tab_probe.py OUT [--bundle LABEL=path]
Restores the original bundle and session."""
import argparse, json, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
import tear_probe as tp  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

# step, command, id, of, expected change of the workspace window count
STEPS = [
    ('new-tab', 'tab', 't1', 'main', 0),
    ('switch-tab', 'select-tab', 'main', None, 0),
    ('new-tab-2', 'tab', 't2', 'main', 0),
    ('close-visible-tab', 'close', 't2', None, 0),
    ('close-hidden-tab', 'close', None, None, 0),
    ('new-window-same-title', 'create', 'sep', 'visible', 1),
]


def overlay_events(start_wall):
    """Ribbon-proxy log lines as (uptime, text); the daemon logs wall-clock time."""
    offset = time.time() - tp.pe_uptime()
    text = subprocess.run(['/usr/bin/log', 'show', '--start', time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(start_wall)),
                           '--style', 'compact', '--predicate',
                           'subsystem == "com.qeude.defi" AND category == "ribbon-proxy"'],
                          capture_output=True, text=True).stdout
    events = []
    for line in text.splitlines():
        match = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.(\d{3}) .*?:ribbon-proxy\] (.*)', line)
        if match:
            wall = time.mktime(time.strptime(match[1], '%Y-%m-%d %H:%M:%S')) + int(match[2]) / 1000
            events.append((wall - offset, match[3]))
    return events


def window_count(workspace):
    monitors = json.loads(session.command('list-workspaces', '--json'))['monitors']
    return next(w['windowCount'] for m in monitors for w in m['workspaces'] if w['id'] == workspace)


def trial(out, label, pause):
    fixtures = []
    try:
        for i in range(2):
            fixtures.append(pe.Fixture(out / 'PerformanceFixture', out / f'{label}-fixture-{i}.jsonl'))
        for f in fixtures:
            f.ask()
        pe.activate(fixtures[0].process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        tp.wait_for_settlement()
        expected, discovered = [], set()
        for i, f in enumerate(fixtures):
            report = f.ask('create', id='main')
            expected.append((i, 'main', report['windows'][0]['windowNumber']))
            pe.wait_owned(fixtures, expected, empty['id'], discovered)
        tabs, other = fixtures
        dump = lambda f: json.loads(subprocess.check_output([str(out / 'window-dump'), str(f.process.pid)]))
        pe.activate(tabs.process.pid)
        tp.wait_for_settlement()
        time.sleep(pause)
        started_wall = time.time() - 1
        rows, timeline = [], []
        for name, command, id, of, expected_delta in STEPS:
            members = tabs.ask()['windows']
            if id is None:  # a hidden member left after closing the visible tab
                id = next(w['id'] for w in members if not w['visible'])
            if of == 'visible':
                of = next(w['id'] for w in members if w['visible'])
            count_before, other_before = window_count(empty['id']), other.ask()['windows'][0]['frame']
            t0 = tp.pe_uptime()
            tabs.ask(command, id=id, **({'of': of} if of else {}))
            early = dump(tabs)
            time.sleep(.3)
            tp.wait_for_settlement()
            time.sleep(pause)
            report = tabs.ask()
            rows.append({'step': name, 'expected_delta': expected_delta,
                         'window_delta': window_count(empty['id']) - count_before,
                         'other_moved': other.ask()['windows'][0]['frame'] != other_before,
                         'tab_windows': [[w['id'], w['windowNumber'], w['visible']] for w in report['windows']],
                         'early': early, 'dump': dump(tabs)})
            timeline.append((t0, tp.pe_uptime()))
            rows[-1]['trace'] = tp.trace_since(t0)
        logs = overlay_events(started_wall)
        (out / f'{label}-overlay.txt').write_text('\n'.join(f'{t:.3f} {l}' for t, l in logs))
        for row, (t0, t1) in zip(rows, timeline):
            row['presents'] = sum(1 for t, l in logs if t0 <= t < t1 and l.startswith('present '))
            row['submit_sources'] = sorted(set(re.findall(r' submit g=\d+ source=(\S+)', row['trace'])))
        (out / f'{label}-trace.txt').write_text('\n'.join(f"# {r['step']}\n{r.pop('trace')}" for r in rows))
        return rows
    finally:
        for f in fixtures:
            f.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', default=['installed='], help='LABEL=path; omit path to keep installed')
    p.add_argument('--pause', type=float, default=.6, help='s after settlement before reading a step')
    args = p.parse_args()
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    bundles = dict(b.split('=', 1) for b in args.bundle[1:] or args.bundle)
    installed = Path.home() / 'Applications/Defi.app'
    original = out / 'original.app'
    pe.run(['ditto', installed, original])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])
    pe.run(['swiftc', '-O', ROOT / 'script/window_dump.swift', '-o', out / 'window-dump'])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while not re.search(r'monitors=[1-9]', session.command('status')):
            if time.monotonic() > deadline:
                raise RuntimeError('daemon did not discover monitor')
            time.sleep(.05)
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon')
        pe.wait_for_quiet_alerts()

    checkpoint = out / 'checkpoint'
    session.checkpoint(checkpoint)
    session.start()
    results = {}
    try:
        for label, path in bundles.items():
            if path:
                install(Path(path).resolve())
            pe.wait_for_idle()
            results[label] = trial(out, label, args.pause)
            for row in results[label]:
                print(label, json.dumps({k: v for k, v in row.items() if k not in ('dump', 'early')}), flush=True)
            (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        try:
            if any(bundles.values()):
                install(original)
        finally:
            try:
                session.restore(checkpoint)
            except Exception:  # LaunchServices can reject the first service start (-600)
                time.sleep(2)
                session.restore(checkpoint)
            print('daemons', session.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
