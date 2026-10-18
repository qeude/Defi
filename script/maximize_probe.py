#!/usr/bin/env python3
"""Maximize probe: does `maximize-column` resize a window within its motion, or land the size late?
Two fixture windows on an empty workspace (the focused one optionally a ClampFixture with --fixture-env,
e.g. a cell-grid snap like Ghostty); a 4 ms WindowServer sampler measures, per toggle, the time from the
command to the focused window's first visible and final width, its distinct widths and reversals, and how long the visible area stays uncovered past the final
layout. Usage (under the desktop lock): script/maximize_probe.py OUT --bundle A=path --bundle B=path
Restores the original bundle and session."""
import argparse, json, os, re, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
import tear_probe as tp  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

WIDTH_PT, GAP_PT = 2, 12


def uncovered(frames, display_w):
    """Visible display width covered by no fixture window."""
    spans = sorted((max(f[0], 0), min(f[0] + f[2], display_w)) for f in frames)
    covered, edge = 0, 0
    for lo, hi in spans:
        lo = max(lo, edge)
        if hi > lo:
            covered += hi - lo
            edge = hi
    return display_w - covered


def analyze(states, end, commands, window, windows, display_w):
    """Per command: ms to the focused window's final width and ms with extra uncovered area."""
    rows = []
    for (t0, kind), t1 in zip(commands, [c[0] for c in commands[1:]] + [end]):
        seg = [s for s in states if t0 <= s['t'] < t1]
        before = next((s for s in reversed(states) if s['t'] < t0), None)
        if before is None or not seg:
            continue
        frame = lambda s: {w[0]: w[2:] for w in s['apps']}
        final = frame(seg[-1])
        if window not in final or window not in frame(before):
            continue
        target_w, start_w = final[window][2], frame(before)[window][2]
        settle = t0
        for s in seg:
            if abs(frame(s).get(window, [0, 0, 0, 0])[2] - target_w) > WIDTH_PT:
                settle = s['t']
        # first sample after the last off-target one
        reached = next((s['t'] for s in seg if s['t'] > settle), settle) if settle > t0 else t0
        widths = [frame(s)[window][2] for s in seg if window in frame(s)]
        sign = 1 if target_w >= start_w else -1
        first = next((s['t'] for s in seg if sign * (frame(s).get(window, [0, 0, 0, start_w])[2] - start_w) > WIDTH_PT), t0)
        # distinct widths seen on the way (1 = single jump) and samples moving against the target
        reached = max(reached, first)  # a sampler stall can hide every off-target sample
        steps = len({w for w in widths if abs(w - start_w) > WIDTH_PT})
        reversals = sum(1 for a, b in zip(widths, widths[1:]) if sign * (b - a) < -WIDTH_PT)
        final_gap = uncovered([f for w, f in final.items() if w in windows], display_w)
        gap_ms = longest = run = gap_px = gap_area = 0.0
        for cur, nxt in zip(seg, seg[1:] + [{'t': t1}]):
            dt = (nxt['t'] - cur['t']) * 1000
            g = uncovered([f for w, f in frame(cur).items() if w in windows], display_w) - final_gap
            if g > GAP_PT:
                gap_ms += dt; run += dt; longest = max(longest, run)
                gap_px = max(gap_px, g); gap_area += g / display_w * dt
            else:
                run = 0
        rows.append({'kind': 'grow' if target_w > start_w + WIDTH_PT else 'shrink' if target_w < start_w - WIDTH_PT
                     else 'same', 'from_w': start_w, 'to_w': target_w,
                     'first_ms': round((first - t0) * 1000, 1), 'steps': steps, 'reversals': reversals,
                     'width_ms': round((reached - t0) * 1000, 1), 'gap_ms': round(gap_ms, 1),
                     'gap_longest_ms': round(longest, 1), 'gap_px_max': gap_px,
                     # display-width-ms of extra uncovered area (half the display for 100 ms = 50)
                     'gap_area': round(gap_area, 1)})
    return rows


def trial(out, label, toggles, sampler_bin, focus_index, fixture_env, pause, command):
    fixtures = []
    try:
        for i in range(2):
            env = fixture_env if i == focus_index else {}
            for k, v in env.items():
                os.environ[k] = v
            try:
                fixtures.append(pe.Fixture(out / ('ClampFixture' if env else 'PerformanceFixture'),
                                           out / f'{label}-fixture-{i}.jsonl'))
            finally:
                for k in env:
                    os.environ.pop(k)
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
            session.command('focus-column', 'last')
            pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[-1][2])
        session.command('focus-column', 'first' if focus_index == 0 else 'last')
        window = expected[focus_index][2]
        pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=window)
        daemon = subprocess.check_output(['pgrep', '-x', 'defi-daemon'], text=True).split()[0]
        session.command('trace')  # drain
        samples = out / f'{label}-samples.jsonl'
        commands = []
        with samples.open('w') as fh:
            sampler = subprocess.Popen([str(sampler_bin), 'sample', daemon, '600', '4'], stdout=fh)
            time.sleep(.3)
            traces = []
            for _ in range(toggles):
                t0 = tp.pe_uptime()
                session.command(*command)
                commands.append((t0, command[0]))
                tp.wait_for_settlement()
                time.sleep(pause)
                traces.append(tp.trace_since(t0))
            time.sleep(.3)
            sampler.send_signal(tp.signal.SIGTERM)
            sampler.wait(timeout=15)
        (out / f'{label}-trace.txt').write_text('\n'.join(traces))
        records = [json.loads(l) for l in samples.read_text().splitlines()]
        states = [r for r in records if 'apps' in r]
        display_w = records[0]['displays'][0][2]
        rows = analyze(states, records[-1]['t'], commands, window, {e[2] for e in expected}, display_w)
        return rows
    finally:
        for f in fixtures:
            f.close()


def summary(rows):
    out = {}
    for kind in ('grow', 'shrink'):
        sel = [r for r in rows if r['kind'] == kind]
        if sel:
            out[kind] = {k: round(statistics.median(r[k] for r in sel), 1) for k in ('first_ms', 'width_ms', 'gap_ms', 'gap_px_max', 'gap_area', 'steps')}
            out[kind].update(width_max=max(r['width_ms'] for r in sel), gap_max=max(r['gap_ms'] for r in sel),
                             reversals=sum(r['reversals'] for r in sel), n=len(sel))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path; omit path to keep installed')
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--toggles', type=int, default=8)
    p.add_argument('--pause', type=float, default=.6, help='s after settlement before the next toggle')
    p.add_argument('--focus-index', type=int, default=0, choices=(0, 1))
    p.add_argument('--command', nargs='+', default=['maximize-column'], help='toggled command, e.g. cycle-width next')
    p.add_argument('--fixture-env', nargs='*', default=[], help='ClampFixture env for the focused window')
    args = p.parse_args()
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    bundles = dict(b.split('=', 1) for b in args.bundle)
    installed = Path.home() / 'Applications/Defi.app'
    original = out / 'original.app'
    pe.run(['ditto', installed, original])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/ClampFixture.swift', '-o', out / 'ClampFixture'])
    pe.run(['swiftc', '-O', '-swift-version', '6', ROOT / 'script/motion_probe.swift', '-o', out / 'motion-probe'])
    fixture_env = dict(e.split('=', 1) for e in args.fixture_env)

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
    results = []
    try:
        for r in range(args.rounds):
            for label, path in bundles.items():
                if path:
                    install(Path(path).resolve())
                pe.wait_for_idle()
                rows = trial(out, f'{label}{r}', args.toggles, out / 'motion-probe', args.focus_index,
                             fixture_env, args.pause, args.command)
                res = {'side': label, 'round': r, 'summary': summary(rows), 'rows': rows}
                print(json.dumps({k: res[k] for k in ('side', 'round', 'summary')}), flush=True)
                results.append(res)
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
