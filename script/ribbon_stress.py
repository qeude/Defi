#!/usr/bin/env python3
"""Measure shared ribbon dispatch gaps under rapid CLI navigation; restore the session."""
import argparse
import os
from pathlib import Path
import re
import signal
import sys
import time

import desktop_session as session
from desktop_lock import inherited_lock


def wait_for_settlement(timeout=10):
    deadline = time.monotonic() + timeout
    stable_since = None
    while time.monotonic() < deadline:
        status = session.command('status')
        settled = all(token in status for token in
                      ('axPending=false', 'focusPending=false', 'animating=false', 'drift=0['))
        if settled:
            stable_since = stable_since or time.monotonic()
        else:
            stable_since = None
        # Read-only daemon status is cached for 250 ms. Require distinct cache
        # generations before accepting a stable state.
        if stable_since is not None and time.monotonic() - stable_since >= 0.30:
            return status
        time.sleep(0.05)
    raise RuntimeError(f'Workspace did not settle within {timeout}s: {status}')


def motion_gaps(trace):
    submitted = re.findall(r' submit g=(\d+) source=command-animation .*?animated=([1-9]\d*)\[', trace)
    if not submitted:
        raise RuntimeError('No command animation submissions in the stress trace')
    cadences = re.findall(r' cadence g=(\d+) frames=\d+ submittedSteps=(\d+) '
                         r'appliedIntermediateWrites=(\d+) maxGapMs=([\d.]+)', trace)
    if submitted[-1][0] not in {item[0] for item in cadences}:
        raise RuntimeError('Final command animation cadence is missing; trace is incomplete')
    generations = {item[0] for item in submitted}
    return [float(gap) for generation, steps, writes, gap in cadences
            if generation in generations and int(steps) >= 2 and int(writes) > 0]


def artifact_directory():
    return Path(__file__).resolve().parents[1] / 'dist/benchmarks' / f'ribbon-stress-{time.time_ns()}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace')
    parser.add_argument('--steps', type=int, default=32)
    parser.add_argument('--interval', type=float, default=0.06)
    parser.add_argument('--max-gap-ms', type=float, default=25)
    args = parser.parse_args()
    if not 4 <= args.steps <= 128 or not 0 <= args.interval <= 1 or not 0 < args.max_gap_ms < 1000:
        parser.error('Use 4–128 steps, 0–1 seconds between commands, and a positive gap budget below 1000 ms')
    if inherited_lock() is None:
        os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name('desktop_lock.py')),
                                 '--wait', sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    output = artifact_directory()
    previous_sigterm_handler = signal.getsignal(signal.SIGTERM)

    def interrupt_on_sigterm(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt_on_sigterm)
    checkpointed = False
    try:
        session.checkpoint(output)
        checkpointed = True
        session.start()
        if args.workspace:
            session.command('workspace', args.workspace)
        wait_for_settlement()
        started_at = time.monotonic()
        for index in range(args.steps):
            session.command('focus-column', ('left', 'left', 'right', 'right')[index % 4])
            time.sleep(args.interval)
        status = wait_for_settlement()
        trace = '\n'.join(line for line in session.command('trace').splitlines()
                          if line.split() and line.split()[0].replace('.', '', 1).isdigit()
                          and float(line.split()[0]) >= started_at)
        (output / 'trace.txt').write_text(trace)
        (output / 'after-status.txt').write_text(status)
    finally:
        try:
            if checkpointed or (output / 'ready').exists():
                session.restore(output)
                if session.daemon_count() != 1:
                    raise RuntimeError('Expected exactly one daemon after restoration')
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm_handler)
    gaps = motion_gaps(trace)
    if not gaps:
        raise RuntimeError(f'No moving ribbon samples; choose a workspace with multiple columns. Artifacts: {output}')
    print(f'maxMotionDispatchGapMs={max(gaps):.2f} budgetMs={args.max_gap_ms:.2f} artifacts={output}')
    print('Dispatch gaps measure scheduler continuity, not presented FPS or visual spacing.')
    if max(gaps) > args.max_gap_ms:
        raise RuntimeError(f'Motion exceeded the dispatch gap budget: {max(gaps):.2f} ms')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
