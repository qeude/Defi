#!/usr/bin/env python3
"""Summarize a script/perf_release.sh run: per-build P50/P95/P99, the PERFORMANCE.md budgets, and
regressions of the candidate against the base beyond run-to-run noise.
Usage: perf_report.py RUN_DIR BASE_LABEL CANDIDATE_LABEL  (writes RUN_DIR/results.json and report.md)"""
import json, re, statistics, sys
from pathlib import Path

# (key, status field, P95 budget in ms or None), in PERFORMANCE.md order.
METRICS = [('plan', 'inputPlan', 4.0), ('write', 'inputWrite', None), ('observed', 'inputObserved', 16.7),
           ('converged', 'inputConverged', 50.0), ('focus', 'inputFocus', None)]
LABELS = {'plan': 'input to planned update', 'write': 'input to first AX write',
          'observed': 'input to first observed movement', 'converged': 'input to converged frame',
          'focus': 'input to confirmed focus'}
# A shift is a regression only when all three hold; see PERFORMANCE.md "Release performance check".
RELATIVE = 0.25
ABSOLUTE_MS = 1.0
GATED = ('p50', 'p95')  # P99 of ~120 samples is the second-worst sample: reported, never flagged.


def parse_status(text):
    values = {}
    for key, field, _ in METRICS:
        match = re.search(rf'\b{field}N/P50/P95/P99=(\d+)/([\d.]+)/([\d.]+)/([\d.]+)', text)
        if match is None:
            raise ValueError(f'status lacks {field}')
        n, *p = match.groups()
        values[key] = {'n': int(n), 'p50': float(p[0]), 'p95': float(p[1]), 'p99': float(p[2])}
    return values


def parse_idle(text):
    before, after, rss_kb = text.split()
    return {'idle_cpu_percent': round((float(after) - float(before)) / 10 * 100, 2),
            'rss_mib': round(int(rss_kb) / 1024, 1)}


def load_rounds(out, label):
    rounds = []
    # A plain glob would let label v0.8.0 also match v0.8.0-3-gabc-1.status.
    matches = [p for p in out.glob('*.status') if re.fullmatch(re.escape(label) + r'-\d+', p.stem)]
    for status in sorted(matches, key=lambda p: int(p.stem.rsplit('-', 1)[1])):
        text = status.read_text()
        entry = parse_status(text)
        idle = status.with_suffix('.idle')
        if idle.exists():
            entry.update(parse_idle(idle.read_text()))
        if hz := re.search(r'\bdisplayHz=(\S+)', text):
            entry['display_hz'] = hz.group(1)
        rounds.append(entry)
    if not rounds:
        raise ValueError(f'no rounds for {label}')
    return rounds


def summary(rounds, key, percentile):
    # The daemon prints 0.00 for a metric without samples; that round says nothing about it.
    values = [r[key][percentile] for r in rounds if r[key]['n']]
    if not values:
        raise ValueError(f'no {key} samples in any round')
    return {'median': statistics.median(values), 'min': min(values), 'max': max(values)}


def compare(base, candidate):
    """Gated percentiles whose candidate shift exceeds noise, as (key, percentile, base, candidate)."""
    found = []
    for key, _, _ in METRICS:
        for percentile in GATED:
            b, c = summary(base, key, percentile), summary(candidate, key, percentile)
            if (c['median'] > b['median'] * (1 + RELATIVE) and c['median'] - b['median'] > ABSOLUTE_MS
                    and c['min'] > b['max']):
                found.append((key, percentile, b['median'], c['median']))
    return found


def report(meta, builds, base, candidate):
    b_rounds, c_rounds = builds[base]['rounds'], builds[candidate]['rounds']
    regressions = compare(b_rounds, c_rounds)
    # compare() returns (key, percentile, worse, better) here, so swap back to base → candidate.
    improvements = [(k, p, b, c) for k, p, c, b in compare(c_rounds, b_rounds)]
    lines = [f'# Release performance: {candidate} vs {base}', '',
             f'Measured {meta["measured_at"]} in the `{meta["vm"]}` VM ({meta["guest"]}, host {meta["host"]}), '
             f'{meta["rounds"]} alternating rounds per build of {meta["navigations"]} `focus-column` '
             f'navigations across {meta["windows"]} fixture windows. Values are medians of per-round '
             'percentiles in ms, with the per-round range for P95. Input is IPC receipt, not a hardware event.', '',
             f'| Metric | P95 budget | {base} P50 / P95 / P99 | {candidate} P50 / P95 / P99 | P95 range base → candidate | Samples per round |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    over = []
    for key, _, budget in METRICS:
        cells = []
        for rounds in (b_rounds, c_rounds):
            cells.append(' / '.join(f'{summary(rounds, key, p)["median"]:.2f}' for p in ('p50', 'p95', 'p99')))
        bp, cp = summary(b_rounds, key, 'p95'), summary(c_rounds, key, 'p95')
        if budget is not None and cp['median'] > budget:
            over.append(f'{LABELS[key]} P95 {cp["median"]:.2f} ms > {budget:g} ms')
        lines.append(f'| {LABELS[key]} | {"≤ %g" % budget if budget else "—"} | {cells[0]} | {cells[1]} | '
                     f'{bp["min"]:.2f}–{bp["max"]:.2f} → {cp["min"]:.2f}–{cp["max"]:.2f} | '
                     f'{statistics.median(r[key]["n"] for r in b_rounds + c_rounds):g} |')
    idle = [(label, [r for r in builds[label]['rounds'] if 'idle_cpu_percent' in r]) for label in (base, candidate)]
    lines += ['', '| Idle after settling (10 s) | CPU % | RSS MiB |', '| --- | ---: | ---: |']
    for label, rounds in idle:
        if rounds:
            lines.append(f'| {label} | {statistics.median(r["idle_cpu_percent"] for r in rounds):.2f} | '
                         f'{statistics.median(r["rss_mib"] for r in rounds):.1f} |')
    lines += ['', '## Verdict', '']
    describe = lambda items: [f'- {LABELS[k]} {p.upper()}: {b:.2f} → {c:.2f} ms' for k, p, b, c in items]
    lines += (['**Regression beyond noise** (blocks promotion until explained):', *describe(regressions)]
              if regressions else ['No regression beyond noise.'])
    if improvements:
        lines += ['', 'Improvements beyond noise:', *describe(improvements)]
    lines += ['', 'Over budget for the candidate:' if over else 'The candidate meets every P95 budget.',
              *[f'- {item}' for item in over]]
    lines += ['', f'Noise rule: a P50 or P95 shift counts only when the median moves by more than '
              f'{RELATIVE:.0%} and {ABSOLUTE_MS:g} ms and every candidate round is worse than every base round.']
    return '\n'.join(lines) + '\n', regressions


def main(run, base, candidate):
    run = Path(run)
    meta = json.loads((run / 'meta.json').read_text())
    builds = meta.pop('builds')
    for label in builds:
        builds[label]['rounds'] = load_rounds(run / 'out', label)
    text, regressions = report(meta, builds, base, candidate)
    results = {'schema': 1, **meta, 'base': base, 'candidate': candidate, 'builds': builds,
               'noise': {'relative': RELATIVE, 'absolute_ms': ABSOLUTE_MS, 'gated': list(GATED)},
               'regressions': [{'metric': k, 'percentile': p, 'base_ms': b, 'candidate_ms': c}
                               for k, p, b, c in regressions]}
    (run / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    (run / 'report.md').write_text(text)
    print(text)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
