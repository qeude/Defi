#!/usr/bin/env python3
"""Split new-window admission latency into stages, paired A/B, under the desktop lock.

Each trial opens one fixture window, either in a running fixture process ("window") or in a
freshly launched one ("launch"), samples its WindowServer bounds every 4 ms with
script/motion_probe.swift, and aligns `defi trace` stages on the same systemUptime clock:
  event      AX kAXWindowCreatedNotification handled          (window-event kind=windowCreated)
  discovery  window classified tiled                          (window-discovery id=W class=tiled)
  apply      first layout apply that knows the window         (initial-apply ids=[..W..])
  submit     first frame-write generation including W         (submit g=N windows=..[..W..])
  complete   that generation's AX writes done                 (complete g=N)
  moved      first sampled bounds change
  final      first sample of the final stable frame (wrong place/size until then)
All stages are milliseconds after the fixture returned from makeKeyAndOrderFront.
  admission_probe.py <A.app> <B.app> --output DIR [--rounds 2] [--trials 6]
"""
import argparse
import json
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import desktop_session as session  # noqa: E402
import motion_probe  # noqa: E402
import performance_experiments as pe  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
STAGES = ('event', 'discovery', 'apply', 'submit', 'complete', 'moved', 'final')
STABLE_S = 0.6


def settle(timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pe.settled(session.command('status')):
            return True
        time.sleep(.05)
    return False


def samples_for(states, window_number):
    rows = []
    for state in states:
        frame = next((a[2:] for a in state['apps'] if a[0] == window_number), None)
        rows.append((state['t'], frame))
    return rows


def stages(events, samples, window_number, pid, created):
    present = [(t, f) for t, f in samples if f is not None]
    if not present:
        raise RuntimeError('Window never sampled on screen')
    appear, initial = created, present[0][1]
    final_frame = present[-1][1]
    final_at = appear
    for t, f in present:
        if f != final_frame:
            final_at = None
        elif final_at is None:
            final_at = t
    moved = next((t for t, f in present if f != initial), None)
    w, result = str(window_number), {}
    def first(predicate):
        return next((e['t'] for e in events if e['t'] >= appear - 0.5 and predicate(e)), None)
    result['event'] = first(lambda e: e['event'] == 'window-event' and e['f'].get('kind') == 'windowCreated'
                            and e['f'].get('pid') == str(pid))
    result['discovery'] = first(lambda e: e['event'] == 'window-discovery'
                                and f'id={w},' in e['line'] and 'class=tiled' in e['line'])
    result['apply'] = first(lambda e: e['event'] == 'initial-apply'
                            and w in re.findall(r'\d+', e['f'].get('ids', '')))
    submit = next((e for e in events if e['t'] >= appear - 0.5 and e['event'] == 'submit'
                   and w in re.findall(r'\d+', e['f'].get('windows', '').partition('[')[2])), None)
    result['submit'] = submit and submit['t']
    result['complete'] = submit and first(lambda e: e['event'] == 'complete' and e['f'].get('g') == submit['f']['g'])
    result['moved'] = moved
    result['final'] = final_at if final_frame != initial else appear
    out = {k: (None if v is None else round((v - appear) * 1000, 1)) for k, v in result.items()}
    out.update(initial=initial, final_frame=final_frame,
               size_changed=initial[2:] != final_frame[2:], position_changed=initial[:2] != final_frame[:2],
               distinct_frames=len({tuple(f) for _, f in present}),
               appeared=round((present[0][0] - created) * 1000, 1),
               timeline=[[round((t - created) * 1000, 1), f] for t, f in present
                         if t - created < 2][:60])
    return out


def trial(binary, sampler, scenario, host, directory, index):
    collector = motion_probe.TraceCollector(session.CLI, period=0.5)
    collector.fetch()
    out = tempfile.TemporaryFile('w+')
    probe = subprocess.Popen([str(sampler), 'sample', motion_probe.daemon_pid(), '30', '4'], stdout=out)
    collector.start()
    fixture = None
    try:
        deadline = time.monotonic() + 5
        while out.tell() == 0 and time.monotonic() < deadline:
            time.sleep(.01)
        time.sleep(.1)
        name = f'n{index}'
        if scenario == 'launch':
            fixture = pe.Fixture(binary, directory / f'launch-{index}.jsonl')
            report = fixture.ask('create', id=name)
        else:
            fixture = host
            report = fixture.ask('create', id=name)
        window_number = next(w['windowNumber'] for w in report['windows'] if w['id'] == name)
        time.sleep(STABLE_S)
        settle()
        time.sleep(STABLE_S)
    finally:
        probe.send_signal(signal.SIGTERM)
        probe.wait(timeout=15)
        collector.stop.set()
        collector.fetch()
    out.seek(0)
    records = [json.loads(line) for line in out]
    states = [r for r in records if 't' in r and 'apps' in r]
    row = stages(collector.events(), samples_for(states, window_number), window_number, fixture.process.pid,
                 report['at'])
    row.update(scenario=scenario, window=window_number, trace_gaps=collector.gaps,
               trace=[f"{(e['t'] - report['at']) * 1000:.1f} {e['line'].partition(' ')[2]}"
                      for e in collector.events() if -0.1 <= e['t'] - report['at'] <= 0.6])
    if scenario == 'launch':
        fixture.close()
    else:
        host.ask('close', id=name)
    settle()
    time.sleep(.3)
    return row


def summarize(rows):
    summary = {}
    for key in sorted({(r['side'], r['scenario']) for r in rows}):
        group = [r for r in rows if (r['side'], r['scenario']) == key]
        summary['/'.join(key)] = {}
        for stage in STAGES:
            values = sorted(r[stage] for r in group if r[stage] is not None)
            if values:
                summary['/'.join(key)][stage] = {
                    'n': len(values), 'p50': statistics.median(values),
                    'p90': values[min(len(values) - 1, int(len(values) * .9))],
                    'min': values[0], 'max': values[-1]}
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('a', type=Path)
    parser.add_argument('b', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--trials', type=int, default=6)
    parser.add_argument('--scenario', action='append', choices=['window', 'launch'])
    args = parser.parse_args()
    if inherited_lock() is None:
        import os
        os.execv(sys.executable, [sys.executable, str(ROOT / 'script/desktop_lock.py'), '--wait',
                                  sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    scenarios = args.scenario or ['window', 'launch']
    output = args.output.resolve()
    output.mkdir(parents=True)
    installed = Path.home() / 'Applications/Defi.app'
    original = output / 'original.app'
    pe.run(['ditto', installed, original])
    bundles = {'A': args.a.resolve(), 'B': args.b.resolve()}
    for bundle in bundles.values():
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
    binary = output / 'PerformanceFixture'
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', binary])
    sampler = output / 'motion-probe'
    pe.run(['swiftc', '-O', '-swift-version', '6', ROOT / 'script/motion_probe.swift', '-o', sampler])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        try:
            pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        except RuntimeError:
            time.sleep(2)
            pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while not re.search(r'monitors=[1-9]', session.command('status')):
            if time.monotonic() >= deadline:
                raise RuntimeError('Installed daemon did not discover the monitor')
            time.sleep(.05)
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon')
        pe.wait_for_quiet_alerts()

    checkpoint = output / 'checkpoint'
    probe_fixture = pe.Fixture(binary, output / 'initial-native.jsonl')
    initial_native = probe_fixture.ask('native-focus')['nativeFocus']
    probe_fixture.close()
    session.checkpoint(checkpoint)
    rows = []
    try:
        for repeat in range(args.rounds):
            for side in 'AB':
                install(bundles[side])
                monitor = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
                empty = next(w for w in monitor['workspaces'] if w['kind'] == 'trailing' and w['windowCount'] == 0)
                session.command('workspace', empty['id'])
                trial_dir = output / f'{side}{repeat}'
                trial_dir.mkdir()
                host = pe.Fixture(binary, trial_dir / 'host.jsonl')
                try:
                    host.ask('create', id='base')
                    pe.activate(host.process.pid)
                    time.sleep(1)
                    settle()
                    for i in range(args.trials):
                        for scenario in scenarios:
                            row = {**trial(binary, sampler, scenario, host, trial_dir, f'{scenario}{i}'),
                                   'side': side, 'repeat': repeat}
                            rows.append(row)
                            print(json.dumps({k: row[k] for k in ('side', 'scenario', *STAGES)}), flush=True)
                            pe.save(output / 'rows.json', rows)
                finally:
                    host.close()
                    settle()
    finally:
        try:
            install(original)
        finally:
            session.restore(checkpoint)
        observer = pe.Fixture(binary, output / 'restored-native.jsonl')
        try:
            pe.activate(initial_native['pid'])
            time.sleep(1)
        finally:
            observer.close()
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon after restoration')
    summary = summarize(rows)
    pe.save(output / 'summary.json', summary)
    for key, values in summary.items():
        print(key, ' '.join(f"{s}={v['p50']:.0f}/{v['p90']:.0f}" for s, v in values.items()))


if __name__ == '__main__':
    main()
