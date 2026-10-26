#!/usr/bin/env python3
"""Frame pacing probe: does the overlay keep every frame while the ribbon scrolls?
Five fixture windows on an empty workspace; spaced focus-column right/left, screen-recorded
with the overlay included. A motion is a burst of changing frames; a frame identical to the
previous one inside a burst is a stall (a frame the compositor did not draw anew).
Usage (under the desktop lock): script/frame_pacing_probe.py OUT --bundle LABEL=path [...]
Restores the original bundle and session."""
import argparse, json, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

GAP = .9


def bursts(movie):
    """Per motion: frame count, stalled frames inside it, and the longest gap between changes."""
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height',
                            '-of', 'csv=p=0', str(movie)], capture_output=True, text=True, check=True).stdout
    width, height = map(int, probe.strip().split(','))
    times = [float(t.strip(',')) for t in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0',
         str(movie)], capture_output=True, text=True, check=True).stdout.split()]
    w = width // 4
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(movie), '-fps_mode', 'passthrough',
                          '-vf', f'crop={width}:4:0:{height // 2},scale={w}:1', '-f', 'rawvideo',
                          '-pix_fmt', 'gray', '-'], capture_output=True, check=True).stdout
    rows = [raw[i:i + w] for i in range(0, len(raw), w)]
    changed = [False] + [sum(abs(a - b) for a, b in zip(r, p)) / w > 1.5 for p, r in zip(rows, rows[1:])]
    moves, current = [], None
    for t, c in zip(times, changed):
        if c:
            if current and t - current[-1] > .15:
                moves.append(current); current = None
            current = (current or []) + [t]
    if current:
        moves.append(current)
    intervals = sorted(b - a for a, b in zip(times, times[1:]) if b > a)
    frame = intervals[len(intervals) // 10] if intervals else 1 / 60
    out = []
    for m in moves:
        if len(m) < 4:
            continue
        gaps = [b - a for a, b in zip(m, m[1:])]
        out.append({'ms': round((m[-1] - m[0]) * 1000), 'changes': len(m),
                    'stalls': sum(round(g / frame) - 1 for g in gaps if g > frame * 1.5),
                    'max_gap_ms': round(max(gaps) * 1000, 1)})
    return {'frame_ms': round(frame * 1000, 2), 'moves': out,
            'stalls_total': sum(m['stalls'] for m in out), 'changes_total': sum(m['changes'] for m in out)}


def trial(out, label, rounds, record):
    fixture = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-fixture.jsonl')
    try:
        fixture.ask()
        pe.activate(fixture.process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        time.sleep(1)
        expected, discovered = [], set()
        for n in range(5):
            report = fixture.ask('create', id=f'w{n}')
            expected.append((0, f'w{n}', next(w['windowNumber'] for w in report['windows'] if w['id'] == f'w{n}')))
            pe.wait_owned([fixture], expected, empty['id'], discovered)
        session.command('focus-column', 'first')
        time.sleep(1.5)
        # -V ends the recording itself; an interrupted screencapture writes no file.
        recorder = subprocess.Popen(['screencapture', '-x', '-v', '-V', str(record), str(out / f'{label}.mov')],
                                    stdin=subprocess.DEVNULL)
        time.sleep(1)
        for _ in range(rounds):
            for direction in ['right'] * 4 + ['left'] * 4:
                subprocess.run([str(session.CLI), 'focus-column', direction], check=True, capture_output=True)
                time.sleep(GAP)
        recorder.wait(timeout=record + 30)
        return bursts(out / f'{label}.mov')
    finally:
        fixture.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path, nargs='?')
    p.add_argument('--bundle', action='append', default=[], help='LABEL=path')
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--analyze', type=Path, help='only analyze this recording')
    args = p.parse_args()
    if args.analyze:
        print(json.dumps(bursts(args.analyze), indent=1)); return
    if not args.output or not args.bundle:
        p.error('OUT and --bundle are required unless --analyze')
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    record = int(args.rounds * 8 * GAP + 3)
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
    # Verification only: screen recordings then include the overlay.
    subprocess.run(['defaults', 'write', 'com.qeude.defi', 'RibbonProxyCapturable', '-bool', 'true'], check=True)
    try:
        for label, path in (b.split('=', 1) for b in args.bundle):
            install(Path(path).resolve())
            pe.wait_for_idle()
            res = trial(out, label, args.rounds, record)
            print(json.dumps({'side': label, 'frame_ms': res['frame_ms'], 'stalls': res['stalls_total'],
                              'changes': res['changes_total'], 'moves': res['moves']}), flush=True)
    finally:
        subprocess.run(['defaults', 'delete', 'com.qeude.defi', 'RibbonProxyCapturable'], check=False)
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
