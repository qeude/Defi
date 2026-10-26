#!/usr/bin/env python3
"""Lifecycle probe: how fast does the ribbon adapt when a window opens, closes, or leaves
native fullscreen? Two fixture windows on an empty workspace; per event a 4 ms WindowServer
sampler measures the time from the event to the first ribbon reaction (overlay or a moved
neighbour), to the last frame change, and how long the overlay covers the screen.
Usage (under the desktop lock): script/lifecycle_probe.py OUT [--bundle LABEL=path] [--record]
Restores the original bundle and session."""
import argparse, json, re, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
import tear_probe as tp  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

MOVE_PT = 2


def overlay_events(start_wall):
    """Overlay log lines as (uptime, text): the daemon logs wall-clock time, the sampler uptime."""
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


def analyze(states, events, end, display, fixtures, trace, logs):
    """events: (t0, kind, window number); fixtures: window numbers owned by the probe."""
    frame = lambda s: {w[0]: tuple(w[2:]) for w in s['apps'] if w[0] in fixtures}
    # Defi surfaces other than the always-ordered ribbon panel: native fullscreen placeholders.
    placeholder = lambda s: any(e[1] == 0 and e[4] > 64 and e[5] > 64 for e in s['edges'])
    rows = []
    for (t0, kind, window), t1 in zip(events, [e[0] for e in events[1:]] + [end]):
        seg = [s for s in states if t0 <= s['t'] < t1]
        before = next((s for s in reversed(states) if s['t'] < t0), None)
        if before is None or not seg:
            continue
        present = lambda s: window in frame(s)
        seen = next((s['t'] for s in seg if present(s) != present(before)), None)
        start = seen if seen is not None else t0
        changes = [b['t'] for a, b in zip(seg, seg[1:]) if frame(a) != frame(b)]
        shown = sum(b['t'] - a['t'] for a, b in zip(seg, seg[1:] + [{'t': t1}]) if placeholder(a))
        ms = lambda t: None if t is None else round((t - start) * 1000, 1)
        lines = [(t, l) for t, l in trace if t0 <= t < t1]
        submit = next(((t, l) for t, l in lines if ' submit g=' in f' {l}'), None)
        overlay = [(t, l) for t, l in logs if t0 <= t < t1]
        shown_at = next(((t, l) for t, l in overlay if l.startswith('present ')), None)
        faded = next((t for t, l in overlay if l.startswith('fade ')), None)
        veils = [int(m) for _, l in overlay for m in re.findall(r'veil-lift id=\d+ ms=(\d+)', l)]
        rows.append({'kind': kind, 'seen_ms': None if seen is None else round((seen - t0) * 1000, 1),
                     'submit_ms': ms(submit and submit[0]),
                     'source': submit and re.search(r'source=(\S+)', submit[1])[1],
                     'present_ms': ms(shown_at and shown_at[0]), 'fade_ms': ms(faded),
                     'missing': shown_at and re.search(r'missing=(\[[^\]]*\])', shown_at[1])[1],
                     'veil_ms': max(veils, default=None),
                     'settle_ms': ms(changes[-1] if changes else None),
                     'placeholder_ms': round(shown * 1000, 1), 'final': frame(seg[-1])})
    return rows


def trial(out, label, repeats, sampler_bin, pause):
    fixtures, sampler = [], None
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
        daemon = subprocess.check_output(['pgrep', '-x', 'defi-daemon'], text=True).split()[0]
        session.command('trace')
        started_wall = time.time() - 1
        samples = out / f'{label}-samples.jsonl'
        events, numbers = [], {e[2] for e in expected}
        with samples.open('w') as fh:
            sampler = subprocess.Popen([str(sampler_bin), 'sample', daemon, '600', '4'], stdout=fh)
            time.sleep(.3)
            traces = []

            def event(kind, fixture, command, id, **fields):
                t0 = tp.pe_uptime()
                report = command() if callable(command) else fixture.ask(command, id=id, **fields)
                number = next((w['windowNumber'] for w in report['windows'] if w['id'] == id), None)
                number = number or next(e for e in events[::-1] if e[1] in ('open', 'open-over', 'launch'))[2]
                numbers.add(number)
                events.append((t0, kind, number))
                tp.wait_for_settlement()
                time.sleep(pause)
                traces.append(f'# {kind} {number}\n' + tp.trace_since(t0))

            for n in range(repeats):
                event('open', fixtures[0], 'create', f'extra{n}')
                event('close', fixtures[0], 'close', f'extra{n}')
            for n in range(repeats):
                # Ghostty opens a new window just inside the focused one's frame.
                event('open-over', fixtures[0], 'over', f'over{n}', of='main')
                event('close', fixtures[0], 'close', f'over{n}')
            for n in range(repeats):
                # A new application: its process, AX observer and first window all start cold.
                def launch():
                    fixtures.append(pe.Fixture(out / 'PerformanceFixture', out / f'{label}-launched-{n}.jsonl'))
                    fixtures[-1].ask()
                    # The Dock or Spotlight activates what it launches; a bare process is refused.
                    pe.activate(fixtures[-1].process.pid)
                    return fixtures[-1].ask('create', id='main')
                event('launch', None, launch, 'main')
                event('quit', None, lambda: (fixtures.pop().close(), {'windows': []})[1], 'main')
            for _ in range(repeats):
                fixtures[1].ask('fullscreen', id='main')
                time.sleep(1.5)
                tp.wait_for_settlement()
                event('fullscreen-exit', fixtures[1], 'fullscreen', 'main')
            time.sleep(.3)
            sampler.send_signal(tp.signal.SIGTERM)
            sampler.wait(timeout=15)
        (out / f'{label}-trace.txt').write_text('\n'.join(traces))
        records = [json.loads(l) for l in samples.read_text().splitlines()]
        states = [r for r in records if 'apps' in r]
        trace = [(float(l.split()[0]), l.split(' ', 1)[1]) for t in traces for l in t.splitlines()
                 if re.match(r'\d', l)]
        logs = overlay_events(started_wall)
        (out / f'{label}-overlay.txt').write_text('\n'.join(f'{t:.3f} {l}' for t, l in logs))
        return analyze(states, events, records[-1]['t'], records[0]['displays'][0], numbers, trace, logs)
    finally:
        if sampler and sampler.poll() is None:
            sampler.kill(); sampler.wait()
        for f in fixtures:
            f.close()


def summary(rows):
    out = {}
    for kind in ('open', 'open-over', 'close', 'launch', 'quit', 'fullscreen-exit'):
        sel = [r for r in rows if r['kind'] == kind]
        med = lambda k: round(statistics.median(v), 1) if (v := [r[k] for r in sel if r[k] is not None]) else None
        out[kind] = {k: med(k) for k in ('seen_ms', 'submit_ms', 'present_ms', 'fade_ms', 'veil_ms',
                                         'settle_ms', 'placeholder_ms')}
        out[kind].update(settle_max=max((r['settle_ms'] or 0 for r in sel), default=None),
                         unanimated=sum(r['present_ms'] is None for r in sel), n=len(sel))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', default=['installed='], help='LABEL=path; omit path to keep installed')
    p.add_argument('--rounds', type=int, default=1)
    p.add_argument('--repeats', type=int, default=4)
    p.add_argument('--pause', type=float, default=.6, help='s after settlement before the next event')
    p.add_argument('--record', type=int, default=0, metavar='S', help='screen-record S seconds of the first round')
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
    pe.run(['swiftc', '-O', '-swift-version', '6', ROOT / 'script/motion_probe.swift', '-o', out / 'motion-probe'])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while 'monitors=0' in session.command('status') or 'monitors=' not in session.command('status'):
            if time.monotonic() > deadline:
                raise RuntimeError('daemon did not discover monitor')
            time.sleep(.05)
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon')
        pe.wait_for_quiet_alerts()

    checkpoint = out / 'checkpoint'
    session.checkpoint(checkpoint)
    session.start()
    if args.record:
        # Verification only: screen recordings then include the overlay. Read at daemon start.
        subprocess.run(['defaults', 'write', 'com.qeude.defi', 'RibbonProxyCapturable', '-bool', 'true'], check=True)
    results = []
    try:
        for r in range(args.rounds):
            for label, path in bundles.items():
                if path:
                    install(Path(path).resolve())
                pe.wait_for_idle()
                # -V ends the recording itself; an interrupted screencapture writes no file.
                recorder = subprocess.Popen(['screencapture', '-x', '-v', '-V', str(args.record), str(out / f'{label}{r}.mov')],
                                            stdin=subprocess.DEVNULL) if args.record and r == 0 else None
                try:
                    rows = trial(out, f'{label}{r}', args.repeats, out / 'motion-probe', args.pause)
                finally:
                    if recorder:
                        recorder.wait(timeout=args.record + 30)
                res = {'side': label, 'round': r, 'summary': summary(rows), 'rows': rows}
                print(json.dumps({k: res[k] for k in ('side', 'round', 'summary')}), flush=True)
                results.append(res)
                (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        subprocess.run(['defaults', 'delete', 'com.qeude.defi', 'RibbonProxyCapturable'], check=False)
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
