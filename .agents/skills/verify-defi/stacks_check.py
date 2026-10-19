#!/usr/bin/env python3
"""Stack size-constraint journey on the installed daemon (see features/stacks.md).

Uses ClampFixture windows whose NSWindow minimum height is set through DEFI_FIXTURE_MIN, on the
empty trailing workspace of the first monitor. Shrinks the viewport with
`set-reserved-area bottom`, then restores it to --restore-bottom (default 0, the built-in default).
Usage: python3 script/desktop_lock.py --wait python3 .agents/skills/verify-defi/stacks_check.py [evidence-dir]
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402

SHRINK_PT = 400
results = []


def defi(*args):
    done = subprocess.run([str(session.CLI), *args], capture_output=True, text=True, timeout=15)
    return done.returncode == 0, (done.stdout + done.stderr).strip()


def status_value(key):
    for token in session.command('status').split(' '):
        if token.startswith(key + '='):
            return token[len(key) + 1:]
    return None


def check(name, ok, detail):
    results.append((name, ok))
    print(f'{"PASS" if ok else "FAIL"} {name}: {detail}')


class Windows:
    def __init__(self, binary, out):
        self.binary, self.out, self.fixtures = binary, out, {}

    def open(self, name, min_height=None):
        if min_height:
            os.environ['DEFI_FIXTURE_MIN'] = f'200,{int(min_height)}'
        try:
            fixture = pe.Fixture(self.binary, self.out / f'{name}.jsonl')
        finally:
            os.environ.pop('DEFI_FIXTURE_MIN', None)
        fixture.ask()
        number = fixture.ask('create', id='main')['windows'][0]['windowNumber']
        pe.activate(fixture.process.pid)
        self.fixtures[name] = (fixture, number)
        self.settle()
        defi('focus-column', 'last')
        self.settle()
        return number

    def close(self, *names):
        for name in names:
            self.fixtures.pop(name)[0].close()
        self.settle()

    def frame(self, name):
        return self.fixtures[name][0].ask()['windows'][0]['frame']

    def number(self, name):
        return self.fixtures[name][1]

    def settle(self, timeout=8):
        deadline, previous, since = time.monotonic() + timeout, None, time.monotonic()
        while time.monotonic() < deadline:
            frames = {name: self.frame(name) for name in self.fixtures}
            if frames != previous:
                previous, since = frames, time.monotonic()
            elif time.monotonic() - since > .6 and pe.settled(session.command('status')):
                return True
            time.sleep(.1)
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('out', nargs='?', default=f'dist/verification/evidence-{time.strftime("%Y%m%d-%H%M%S")}')
    parser.add_argument('--restore-bottom', type=int, default=0)
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'before.status').write_text(session.command('status'))
    (out / 'workspaces-before.json').write_text(session.command('list-workspaces', '--json'))
    initial_workspace = status_value('workspace')
    binary = out / 'ClampFixture'
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/ClampFixture.swift', '-o', binary])

    monitor = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
    empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)
    session.command('workspace', empty['id'])
    windows = Windows(binary, out)
    try:
        windows.open('plain')
        lone = windows.frame('plain')[3]
        print(f'lone window height {lone:.0f}pt')

        windows.open('b')
        windows.open('c')
        defi('join-window', 'left')
        defi('focus-column', 'first')
        defi('join-window', 'right')
        windows.settle()
        heights = [windows.frame(n)[3] for n in ('b', 'c', 'plain')]
        xs = {round(windows.frame(n)[0]) for n in ('b', 'c', 'plain')}
        check('balanced three-window stack', len(xs) == 1 and max(heights) - min(heights) <= 2,
              f'x={sorted(xs)} heights={[round(h) for h in heights]}')
        defi('unjoin-windows')
        windows.close('b', 'c')

        tall = 0.6 * lone
        windows.open('tall', tall)
        defi('join-window', 'left')
        windows.settle()
        plain, constrained = windows.frame('plain'), windows.frame('tall')
        check('feasible unequal stack', round(plain[0]) == round(constrained[0])
              and constrained[3] >= tall - 1 and plain[3] < constrained[3],
              f'min={tall:.0f} tall={constrained[3]:.0f} plain={plain[3]:.0f}')
        defi('unjoin-windows')
        windows.settle()

        windows.open('tall2', tall)
        before = (windows.frame('tall'), windows.frame('tall2'))
        ok, text = defi('join-window', 'left')
        windows.settle()
        after = (windows.frame('tall'), windows.frame('tall2'))
        check('impossible join rejected', not ok and 'cannot join' in text
              and before == after and status_value('focused') == str(windows.number('tall2')),
              f'reply="{text}" unchanged={before == after} focused={status_value("focused")}')
        windows.close('tall', 'tall2')

        half = 0.42 * lone
        windows.open('s1', half)
        windows.open('s2', half)
        defi('join-window', 'left')
        windows.settle()
        joined = round(windows.frame('s1')[0]) == round(windows.frame('s2')[0])
        defi('set-reserved-area', 'bottom', str(SHRINK_PT))
        windows.settle()
        split = (windows.frame('s1'), windows.frame('s2'))
        check('shrink separates stack', joined and round(split[0][0]) < round(split[1][0])
              and status_value('focused') == str(windows.number('s2')),
              f'joined={joined} s1.x={split[0][0]:.0f} s2.x={split[1][0]:.0f} focused={status_value("focused")}')
        defi('set-reserved-area', 'bottom', str(args.restore_bottom))
        windows.settle()
        check('growth does not re-merge', round(windows.frame('s1')[0]) != round(windows.frame('s2')[0]),
              f's1.x={windows.frame("s1")[0]:.0f} s2.x={windows.frame("s2")[0]:.0f}')
        windows.close('s1', 's2')

        windows.open('huge', lone + 200)
        windows.settle()
        oversized = status_value('oversized-stack-windows') or ''
        ok, text = defi('join-window', 'left')
        windows.settle()
        check('oversized single window diagnosed, not split',
              str(windows.number('huge')) in oversized.split(',') and not ok,
              f'oversized-stack-windows={oversized} join="{text}"')
    finally:
        defi('set-reserved-area', 'bottom', str(args.restore_bottom))
        for name in list(windows.fixtures):
            windows.fixtures.pop(name)[0].close()
        time.sleep(1)
        session.command('workspace', initial_workspace)
        (out / 'after.status').write_text(session.command('status'))
        (out / 'workspaces-after.json').write_text(session.command('list-workspaces', '--json'))
        (out / 'trace.log').write_text(session.command('trace'))
    print(f'daemons={session.daemon_count()} evidence: {out}')
    return 0 if results and all(ok for _, ok in results) else 1


if __name__ == '__main__':
    sys.exit(main())
