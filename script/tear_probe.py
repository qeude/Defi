#!/usr/bin/env python3
"""Ribbon tear probe: does a slow-AX window freeze, gap or overlap its neighbours during
human-timed focus-column navigation? Three fixture windows (rightmost made busy, like Mail)
on an empty workspace; a 4 ms WindowServer sampler scores adjacent-window spacing error.
Usage (under the desktop lock): script/tear_probe.py OUT --bundle A=path --bundle B=path [--rounds N]
Reuses the frozen harness helpers read-only; restores the original bundle and session."""
import argparse, json, os, random, re, signal, socket, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402
from ribbon_stress import wait_for_settlement  # noqa: E402

GAP, TEAR_PT, VISIBLE_PT = 4, 12, 8


def sequence(seed, pause=(.12, .30)):
    rng = random.Random(seed)
    steps = []
    for _ in range(8):
        for d in ('right', 'right', 'left', 'left'):
            steps.append((d, rng.uniform(*pause)))
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


def start_latency(states, trace):
    """Per animated ribbon generation: ms from Defi's animation start to the first on-screen change.
    A ribbon-wide block shows as a late first move with every window still."""
    starts = {g: float(t) for t, g in re.findall(r'^(\S+) start g=(\d+) ', trace, re.M)}
    aborted = set(re.findall(r'^\S+ abort g=(\d+) ', trace, re.M))  # e.g. real mouse input
    out = []
    for g in re.findall(r'^\S+ clock g=(\d+) ', trace, re.M):
        t0 = starts.get(g)
        if t0 is None or t0 <= states[0]['t'] or g in aborted:
            continue
        before = next(s for s in reversed(states) if s['t'] <= t0)['apps']
        moved = next((s['t'] for s in states if s['t'] > t0 and s['apps'] != before), None)
        if moved is not None:
            out.append((moved - t0) * 1000)
    return out


def frontmost_pid():
    return int(subprocess.check_output(['osascript', '-e', 'tell application "System Events" to unix id of '
                                        'first process whose frontmost is true'], text=True))


def trace_since(t0):
    """`defi trace` is a ring buffer cached for 250 ms; call it after the cache expires."""
    return '\n'.join(l for l in session.command('trace').splitlines()
                     if re.match(r'\d', l) and float(l.split()[0]) >= t0)


def send_async(command):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.path.join(os.environ['TMPDIR'], f'defi-{os.getuid()}.sock'))
    sock.sendall(json.dumps({'command': command}).encode() + b'\n')
    return sock


# reset commands, first and second command, fixture index departed by the first command, and the
# expected final native focus. 'noop' ends on a boundary, 'maximize' is not navigation, 'click' adds a
# native click on fixture 1 during the second command's motion.
RACE_PLANS = {
    'race': (['first'], 'focus-column right', 'focus-column right', 0, 2),
    'noop': (['first', 'right'], 'focus-column left', 'focus-column left', 1, 0),
    'maximize': (['first'], 'focus-column right', 'maximize-column', 0, 1),
    'click': (['first'], 'focus-column right', 'focus-column right', 0, 1),
}


def race(out, fixtures, windows, delays, driver, plan='race'):
    """Forced race: the second command `delay` ms after the first, while the first command's focus
    write is still activating its target. That write's recovery fallback is the app the first
    command departed (slow it with --activation-fixtures)."""
    pids = [f.process.pid for f in fixtures]
    resets, command1, command2, departed_index, final_index = RACE_PLANS[plan]
    trials, traces = [], []
    for delay in delays:
        for reset in resets:
            session.command('focus-column', reset)
            wait_for_settlement()
        time.sleep(.6)  # let the departed fixture's activation work finish
        # Raw socket requests: a CLI round trip (~10 ms, jittery) is longer than that write.
        t0 = pe_uptime()
        first = send_async(command1)
        time.sleep(max(0, t0 + delay / 1000 - pe_uptime()))
        t1 = pe_uptime()
        second = send_async(command2)
        for sock, t in ((first, t0), (second, t1)):
            sock.makefile().readline()
            sock.close()
            driver.append({'command': plan, 'uptime': t, 'replyMS': (pe_uptime() - t) * 1000})
        if plan == 'click':
            time.sleep(max(0, t1 + .06 - pe_uptime()))
            clicked_at, hit = subprocess.check_output([str(out / 'click-probe'), str(windows[1])], text=True).split()
        wait_for_settlement()
        time.sleep(2)  # status and trace are cached reads; let delayed activation work land
        text = trace_since(t0)
        traces.append(text)
        cgs = re.findall(rf'^(\S+) command-start cg=(\d+) command=(?:{command1}|{command2}) ', text, re.M)
        after = '\n'.join(l for l in text.splitlines() if cgs and float(l.split()[0]) >= float(cgs[-1][0]))
        recovery = re.findall(r'focus-recovery (?:pid=(\d+)|window=(\d+))', text)
        departed = sum(p == str(pids[departed_index]) or w == str(windows[departed_index]) for p, w in recovery)
        starts = [t for t, _ in cgs]
        cgs = [cg for _, cg in cgs]
        first_ms, focus_ms = (re.search(rf'command-focus cg={cg} ms=([\d.]+)', text) for cg in (cgs + [None, None])[:2])
        gens = re.findall(r'^\S+ start g=(\d+) ', after, re.M)
        stall = max((float(ms) for g, ms in re.findall(rf' slow g=(\d+) pid={pids[departed_index]} .*? ms=([\d.]+)', after)
                     if gens and g == gens[0]), default=0)
        trials.append({'delay_ms': delay, 'commands': len(cgs), 'noop': 'command-no-op' in text, 'gap_ms': round((float(starts[1]) - float(starts[0])) * 1000, 1)
                       if len(starts) == 2 else None, 'recovery': len(recovery),
                       'recovery_departed': departed, 'front': pids.index(front) if (front := frontmost_pid()) in pids else -1,
                       'final_ok': front == pids[final_index],
                       'focus_ms': float(focus_ms.group(1)) if focus_ms else None,
                       'first_focus_ms': float(first_ms.group(1)) if first_ms else None,  # None: cancelled
                       'departed_stall_ms': stall})
        if plan == 'click':
            trials[-1].update(click_ms=round((float(clicked_at) - t0) * 1000), click_hit=windows.index(int(hit))
                              if int(hit) in windows else -1)
    return trials, '\n'.join(traces)


def trial(out, bundle_label, steps, busy, sampler_bin, sample_daemon=False, activation_busy=0,
          activation_fixtures=(2,), race_delays=(), busy_fixtures=(2,), race_plan='race',
          clamp_fixture=None, clamp_env=None, idle=0):
    fixtures = []
    try:
        for i in range(3):
            env = {'DYLD_INSERT_LIBRARIES': str(out / 'slow_activation_hook.dylib'),
                   'DEFI_ACTIVATION_BUSY_MS': str(activation_busy)} if activation_busy and i in activation_fixtures else {}
            clamped = i == clamp_fixture
            env.update(clamp_env if clamped else {})
            os.environ.update(env)
            try:
                fixtures.append(pe.Fixture(out / ('ClampFixture' if clamped else 'PerformanceFixture'),
                                           out / f'{bundle_label}-fixture-{i}.jsonl'))
            finally:
                for k in env:
                    os.environ.pop(k)
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
        for i in busy_fixtures if busy[0] > 0 else ():
            fixtures[i].ask('set-busy', delay=busy[0], period=busy[1])
        writes = {}
        if idle:
            writes['idle_before'] = write_rate(idle)
            (out / f'{bundle_label}-idle-trace.txt').write_text(session.command('trace'))
        daemon = subprocess.check_output(['pgrep', '-x', 'defi-daemon'], text=True).split()[0]
        session.command('trace')  # drain
        samples = out / f'{bundle_label}-samples.jsonl'
        with samples.open('w') as fh:
            sampler = subprocess.Popen([str(sampler_bin), 'sample', daemon, '600', '4'], stdout=fh)
            vsync = subprocess.Popen([str(out / 'vsync-probe'), '600'],
                                     stdout=(out / f'{bundle_label}-vsync.jsonl').open('w'))
            # Time Profiler keeps per-sample timestamps, so a stall can be matched to its stack.
            stacks = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                                       '--attach', daemon, '--time-limit', '60s', '--output',
                                       str(out / f'{bundle_label}-daemon.trace')],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if sample_daemon else None
            if stacks:
                time.sleep(3)  # xctrace attaches asynchronously
            time.sleep(.3)
            nav_start = write_counters()
            driver = []
            races, race_trace = race(out, fixtures, [e[2] for e in expected], race_delays, driver, race_plan) \
                if race_delays else (None, '')
            for command, pause in [] if race_delays else steps:
                began = time.monotonic()
                session.command('focus-column', command)
                driver.append({'command': command, 'uptime': pe_uptime(), 'replyMS': (time.monotonic() - began) * 1000})
                time.sleep(pause)
            time.sleep(1.2)
            writes['navigation'] = write_rate(0, nav_start)
            sampler.send_signal(signal.SIGTERM)
            sampler.wait(timeout=15)
            vsync.send_signal(signal.SIGTERM)
            vsync.wait(timeout=5)
            if stacks:
                stacks.send_signal(signal.SIGINT)
                stacks.wait(timeout=120)
        trace = race_trace or session.command('trace')
        (out / f'{bundle_label}-trace.txt').write_text(trace)
        (out / f'{bundle_label}-driver.json').write_text(json.dumps(driver))
        for i in busy_fixtures if busy[0] > 0 else ():
            fixtures[i].ask('set-busy', delay=0, period=busy[1])
        records = [json.loads(l) for l in samples.read_text().splitlines()]
        start = records[0]
        states = [r for r in records if 'apps' in r]
        end = records[-1]['t']
        display_w = start['displays'][0][2]
        result = analyze(states, end, [e[2] for e in expected], display_w)
        result['trace'] = {k: len(re.findall(p, trace)) for k, p in {
            'fallback': r'animation-fallback|fallback ', 'slow_lane': r'slow-lane ', 'abort': r'abort',
            'stale': r'stale-completion', 'slow': r' slow g=', 'recovery': r'focus-recovery'}.items()}
        focus_ms = [float(m) for m in re.findall(r'command-focus cg=\d+ ms=([\d.]+)', trace)]
        result['focus_ms'] = {'p50': round(statistics.median(focus_ms), 1) if focus_ms else None,
                              'max': round(max(focus_ms, default=0), 1), 'n': len(focus_ms)}
        if races is not None:
            result['races'] = races
        latency = start_latency(states, trace)
        result['start_latency_ms'] = {'max': round(max(latency, default=0), 1),
                                      'late': sum(x > 80 for x in latency), 'animations': len(latency)}
        result['reply_ms_max'] = max(d['replyMS'] for d in driver)
        if idle:
            writes['idle_after'] = write_rate(idle)
        result['writes'] = {k: {f: v[f] for f in ('pos_per_s', 'size_per_s', 'drift')} for k, v in writes.items()}
        return result
    finally:
        for f in fixtures:
            f.close()


def write_counters():
    status = session.command('status')
    get = lambda k: int(re.search(r'\b' + k + r'=(\d+)', status).group(1))
    return {'t': time.monotonic(), 'pos': get('posWrites'), 'size': get('sizeWrites'), 'drift': get('drift')}


def write_rate(seconds, start=None):
    """Daemon AX position/size writes per second over `seconds` of idle (or since `start`)."""
    start = start or write_counters()
    time.sleep(seconds)
    end = write_counters()
    dt = end['t'] - start['t']
    return {'pos_per_s': round((end['pos'] - start['pos']) / dt, 2),
            'size_per_s': round((end['size'] - start['size']) / dt, 2), 'drift': end['drift'], 'end': end}


def pe_uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--rounds', type=int, default=3)
    p.add_argument('--busy', type=float, nargs=2, default=[.018, .020], help='delay period (s); 0 PERIOD disables')
    p.add_argument('--busy-fixtures', type=int, nargs='+', default=[2],
                   help='fixture indexes (0-2, left to right) slowed by --busy')
    p.add_argument('--activation-busy', type=float, default=0,
                   help='ms the busy fixture blocks its main thread after becoming active')
    p.add_argument('--pause', type=float, nargs=2, default=[.12, .30],
                   help='seconds between commands (min max) within each burst')
    p.add_argument('--activation-fixtures', type=int, nargs='+', default=[2],
                   help='fixture indexes (0-2, left to right) slowed by --activation-busy')
    p.add_argument('--race-delays', type=float, nargs='+', default=[],
                   help='forced focus race: ms after the first command to send the second (replaces the human sequence)')
    p.add_argument('--race-plan', choices=RACE_PLANS, default='race')
    p.add_argument('--clamp-fixture', type=int, help='fixture index (0-2) replaced by Tests/Fixtures/ClampFixture.swift; '
                   'drift is then excluded from settledness (a clamped window may drift by construction)')
    p.add_argument('--clamp-env', nargs='+', default=['DEFI_FIXTURE_MIN=196,464', 'DEFI_FIXTURE_MAX=468,1007',
                   'DEFI_FIXTURE_SNAP=230,532'], help='ClampFixture environment (default mimics Device Hub)')
    p.add_argument('--idle', type=float, default=0, help='s of idle write counting before and after navigation')
    p.add_argument('--sample-daemon', action='store_true', help='also record a Time Profiler trace of defi-daemon (perturbs timing)')
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
    if args.clamp_fixture is not None:
        pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/ClampFixture.swift', '-o', out / 'ClampFixture'])
        # A window the app keeps re-clamping never settles on a looping build; measure, do not gate.
        lenient = lambda status: 'focusPending=false' in status
        pe.settled = lenient
        global wait_for_settlement
        def wait_for_settlement(timeout=10):
            deadline = time.monotonic() + timeout
            while not lenient(session.command('status')):
                if time.monotonic() > deadline:
                    raise RuntimeError(f'Workspace did not settle within {timeout}s')
                time.sleep(.3)
    pe.run(['swiftc', '-O', '-swift-version', '6', ROOT / 'script/motion_probe.swift', '-o', out / 'motion-probe'])
    pe.run(['swiftc', '-O', ROOT / 'script/vsync_probe.swift', '-o', out / 'vsync-probe'])
    pe.run(['swiftc', '-O', ROOT / 'script/click_probe.swift', '-o', out / 'click-probe'])
    if args.activation_busy:
        pe.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                ROOT / 'script/slow_activation_hook.m', '-o', out / 'slow_activation_hook.dylib'])

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
            steps = sequence(r, args.pause)
            for label, path in bundles.items():
                install(Path(path).resolve())
                pe.wait_for_idle()
                res = trial(out, f'{label}{r}', steps, args.busy, out / 'motion-probe', args.sample_daemon,
                            args.activation_busy, args.activation_fixtures, args.race_delays,
                            args.busy_fixtures, args.race_plan, args.clamp_fixture,
                            dict(e.split('=', 1) for e in args.clamp_env), args.idle)
                res.update(side=label, round=r)
                print(json.dumps(res), flush=True)
                results.append(res)
                (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        try:
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
