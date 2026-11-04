#!/usr/bin/env bash
# Mutation check for the isolated loop: plants realistic bugs one at a time in worker copies of
# the checkout and reports, by bug type and area, which ones make check catches.
#   mutate.sh                 regenerate the catalog, draw the sample, run it, write the report
#   JOBS=n mutate.sh          parallel workers (default 3)
#   ONLY=regex mutate.sh      only mutants whose id, type, area or description matches
#   RESUME=1 mutate.sh        keep earlier results and run only the missing mutants
# Catalog: Tests/Mutation/catalog.tsv (generated) and curated.tsv (hand-written);
# sample: Tests/Mutation/sample.tsv; equivalents: Tests/Mutation/equivalent.tsv;
# report: docs/testing/mutation-results.md. The checkout itself is never mutated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RESULTS=.build/mutation/results.tsv
python3 script/mutation/generate.py
python3 script/mutation/sample.py
[[ "${RESUME:-}" == 1 ]] || rm -f "$RESULTS"
status=0
python3 script/mutation/run.py --jobs "${JOBS:-3}" --only "${ONLY:-}" --out "$RESULTS" || status=$?
python3 script/mutation/report.py --results "$RESULTS"
exit "$status"
