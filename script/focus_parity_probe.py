#!/usr/bin/env python3
"""Focus parity probe: does a click or an app activation (Cmd-Tab's path) move the ribbon like
the keyboard? Fixture A owns columns 0 and 2, fixture B column 1. From column 0 focused, each
trial focuses column 1 by `focus-column right`, by a click on it, or by activating B. Reports,
per trigger, the delay from the input to the motion's submit in `defi trace`, its source, and
the screen-recorded motion (overlay included): bursts of changing frames, their length and stalls.
Usage (under the desktop lock): script/focus_parity_probe.py OUT [--trials N]
Restores the session; the installed bundle is used as is."""
import argparse, json, os, re, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

SPACING = 2.5


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def frames(movie):
    """Times of the recording's frames and whether each changed from the previous one. Whole
    frames at 160x90: same-coloured fixtures differ only by their edges and title bars."""
    times = [float(t.strip(',')) for t in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0',
         str(movie)], capture_output=True, text=True, check=True).stdout.split()]
    w, h = 160, 90
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(movie), '-fps_mode', 'passthrough',
                          '-vf', f'scale={w}:{h},format=gray', '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    rows = [raw[i:i + w * h] for i in range(0, len(raw), w * h)]
    changed = [False] + [sum(abs(a - b) > 12 for a, b in zip(p, r)) > 20 for p, r in zip(rows, rows[1:])]
    return list(zip(times, changed))


def bursts(changes):
    """Runs of changing frames split by 120 ms still: a jump is a burst of one or two."""
    out, current = [], []
    for t in changes:
        if current and t - current[-1] > .12:
            out.append(current); current = []
        current.append(t)
    if current:
        out.append(current)
    return [{'at_ms': round(b[0] * 1000), 'ms': round((b[-1] - b[0]) * 1000), 'changes': len(b),
             'max_gap_ms': round(max([y - x for x, y in zip(b, b[1:])] or [0]) * 1000, 1)} for b in out]


def trace_lines():
    return [l for l in session.command('trace').splitlines() if re.match(r'\d', l)]


def run(out, trials, hold_ms):
    a = pe.Fixture(out / 'PerformanceFixture', out / 'a.jsonl')
    b = pe.Fixture(out / 'PerformanceFixture', out / 'b.jsonl')
    results = {k: [] for k in ('keyboard', 'click', 'activation')}
    try:
        a.ask(); b.ask()
        pe.activate(a.process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        time.sleep(1)
        expected, discovered = [], set()
        # A's windows first: activating A again would select a0 and open a2 after it.
        for fixture, index, name in ((a, 0, 'a0'), (a, 0, 'a2'), (b, 1, 'b1')):
            pe.activate(fixture.process.pid)
            if name == 'b1':
                session.command('focus-column', 'first')
                time.sleep(.6)
            report = fixture.ask('create', id=name)
            number = next(w['windowNumber'] for w in report['windows'] if w['id'] == name)
            expected.insert(1, (index, name, number)) if name == 'b1' else expected.append((index, name, number))
            pe.wait_owned([a, b], expected, empty['id'], discovered)
        b1 = expected[1][2]
        # 0.80 wide: column 1 is only partly visible from column 0, so focusing it scrolls.
        session.command('focus-column', 'first')
        for _ in range(3):
            session.command('cycle-width', 'next'); session.command('cycle-width', 'next')
            session.command('focus-column', 'right')
            time.sleep(.6)
        for trigger in list(results):
            # One recording per trigger: its motions are matched to trials by order.
            starts = []
            record = int(trials * (SPACING + .6) + 5)
            movie = out / f'{trigger}.mov'
            for _ in range(trials):
                session.command('focus-column', 'first')
                time.sleep(SPACING / 2)
                if not starts:
                    recorder = subprocess.Popen(['screencapture', '-x', '-v', '-V', str(record), str(movie)],
                                                stdin=subprocess.DEVNULL)
                    recording_started = uptime()
                    time.sleep(1.5)
                    session.command('focus-column', 'first')
                    time.sleep(SPACING / 2)
                if trigger == 'keyboard':
                    t0 = uptime()
                    subprocess.run([str(session.CLI), 'focus-column', 'right'], check=True, capture_output=True)
                elif trigger == 'click':
                    t0 = float(subprocess.check_output([str(out / 'click-probe'), str(b1)], text=True,
                                                       env={**os.environ, 'CLICK_HOLD_MS': str(hold_ms)}).split()[0])
                else:
                    t0 = uptime()
                    pe.activate(b.process.pid)
                starts.append(t0)
                time.sleep(SPACING / 2)
            recorder.wait(timeout=record + 30)
            lines = trace_lines()
            (out / f'{trigger}-trace.txt').write_text('\n'.join(lines))
            (out / f'{trigger}-starts.json').write_text(json.dumps({'starts': starts, 'recording': recording_started}))
            changes = [t for t, c in frames(movie) if c]
            moves = bursts(changes)
            for i, t0 in enumerate(starts):
                window = [l for l in lines if t0 - .05 <= float(l.split()[0]) < t0 + SPACING / 2]
                focus = next((l for l in window if 'native-focus target' in l and 'accepted=true' in l), None)
                if trigger == 'activation' and focus and (m := re.search(r'activationTS=([\d.]+)', focus)):
                    t0 = float(m.group(1))
                submit = next((l for l in window if re.search(r'\bsubmit g=\d+ source=(?!desktop-sync)', l)), None)
                results[trigger].append({
                    'submit_ms': round((float(submit.split()[0]) - t0) * 1000) if submit else None,
                    'source': re.search(r'source=(\S+)', submit).group(1) if submit else None,
                })
            # The motions after each reset: every other burst group (reset, trigger, reset, trigger...).
            results[trigger + '_bursts'] = moves
    finally:
        a.close(); b.close()
    return results


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--trials', type=lambda v: max(1, int(v)), default=5)
    p.add_argument('--hold-ms', type=int, default=110, help='how long each click holds the button')
    args = p.parse_args()
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])
    pe.run(['swiftc', '-O', ROOT / 'script/click_probe.swift', '-o', out / 'click-probe'])
    checkpoint = out / 'checkpoint'
    session.checkpoint(checkpoint)
    session.start()
    subprocess.run(['defaults', 'write', 'com.qeude.defi', 'RibbonProxyCapturable', '-bool', 'true'], check=True)
    try:
        pe.wait_for_idle()
        res = run(out, args.trials, args.hold_ms)
        for trigger in ('keyboard', 'click', 'activation'):
            rows = res[trigger]
            delays = [r['submit_ms'] for r in rows if r['submit_ms'] is not None]
            print(json.dumps({'trigger': trigger, 'sources': sorted({str(r['source']) for r in rows}),
                              'submit_ms_median': statistics.median(delays) if delays else None,
                              'submit_ms': [r['submit_ms'] for r in rows],
                              'bursts': res[trigger + '_bursts']}), flush=True)
    finally:
        subprocess.run(['defaults', 'delete', 'com.qeude.defi', 'RibbonProxyCapturable'], check=False)
        try:
            session.restore(checkpoint)
        except Exception:  # LaunchServices can reject the first service start (-600)
            time.sleep(2)
            session.restore(checkpoint)
        print('daemons', session.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
