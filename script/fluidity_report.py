#!/usr/bin/env python3
"""Tables a fluidity_probe.py run: per action and build, the median over trials and the trial range.
Noise comes from every trial of the base build across earlier runs (--pool, results.json files): a
difference counts only when every candidate trial lies beyond every base trial, pooled and in this run. Spikes over 30 ms are shown, never judged.
Usage: script/fluidity_report.py RUN --base LABEL --pool 'dist/bench/*/results.json'"""
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
    import glob
    p = argparse.ArgumentParser()
    p.add_argument('run', type=Path)
    p.add_argument('--base', default='base', help='base build label in RUN')
    p.add_argument('--pool', default='dist/bench/*/results.json', help='runs whose base trials give the noise')
    p.add_argument('--pool-labels', help='builds whose trials give the noise; defaults to --base')
    args = p.parse_args()
    table = values(json.loads((args.run / 'results.json').read_text()))
    labels = set((args.pool_labels or args.base).split(','))
    pooled = {}
    for path in glob.glob(args.pool):
        for result in json.loads(Path(path).read_text()):
            if result['build'] in labels and 'idle_cpu_pct' in result:
                result = dict(result, build='pool')
                for key, series in values([result])['pool'].items():
                    pooled.setdefault(key, []).extend(series)
    builds = list(table)
    candidate = next(b for b in builds if b != args.base)
    better = {name: way for name, way, _ in METRICS} | dict(TRIAL)
    keys = sorted({k for b in table.values() for k in b})
    print(f'| action | metric | pooled base median [range, n] | {args.base} | {candidate} | verdict |')
    print('|---|---|---|---|---|---|')
    for key in keys:
        def cell(series):
            return f'{statistics.median(series):.2f} [{min(series):.2f}–{max(series):.2f}]' if series else '—'
        pool = pooled.get(key, [])
        verdict = ''
        if key[1] != 'spikes' and all(key in table[b] for b in (args.base, candidate)):
            # Every candidate trial beyond every base trial, pooled and in this run.
            reference = pool + table[args.base][key]
            trials = table[candidate][key]
            lower, higher = max(trials) < min(reference), min(trials) > max(reference)
            if lower or higher:
                verdict = 'GAIN' if lower == (better[key[1]] == 'lower') else 'LOSS'
        print(f'| {key[0]} | {key[1]} | {cell(pool)}, {len(pool)} | {cell(table[args.base].get(key))} | '
              f'{cell(table[candidate].get(key))} | {verdict} |')


if __name__ == '__main__':
    main()
