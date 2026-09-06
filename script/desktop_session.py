#!/usr/bin/env python3
"""Checkpoint and restore Defi's existing session stores under the desktop lock."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from desktop_lock import inherited_lock

CLI = Path.home() / 'Applications/Defi.app/Contents/MacOS/defi'
STATE = Path.home() / 'Library/Application Support/Defi'
STORES = ('workspace-topology.json', 'placements.json')


def command(*args):
    return subprocess.check_output([str(CLI), *args], text=True, timeout=15).strip()


def daemon_count():
    result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', 'defi-daemon'],
                            capture_output=True, text=True, check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not inspect daemon processes')
    return len(result.stdout.splitlines())


def stop():
    command('service', 'stop')
    for _ in range(100):
        if daemon_count() == 0:
            return
        time.sleep(0.1)
    raise RuntimeError('Daemon still running; refusing to replace session stores')


def start():
    command('service', 'start')
    for _ in range(100):
        try:
            status = command('status')
            if (daemon_count() == 1 and 'monitors=0[' not in status
                    and re.search(r'\bsnapshots=([1-9][0-9]*)/', status)):
                return
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.1)
    raise RuntimeError('Expected one IPC-ready daemon with discovered monitors')


def checkpoint(directory):
    directory.mkdir(parents=True)
    if daemon_count() != 1:
        raise RuntimeError('Session checkpoint requires exactly one running daemon')
    (directory / 'status.txt').write_text(command('status'))
    (directory / 'workspaces.json').write_text(command('list-workspaces', '--json'))
    try:
        stop()  # Shutdown flushes both stores before unparking windows.
        for name in STORES:
            (directory / name).write_bytes((STATE / name).read_bytes())
        (directory / 'ready').touch()
    except BaseException:
        start()
        raise


def close_enough(actual, expected):
    if isinstance(actual, (float, int)) and isinstance(expected, (float, int)):
        return abs(actual - expected) < 0.000001
    if isinstance(actual, dict) and isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(close_enough(actual[k], expected[k]) for k in actual)
    if isinstance(actual, list) and isinstance(expected, list):
        return len(actual) == len(expected) and all(close_enough(a, b) for a, b in zip(actual, expected))
    return actual == expected


def restore(directory):
    if not (directory / 'ready').exists():
        raise RuntimeError('No complete session checkpoint available')
    expected = json.loads((directory / STORES[0]).read_text())
    current = json.loads((STATE / STORES[0]).read_text())
    if current['sessionID'] != expected['sessionID']:
        raise RuntimeError('Login session changed; refusing stale session restoration')
    try:
        stop()
        for name in STORES:
            temporary = STATE / (name + '.verification.tmp')
            temporary.write_bytes((directory / name).read_bytes())
            temporary.replace(STATE / name)
    finally:
        start()
    workspaces = json.loads((directory / 'workspaces.json').read_text())
    # Restore other monitors first, then the initially focused monitor.
    for monitor in sorted(workspaces['monitors'], key=lambda m: m['focused']):
        current_workspaces = json.loads(command('list-workspaces', '--json'))
        current_monitor = next((m for m in current_workspaces['monitors'] if m['id'] == monitor['id']), None)
        if current_monitor is None:
            raise RuntimeError('Monitor topology changed during verification')
        if current_monitor['activeWorkspace'] != monitor['activeWorkspace'] or (
                monitor['focused'] and not current_monitor['focused']):
            command('--monitor', str(current_monitor['display']), 'workspace', monitor['activeWorkspace'])
    initial_focus = re.search(r'\bfocused=(\S+)', (directory / 'status.txt').read_text()).group(1)
    # ponytail: validate persisted logical state and managed-frame convergence;
    # native focus and visual quality still require the Computer Use reservation.
    for _ in range(40):
        time.sleep(0.25)
        current = json.loads((STATE / STORES[0]).read_text())
        status = command('status')
        (directory / 'restored-status.txt').write_text(status)
        (directory / 'restored-topology.json').write_text(json.dumps(current, indent=2))
        if (close_enough(current['topology']['monitors'], expected['topology']['monitors'])
                and re.search(r'\bfocused=(\S+)', status).group(1) == initial_focus
                and 'drift=0[' in status and 'focusPending=false' in status
                and 'axPending=false' in status and daemon_count() == 1):
            print('Restored all monitor workspaces, logical focus, widths, scroll, and managed-frame convergence')
            return
    raise RuntimeError('Session restoration incomplete; inspect checkpoint/restored-topology.json and restored-status.txt')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['checkpoint', 'restore'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if inherited_lock() is None:
        parser.error('A desktop reservation is required')
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        (checkpoint if args.mode == 'checkpoint' else restore)(args.directory)
    except KeyboardInterrupt:
        parser.exit(130, 'Session operation interrupted\n')
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
