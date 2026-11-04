#!/usr/bin/env python3
"""Runs a mutation sample in parallel worker copies of the checkout, never in the checkout itself.

Each worker is a copy under .build/mutation/workers/<n> with its own build directory. Its baseline
must build and pass script/check.sh; then each mutant is planted, built, checked and restored.
A mutant counts as killed only when check.sh exits 1 with a failing test or a crash in a lane
log, or when it times out (a hang). Results go to a TSV, one row per mutant.

    run.py [--sample Tests/Mutation/sample.tsv] [--jobs 3] [--only REGEX] [--out .build/mutation/results.tsv]
"""
import argparse
import csv
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKERS = ROOT / ".build/mutation/workers"
KILL_MARKER = re.compile(r"recorded an issue|Test Case .* failed|Fatal error|unexpected signal")
FAILED_TEST = re.compile(r"(?:Test|Test Case) (\S+) (?:recorded an issue|failed)")
BUILD_TIMEOUT = 20 * 60
CHECK_TIMEOUT = 8 * 60


def read(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\"))


def sync(worker: Path):
    worker.mkdir(parents=True, exist_ok=True)
    # The worker keeps its own .build; the checkout's build and git data stay out.
    subprocess.run(
        ["rsync", "-a", "--delete", "--exclude", "/.build/", "--exclude", "/dist/", "--exclude", "/.git/",
         f"{ROOT}/", f"{worker}/"],
        check=True,
    )


def build(worker: Path) -> bool:
    try:
        return subprocess.run(["swift", "build", "--build-tests"], cwd=worker, capture_output=True,
                              timeout=BUILD_TIMEOUT).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def check(worker: Path, shards: int):
    env = dict(os.environ, SHARDS=str(shards), LOGS=str(worker / ".build/check"), FAIL_FAST="1")
    try:
        result = subprocess.run(["./script/check.sh"], cwd=worker, env=env, capture_output=True, text=True,
                                timeout=CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    logs = "".join(p.read_text(errors="replace") for p in (worker / ".build/check").glob("*.log"))
    return result.returncode, result.stdout + logs


def classify(status, output):
    if status == 0:
        return "survived", "", ""
    if status == "timeout":
        return "killed", "timeout", ""
    if status != 1 or not KILL_MARKER.search(output):
        return "error", "", ""
    lanes = sorted(set(re.findall(r"^FAIL +([a-z0-9-]+)", output, re.M)))
    tests = sorted(set(name.split("(")[0] for name in FAILED_TEST.findall(output)))[:4]
    return "killed", " ".join(lanes), " ".join(tests)


def run_mutant(worker: Path, row, shards):
    target = worker / row["file"]
    original_text = target.read_text()
    if original_text.count(row["original"]) != 1:
        return "skip-not-found", "", "", 0
    started = time.time()
    try:
        target.write_text(original_text.replace(row["original"], row["replacement"], 1))
        if not build(worker):
            return "skip-compile", "", "", time.time() - started
        status, output = check(worker, shards)
        verdict, lanes, tests = classify(status, output)
        return verdict, lanes, tests, time.time() - started
    finally:
        target.write_text(original_text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sample", default="Tests/Mutation/sample.tsv")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--shards", type=int, default=2)
    parser.add_argument("--only", default="")
    parser.add_argument("--out", default=".build/mutation/results.tsv")
    args = parser.parse_args()
    rows = [r for r in read(ROOT / args.sample)
            if not args.only or re.search(args.only, " ".join([r["id"], r["type"], r["area"], r["description"]]))]
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {r["id"] for r in read(out)} if out.exists() else set()
    todo = queue.Queue()
    for row in rows:
        if row["id"] not in done:
            todo.put(row)
    print(f"{todo.qsize()} mutants to run ({len(done)} already in {args.out}), {args.jobs} workers", flush=True)
    lock = threading.Lock()
    fields = ["id", "type", "area", "operator", "file", "line", "description", "verdict", "lanes", "tests", "seconds"]
    if not out.exists():
        with out.open("w", newline="") as handle:
            csv.writer(handle, delimiter="\t").writerow(fields)
    failures = []

    def work(index):
        worker = WORKERS / str(index)
        sync(worker)
        if not build(worker):
            failures.append(f"worker {index}: baseline does not build")
            return
        status, _ = check(worker, args.shards)
        if status != 0:
            failures.append(f"worker {index}: baseline check fails ({status})")
            return
        while True:
            try:
                row = todo.get_nowait()
            except queue.Empty:
                return
            verdict, lanes, tests, seconds = run_mutant(worker, row, args.shards)
            with lock:
                with out.open("a", newline="") as handle:
                    csv.writer(handle, delimiter="\t").writerow(
                        [row[f] for f in fields[:7]] + [verdict, lanes, tests, f"{seconds:.0f}"])
                print(f"{verdict:14} {row['type']:13} {row['description']}", flush=True)
            if verdict == "error":
                failures.append(f"worker {index}: setup error on {row['id']}")
                return

    threads = [threading.Thread(target=work, args=(i,)) for i in range(args.jobs)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(2 if failures else 0)


if __name__ == "__main__":
    main()
