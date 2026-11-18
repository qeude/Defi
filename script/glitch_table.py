#!/usr/bin/env python3
"""Prints defect counts per scenario for glitch_bench runs side by side.
Usage: glitch_table.py LABEL=RUN_DIR [...]   (RUN_DIR holds summary.json)"""
import json, sys
runs = [(a.split('=', 1)[0], json.load(open(a.split('=', 1)[1] + '/summary.json'))) for a in sys.argv[1:]]
kinds = sorted({k for _, s in runs for c in s['scenarios'].values() for k in c} - {'checks', 'defects'})
scenarios = sorted({k for _, s in runs for k in s['scenarios']})
print('| scenario | defect | ' + ' | '.join(l for l, _ in runs) + ' |')
print('|---|---|' + '---:|' * len(runs))
for scenario in scenarios:
    for kind in kinds + ['defects']:
        values = [s['scenarios'].get(scenario, {}).get(kind, 0) for _, s in runs]
        if any(values):
            print(f'| {scenario} | {kind} | ' + ' | '.join(map(str, values)) + ' |')
print('| all | start p50/p90 | ' + ' | '.join(f"{s['start_fraction']['p50']}/{s['start_fraction']['p90']}" for _, s in runs) + ' |')
print('| all | blind actions | ' + ' | '.join(str(s['blind_actions']) for _, s in runs) + ' |')
