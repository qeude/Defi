#!/usr/bin/env python3
"""Stack size-constraint journey on the installed daemon (see features/stacks.md).

Uses ClampFixture windows whose NSWindow minimum height is set through DEFI_FIXTURE_MIN, on the
first empty workspace of the first monitor. Shrinks the viewport with
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


def wait_until(condition, timeout=5):
    deadline = time.monotonic() + timeout
    while not condition() and time.monotonic() < deadline:
        time.sleep(.2)
    return condition()


def applied_writes(window_number, seconds=3):
    """AX frame writes the coordinator applied to one window over `seconds`."""
    def events():
        for line in session.command('trace').splitlines():
            fields = line.split(' ')
            try:
                yield float(fields[0]), fields
            except ValueError:
                continue
    start = max(at for at, _ in events())
    time.sleep(seconds)
    lines = [fields for at, fields in events() if at > start and len(fields) > 4]
    def submitted(field):
        return field.startswith('windows=') and str(window_number) in field.split('[')[1].rstrip(']').split(',')
    generations = {fields[2] for fields in lines if fields[1] == 'submit' and any(map(submitted, fields))}
    # Generation-wide totals over every completion kind: conservative, a mixed batch can only over-count.
    return sum(int(field.split('=')[1]) for fields in lines if fields[1] != 'submit' and fields[2] in generations
               for field in fields if field.startswith('applied='))


def check(name, ok, detail):
    results.append((name, ok))
    print(f'{"PASS" if ok else "FAIL"} {name}: {detail}')


class Windows:
    def __init__(self, binary, out, workspace):
        self.binary, self.out, self.workspace, self.fixtures = binary, out, workspace, {}

    def home(self):
        # Closing a window hands native focus to another app, which Defi follows to its workspace.
        defi('workspace', self.workspace)
        self.settle()

    def open(self, name, min_height=None):
        self.home()
        if min_height:
            os.environ['DEFI_FIXTURE_MIN'] = f'200,{int(min_height)}'
        try:
            fixture = pe.Fixture(self.binary, self.out / f'{name}.jsonl')
        finally:
            os.environ.pop('DEFI_FIXTURE_MIN', None)
        try:
            fixture.ask()
            managed = int(status_value('windows') or 0)
            number = fixture.ask('create', id='main')['windows'][0]['windowNumber']
            # Constraints are read when discovery adopts the window, a few hundred ms after it appears.
            wait_until(lambda: int(status_value('windows') or 0) > managed)
            pe.activate(fixture.process.pid)
        except BaseException:
            fixture.close()
            raise
        self.fixtures[name] = (fixture, number)
        self.settle()
        self.focus('last', number)
        return number

    def focus(self, column, number):
        defi('focus-column', column)
        wait_until(lambda: status_value('focused') == str(number))
        self.settle()

    def close(self, *names):
        for name in names:
            self.fixtures.pop(name)[0].close()
        self.home()

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
    parser.add_argument('--restore-bottom', type=int, default=0, choices=range(0, 513), metavar='0..512')
    args = parser.parse_args()
    # Reserved-area commands apply to every monitor; restoring one value is only safe with one.
    if len(json.loads(session.command('list-workspaces', '--json'))['monitors']) != 1:
        sys.exit('stacks_check.py requires exactly one monitor')
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'before.status').write_text(session.command('status'))
    (out / 'workspaces-before.json').write_text(session.command('list-workspaces', '--json'))
    initial_workspace = status_value('workspace')
    daemon = Path(session.CLI).with_name('defi-daemon')
    daemon_digest = daemon.read_bytes()
    binary = out / 'ClampFixture'
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/ClampFixture.swift', '-o', binary])

    monitor = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
    empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)
    session.command('workspace', empty['id'])
    windows = Windows(binary, out, empty['id'])
    try:
        windows.open('plain')
        lone = windows.frame('plain')[3]
        print(f'lone window height {lone:.0f}pt')

        windows.open('b')
        windows.open('c')
        defi('join-window', 'left')
        wait_until(lambda: round(windows.frame('b')[0]) == round(windows.frame('c')[0]))
        windows.focus('first', windows.number('plain'))
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
        wait_until(lambda: windows.frame('plain')[3] + windows.frame('tall')[3] <= lone)
        plain, constrained = windows.frame('plain'), windows.frame('tall')
        check('feasible unequal stack', round(plain[0]) == round(constrained[0])
              and constrained[3] >= tall - 1 and plain[3] + constrained[3] <= lone,
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

        # The window server reports a minimum taller than the screen as the current height,
        # so an oversized window only exists against a viewport smaller than the screen.
        windows.open('huge', 0.9 * lone)
        defi('set-reserved-area', 'bottom', str(SHRINK_PT))
        windows.settle()
        oversized = status_value('oversized-stack-windows') or ''
        # sizeWrites is global and moves for unrelated windows; count this window's applied writes.
        writes = applied_writes(windows.number('huge'))
        ok, text = defi('join-window', 'left')
        windows.settle()
        check('oversized single window diagnosed, not split or retried',
              str(windows.number('huge')) in oversized.split(',') and not ok and 'cannot join' in text
              and writes == 0,
              f'oversized-stack-windows={oversized} appliedWrites={writes} join="{text}"')
        defi('set-reserved-area', 'bottom', str(args.restore_bottom))
    finally:
        defi('set-reserved-area', 'bottom', str(args.restore_bottom))
        for name in list(windows.fixtures):
            windows.fixtures.pop(name)[0].close()
        time.sleep(1)
        session.command('workspace', initial_workspace)
        (out / 'after.status').write_text(session.command('status'))
        (out / 'workspaces-after.json').write_text(session.command('list-workspaces', '--json'))
        (out / 'trace.log').write_text(session.command('trace'))
    if daemon.read_bytes() != daemon_digest:
        check('installed daemon unchanged during the run', False, 'another install replaced the bundle')
    daemons = session.daemon_count()
    print(f'daemons={daemons} evidence: {out}')
    return 0 if results and all(ok for _, ok in results) and daemons == 1 else 1


if __name__ == '__main__':
    sys.exit(main())
