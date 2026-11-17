#!/usr/bin/env python3
"""Tables a fluidity_probe.py run: per action and build, the median over trials and the trial range.
With --noise A_A_RUN, a difference counts only beyond the spread the same build showed against itself.
Usage: script/fluidity_report.py RUN [--noise AA_RUN] [--write-noise FILE]"""
import argparse, json, statistics
from pathlib import Path

# (name, better when, per-trial value)
METRICS = [
    ('smooth_pct', 'higher', lambda a: 100 * a['smooth'] / a['gaps'] if a.get('gaps') else None),
    ('worst_ms', 'lower', lambda a: a.get('worst_ms') if a.get('gaps') else None),
    ('spikes', 'lower', lambda a: a.get('spikes')),
    ('hitches', 'lower', lambda a: a['hitches'] / a['events'] if a.get('events') else None),
    ('cpu_ms', 'lower', lambda a: a['cpu_ms'] / a['events'] if a.get('events') else None),
    ('wakeups', 'lower', lambda a: a['wakeups'] / a['events'] if a.get('events') else None),
    ('ax_writes', 'lower', lambda a: a['ax_writes'] / a['events'] if a.get('events') else None),
]
TRIAL = [('idle_cpu_pct', 'lower'), ('idle_wakeups_per_s', 'lower'), ('footprint_mib', 'lower')]


def values(results):
    """{build: {(action, metric): [per-trial values]}}"""
    table = {}
    for result in results:
        build = table.setdefault(result['build'], {})
        for action, entry in result['actions'].items():
            for name, _, get in METRICS:
                value = get(entry)
                if value is not None:
                    build.setdefault((action, name), []).append(value)
        for name, _ in TRIAL:
            build.setdefault(('idle', name), []).append(result[name])
    return table


def spread(table):
    """Per (action, metric): the largest trial range one build showed, or the gap between the
    medians of two runs of the same build if larger (drift between runs)."""
    noise = {}
    for build in table.values():
        for key, series in build.items():
            noise[key] = max(noise.get(key, 0), max(series) - min(series))
    medians = [{k: statistics.median(v) for k, v in build.items()} for build in table.values()]
    for key in noise:
        found = [m[key] for m in medians if key in m]
        noise[key] = max(noise[key], max(found) - min(found))
    return noise


def main():
    p = argparse.ArgumentParser()
    p.add_argument('run', type=Path)
    p.add_argument('--noise', type=Path)
    p.add_argument('--write-noise', type=Path)
    args = p.parse_args()
    table = values(json.loads((args.run / 'results.json').read_text()))
    if args.write_noise:
        args.write_noise.write_text(json.dumps({f'{a}|{m}': v for (a, m), v in spread(table).items()}, indent=1))
    noise = {tuple(k.split('|')): v for k, v in json.loads(args.noise.read_text()).items()} if args.noise else spread(table)
    builds = list(table)
    better = {name: way for name, way, _ in METRICS} | dict(TRIAL)
    keys = sorted({k for b in table.values() for k in b})
    print('| action | metric | ' + ' | '.join(f'{b} median [range]' for b in builds) + ' | noise | verdict |')
    print('|---|---|' + '---|' * len(builds) + '---|---|')
    for key in keys:
        cells = []
        for build in builds:
            series = table[build].get(key)
            cells.append(f'{statistics.median(series):.2f} [{min(series):.2f}–{max(series):.2f}]' if series else '—')
        verdict = ''
        if len(builds) == 2 and all(key in table[b] for b in builds):
            a, b = (statistics.median(table[x][key]) for x in builds)
            delta = b - a if better[key[1]] == 'higher' else a - b
            if abs(b - a) > noise.get(key, 0):
                verdict = 'GAIN' if delta > 0 else 'LOSS'
        print(f'| {key[0]} | {key[1]} | ' + ' | '.join(cells) + f' | {noise.get(key, 0):.2f} | {verdict} |')


if __name__ == '__main__':
    main()
