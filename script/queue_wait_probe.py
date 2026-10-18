#!/usr/bin/env python3
"""Queue-wait probe: does a snapshot started by one navigation command delay the next command?
Three fixture windows (the right ones made busy, like Xcode/Devices) on an empty workspace.
Pairs of focus-column commands are sent over the raw socket `gap` ms apart, then the daemon idles
so every pair starts from a settled state. Per command, from the daemon trace on the same uptime
clock: queue_wait_ms (socket write -> command-start) and focus_ms (`command-focus`).
Usage (under the desktop lock): script/queue_wait_probe.py OUT --bundle A=path --bundle B=path"""
import argparse, json, os, re, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import performance_experiments as pe  # noqa: E402
import desktop_session as session  # noqa: E402
import tear_probe as tp  # noqa: E402
from desktop_lock import inherited_lock  # noqa: E402

NAV_LOG = Path('/tmp/defi-nav-slow.log')
# The user's own parked windows (e.g. Devices) can report permanent drift; only count settledness
# of the fixture workspace through the other tokens.
_strict_settled = pe.settled
pe.settled = lambda status: _strict_settled(status) if '--strict' in sys.argv else all(t in status for t in ('axPending=false', 'focusPending=false', 'animating=false', 'settling=0 '))


def wait_for_settlement(timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = session.command('status')
        if pe.settled(status):
            time.sleep(.3)  # status is cached for 250 ms
            if pe.settled(session.command('status')):
                return status
        time.sleep(.05)
    raise RuntimeError(f'Workspace did not settle within {timeout}s')


def command_rows(trace, sent):
    """Match each sent (uptime, command) to the next `command-start` of that command."""
    starts = [(float(t), cg, c) for t, cg, c in re.findall(
        r'^(\S+) command-start cg=(\d+) command=(\S+(?: \S+)?) source=ipc', trace, re.M)]
    focus = {cg: float(ms) for cg, ms in re.findall(r'command-focus cg=(\d+) ms=([\d.]+)', trace)}
    rows, used = [], set()
    for t_sent, command, gap in sent:
        match = next((s for s in starts if s[0] >= t_sent and s[1] not in used and s[2] == command), None)
        if match is None or match[0] - t_sent > 1:
            continue
        used.add(match[1])
        rows.append({'command': command, 'gap': gap, 'queue_wait_ms': round((match[0] - t_sent) * 1000, 2),
                     'focus_ms': focus.get(match[1])})
    return rows


def trial(out, label, args):
    fixtures, binary = [], out / 'PerformanceFixture'
    try:
        for i in range(3):
            fixtures.append(pe.Fixture(binary, out / f'{label}-fixture-{i}.jsonl'))
        for f in fixtures:
            f.ask()
        pe.activate(fixtures[0].process.pid)
        mon = json.loads(session.command('list-workspaces', '--json'))['monitors'][0]
        empty = next(w for w in mon['workspaces'] if w['windowCount'] == 0)
        session.command('workspace', empty['id'])
        wait_for_settlement()
        expected, discovered = [], set()
        for i, f in enumerate(fixtures):
            report = f.ask('create', id='main')
            expected.append((i, 'main', report['windows'][0]['windowNumber']))
            pe.wait_owned(fixtures, expected, empty['id'], discovered)
            session.command('focus-column', 'last')
            pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[-1][2])
        session.command('focus-column', 'first')
        pe.wait_owned(fixtures, expected, empty['id'], discovered, selected=expected[0][2])
        for i in args.busy_fixtures:
            fixtures[i].ask('set-busy', delay=args.busy[0], period=args.busy[1])
        session.command('trace')  # drain
        NAV_LOG.unlink(missing_ok=True)
        sent, t_begin, lines = [], tp.pe_uptime(), {}
        def pull():  # `defi trace` is a small ring buffer; read it often enough not to lose commands
            time.sleep(.3)  # read cache is 250 ms
            lines.update({l: None for l in tp.trace_since(t_begin).splitlines()})
        for n in range(args.pairs):
            gap = args.gap[n % len(args.gap)]
            for command in ('focus-column right', 'focus-column left'):
                t = tp.pe_uptime()
                sock = tp.send_async(command)
                sent.append((t, command, gap))
                sock.makefile().readline()
                sock.close()
                time.sleep(gap / 1000 if command.endswith('right') else args.rest)
            if n % 2 == 1:
                pull()
        wait_for_settlement()
        pull()
        trace = '\n'.join(sorted(lines, key=lambda l: float(l.split()[0])))
        (out / f'{label}-trace.txt').write_text(trace)
        if NAV_LOG.exists():
            (out / f'{label}-navlog.txt').write_text(NAV_LOG.read_text())
        for i in args.busy_fixtures:
            fixtures[i].ask('set-busy', delay=0, period=args.busy[1])
        return command_rows(trace, sent)
    finally:
        for f in fixtures:
            f.close()


def summarize(rows):
    def stats(key, only=None):
        v = [r[key] for r in rows if r[key] is not None and (only is None or r['command'] == only)]
        return {'n': len(v), 'median': round(statistics.median(v), 1) if v else None,
                'max': round(max(v), 1) if v else None}
    # second command of a pair is the 'left' one, sent `gap` ms after 'right'
    return {'second': {k: stats(k, 'focus-column left') for k in ('queue_wait_ms', 'focus_ms')},
            'first': {k: stats(k, 'focus-column right') for k in ('queue_wait_ms', 'focus_ms')}}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    p.add_argument('--bundle', action='append', required=True, help='LABEL=path')
    p.add_argument('--strict', action='store_true', help='also require drift=0, like the frozen harness')
    p.add_argument('--rounds', type=int, default=4)
    p.add_argument('--pairs', type=int, default=12)
    p.add_argument('--gap', type=float, nargs='+', default=[125], help='ms between the first and second command of a pair (cycled per pair)')
    p.add_argument('--rest', type=float, default=.9, help='s of rest after each pair')
    p.add_argument('--busy', type=float, nargs=2, default=[.018, .020])
    p.add_argument('--busy-fixtures', type=int, nargs='+', default=[1, 2])
    args = p.parse_args()
    if inherited_lock() is None:
        p.error('run under script/desktop_lock.py --wait')
    out = args.output.resolve()
    out.mkdir(parents=True)
    bundles = dict(b.split('=', 1) for b in args.bundle)
    installed = Path.home() / 'Applications/Defi.app'
    original = out / 'original.app'
    pe.run(['ditto', installed, original])
    pe.run(['swiftc', '-parse-as-library', ROOT / 'Tests/Fixtures/PerformanceFixture.swift', '-o', out / 'PerformanceFixture'])

    def install(bundle):
        pe.run([ROOT / 'script/check_signing.sh', installed, bundle])
        pe.run([ROOT / 'script/build_and_run.sh', '--install-staged', bundle, '--verify'], timeout=120)
        deadline = time.monotonic() + 15
        while not re.search(r'monitors=[1-9]', session.command('status')):
            if time.monotonic() > deadline:
                raise RuntimeError('daemon did not discover monitor')
            time.sleep(.05)
        if session.daemon_count() != 1:
            raise RuntimeError('Expected exactly one daemon')
        pe.wait_for_quiet_alerts()

    checkpoint = out / 'checkpoint'
    session.checkpoint(checkpoint)
    session.start()
    results = []
    try:
        for r in range(args.rounds):
            for label, path in bundles.items():
                install(Path(path).resolve())
                pe.wait_for_idle()
                try:
                    rows = trial(out, f'{label}{r}', args)
                except RuntimeError as error:
                    status = session.command('status')
                    print(json.dumps({'side': label, 'round': r, 'failed': str(error)[:120],
                                      'status': re.findall(r'\b(?:drift|settling|hidden)=\S+', status)}), flush=True)
                    continue
                res = {'side': label, 'round': r, **summarize(rows), 'rows': rows}
                print(json.dumps({k: v for k, v in res.items() if k != 'rows'}), flush=True)
                results.append(res)
                (out / 'results.json').write_text(json.dumps(results, indent=1))
    finally:
        try:
            install(original)
        finally:
            try:
                session.restore(checkpoint)
            except Exception:
                time.sleep(2)
                session.restore(checkpoint)
            print('daemons', session.daemon_count(), flush=True)


if __name__ == '__main__':
    main()
