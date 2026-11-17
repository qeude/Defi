#!/usr/bin/env python3
"""Glitch bench: counts visible glitches, focus errors and incoherent states per scenario.
Runs inside the defi-e2e guest's GUI session (script/glitch_vm.sh copies and starts it), never on a user's Mac.
Usage: glitch_bench.py APP OUT [--scenarios a,b] [--rounds N] [--seed S]
APP is a Defi.app whose defi-daemon path holds Accessibility and Screen Recording grants; OUT gets
events.jsonl, camera.jsonl, checks.jsonl and summary.json. Analysis needs only those files:
glitch_bench.py --analyze OUT re-scores a finished run."""
import argparse, collections, json, os, random, re, signal, subprocess, sys, time
from pathlib import Path

HUES = [i / 10 for i in range(10)]
SETTLE_S = 6
HOME = Path.home()


def now():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)  # mach_absolute_time: the camera's and fixtures' clock


class Fixture:
    def __init__(self, binary, directory, name):
        contents = directory / f'{name}.app' / 'Contents'
        (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
        executable = contents / 'MacOS' / 'PerformanceFixture'
        if executable.exists():
            executable.unlink()
        executable.write_bytes(Path(binary).read_bytes())
        executable.chmod(0o755)
        self.app_id = f'com.qeude.defi.glitchfixture.{name}'
        (contents / 'Info.plist').write_text(
            '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
            f'<key>CFBundleIdentifier</key><string>{self.app_id}</string>'
            '<key>CFBundlePackageType</key><string>APPL</string>'
            '<key>CFBundleExecutable</key><string>PerformanceFixture</string>'
            '<key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>')
        self.executable, self.name, self.seq = executable, name, 0
        self.log = (directory / f'{name}.log').open('a')
        self.start()

    def start(self):
        self.process = subprocess.Popen([str(self.executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1)
        self.seq = 0

    @property
    def pid(self):
        return self.process.pid

    def ask(self, command='report', **fields):
        self.seq += 1
        self.process.stdin.write(json.dumps({'seq': self.seq, 'command': command, **fields}) + '\n')
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError(f'fixture {self.name} exited')
            report = json.loads(line)
            if report.get('seq') == self.seq:
                return report

    def quit(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def parse_status(text):
    fields = {}
    for token in text.split():
        if '=' in token:
            key, value = token.split('=', 1)
            fields[key] = value
    return fields


def settled(status):
    return (status.get('axPending') == 'false' and status.get('focusPending') == 'false'
            and status.get('animating') == 'false' and status.get('drift', '').startswith('0[')
            and status.get('settling') == '0')


class Bench:
    def __init__(self, app, out, tools):
        self.cli = str(Path(app) / 'Contents/MacOS/defi')
        self.out, self.tools = out, tools
        self.events = (out / 'events.jsonl').open('a')
        self.checks = (out / 'checks.jsonl').open('a')
        self.fixtures, self.hue_of, self.scenario = {}, {}, ''
        self.next_hue = 0

    # -- daemon ------------------------------------------------------------------------------------
    def cli_run(self, *args, timeout=20):
        started = now()
        result = subprocess.run([self.cli, *args], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip(), now() - started, result.returncode

    def command(self, *args):
        output, latency, code = self.cli_run(*args)
        return latency

    def status(self):
        return parse_status(self.cli_run('status')[0])

    def layout(self):
        return json.loads(self.cli_run('list-workspaces', '--json')[0])

    def focused(self):
        value = self.status().get('focused', '')
        return int(value) if value.isdigit() else None

    def window_ids(self):
        return {w['id'] for m in self.layout()['monitors'] for ws in m['workspaces'] for w in ws['windows']}

    def daemons(self):
        return [int(p) for p in subprocess.run(['pgrep', '-x', 'defi-daemon'], capture_output=True, text=True).stdout.split()]

    def wait_settled(self, timeout=SETTLE_S):
        deadline = now() + timeout
        while now() < deadline:
            status = self.status()
            if settled(status):
                return status, True
            time.sleep(0.05)
        return self.status(), False

    # -- fixtures ----------------------------------------------------------------------------------
    def fixture(self, name):
        if name not in self.fixtures:
            self.fixtures[name] = Fixture(self.tools / 'PerformanceFixture', self.out / 'fixtures', name)
        return self.fixtures[name]

    def create(self, fixture, window_id, frame=None):
        # A colour no live window wears: a reused one reads as that window leaking.
        live = {self.hue_of[n] for n in self.window_ids() if n in self.hue_of}
        hue = next((h for h in HUES if f'w{HUES.index(h)}' not in live), HUES[self.next_hue % len(HUES)])
        self.next_hue += 1
        report = self.fixture(fixture).ask('create', id=window_id, hue=hue, **({'frame': frame} if frame else {}))
        number = next(w['windowNumber'] for w in report['windows'] if w['id'] == window_id)
        self.hue_of[number] = f'w{HUES.index(hue)}'
        self.log_event('create', window=number, label=self.hue_of[number], fixture=fixture)
        return number

    def key_window(self):
        """The window number holding the keyboard among fixture windows, and the frontmost pid."""
        key, front = None, None
        for fixture in self.fixtures.values():
            if fixture.process.poll() is not None:
                continue
            report = fixture.ask()
            front = report['frontmostPID']
            for window in report['windows']:
                if window['key'] and report['active']:
                    key = window['windowNumber']
        return key, front

    def key_events(self, since):
        events = []
        for fixture in self.fixtures.values():
            if fixture.process.poll() is not None:
                continue
            for event in fixture.ask()['events']:
                if event['kind'] == 'key' and event['key'] and event['at'] >= since:
                    events.append((event['at'], fixture.name, event['id']))
        return sorted(events)

    # -- logging -----------------------------------------------------------------------------------
    def log_event(self, action, **fields):
        record = {'t': now(), 'scenario': self.scenario, 'action': action, **fields}
        self.events.write(json.dumps(record) + '\n')
        self.events.flush()
        return record

    def check(self, kind, ok, **fields):
        record = {'t': now(), 'scenario': self.scenario, 'check': kind, 'ok': bool(ok), **fields}
        self.checks.write(json.dumps(record) + '\n')
        self.checks.flush()
        if not ok:
            print('DEFECT', json.dumps(record), flush=True)

    # -- expectations ------------------------------------------------------------------------------
    def monitor(self, layout=None):
        layout = layout or self.layout()
        return next(m for m in layout['monitors'] if m['focused'])

    def active(self, layout=None):
        monitor = self.monitor(layout)
        return next(w for w in monitor['workspaces'] if w['active'])

    def columns(self, workspace):
        columns = collections.OrderedDict()
        for window in workspace['windows']:
            if 'column' in window:
                columns.setdefault(window['column'], []).append(window['id'])
        return [columns[c] for c in sorted(columns)]

    def act(self, action, args, expect_focus=None, direction=None, settle=True, pause=0.0, **fields):
        """Runs one command, then judges the state it leaves."""
        before = self.daemons()
        start = now()
        latency = self.command(*args)
        record = self.log_event(action, args=list(args), latency=round(latency, 4), direction=direction,
                                expect=expect_focus, **fields)
        if latency > 0.5:
            self.check('slow_command', False, action=action, latency=round(latency, 3))
        if settle:
            time.sleep(0.25)  # status reads settled until the daemon starts on the command
            self.judge(action, start, expect_focus, before)
        if pause:
            time.sleep(pause)
        return record

    def judge(self, action, start, expect_focus, before_pids, writes_quiet=True, until=None):
        if until is not None:
            # An event-driven action: wait for the daemon to see it before judging the state it leaves.
            deadline = now() + 4
            while now() < deadline and not until():
                time.sleep(0.05)
            self.check('event_seen', until(), action=action)
        status, ok = self.wait_settled()
        self.check('unsettled', ok, action=action, status={k: status.get(k) for k in
                                                           ('axPending', 'focusPending', 'animating', 'drift', 'settling')})
        if ok and writes_quiet:
            writes = (int(status.get('posWrites', 0)), int(status.get('sizeWrites', 0)))
            time.sleep(1.0)
            later = self.status()
            delta = (int(later.get('posWrites', 0)) - writes[0], int(later.get('sizeWrites', 0)) - writes[1])
            self.check('endless_writes', delta == (0, 0), action=action, delta=delta)
            status = later
        focused = int(status['focused']) if status.get('focused', '').isdigit() else None
        if expect_focus is not None:
            self.check('logical_focus', focused == expect_focus, action=action, focused=focused, expected=expect_focus)
            # Native focus: the expected fixture window holds the keyboard, unless it is in fullscreen elsewhere.
            key, front = self.key_window()
            # A fullscreen window's slot hands the keyboard to Defi's placeholder.
            placeholder = expect_focus in self.fullscreen_windows(self.layout()) and front in self.daemons()
            self.check('native_focus', key == expect_focus or placeholder, action=action, key=key,
                       expected=expect_focus, front=front)
        # Coherence: Defi's focused window is the one taking the keyboard, whatever was asked.
        key, front = self.key_window()
        fixture_pids = {f.pid for f in self.fixtures.values() if f.process.poll() is None}
        if front in fixture_pids and key is not None and focused is not None:
            self.check('focus_coherence', key == focused, action=action, key=key, focused=focused)
        flips = self.key_events(start)
        gained = [window for _, _, window in flips]
        # Oscillation: one window gains the keyboard, loses it and gains it again within one action.
        oscillating = any(gained[i] == gained[j] and gained[i] != gained[i + 1]
                          for i in range(len(gained)) for j in range(i + 2, len(gained)))
        if action != 'workspace-burst':  # its targets alternate on purpose
            self.check('focus_oscillation', not oscillating, action=action, gained=gained,
                       at=[round(t, 3) for t, _, _ in flips])
            if oscillating:
                (self.out / f'oscillation-{round(start, 1)}-trace.txt').write_text(self.cli_run('trace')[0])
        pids = self.daemons()
        self.check('daemon_count', len(pids) == 1, action=action, pids=pids)
        if before_pids is not None and action != 'restart':
            self.check('crash', pids == before_pids, action=action, before=before_pids, after=pids)
        layout = self.layout()
        self.log_event('settled', of=action, settled=ok, focused=focused,
                       visible=self.expected_hidden(layout), fullscreen=self.fullscreen_windows(layout))
        return layout

    def expected_hidden(self, layout):
        """Labels that must not show: windows of every inactive workspace."""
        hidden = []
        for monitor in layout['monitors']:
            for workspace in monitor['workspaces']:
                if not workspace['active']:
                    hidden += [self.hue_of[w['id']] for w in workspace['windows'] if w['id'] in self.hue_of]
        return {'hidden': hidden}

    def fullscreen_windows(self, layout):
        return [w['id'] for m in layout['monitors'] for ws in m['workspaces'] if ws['active']
                for w in ws['windows'] if w.get('nativeFullscreen')]

    def neighbour(self, direction):
        workspace = self.active()
        columns = self.columns(workspace)
        selected = workspace.get('selectedWindowID')
        index = next((i for i, c in enumerate(columns) if selected in c), 0)
        index = max(0, min(len(columns) - 1, index + (1 if direction == 'right' else -1)))
        return columns[index][0] if columns else None


# -- scenarios ---------------------------------------------------------------------------------------
def dismiss_alerts(bench):
    """macOS's consent alert for private window capture covers the windows; it is the system's, not Defi's."""
    result = subprocess.run(['osascript', '-e', 'tell application "System Events" to tell process "UserNotificationCenter"\n'
                             'set n to count windows\nrepeat with w in windows\ntry\nclick button "Allow" of w\nend try\n'
                             'end repeat\nreturn n\nend tell'], capture_output=True, text=True)
    if result.stdout.strip() not in ('', '0'):
        bench.log_event('alert-dismissed', count=result.stdout.strip())
        time.sleep(1)


def activate(pid):
    subprocess.run(['osascript', '-e', 'tell application "System Events" to set frontmost of '
                    f'(first process whose unix id is {pid}) to true'], capture_output=True)


def switch(bench, workspace, action='workspace'):
    """Switches workspace and checks that the switch took: a lost switch is a defect."""
    bench.command('workspace', workspace)
    deadline = now() + 3
    while now() < deadline and bench.active()['id'] != workspace:
        time.sleep(0.05)
    ok = bench.active()['id'] == workspace
    bench.check('lost_command', ok, action=action, target=workspace, active=bench.active()['id'])
    if not ok:
        bench.command('workspace', workspace)
        time.sleep(1)


def populate(bench, fixture, names, workspace):
    numbers = []
    for name in names:
        numbers.append(bench.create(fixture, name))
        time.sleep(0.5)
    bench.wait_settled(15)
    time.sleep(0.5)
    where = {w['id']: ws['id'] for m in bench.layout()['monitors'] for ws in m['workspaces'] for w in ws['windows']}
    for number in numbers:
        bench.check('wrong_workspace', where.get(number) == workspace, action='open', window=number,
                    expected=workspace, actual=where.get(number))
        if where.get(number) != workspace:
            bench.command('focus-window-id', str(number))
            time.sleep(0.5)
            bench.command('move-window-to-workspace', workspace)
            time.sleep(1)
    return numbers


def setup(bench):
    for _ in range(10):  # the alert comes a moment after the daemon's first capture
        dismiss_alerts(bench)
        time.sleep(0.5)
    monitor = bench.monitor()
    empty = next(w for w in monitor['workspaces'] if w['windowCount'] == 0)
    switch(bench, empty['id'], 'setup-switch')
    bench.home = empty['id']
    bench.main = populate(bench, 'a', [f'a{i}' for i in range(4)], bench.home)
    bench.main += populate(bench, 'b', ['b0', 'b1'], bench.home)
    # A second occupied workspace, for vertical motion and parking.
    below = next(w for w in bench.monitor()['workspaces'] if w['windowCount'] == 0)
    switch(bench, below['id'], 'setup-switch')
    bench.other_workspace = below['id']
    bench.other = populate(bench, 'c', ['c0', 'c1'], bench.other_workspace)
    switch(bench, bench.home, 'setup-switch')
    bench.command('focus-column', 'first')
    bench.wait_settled(15)
    bench.log_event('setup-done', layout=bench.layout())


def columns(bench, rng, rounds):
    for _ in range(rounds):
        for _ in range(10):
            direction = rng.choice(['left', 'right'])
            bench.act('column', ['focus-column', direction], bench.neighbour(direction), direction,
                      pause=rng.uniform(0.1, 0.5))
        for direction in ['right', 'left', 'right', 'left']:
            # A burst: five presses 60 ms apart, judged once at the end.
            start, pids = now(), bench.daemons()
            bench.log_event('column-burst', direction=direction)
            target = None
            for _ in range(5):
                target = bench.neighbour(direction) if target is None else target
                bench.command('focus-column', direction)
                bench.log_event('column-burst-step', direction=direction)
                time.sleep(0.06)
            workspace = bench.active()
            columns_ = bench.columns(workspace)
            bench.log_event('burst-end', direction=direction)
            time.sleep(0.25)
            expected = (columns_[-1] if direction == 'right' else columns_[0])[0]
            bench.judge('column-burst', start, expected, pids)


def workspaces(bench, rng, rounds):
    for _ in range(rounds):
        for target in [bench.other_workspace, bench.home] * 3:
            bench.act('workspace', ['workspace', target], None, 'vertical', pause=rng.uniform(0.1, 0.4))
            bench.check('lost_command', bench.active()['id'] == target, action='workspace', target=target)
        start, pids = now(), bench.daemons()
        bench.log_event('workspace-burst')
        for target in [bench.other_workspace, bench.home, bench.other_workspace, bench.home]:
            bench.command('workspace', target)
            bench.log_event('workspace-burst-step')
            time.sleep(0.08)
        time.sleep(0.25)
        bench.judge('workspace-burst', start, None, pids)
        bench.check('lost_command', bench.active()['id'] == bench.home, action='workspace-burst')


def windows(bench, rng, rounds):
    for r in range(rounds):
        added = []
        for i in range(2):
            start, pids = now(), bench.daemons()
            # A new window comes from the frontmost app, as with Command-N.
            focused = bench.focused()
            owner = next((n for n, f in bench.fixtures.items() if f.process.poll() is None
                          and focused in {w['windowNumber'] for w in f.ask()['windows']}), 'a')
            number = bench.create(owner, f'extra{r}-{i}-{int(time.time() * 1000)}')
            added.append(number)
            bench.log_event('open', window=number)
            bench.judge('open', start, number, pids, until=lambda: bench.focused() == number)
        for number in added:
            fixture = next(f for f in bench.fixtures.values() if f.process.poll() is None
                           and number in {w['windowNumber'] for w in f.ask()['windows']})
            window_id = next(w['id'] for w in fixture.ask()['windows'] if w['windowNumber'] == number)
            start, pids = now(), bench.daemons()
            bench.log_event('close', window=number)
            fixture.ask('close', id=window_id)
            bench.judge('close', start, None, pids, until=lambda: number not in bench.window_ids())
            (bench.out / f'close-{number}-trace.txt').write_text(bench.cli_run('trace')[0])


def activation(bench, rng, rounds):
    for _ in range(rounds):
        for name in ['b', 'a', 'b', 'a']:
            fixture = bench.fixture(name)
            start, pids = now(), bench.daemons()
            bench.log_event('activate', fixture=name)
            subprocess.run(['osascript', '-e', 'tell application "System Events" to set frontmost of '
                            f'(first process whose unix id is {fixture.pid}) to true'], capture_output=True)
            mine = {w['windowNumber'] for w in fixture.ask()['windows']}
            bench.judge('activate', start, None, pids, until=lambda: bench.focused() in mine)


def overview(bench, rng, rounds):
    for _ in range(rounds):
        start, pids = now(), bench.daemons()
        bench.act('overview-open', ['toggle-overview'], settle=False, pause=1.0)
        bench.act('overview-nav', ['focus-column', 'right'], settle=False, pause=0.5)
        # An app opening a window behind the Overview must not close it.
        name = f'o{len(bench.fixtures)}'
        bench.create(name, 'w')
        time.sleep(1.0)
        bench.check('overview_kept', bench.status().get('overview') == 'open', action='overview-open-app')
        bench.act('overview-nav', ['focus-column', 'right'], settle=False, pause=0.5)
        if bench.status().get('overview') == 'open':
            bench.act('overview-close', ['toggle-overview'], settle=False)
        bench.fixtures.pop(name).quit()
        bench.judge('overview', start, None, pids)


def fullscreen(bench, rng, rounds):
    """Native fullscreen: its placeholder must exist once, in the window's slot, and never outlive it."""
    for r in range(rounds):
        name = f'f{r}'
        start, pids = now(), bench.daemons()
        window = bench.create('f', name)
        fixture = bench.fixture('f')
        activate(fixture.pid)  # a launched app comes forward, as from the Dock
        bench.judge('fs-open', start, window, pids, until=lambda: bench.focused() == window)
        start = now()
        bench.log_event('fs-enter', window=window)
        fixture.ask('fullscreen', id=name)
        time.sleep(2.5)
        bench.judge('fs-enter', start, window, pids)
        # Leave the Space by navigating; cross the placeholder back and forth.
        for direction in ['left', 'left', 'right', 'right', 'left']:
            bench.act('fs-column', ['focus-column', direction], bench.neighbour(direction), direction, pause=0.3)
        # Select the placeholder and press Return in it: the fullscreen Space shows.
        bench.act('fs-select', ['focus-window-id', str(window)], None, pause=0.5)
        start = now()
        bench.log_event('fs-return', window=window)
        subprocess.run([str(bench.tools / 'GlitchCamera'), 'key', str(bench.daemons()[0]), '36'])
        time.sleep(2.5)
        bench.judge('fs-return', start, window, pids)
        # Workspaces and the Overview while it is fullscreen.
        bench.act('fs-workspace', ['workspace', bench.other_workspace], None, 'vertical', pause=0.3)
        bench.act('fs-workspace', ['workspace', bench.home], None, 'vertical', pause=0.3)
        bench.act('fs-overview-open', ['toggle-overview'], settle=False, pause=1.0)
        bench.act('fs-overview-close', ['toggle-overview'], pause=0.3)
        # Command-Tab's path: the app activates itself.
        start = now()
        bench.log_event('fs-activate', window=window)
        subprocess.run(['osascript', '-e', 'tell application "System Events" to set frontmost of '
                        f'(first process whose unix id is {fixture.pid}) to true'], capture_output=True)
        time.sleep(2.0)
        bench.judge('fs-activate', start, None, pids)
        if r % 3 == 0:
            # Exit fullscreen: the window returns to its slot.
            start = now()
            bench.log_event('fs-exit', window=window)
            fixture.ask('fullscreen', id=name)
            time.sleep(2.5)
            bench.judge('fs-exit', start, window, pids)
            bench.log_event('close', window=window)
            fixture.ask('close', id=name)
            bench.judge('fs-close-after-exit', now(), None, pids, until=lambda: window not in bench.window_ids())
        elif r % 3 == 1:
            # Close it while fullscreen.
            start = now()
            bench.log_event('fs-close', window=window)
            fixture.ask('close', id=name)
            time.sleep(2.5)
            bench.judge('fs-close', start, None, pids, until=lambda: window not in bench.window_ids())
        else:
            # Restart the daemon while fullscreen, then quit the app.
            start = now()
            bench.log_event('restart', window=window)
            bench.cli_run('service', 'restart', timeout=60)
            time.sleep(3)
            bench.judge('restart', start, None, None)
            start, pids = now(), bench.daemons()
            bench.log_event('fs-quit', window=window)
            fixture.quit()
            del bench.fixtures['f']
            time.sleep(2.5)
            bench.judge('fs-quit', start, None, pids, until=lambda: window not in bench.window_ids())
        bench.command('workspace', bench.home)


def restart(bench, rng, rounds):
    topology = HOME / 'Library/Application Support/Defi/workspace-topology.json'
    for attempt in range(rounds * 3):
        saved = topology.read_text() if topology.exists() else ''
        layout = bench.layout()
        before = [(m['id'], m['activeWorkspace'], [(w['id'], bench.columns(w), w.get('selectedWindowID'))
                                                    for w in m['workspaces'] if w['windowCount']]) for m in layout['monitors']]
        start = now()
        bench.log_event('restart')
        bench.cli_run('service', 'restart', timeout=60)
        time.sleep(3)
        layout = bench.judge('restart', start, None, None)
        after = [(m['id'], m['activeWorkspace'], [(w['id'], bench.columns(w), w.get('selectedWindowID'))
                                                   for w in m['workspaces'] if w['windowCount']]) for m in layout['monitors']]
        bench.check('restart_state', before == after, before=before, after=after)
        if before != after:
            (bench.out / f'restart-{attempt}-topology.json').write_text(saved)
            (bench.out / f'restart-{attempt}-trace.txt').write_text(bench.cli_run('trace')[0])


def slow(bench, rng, rounds):
    bench.fixture('a').ask('set-busy', delay=0.12, period=0.3)
    try:
        columns(bench, rng, rounds)
    finally:
        bench.fixture('a').ask('set-busy', delay=0, period=1)


def displays(bench, rng, rounds):
    """A fullscreen window on the second display, while the first one navigates and switches."""
    layout = bench.layout()
    if len(layout['monitors']) < 2:
        bench.log_event('lane-not-run', reason='one display')
        return
    second = next(m for m in layout['monitors'] if not m['focused'])
    # The second display's CG frame from the camera's display records is not known here; the
    # VM's virtual display sits at (-1280, 768) per Tests/Fixtures/VirtualDisplayFixture.m.
    origin = [-1280 + 100, 768 + 100, 600, 400]
    for r in range(rounds):
        name = f'd{r}'
        start, pids = now(), bench.daemons()
        window = bench.create('d', name, frame=origin)
        fixture = bench.fixture('d')
        activate(fixture.pid)
        bench.judge('d-open', start, window, pids, until=lambda: bench.focused() == window)
        where = {w['id']: m['id'] for m in bench.layout()['monitors'] for ws in m['workspaces'] for w in ws['windows']}
        bench.check('wrong_display', where.get(window) == second['id'], window=window, display=where.get(window))
        start = now()
        bench.log_event('d-enter', window=window)
        fixture.ask('fullscreen', id=name)
        time.sleep(2.5)
        bench.judge('d-enter', start, window, pids)
        # The first display moves on while the second shows the fullscreen Space.
        bench.act('d-home', ['focus-window-id', str(bench.main[0])], bench.main[0], pause=0.5)
        for direction in ['right', 'left']:
            bench.act('d-column', ['focus-column', direction], bench.neighbour(direction), direction, pause=0.3)
        bench.act('d-workspace', ['workspace', bench.other_workspace], None, 'vertical', pause=0.3)
        bench.act('d-workspace', ['workspace', bench.home], None, 'vertical', pause=0.3)
        bench.act('d-overview-open', ['toggle-overview'], settle=False, pause=1.0)
        bench.act('d-overview-close', ['toggle-overview'], pause=0.3)
        # Back onto the fullscreen window by id, then out of fullscreen and closed.
        start = now()
        bench.log_event('d-select', window=window)
        bench.command('focus-window-id', str(window))
        time.sleep(2.0)
        bench.judge('d-select', start, None, pids)
        if r % 2 == 0:
            start = now()
            bench.log_event('d-exit', window=window)
            fixture.ask('fullscreen', id=name)
            time.sleep(2.5)
            bench.judge('d-exit', start, window, pids)
            fixture.ask('close', id=name)
            bench.judge('d-close', now(), None, pids, until=lambda: window not in bench.window_ids())
        else:
            start = now()
            bench.log_event('restart', window=window)
            bench.cli_run('service', 'restart', timeout=60)
            time.sleep(3)
            bench.judge('restart', start, None, None)
            start, pids = now(), bench.daemons()
            bench.log_event('d-quit', window=window)
            fixture.quit()
            del bench.fixtures['d']
            time.sleep(2.5)
            bench.judge('d-quit', start, None, pids, until=lambda: window not in bench.window_ids())
        bench.command('focus-window-id', str(bench.main[0]))
        time.sleep(1)


def settings(bench, rng, rounds):
    """Focus moving to and from System Settings, where Defi lifts its display staircase."""
    subprocess.run(['open', '-a', 'System Settings'])
    time.sleep(3)
    bench.wait_settled()
    for _ in range(rounds):
        for direction in ['right', 'left'] * 3:
            start = now()
            bench.act('settings-nav', ['focus-column', direction], direction=direction, pause=rng.uniform(0.4, 0.9))
            resets = [line for line in bench.cli_run('trace')[0].splitlines()
                      if 'reason=display-change' in line and float(line.split()[0]) >= start]
            arrangement = bench.status().get('displayArrangement')
            # Lifting a native desk changes nothing; a reset there cuts the motion for nothing.
            bench.check('display_reset', not resets or arrangement != 'native', action='settings-nav',
                        resets=len(resets), arrangement=arrangement)
    bench.log_event('settings-quit')
    subprocess.run(['osascript', '-e', 'quit app "System Settings"'], capture_output=True)
    time.sleep(1.5)


SCENARIOS = {'columns': columns, 'workspaces': workspaces, 'windows': windows, 'activation': activation,
             'overview': overview, 'fullscreen': fullscreen, 'restart': restart, 'slow': slow,
             'displays': displays, 'settings': settings}


# -- analysis ----------------------------------------------------------------------------------------
def load(path):
    return [json.loads(line) for line in path.open() if line.strip()] if path.exists() else []


def window_of(events, label, before):
    """The window that wore this colour at that time: colours are reused once a window closes."""
    return next((e['window'] for e in reversed(events)
                 if e['action'] == 'create' and e.get('label') == label and e['t'] <= before), None)


def onscreen(row, displays):
    """Widest overlap, in points, of a WindowServer frame [number,pid,layer,alpha,x,y,w,h] with a display."""
    x, y, w, h = row[4:8]
    return max((min(x + w, dx + dw) - max(x, dx) if min(y + h, dy + dh) > max(y, dy) else 0
                for dx, dy, dw, dh in displays.values()), default=0)


def analyze(out):
    events, checks, camera = load(out / 'events.jsonl'), load(out / 'checks.jsonl'), load(out / 'camera.jsonl')
    displays = {c['display']: c['frame'] for c in camera if 'frame' in c}
    frames, last = [], {}
    for c in camera:
        if 'rows' in c:
            last[c['d']] = c['rows']
            frames.append(c)
        elif 'same' in c and c['d'] in last:
            frames.append({'t': c['t'], 'd': c['d'], 'rows': last[c['d']]})
    counts = collections.defaultdict(collections.Counter)
    examples = collections.defaultdict(list)

    def defect(scenario, kind, **detail):
        counts[scenario][kind] += 1
        if len(examples[kind]) < 40:
            examples[kind].append({'scenario': scenario, **detail})

    for check in checks:
        counts[check['scenario']]['checks'] += 1
        if not check['ok']:
            defect(check['scenario'], check['check'], **{k: v for k, v in check.items() if k not in ('ok', 'scenario')})

    # Setup opens fixtures at arbitrary frames: only scenarios are scored.
    actions = [e for e in events if e['scenario'] != 'setup'
               and e['action'] not in ('mode', 'create', 'settled', 'column-burst-step', 'workspace-burst-step', 'burst-end')]
    settled_at = {}
    for e in events:
        if e['action'] == 'settled':
            settled_at.setdefault(e['of'], []).append(e)
    starts = [e['t'] for e in actions] + [float('inf')]
    instant = any(e['action'] == 'mode' and e.get('instant') for e in events)
    blind = 0
    for index, action in enumerate(actions):
        t0, t1 = action['t'], starts[index + 1]
        span = [f for f in frames if t0 - 0.05 <= f['t'] < t1]
        if not span:
            # Every action moves or repaints something; no frame means the camera was down.
            blind += 1
            continue
        by_display = collections.defaultdict(list)
        for f in span:
            by_display[f['d']].append(f)
        settled = next((e for e in events if e['action'] == 'settled' and t0 <= e['t'] < t1), None)
        before = next((e for e in reversed(events) if e['action'] == 'settled' and e['t'] < t0), None)
        # A window hidden on both sides of the action does not move on screen: its colour there is another app's.
        still_hidden = (set(settled['visible']['hidden']) & set(before['visible']['hidden'])
                        if settled and before else set())
        for display, seq in by_display.items():
            width = displays.get(display, [0, 0, 1024, 768])[2]
            seq = [{**f, 'rows': [[run for run in row if run[0] not in still_hidden] for row in f['rows']]} for f in seq]
            judge_motion(action, seq, width, defect, instant)
        # Parking leak: a hidden window shows once its action settled.
        if settled:
            hidden = set(settled['visible']['hidden'])
            after = [f for f in span if f['t'] >= settled['t']]
            # Under 30 pt is an app's coloured icon, not a window: a parked one leaves no visible sliver.
            leaked = {run[0] for f in after for row in f['rows'] for run in row
                      if run[0] in hidden and run[2] - run[1] >= 30}
            # Another app can show the same colour: WindowServer must also put the window on a display.
            samples = [c for c in camera if 'windows' in c and settled['t'] <= c['t'] < t1]
            leaked = {label for label in leaked
                      if any(onscreen(row, displays) > 2 for c in samples for row in c['windows']
                             if row[0] == window_of(events, label, t0))}
            if leaked:
                defect(action['scenario'], 'parking_leak', action=action['action'], labels=sorted(leaked), t=t0)
            placeholders(action, settled, [c for c in camera if 'windows' in c and settled['t'] <= c['t'] < t1],
                         after, defect)
    # Seams are 2 pt marks seen at half resolution for one frame: reported, not scored.
    for c in counts.values():
        c['defects'] = sum(v for k, v in c.items() if k not in ('checks', 'seam', 'defects'))
    ordered = sorted(first_steps)
    summary = {'scenarios': {s: dict(c) for s, c in counts.items()}, 'examples': examples, 'blind_actions': blind,
               'stall_ms': sorted(stalls)[len(stalls) // 2:][::max(1, len(stalls) // 10)] if stalls else [],
               'start_fraction': {'n': len(ordered), 'p50': ordered[len(ordered) // 2] if ordered else None,
                                  'p90': ordered[int(len(ordered) * 0.9)] if ordered else None},
               'camera_errors': [c for c in camera if 'error' in c][:5],
               'frames': sum(c.get('frames', 0) for c in camera)}
    (out / 'summary.json').write_text(json.dumps(summary, indent=1))
    return summary


first_steps, stalls = [], []


def judge_motion(action, frames, width, defect, instant=False):
    """Backtracks, jumps, blinks and two-step landings of each window's run on the middle row."""
    scenario, name, direction = action['scenario'], action['action'], action.get('direction')
    tracks = collections.defaultdict(list)
    seams, changes, previous_seen = set(), [], None
    for f in frames:
        seen, merged = {}, []
        for run in f['rows'][1]:
            # A gap under 8 pt inside one window is a seam drawn over it, not another window.
            if merged and merged[-1][0] == run[0] and run[1] - merged[-1][2] < 8:
                seams.add(run[0])
                merged[-1] = [run[0], merged[-1][1], run[2]]
            else:
                merged.append(list(run))
        for run in merged:
            label, x0, x1 = run
            # The widest run: another window or a border fragment can cover or mimic part of it.
            if x1 - x0 >= 30 and (label not in seen or x1 - x0 > seen[label][1] - seen[label][0]):
                seen[label] = (x0, x1)
        for label in set(tracks) | set(seen):
            tracks[label].append((f['t'], seen.get(label)))
        if previous_seen is not None and seen != previous_seen:
            changes.append(f['t'])
        previous_seen = seen
    # A freeze mid-motion: nothing on the row changes for longer than the camera's own gaps.
    if direction in ('left', 'right') and len(changes) > 2 and not instant:
        gap = max(b - a for a, b in zip(changes, changes[1:]))
        stalls.append(round(gap * 1000))
        if gap > 0.12:
            defect(scenario, 'stall', action=name, at=changes[0], ms=round(gap * 1000))
    for label in seams:
        defect(scenario, 'seam', action=name, label=label, t=action['t'])
    for label, track in tracks.items():
        present = [p is not None for _, p in track]
        # Blink: shown before and after, missing in between while nothing else hides it.
        if present[0] and present[-1] and not all(present) and name not in ('overview-open', 'overview-close', 'fs-overview-open', 'fs-overview-close', 'workspace', 'fs-workspace', 'workspace-burst', 'restart', 'fs-return', 'fs-enter', 'fs-exit', 'fs-activate'):
            gaps = [t for (t, p) in track if p is None]
            defect(scenario, 'blink', action=name, label=label, at=gaps[0], frames=len(gaps))
        positions = [(t, p) for t, p in track if p is not None]
        if direction in ('left', 'right') and len(positions) > 2 and not instant:
            # The first visible step of a motion: a spring frame covers about 8 % of the travel at
            # 60 Hz; a quarter or more means the clock ran while nothing was drawn.
            edge = 0 if positions[0][1][0] > 1 else 1
            travel = positions[-1][1][edge] - positions[0][1][edge]
            moving = [p for _, p in positions if p[edge] != positions[0][1][edge]]
            if abs(travel) > 100 and moving:
                fraction = (moving[0][edge] - positions[0][1][edge]) / travel
                first_steps.append(round(fraction, 3))
                if fraction > 0.25:
                    defect(scenario, 'start_jump', action=name, label=label, fraction=round(fraction, 2),
                           at=next(t for t, p in positions if p[edge] != positions[0][1][edge]))
        if direction in ('left', 'right'):
            sign = -1 if direction == 'right' else 1
            for (ta, a), (tb, b) in zip(positions, positions[1:]):
                for edge in (0, 1):
                    clipped = (a[edge] <= 1 or a[edge] >= width - 1 or b[edge] <= 1 or b[edge] >= width - 1)
                    moved = b[edge] - a[edge]
                    if not clipped and moved * sign < -3:
                        defect(scenario, 'backtrack', action=name, label=label, at=tb, dx=moved)
                        break
                    # Per display frame: the camera itself skips frames under load.
                    if not clipped and not instant and abs(moved) / max(1, round((tb - ta) * 60)) > width * 0.3:
                        defect(scenario, 'jump', action=name, label=label, at=tb, dx=moved)
                        break
        # Two-step: the window rests 60 ms or more short of where it lands, then moves on by itself.
        # macOS draws its own fullscreen zoom when a window enters a Space.
        if len(positions) > 2 and name not in ('overview-open', 'fs-overview-open', 'fs-enter'):
            final = positions[-1][1]
            moves = [i for i in range(1, len(positions)) if positions[i][1] != positions[i - 1][1]]
            for i in moves:
                # Frames that held this position while the screen changed elsewhere.
                held = [t for t, p in positions if p == positions[i - 1][1] and t <= positions[i - 1][0]]
                first = next(t for t, p in reversed(positions[:i]) if p != positions[i - 1][1]) if any(
                    p != positions[i - 1][1] for _, p in positions[:i]) else positions[0][0]
                rest = positions[i][0] - first
                previous = positions[i - 1][1]
                if rest >= 0.06 and len([t for t in held if t > first]) >= 3 and previous != final and i - 1 > 0 and abs(previous[0] - final[0]) > 4 \
                        and positions[i - 1][0] > action['t'] + 0.05:
                    shift = max(abs(previous[0] - final[0]), abs(previous[1] - final[1]))
                    defect(scenario, 'two_step' if shift > 12 else 'nudge', action=name, label=label,
                           at=positions[i][0], rest=round(rest, 3), resting=previous, final=final)
                    break


def placeholders(action, settled, window_samples, frames, defect):
    """Exactly one placeholder card per fullscreen window while the desktop shows; none without one."""
    fullscreen = settled.get('fullscreen', [])
    scenario, name = action['scenario'], action['action']
    if not frames and not window_samples:
        return
    shown = [len([run for run in f['rows'][0] if run[0] == 'ph' and run[2] - run[1] > 40]) for f in frames]
    desktop = [f for f in frames if not any(run[0] != 'ph' and run[2] - run[1] >= 1000 for run in f['rows'][1])]
    if not fullscreen and any(shown):
        defect(scenario, 'placeholder_orphan', action=name, t=settled['t'], cards=max(shown))
    if fullscreen and desktop:
        cards = [len([run for run in f['rows'][0] if run[0] == 'ph' and run[2] - run[1] > 40]) for f in desktop]
        if max(cards) > len(fullscreen):
            defect(scenario, 'placeholder_duplicate', action=name, t=settled['t'], cards=max(cards))
    panels = [len([w for w in s['windows'] if w[2] == 0 and w[7] > 200 and w[6] > 100 and w[3] > 0
                   and w[1] not in ()]) for s in window_samples]
    if panels:
        settled['panels'] = max(panels)


def run(args):
    out = Path(args.out).resolve()
    (out / 'fixtures').mkdir(parents=True, exist_ok=True)
    tools = Path(args.tools).resolve()
    camera_log = out / 'camera.jsonl'
    camera = subprocess.Popen([str(tools / 'GlitchCamera'), str(camera_log), ','.join(map(str, HUES))],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(out / 'camera.err').open('w'), text=True)
    if camera.stdout.readline().strip() != 'ready':
        raise SystemExit('camera failed: ' + (out / 'camera.err').read_text())
    bench = Bench(args.app, out, tools)
    bench.log_event('mode', instant=args.instant)
    rng = random.Random(args.seed)
    try:
        bench.scenario = 'setup'
        setup(bench)
        for name in args.scenarios.split(','):
            bench.scenario = name
            print('scenario', name, flush=True)
            dismiss_alerts(bench)
            try:
                SCENARIOS[name](bench, rng, args.rounds)
            except Exception as error:  # a broken scenario is a defect, not the end of the run
                bench.check('scenario_error', False, error=repr(error))
                bench.command('workspace', bench.home)
    finally:
        camera.stdin.close()
        camera.wait(timeout=10)
        for fixture in bench.fixtures.values():
            fixture.quit()
    summary = analyze(out)
    print(json.dumps(summary['scenarios'], indent=1))
    print('blind actions', summary['blind_actions'], 'start fraction', summary['start_fraction'],
          'camera errors', summary['camera_errors'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', nargs='?')
    parser.add_argument('out', nargs='?')
    parser.add_argument('--tools', default=str(HOME / 'defi-glitch/tools'))
    parser.add_argument('--scenarios', default=','.join(SCENARIOS))
    parser.add_argument('--rounds', type=int, default=1)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--analyze', action='store_true')
    # Without Screen Recording the overlay is off and windows move at once: no motion to judge.
    parser.add_argument('--instant', action='store_true')
    args = parser.parse_args()
    if args.analyze:
        print(json.dumps(analyze(Path(args.out or args.app))['scenarios'], indent=1))
    else:
        run(args)


if __name__ == '__main__':
    main()
