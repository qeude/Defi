#!/usr/bin/env python3
"""Read-only probe: how closely Defi border rings track real window frames, and their cost."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "script/border_sync_probe.swift"
BINARY = ROOT / "dist/benchmarks/border-sync-probe"
OUTSET = 4          # ring outer rect = window frame outset by 4 pt
TOLERANCE = 2       # pt; errors above this count as desync
MATCH_LIMIT = 600   # pt; a ring farther than this from every window is unmatched
STATUS_FIELDS = ("borderSurfaceMiB", "borders", "borderNodes", "posWrites", "axReads")


def group_rings(edges):
    """Edges are [id, layer, x, y, w, h]; four consecutive-id edges form one ring."""
    edges = sorted(edge for edge in edges if min(edge[4], edge[5]) <= 64)
    runs = []
    for edge in edges:
        if runs and runs[-1][-1][0] + 1 == edge[0]:
            runs[-1].append(edge)
        else:
            runs.append([edge])
    rings = []
    for run in runs:
        for i in range(0, len(run) - 3, 4):
            part = run[i:i + 4]
            rect = (min(e[2] for e in part), min(e[3] for e in part),
                    max(e[2] + e[4] for e in part), max(e[3] + e[5] for e in part))
            rings.append({"key": tuple(e[0] for e in part), "rect": rect, "active": any(e[1] == 3 for e in part)})
    return rings


def ring_error(rect, window):
    _, x, y, w, h = window
    expected = (x - OUTSET, y - OUTSET, x + w + OUTSET, y + h + OUTSET)
    return max(abs(a - b) for a, b in zip(rect, expected))


def match_ring(rect, windows, preferred=None):
    """Nearest window by expected outset; a stale ring keeps its previous window (preferred)."""
    if not windows:
        return None
    best = min(windows, key=lambda window: ring_error(rect, window))
    if ring_error(rect, best) > TOLERANCE:
        best = next((w for w in windows if w[0] == preferred), best)
    error = ring_error(rect, best)
    return (best[0], error) if error <= MATCH_LIMIT else None


def weighted_percentile(pairs, fraction):
    pairs = sorted(pairs)
    target = fraction * sum(weight for _, weight in pairs)
    seen = 0
    for value, weight in pairs:
        seen += weight
        if seen >= target:
            return value
    return pairs[-1][0]


def summarize(states, end_t, end_n):
    """states: [{'t','n','apps','edges'}] on each geometry change; each state holds until the next."""
    owner, windows = {}, {}
    ring_keys, unmatched, max_rings = set(), {}, 0
    for index, state in enumerate(states):
        t_next, n_next = (states[index + 1]["t"], states[index + 1]["n"]) if index + 1 < len(states) else (end_t, end_n)
        ms, weight = (t_next - state["t"]) * 1000, n_next - state["n"]
        rings = group_rings(state["edges"])
        max_rings = max(max_rings, len(rings))
        errors = {}
        for ring in rings:
            ring_keys.add(ring["key"])
            match = match_ring(ring["rect"], state["apps"], owner.get(ring["key"]))
            if match is None:
                unmatched[ring["key"]] = unmatched.get(ring["key"], 0) + weight
                continue
            owner[ring["key"]] = match[0]
            errors[match[0]] = max(errors.get(match[0], 0), match[1])
        for window_id, error in errors.items():
            entry = windows.setdefault(window_id, {"pairs": [], "desync_ms": 0.0, "run_ms": 0.0, "longest_ms": 0.0,
                                                   "last": -1})
            entry["pairs"].append((error, weight))
            if error > TOLERANCE:
                entry["desync_ms"] += ms
                # a gap in states (window or ring absent) breaks the continuous run
                entry["run_ms"] = entry["run_ms"] + ms if entry["last"] == index - 1 and entry["run_ms"] else ms
                entry["longest_ms"] = max(entry["longest_ms"], entry["run_ms"])
            else:
                entry["run_ms"] = 0.0
            entry["last"] = index
    return {
        "windows": {str(window_id): {
            "samples": sum(w for _, w in e["pairs"]),
            "error_pt_p50": weighted_percentile(e["pairs"], .5),
            "error_pt_p95": weighted_percentile(e["pairs"], .95),
            "error_pt_max": max(error for error, _ in e["pairs"]),
            "desync_ms": round(e["desync_ms"], 1),
            "longest_desync_ms": round(e["longest_ms"], 1),
        } for window_id, e in sorted(windows.items())},
        "unmatched_rings": len(unmatched),
        "unmatched_ring_samples": sum(unmatched.values()),
        "rings": max_rings,
        "distinct_rings_seen": len(ring_keys),
    }


def parse_status(text):
    values = {}
    for key, raw in re.findall(r"\b(\w+)=(\S+)", text):
        if key in STATUS_FIELDS and key not in values:
            values[key] = [float(part) for part in raw.split("/")]
    return values


def status_delta(before, after):
    unwrap = lambda v: v[0] if len(v) == 1 else v
    return {key: {"before": unwrap(before[key]), "after": unwrap(after[key]),
                  "delta": unwrap([a - b for a, b in zip(after[key], before[key])])}
            for key in STATUS_FIELDS if key in before and key in after}


def build():
    if not BINARY.exists() or BINARY.stat().st_mtime < SOURCE.stat().st_mtime:
        BINARY.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-swift-version", "6", str(SOURCE), "-o", str(BINARY)],
                       check=True, timeout=120)
    return BINARY


def daemon_pid():
    result = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "defi-daemon"],
                            capture_output=True, text=True, check=False)
    pids = result.stdout.split()
    if len(pids) != 1:
        raise RuntimeError(f"Expected exactly one defi-daemon, found {len(pids)}")
    return pids[0]


def run_probe(args):
    import desktop_session  # command() runs the installed defi CLI
    commands = [shlex.split(item) for item in args.commands.split(";") if item.strip()] if args.commands else []
    binary, pid = build(), daemon_pid()
    before = parse_status(desktop_session.command("status"))
    with tempfile.TemporaryFile("w+") as out:
        sampler = subprocess.Popen([str(binary), pid, str(args.seconds), str(args.interval_ms)], stdout=out)
        deadline = time.monotonic() + args.seconds
        step = 0
        while commands and time.monotonic() < deadline:
            desktop_session.command(*commands[step % len(commands)])
            step += 1
            time.sleep(args.command_gap_ms / 1000)
        if sampler.wait() != 0:
            raise RuntimeError("border sampler failed")
        after = parse_status(desktop_session.command("status"))
        out.seek(0)
        records = [json.loads(line) for line in out]
    end = records.pop()
    report = summarize(records, end["t"], end["n"])
    report.update(seconds=round(end["t"], 3), frames_sampled=end["n"],
                  interval_ms_achieved=round(end["t"] * 1000 / max(end["n"], 1), 2),
                  geometry_changes=len(records), commands_sent=step)
    report["resources"] = {"daemon_cpu_percent": round(end["cpu_s"] / end["t"] * 100, 2),
                           "status": status_delta(before, after)}
    return report


def print_summary(report, stream=sys.stderr):
    print(f"{report['seconds']}s frames={report['frames_sampled']} interval={report['interval_ms_achieved']}ms "
          f"rings={report['rings']} unmatched={report['unmatched_rings']} commands={report['commands_sent']}", file=stream)
    for window_id, w in report["windows"].items():
        print(f"  window {window_id}: samples={w['samples']} err p50/p95/max={w['error_pt_p50']}/"
              f"{w['error_pt_p95']}/{w['error_pt_max']}pt desync={w['desync_ms']}ms longest={w['longest_desync_ms']}ms",
              file=stream)
    resources = report["resources"]
    fields = " ".join(f"{k}={v['delta']}" for k, v in resources["status"].items())
    print(f"  daemon cpu={resources['daemon_cpu_percent']}% status deltas: {fields}", file=stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--interval-ms", type=float, default=4)
    parser.add_argument("--commands", help='defi commands separated by ";", e.g. "focus-column right;focus-column left"')
    parser.add_argument("--command-gap-ms", type=float, default=300)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    report = run_probe(args)
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.json_out:
        args.json_out.write_text(text + "\n")
    print(text)
    print_summary(report)


if __name__ == "__main__":
    main()
