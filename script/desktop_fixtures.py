"""Fixture windows and daemon helpers for desktop probes run under script/desktop_lock.sh."""
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = Path.home() / 'Applications/Defi.app/Contents/MacOS/defi'
IDLE_S = 10


def locked():
    return subprocess.run([str(ROOT / 'script/desktop_lock.sh'), '--check']).returncode == 0


def session(mode, directory=None):
    """checkpoint, restore or start through script/desktop_session.sh."""
    subprocess.run([str(ROOT / 'script/desktop_session.sh'), mode, *([str(directory)] if directory else [])],
                   check=True)


def command(*args):
    return subprocess.check_output([str(CLI), *args], text=True, timeout=15).strip()


def daemon_count():
    return int(subprocess.check_output([str(ROOT / 'script/desktop_session.sh'), 'daemons'], text=True))


def run(command, log=None, env=None, timeout=600):
    stream = log.open('w') if log else None
    try:
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env, text=True,
                                stdout=stream or subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    finally:
        if stream:
            stream.close()
    raw = log.read_text() if log else result.stdout
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}; log={log}\n{raw[-2000:]}')
    return raw.strip()


class Fixture:
    def __init__(self, binary, log):
        contents = log.with_suffix('.app') / 'Contents'
        executable = contents / 'MacOS' / 'PerformanceFixture'
        executable.parent.mkdir(parents=True, exist_ok=False)
        shutil.copy2(binary, executable)
        self.application_id = 'com.qeude.defi.performancefixture.' + \
                              hashlib.sha256(str(log.resolve()).encode()).hexdigest()[:12]
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': self.application_id,
            'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'PerformanceFixture',
            'NSPrincipalClass': 'NSApplication'}))
        self.log = log.open('w')
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0

    def ask(self, command='report', **fields):
        self.sequence += 1
        self.process.stdin.write(json.dumps({'seq': self.sequence, 'command': command, **fields}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not self.selector.select(max(0, deadline - time.monotonic())):
                break
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('Fixture exited before completing operation')
            self.log.write(line)
            self.log.flush()
            report = json.loads(line)
            if report['errors'] or report.get('error'):
                raise RuntimeError('Fixture error: ' + line)
            if report.get('seq') == self.sequence:
                return report
        raise RuntimeError('Fixture response timed out')

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.log.close()


def idle_seconds():
    output = subprocess.check_output(['ioreg', '-c', 'IOHIDSystem', '-d', '4'], text=True)
    return int(re.search(r'"HIDIdleTime" = (\d+)', output).group(1)) / 1e9


def wait_for_idle(seconds=IDLE_S):
    announced = False
    while idle_seconds() < seconds:
        if not announced:
            print(f'waiting for {seconds:.0f}s without keyboard or mouse input', flush=True)
            announced = True
        time.sleep(1)


def activate(pid):
    # Cooperative activation lets the frontmost app refuse an app's own activation request.
    run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'])


def alert_count():
    result = subprocess.run(['osascript', '-e', 'tell application "System Events" to count windows of '
                             '(processes whose name is "UserNotificationCenter")'],
                            capture_output=True, text=True, timeout=10)
    return sum(map(int, re.findall(r'\d+', result.stdout))) if result.returncode == 0 else 0


def wait_for_quiet_alerts(quiet=5):
    # A daemon start can raise a system permission alert that steals focus when it appears;
    # alerts already on screen are left for the user.
    since, count = time.monotonic(), alert_count()
    while time.monotonic() - since < quiet:
        time.sleep(.5)
        if (current := alert_count()) > count:
            since = time.monotonic()
        count = current


def settled(status):
    return all(token in status for token in
               ('axPending=false', 'focusPending=false', 'animating=false', 'drift=0[', 'settling=0 '))


def frame_write_delta(before, after):
    counts = {}
    for metric, field in (('daemon_completed_position_writes', 'posWrites'),
                          ('daemon_completed_size_writes', 'sizeWrites')):
        values = [re.search(r'\b' + field + r'=(\d+)(?=\s|$)', status) for status in (before, after)]
        if any(value is None for value in values):
            raise RuntimeError('Missing frame write counter: ' + field)
        change = int(values[1].group(1)) - int(values[0].group(1))
        if change < 0:
            raise RuntimeError('Frame write counter reset during workload')
        counts[metric] = change
    return counts


def owned_observation(fixtures, expected, workspace, status, state, reports, discovered,
                      require_focus=True, selected=None):
    windows = [(i, w) for i, report in enumerate(reports) for w in report['windows']]
    actual = [(i, w['id'], w['windowNumber']) for i, w in windows]
    owned_ids = {row[2] for row in expected}
    apps = {fixtures[i].application_id for i, _, _ in expected}
    active = next((w for w in state['workspaces'] if w['active']), None)
    if not expected or actual != sorted(expected) or len(owned_ids) != len(expected) \
            or not owned_ids.issubset(discovered) or active is None \
            or active['id'] != workspace or active['windowCount'] != len(expected) \
            or set(active['applications']) != apps \
            or any(apps.intersection(w['applications']) for w in state['workspaces'] if not w['active']):
        raise RuntimeError('Missed owned discovery, foreign window or workspace change')
    if sum(r['completed'] for r in reports) != len(expected) or any(r['pending'] for r in reports):
        raise RuntimeError('Incomplete fixture operations')
    match = re.search(r'\bfocused=(\d+)', status)
    focused = int(match.group(1)) if match else None
    target = next(((i, w) for i, w in windows if w['windowNumber'] == focused), None)
    if target is None or (selected is not None and focused != selected):
        raise RuntimeError('Wrong logical focus')
    i, window = target
    if require_focus and (not window['key'] or not reports[i]['active']
                          or reports[i]['frontmostPID'] != fixtures[i].process.pid):
        raise RuntimeError('Wrong native focus; command focus is only writer completion')
    if not settled(status):
        raise RuntimeError('Unsettled native frames')
    if any(not all(math.isfinite(v) for v in w['frame']) or min(w['frame'][2:]) <= 0 for _, w in windows):
        raise RuntimeError('Invalid native frame')
    return {'focus': [i, window['id']],
            'windows': [[i, w['id'], w['frame']] for i, w in windows]}, reports


def wait_owned(fixtures, expected, workspace, discovered, require_focus=True, selected=None, timeout=15):
    deadline, stable_since, previous = time.monotonic() + timeout, None, None
    error = 'No observation'
    while time.monotonic() < deadline:
        status = command('status')
        # The workload lives on its workspace's monitor; other displays only stay as they are.
        monitors = [m for m in json.loads(command('list-workspaces', '--json'))['monitors']
                    if any(w['id'] == workspace for w in m['workspaces'])]
        if len(monitors) != 1:
            raise RuntimeError('Frozen native workload requires its workspace on one monitor')
        trace = command('trace')
        for group in re.findall(r'window-snapshot .*?discovered=\d+\[([\d,]*)\]', trace):
            discovered.update(int(value) for value in group.split(',') if value)
        reports = [fixture.ask() for fixture in fixtures]
        try:
            observation = owned_observation(fixtures, expected, workspace, status, monitors[0], reports,
                                            discovered, require_focus, selected)
        except RuntimeError as failure:
            error, stable_since, previous = str(failure), None, None
        else:
            now = time.monotonic()
            if observation[0] != previous:
                stable_since, previous = now, observation[0]
            if now - stable_since >= .30:
                return observation
        time.sleep(.05)
    raise RuntimeError(f'Owned readiness/native focus did not converge within {timeout}s: {error}')

