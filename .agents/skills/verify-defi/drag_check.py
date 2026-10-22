#!/usr/bin/env python3
"""Native title-bar drags of fixture windows on an empty workspace, checked against column membership.
Usage: python3 script/desktop_lock.py --wait python3 .agents/skills/verify-defi/drag_check.py [evidence-dir]
Needs cliclick and Accessibility for the calling terminal. Restores the initial workspace."""
import json, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402

TOPOLOGY = Path.home() / 'Library/Application Support/Defi/workspace-topology.json'


def columns(workspace):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        for monitor in json.loads(TOPOLOGY.read_text())['topology']['monitors']:
            for candidate in monitor['workspaces']:
                if candidate['id'] == workspace:
                    return [column['windows'] for column in candidate['columns']]
        time.sleep(.1)
    raise RuntimeError(f'workspace {workspace} missing from topology store')


def converge(workspace, expected, timeout=4):
    """Membership once it equals `expected` with frames settled, else (last membership, False)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        actual = columns(workspace)
        if actual == expected and pe.settled(session.command('status')):
            return actual, True
        time.sleep(.1)
    return columns(workspace), False


def frame(fixture, window_number):
    rows = fixture.ask()['windows']
    return next(r['frame'] for r in rows if r['windowNumber'] == window_number)


def drag(fixture, window_number, targets, workspace, display_width, hold=.35):
    """Human-paced drag of the title bar so the window center visits each absolute x in `targets`
    (30 moves per leg at ~20 ms), pause, sample the previewed drop and membership while held, release.
    Targets stay 80 pt inside the display so macOS edge tiling never engages."""
    x, y, w, _ = frame(fixture, window_number)
    sx, sy = round(x + w / 2), round(y + 12)
    script, last = [f'm:{sx},{sy}', 'w:80', f'dd:{sx},{sy}', 'w:120'], sx
    for target in targets:
        target = min(max(round(target), 80), display_width - 80)
        for i in range(1, 31):
            script += [f'dm:{round(last + (target - last) * i / 30)},{sy}', 'w:20']
        last = target
    try:
        subprocess.run(['cliclick', *script, f'w:{int(hold * 1000)}'], check=True)
        previews = shown_preview()
        held = columns(workspace)
        held_frame = frame(fixture, window_number)
    finally:
        subprocess.run(['cliclick', f'du:{last},{sy}'], check=True)
    return previews, held, held_frame, last


def shown_preview():
    """The drop target the overlay is previewing, from the daemon's latest preview trace."""
    requested = re.findall(r'mouse-drop-preview window=\d+ target=(.+)', session.command('trace'))
    return [] if not requested or requested[-1] == 'none' else [requested[-1]]


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else
               ROOT / f'dist/verification/evidence-{time.strftime("%Y%m%d-%H%M%S")}')
    out.mkdir(parents=True, exist_ok=True)
    (out / 'before.status').write_text(session.command('status'))
    initial = next(w for w in (out / 'before.status').read_text().split() if w.startswith('workspace='))
    initial = initial.split('=', 1)[1]
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift',
            '-o', out / 'PerformanceFixture'])
    if len(json.loads(session.command('list-workspaces', '--json'))['monitors']) != 1:
        sys.exit('drag_check needs exactly one monitor; drive cross-monitor drops by hand')
    fixtures, results = [], []
    try:
        for i in range(3):
            fixtures.append(pe.Fixture(out / 'PerformanceFixture', out / f'fixture-{i}.jsonl'))
        for f in fixtures:
            f.ask()
        pe.activate(fixtures[0].process.pid)
        monitor = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)['id']
        session.command('workspace', empty)
        expected, discovered = [], set()
        for i, f in enumerate(fixtures):
            number = f.ask('create', id='main')['windows'][0]['windowNumber']
            expected.append((i, 'main', number))
            pe.wait_owned(fixtures, expected, empty, discovered)
            session.command('focus-column', 'last')
            pe.wait_owned(fixtures, expected, empty, discovered, selected=number)
            session.command('cycle-width', 'previous')
        a, b, c = (e[2] for e in expected)
        start, _ = converge(empty, [[a], [b], [c]])
        session.command('focus-column', 'first')
        time.sleep(.4)
        session.command('focus-column', 'right')
        time.sleep(.4)
        session.command('join-window', 'left')
        stacked, _ = converge(empty, [[a, b], [c]])
        session.command('trace')

        display_width = int(re.search(r'monitors=\d+\[\d+:(\d+)x', session.command('status')).group(1))
        windows = dict(zip((a, b, c), fixtures))

        def center(number, offset=0.0):
            x, _, w, _ = frame(windows[number], number)
            return x + w / 2 + offset * w

        for number in (a, b, c):
            x, _, w, _ = frame(windows[number], number)
            if x < 0 or x + w > display_width:
                raise RuntimeError(f'fixture {number} not fully on screen; three columns must fit')

        def check(name, number, targets, want, want_preview):
            before = columns(empty)
            previews, held, held_frame, pointer = drag(windows[number], number, targets, empty, display_width)
            want = want or before
            actual, settled = converge(empty, want)
            ok = settled and actual == want and held == before and bool(previews) == want_preview
            results.append({'name': name, 'before': before, 'heldDuringDrag': held, 'after': actual,
                            'expected': want, 'previews': previews, 'heldFrame': held_frame,
                            'pointerX': pointer, 'pass': ok})
            (out / f'trace-{name}.log').write_text(session.command('trace'))
            print(f'{name}: {"PASS" if ok else "FAIL"} before={before} held={held} after={actual} '
                  f'expected={want} preview={previews[:1]} heldFrame={held_frame} pointerX={pointer}')

        print(f'start={start} stacked={stacked}')
        check('cancel-within-own-column', c, [center(c) + 40], [[a, b], [c]], False)
        check('extract-stack-bottom-right', b, [center(c, .35)], [[a], [c], [b]], True)
        check('single-column-left-across-two', b, [center(a, -.35)], [[b], [a], [c]], True)
        check('drop-back-at-origin', a, [center(c, .35), center(a) + 10], None, False)
        print('cross-monitor: SKIP single-monitor harness')
    finally:
        for f in fixtures:
            f.close()
        session.command('workspace', initial)
        (out / 'after.status').write_text(session.command('status'))
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        daemons = session.daemon_count()
        print(f'daemons={daemons} evidence: {out}')
    sys.exit(0 if daemons == 1 and results and all(r['pass'] for r in results) else 1)


if __name__ == '__main__':
    main()
