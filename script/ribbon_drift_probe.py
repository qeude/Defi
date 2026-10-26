#!/usr/bin/env python3
"""Ribbon drift probe: do neighbours on the overlay move as one while the ribbon scrolls?
Five coloured fixture windows on an empty workspace; focus-column right/left at spaced,
human and rapid cadences, screen-recorded with the overlay included. Per frame, one row at
mid-height measures the widest wallpaper hole between two windows: neighbours that drift
apart open one (and overlap on the other side).
Usage (under the desktop lock): script/ribbon_drift_probe.py OUT --bundle LABEL=path [...]
Restores the original bundle and session."""
import argparse, json, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
import tear_probe as tp  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

CADENCES = {'spaced': .45, 'human': .15, 'rapid': .08}


def holes(movie, start_uptime, spans):
    """Widest interior wallpaper run (points) per frame at mid-height, grouped by cadence span."""
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height',
                            '-of', 'csv=p=0', str(movie)], capture_output=True, text=True, check=True).stdout
    width, height = map(int, probe.strip().split(','))
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(movie), '-vf', f'fps=60,crop={width}:2:0:{height // 2}',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True, check=True).stdout
    scale = width / 1512
    rows = [raw[i:i + width * 3] for i in range(0, len(raw), width * 6)]
    out = {name: [] for name in spans}
    for index, row in enumerate(rows):
        t = start_uptime + index / 60
        name = next((n for n, (a, b) in spans.items() if a <= t < b), None)
        if name is None:
            continue
        # The wallpaper here is black and orange; every fixture colour keeps a strong blue channel.
        window = [row[x * 3 + 2] >= 70 for x in range(width)]
        if True not in window:
            continue
        first, last = window.index(True), width - 1 - window[::-1].index(True)
        widest = run = 0
        for x in range(first, last + 1):
            run = 0 if window[x] else run + 1
            widest = max(widest, run)
        out[name].append(widest / scale)
    return {name: {'frames': len(v), 'hole_max_pt': round(max(v, default=0)),
                   'frames_hole_over_12pt': sum(h > 12 for h in v)} for name, v in out.items()}


def trial(out, label, rounds, record):
    fixture = pe.Fixture(out / 'PerformanceFixture', out / f'{label}-fixture.jsonl')
    try:
        fixture.ask()
        pe.activate(fixture.process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        tp.wait_for_settlement()
        expected, discovered = [], set()
        for n in range(5):
            report = fixture.ask('create', id=f'w{n}')
            expected.append((0, f'w{n}', next(w['windowNumber'] for w in report['windows'] if w['id'] == f'w{n}')))
            pe.wait_owned([fixture], expected, empty['id'], discovered)
        session.command('focus-column', 'first')
        tp.wait_for_settlement()
        # -V ends the recording itself; an interrupted screencapture writes no file.
        recorder = subprocess.Popen(['screencapture', '-x', '-v', '-V', str(record), str(out / f'{label}.mov')],
                                    stdin=subprocess.DEVNULL)
        recording_started = tp.pe_uptime()
        spans = {}
        for name, gap in CADENCES.items():
            time.sleep(.5)
            began = tp.pe_uptime()
            for _ in range(rounds):
                for direction in ['right'] * 4 + ['left'] * 4:
                    subprocess.run([str(session.CLI), 'focus-column', direction], check=True, capture_output=True)
                    time.sleep(gap)
                tp.wait_for_settlement()
            spans[name] = (began, tp.pe_uptime())
        recorder.wait(timeout=record + 30)
        return holes(out / f'{label}.mov', recording_started, spans)
    finally:
        fixture.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--record', type=int, default=20, metavar='S', help='seconds recorded; must cover every cadence')
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
    # Verification only: screen recordings then include the overlay.
    subprocess.run(['defaults', 'write', 'com.qeude.defi', 'RibbonProxyCapturable', '-bool', 'true'], check=True)
    try:
        for label, path in (b.split('=', 1) for b in args.bundle):
            install(Path(path).resolve())
            pe.wait_for_idle()
            res = trial(out, label, args.rounds, args.record)
            print(json.dumps({'side': label, **res}), flush=True)
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
