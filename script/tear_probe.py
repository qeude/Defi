#!/usr/bin/env python3
"""Ribbon tear probe: does a slow-AX window freeze, gap or overlap its neighbours during
human-timed focus-column navigation? Three fixture windows (rightmost made busy, like Mail)
on an empty workspace; a 4 ms WindowServer sampler scores adjacent-window spacing error.
Usage (under the desktop lock): script/tear_probe.py OUT --bundle A=path --bundle B=path [--rounds N]
Reuses the frozen harness helpers read-only; restores the original bundle and session."""
import argparse, json, random, re, signal, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402
from ribbon_stress import wait_for_settlement  # noqa: E402

GAP, TEAR_PT, VISIBLE_PT = 4, 12, 8


def sequence(seed):
    rng = random.Random(seed)
    steps = []
    for _ in range(8):
        for d in ('right', 'right', 'left', 'left'):
            steps.append((d, rng.uniform(.12, .30)))
        steps[-1] = (steps[-1][0], rng.uniform(.4, .8))
    return steps


def analyze(states, end, windows, display_w):
    """windows: ribbon order of window numbers. Returns tear metrics per adjacent pair."""
    out = {}
    for a, b in zip(windows, windows[1:]):
        tear_ms = max_err = longest = run = 0.0
        for cur, nxt in zip(states, states[1:] + [{'t': end}]):
            dt = (nxt['t'] - cur['t']) * 1000
            frames = {w[0]: w[2:] for w in cur['apps']}
            fa, fb = frames.get(a), frames.get(b)
            vis = lambda f: f and min(f[0] + f[2], display_w) - max(f[0], 0) > VISIBLE_PT
            if vis(fa) and vis(fb):
                err = fb[0] - (fa[0] + fa[2]) - GAP
                if abs(err) > TEAR_PT:
                    tear_ms += dt; run += dt; longest = max(longest, run)
                    max_err = max(max_err, abs(err))
                    continue
            run = 0
        out[f'{a}-{b}'] = {'tear_ms': round(tear_ms, 1), 'longest_tear_ms': round(longest, 1),
                           'max_err_pt': max_err}
    return out


def trial(out, bundle_label, steps, busy, sampler_bin):
    fixtures = []
    binary = out / 'PerformanceFixture'
    try:
        for i in range(3):
            fixtures.append(pe.Fixture(binary, out / f'{bundle_label}-fixture-{i}.jsonl'))
        for f in fixtures:
            f.ask()
        pe.activate(fixtures[0].process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        wait_for_settlement()
        expected, discovered = [], set()
        for i, f in enumerate(fixtures):
            report = f.ask('create', id='main')
            expected.append((i, 'main', report['windows'][0]['windowNumber']))
            pe.wait_owned(fixtures, expected, empty['id'], discovered)
            session.command('focus-column', 'last')
            pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[-1][2])
        session.command('focus-column', 'first')
        pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[0][2])
        if busy:
            fixtures[2].ask('set-busy', delay=busy[0], period=busy[1])
        daemon = subprocess.check_output(['pgrep', '-x', 'defi-daemon'], text=True).split()[0]
        session.command('trace')  # drain
        samples = out / f'{bundle_label}-samples.jsonl'
        with samples.open('w') as fh:
            sampler = subprocess.Popen([str(sampler_bin), 'sample', daemon, '600', '4'], stdout=fh)
            time.sleep(.3)
            driver = []
            for command, pause in steps:
                began = time.monotonic()
                session.command('focus-column', command)
                driver.append({'command': command, 'uptime': pe_uptime(), 'replyMS': (time.monotonic() - began) * 1000})
                time.sleep(pause)
            time.sleep(1.2)
            sampler.send_signal(signal.SIGTERM)
            sampler.wait(timeout=15)
        trace = session.command('trace')
        (out / f'{bundle_label}-trace.txt').write_text(trace)
        (out / f'{bundle_label}-driver.json').write_text(json.dumps(driver))
        if busy:
            fixtures[2].ask('set-busy', delay=0, period=busy[1])
        records = [json.loads(l) for l in samples.read_text().splitlines()]
        start = records[0]
        states = [r for r in records if 'apps' in r]
        end = records[-1]['t']
        display_w = start['displays'][0][2]
        result = analyze(states, end, [e[2] for e in expected], display_w)
        result['trace'] = {k: len(re.findall(p, trace)) for k, p in {
            'fallback': r'animation-fallback|fallback ', 'slow_lane': r'slow-lane ', 'abort': r'abort',
            'stale': r'stale-completion', 'slow': r' slow g='}.items()}
        result['reply_ms_max'] = max(d['replyMS'] for d in driver)
        return result
    finally:
        for f in fixtures:
            f.close()


def pe_uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--rounds', type=int, default=3)
    p.add_argument('--busy', type=float, nargs=2, default=[.018, .020], help='delay period (s)')
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
    pe.run(['swiftc', '-O', '-swift-version', '6', ROOT / 'script/motion_probe.swift', '-o', out / 'motion-probe'])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while 'monitors=1[' not in session.command('status'):
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
            steps = sequence(r)
            for label, path in bundles.items():
                install(Path(path).resolve())
                pe.wait_for_idle()
                res = trial(out, f'{label}{r}', steps, args.busy, out / 'motion-probe')
                res.update(side=label, round=r)
                print(json.dumps(res), flush=True)
                results.append(res)
                (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        install(original)
        try:
            session.restore(checkpoint)
        except Exception:  # LaunchServices can reject the first service start (-600)
            time.sleep(2)
            session.restore(checkpoint)
        print('daemons', session.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
