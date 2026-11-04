#!/usr/bin/env python3
"""Draws the stratified mutation sample: every curated mutant, then catalog rows so each bug type
has at least --per-type mutants and the rest follow the weight of past fixes by area.

    sample.py [--size 400] [--per-type 25] [--seed 1] [--out Tests/Mutation/sample.tsv]
"""
import argparse
import csv
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Fix PRs touching each area since the first release (docs/testing/retro-validation.md corpus).
AREA_WEIGHTS = {
    "focus": 9, "discovery": 9, "layout": 9, "frames": 6, "parking": 3, "displays": 3,
    "mouse": 3, "overview": 3, "animation": 4, "permissions": 2, "daemon": 3,
}


def read(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--size", type=int, default=400)
    parser.add_argument("--per-type", type=int, default=25)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out", default="Tests/Mutation/sample.tsv")
    args = parser.parse_args()
    random.seed(args.seed)
    curated = read(ROOT / "Tests/Mutation/curated.tsv")
    catalog = read(ROOT / "Tests/Mutation/catalog.tsv")
    random.shuffle(catalog)
    chosen = {row["id"]: row for row in curated}
    for kind in sorted({row["type"] for row in catalog}):
        have = sum(1 for row in chosen.values() if row["type"] == kind)
        for row in [r for r in catalog if r["type"] == kind and r["id"] not in chosen][: max(0, args.per_type - have)]:
            chosen[row["id"]] = row
    total = sum(AREA_WEIGHTS.values())
    for area, weight in AREA_WEIGHTS.items():
        want = round(args.size * weight / total)
        have = sum(1 for row in chosen.values() if row["area"] == area)
        for row in [r for r in catalog if r["area"] == area and r["id"] not in chosen][: max(0, want - have)]:
            chosen[row["id"]] = row
    rows = list(chosen.values())
    with open(ROOT / args.out, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(curated[0]), delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\")
        writer.writeheader()
        writer.writerows(rows)
    print(f"{len(rows)} mutants -> {args.out}")


if __name__ == "__main__":
    main()
