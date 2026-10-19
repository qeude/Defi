#!/usr/bin/env python3
"""Drive a fixed desktop scenario and report border detachment and ribbon smoothness.

A 4 ms WindowServer sampler (script/motion_probe.swift) records the daemon's border
windows and every on-screen app window. `defi trace` is fetched while the run is live.
Both use systemUptime, so each bad episode is attributed to the trace phase active at
its start. Scenario mode moves real windows; --passive N only observes.
"""
import argparse
from bisect import bisect_left
import json
import tomllib
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

from desktop_lock import inherited_lock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "script/motion_probe.swift"
BINARY = ROOT / "dist/benchmarks/motion-probe"
CLI_FALLBACK = Path.home() / "Applications/Defi.app/Contents/MacOS/defi"

BORDER = 4             # pt; ring outset from the window rect; set from the user's config in main()
RING_OUTSET = 6        # pt; BORDER + 2 of tolerance
CONFIG = Path.home() / ".config/defi/config.toml"
LAG_SLICE_S = 0.004    # lag integration step while a border is misaligned; the sampler period
LAG_HORIZON_S = 1.0    # a border no window passed through this recently is stuck, not lagging
THIN = 64              # pt; border strips are thinner than this
EDGE_MARGIN = 20       # pt; thin windows this close to a display's side are parked-window leaks
EPISODE_MS = 50        # detached episodes shorter than this are sampling noise
STALL_MS = 25          # gap between consecutive position changes that counts as a stall
BACKWARD_PT = 1        # steps against the net direction larger than this are backward
ARRIVED_PT = 1         # a window this close to its final position has finished moving
SETTLE_S = 1.0         # how long after `complete` a late window write is still attributed
WORKSPACE_WINDOW_S = 1.0
REST_S = 0.3


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)  # same clock as ProcessInfo.systemUptime


# ---- scenario ---------------------------------------------------------------------

def soak_steps():
    """(defi args, sleep seconds after) in the exact order of /tmp/defi-bench/soak.sh."""
    steps = []
    for _ in range(3):
        steps += [(("focus-column", d), 0.35) for d in ("right", "right", "left", "left", "right", "left")]
        steps += [(("focus-column", "right"), 0.6)]
        for _ in range(2):
            steps += [(("move-column", "left"), 0.6), (("move-column", "right"), 0.6)]
        steps += [(("focus-column", "left"), 0.5)]
        steps += [(("workspace", "web"), 1.2), (("workspace", "dev"), 1.2), (("workspace", "dev-secondary"), 1.2)]
        steps += [(("focus-column", d), 0.3) for d in ("right", "left", "right", "left")]
        steps += [(("workspace", "dev"), 1.2)]
        steps += [(("focus-column", d), 0.12) for d in ("right", "left", "right", "left", "right", "left")]
        steps[-1] = (steps[-1][0], 0.12 + 1.5)
    return steps


# ---- trace ------------------------------------------------------------------------

def parse_trace(text):
    events = []
    for line in text.splitlines():
        head, _, rest = line.partition(" ")
        try:
            t = float(head)
        except ValueError:
            continue
        name, _, tail = rest.partition(" ")
        events.append({"t": t, "event": name, "f": dict(re.findall(r"(\w+)=(\S+)", tail)), "line": line})
    return sorted(events, key=lambda e: e["t"])


def build_generations(events):
    """Returns (generations by submit time, deferred parking intervals).

    A generation ends at complete/abort, else when the next one is submitted."""
    gens, by_g, deferred, open_deferred = [], {}, [], {}
    for e in events:
        g, f = e["f"].get("g"), e["f"]
        if e["event"] == "submit" and g is not None:
            animated = f.get("animated", "")
            ids = [int(i) for i in re.findall(r"\d+", animated.partition("[")[2])]
            by_g[g] = {"g": int(g), "source": f.get("source", ""), "submit": e["t"], "end": None,
                       "parking_from": None, "animated": ids}
            gens.append(by_g[g])
        elif e["event"] in ("complete", "abort") and g in by_g and by_g[g]["end"] is None:
            by_g[g]["end"] = e["t"]
        elif e["event"] == "phase" and f.get("kind") == "parking" and g in by_g:
            by_g[g]["parking_from"] = e["t"]
        elif e["event"] == "parking-deferred-start" and g is not None:
            open_deferred[g] = e["t"]
        elif e["event"] == "parking-deferred-complete" and g in open_deferred:
            deferred.append((open_deferred.pop(g), e["t"]))
    for gen, following in zip(gens, gens[1:] + [None]):
        if gen["end"] is None:
            gen["end"] = following["submit"] if following else float("inf")
    return gens, deferred


def source_phase(source):
    if source.startswith("workspace") or source == "native-workspace":
        return "workspace-switch"
    if "layout" in source:
        return "layout-animation"
    if "focus" in source or source == "command-animation":
        return "focus-animation"
    return "other"


def classify(t, gens, deferred, marks):
    """Trace phase active at uptime t. marks: sorted submit/complete/abort times."""
    active = [g for g in gens if g["submit"] <= t <= g["end"]]
    if active:
        gen = active[-1]
        phase = source_phase(gen["source"])
        if phase != "workspace-switch" and gen["parking_from"] is not None and gen["parking_from"] <= t:
            return "parking"
        return phase
    if any(source_phase(g["source"]) == "workspace-switch" and 0 <= t - g["submit"] <= WORKSPACE_WINDOW_S
           for g in gens):
        return "workspace-switch"
    if any(start <= t <= end for start, end in deferred):
        return "parking"
    i = bisect_left(marks, t)
    near = [abs(marks[j] - t) for j in (i - 1, i) if 0 <= j < len(marks)]
    return "rest" if not near or min(near) > REST_S else "other"


def trace_aggregates(events):
    slow, lanes, display_gaps, cadence_gaps, stale = {}, 0, [], [], 0
    for e in events:
        f = e["f"]
        if e["event"] == "slow" and f.get("phase") == "motion":
            slow[f.get("pid", "?")] = slow.get(f.get("pid", "?"), 0) + 1
        elif e["event"] == "slow-lane" and f.get("state") == "enter":
            lanes += 1
        elif e["event"] == "clock" and "displayGapMs" in f:
            display_gaps.append(float(f["displayGapMs"]))
        elif e["event"] == "cadence" and "maxGapMs" in f:
            cadence_gaps.append(float(f["maxGapMs"]))
        elif e["event"] == "border-stale":
            stale += 1
    return {"slow_motion_by_pid": slow, "slow_lane_enters": lanes, "border_stale": stale,
            "max_display_gap_ms": max(display_gaps, default=0.0), "max_cadence_gap_ms": max(cadence_gaps, default=0.0)}


# ---- borders ----------------------------------------------------------------------

def attached(edge, apps):
    """edge and apps are (x, y, w, h). Attached: inside some app's outset ring, touching
    the ring boundary, and not inside the window body."""
    ex, ey, ew, eh = edge
    for x, y, w, h in apps:
        ox0, oy0, ox1, oy1 = x - RING_OUTSET, y - RING_OUTSET, x + w + RING_OUTSET, y + h + RING_OUTSET
        if ex >= ox0 - 2 and ey >= oy0 - 2 and ex + ew <= ox1 + 2 and ey + eh <= oy1 + 2:
            touches = (abs(ex - ox0) <= RING_OUTSET or abs(ey - oy0) <= RING_OUTSET
                       or abs(ex + ew - ox1) <= RING_OUTSET or abs(ey + eh - oy1) <= RING_OUTSET)
            inside_body = ex > x + 2 and ey > y + 2 and ex + ew < x + w - 2 and ey + eh < y + h - 2
            if touches and not inside_body:
                return True
    return False


def edge_kind(rect, displays):
    """None when no display shows the edge; 'edge-strip' for a vertical edge within EDGE_MARGIN
    of its display's side (a parked-window leak); otherwise 'detached'."""
    if not displays:
        return "detached"
    x, y, w, h = rect
    shown = [d for d in displays if x < d[0] + d[2] and x + w > d[0] and y < d[1] + d[3] and y + h > d[1]]
    if not shown:
        return None
    dx, _, dw, _ = shown[0]
    near_side = x <= dx + EDGE_MARGIN or x + w >= dx + dw - EDGE_MARGIN
    return "edge-strip" if h > w and near_side else "detached"


def detached_episodes(states, end_t, displays):
    """states: [{'t', 'apps': [[id, pid, x, y, w, h]], 'edges': [[id, layer, x, y, w, h]]}], each
    holding until the next. One episode = a continuous period with at least one unattached
    thin daemon window of that kind."""
    opened, episodes = {}, []

    def close(kind, t):
        item = opened.pop(kind)
        episodes.append({**item, "kind": kind, "end": t, "ms": round((t - item["start"]) * 1000, 1)})

    for state in states:
        apps = [tuple(a[2:6]) for a in state["apps"]]
        bad = {"detached": [], "edge-strip": []}
        for edge in state["edges"]:
            rect = tuple(edge[2:6])
            kind = edge_kind(rect, displays) if min(rect[2], rect[3]) <= THIN else None
            if kind and not attached(rect, apps):
                bad[kind].append(edge)
        for kind, edges in bad.items():
            if edges and kind not in opened:
                opened[kind] = {"start": state["t"], "edges": 0, "rect": edges[0][2:6]}
            if edges:
                opened[kind]["edges"] = max(opened[kind]["edges"], len(edges))
            elif kind in opened:
                close(kind, state["t"])
    for kind in list(opened):
        close(kind, end_t)
    return sorted(episodes, key=lambda e: e["start"])


def segment_distance(point, start, end):
    """Distance from point to the straight path between two window samples."""
    (px, py), (ax, ay), (bx, by) = point, start, end
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    k = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - ax - k * dx, py - ay - k * dy)


def border_lag_ms(edge, now, track):
    """Time between now and the nearest moment (past or future) the window was where the
    border's top edge shows it: 0 when it is there now, None when it is not within
    LAG_HORIZON_S either way. A border can lead its window when WindowServer applies a
    slow app's write late. track: [(t, x, y)], the window's whole sampled history."""
    x, y = edge[0] + BORDER, edge[1] + BORDER
    best = None
    for index, (t, wx, wy) in enumerate(track):
        until = track[index + 1][0] if index + 1 < len(track) else float("inf")
        nx, ny = track[index + 1][1:] if index + 1 < len(track) else (wx, wy)
        if abs(wx - x) <= 1 and abs(wy - y) <= 1:
            dt = 0.0 if t <= now < until else min(abs(now - t), abs(now - until))
        elif segment_distance((x, y), (wx, wy), (nx, ny)) <= 1:
            dt = abs(now - until)  # passed between two samples
        else:
            continue
        if dt <= LAG_HORIZON_S and (best is None or dt < best):
            best = dt
    return None if best is None else best * 1000


def border_lag(states, end_t):
    """Time-weighted lag of the worst border in each sampled state. A border's top edge is the
    upper of its two horizontal edges (same x and width); it belongs to a window whose width
    it outsets by BORDER."""
    history, _ = window_tracks(states)
    weighted, stuck_ms = [], 0.0

    def worst_lag(state, at):
        """Worst border lag at time `at` while `state` holds; None when a border is stuck."""
        tracks = {wid: (x, y, w, h) for wid, _, x, y, w, h in state["apps"]}  # windows shown now
        horizontal = [edge[2:6] for edge in state["edges"] if edge[5] <= THIN < edge[4]]
        # Horizontal panels span the window, so any thin-width panel is a side panel, even a
        # short one on a short window with a thick border.
        vertical = [edge[2:6] for edge in state["edges"] if edge[4] <= THIN]
        worst = 0.0
        for ex, ey, ew, eh in horizontal:
            # A ring's left edge starts where its top edge ends and stops where its bottom begins.
            if any(abs(vx - ex) <= 1 and abs(vy + vh - ey) <= 1 for vx, vy, _, vh in vertical):
                continue  # a bottom edge; its top edge carries the lag
            owners = [wid for wid, (x, y, w, h) in tracks.items() if abs(w + 2 * BORDER - ew) <= 2]
            if not owners:  # a border whose window is gone
                return None
            known = [lag for lag in (border_lag_ms((ex, ey), at, history[wid]) for wid in owners)
                     if lag is not None]
            if not known:
                return None
            worst = max(worst, min(known))
        return worst

    for state, nxt in zip(states, states[1:] + [{"t": end_t}]):
        start, end = state["t"], nxt["t"]
        # An aligned border stays aligned until the next change; a misaligned one drifts
        # during the hold, so integrate it in sampler-sized slices.
        # Probe just after the change: a window leaving at `start` still reads as aligned there.
        probe_at = start + min(LAG_SLICE_S, end - start) / 2
        slices = [start] if worst_lag(state, probe_at) == 0 else \
            [start + i * LAG_SLICE_S for i in range(max(1, math.ceil((end - start) / LAG_SLICE_S)))]
        for at, until in zip(slices, slices[1:] + [end]):
            lag, hold = worst_lag(state, at), (until - at) * 1000
            if lag is None:
                stuck_ms += hold
            elif lag > 0:
                weighted.append((lag, hold))
    weighted.sort()
    total = sum(h for _, h in weighted)

    def quantile(q):
        acc = 0.0
        for lag, hold in weighted:
            acc += hold
            if acc >= q * total:
                return round(lag, 1)
        return 0.0
    return {"lagging_ms": round(total, 1), "lag_p50_ms": quantile(0.5), "lag_p95_ms": quantile(0.95),
            "lag_max_ms": round(max((lag for lag, _ in weighted), default=0.0), 1),
            "lagging_over_17ms_ms": round(sum(h for lag, h in weighted if lag > 17), 1),
            "stuck_ms": round(stuck_ms, 1)}


# ---- ribbon -----------------------------------------------------------------------

def window_tracks(states):
    """{window id: [(t, x, y)]} with an entry only when the position changes; and pids."""
    tracks, pids = {}, {}
    for state in states:
        for wid, pid, x, y, *_ in state["apps"]:
            pids[wid] = pid
            track = tracks.setdefault(wid, [])
            if not track or track[-1][1:] != (x, y):
                track.append((state["t"], x, y))
    return tracks, pids


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * fraction))] if values else 0.0


def window_motion(track, submit, end, settle_end):
    """Smoothness of one window during one generation, or None if it did not travel.

    Stalls are gaps > STALL_MS between consecutive position changes while the generation is
    active and the window is still short of its final position (the sub-pixel tail is excluded)."""
    before = [p for p in track if p[0] <= submit]
    inside = [p for p in track if submit < p[0] <= settle_end]
    if not inside:
        return None
    origin = before[-1] if before else inside.pop(0)
    if not inside:
        return None
    final = inside[-1]
    # A window that leaves and comes back did travel: judge by its farthest excursion, and
    # measure a round trip along the way out so the return reads as overshoot and backward steps.
    far = max(inside, key=lambda p: max(abs(p[1] - origin[1]), abs(p[2] - origin[2])))
    if max(abs(far[1] - origin[1]), abs(far[2] - origin[2])) < 2:
        return None
    reference = final if max(abs(final[1] - origin[1]), abs(final[2] - origin[2])) >= 2 else far
    axis = 1 if abs(reference[1] - origin[1]) >= abs(reference[2] - origin[2]) else 2
    sign = 1 if reference[axis] > origin[axis] else -1
    # Arrived once it stays within ARRIVED_PT; an overshoot that returns is still motion.
    arrived = len(inside) - 1
    while arrived > 0 and abs(inside[arrived - 1][axis] - final[axis]) <= ARRIVED_PT:
        arrived -= 1
    moving = inside[:arrived + 1]
    active = [p for p in moving if p[0] <= end]
    gaps = [(b[0] - a[0]) * 1000 for a, b in zip(active, active[1:])]
    # A freeze that spans `end` still interrupted the motion; its part after `end` is settle_ms.
    if active and len(moving) > len(active):
        gaps.append((end - active[-1][0]) * 1000)
    series = [origin] + inside
    return {
        "frames": len(active),
        "stalls": sum(g > STALL_MS for g in gaps),
        "max_gap_ms": round(max(gaps, default=0.0), 1),
        "backward_steps": sum(sign * (b[axis] - a[axis]) < -BACKWARD_PT for a, b in zip(series, series[1:])),
        "overshoot_pt": max(0, max(sign * (p[axis] - final[axis]) for p in inside)),
        "settle_ms": round(max(0.0, moving[-1][0] - end) * 1000, 1),
        "start_lag_ms": round((inside[0][0] - submit) * 1000, 1),
        "seconds": moving[-1][0] - moving[0][0],
    }


def ribbon_rows(gens, tracks, pids):
    rows = []
    for gen, following in zip(gens, gens[1:] + [None]):
        if not gen["animated"] or gen["end"] == float("inf"):
            continue
        settle_end = min(gen["end"] + SETTLE_S, following["submit"] if following else float("inf"))
        for wid in gen["animated"]:
            motion = window_motion(tracks.get(wid, []), gen["submit"], gen["end"], settle_end)
            if motion:
                rows.append({"g": gen["g"], "wid": wid, "pid": pids.get(wid), **motion})
    return rows


def summarize_rows(rows):
    seconds = sum(r["seconds"] for r in rows)
    stalls = sum(r["stalls"] for r in rows)
    return {"windows": len(rows), "frames": sum(r["frames"] for r in rows), "stalls": stalls,
            "window_seconds": round(seconds, 3), "stalls_per_s": round(stalls / seconds, 3) if seconds else 0.0,
            "p95_max_gap_ms": percentile([r["max_gap_ms"] for r in rows], 0.95),
            "max_gap_ms": max((r["max_gap_ms"] for r in rows), default=0.0),
            "backward_steps": sum(r["backward_steps"] for r in rows),
            "max_overshoot_pt": max((r["overshoot_pt"] for r in rows), default=0),
            "p95_settle_ms": percentile([r["settle_ms"] for r in rows], 0.95),
            "p95_start_lag_ms": percentile([r["start_lag_ms"] for r in rows], 0.95)}


# ---- run --------------------------------------------------------------------------

def slow_motion_by_app(by_pid, bundles):
    """Slow-motion counts summed per bundle; several processes can share one."""
    totals = {}
    for pid, count in by_pid.items():
        app = bundles.get(pid, pid)
        totals[app] = totals.get(app, 0) + count
    return totals


def analyze(states, end_t, displays, events, bundles, stalls=()):
    gens, deferred = build_generations(events)
    marks = sorted(e["t"] for e in events if e["event"] in ("submit", "complete", "abort"))
    episodes = detached_episodes(states, end_t, displays)
    for e in episodes:
        e["phase"] = classify(e["start"], gens, deferred, marks)
        # The sampler saw nothing while WindowServer stalled; Defi cannot move anything then either.
        # Only an episode that is detached mostly because of stalls is set aside.
        e["stall_ms"] = round(sum(max(0.0, min(e["end"], t + ms / 1000) - max(e["start"], t)) * 1000
                                  for t, ms in stalls), 1)
        e["windowserver_stall"] = e["ms"] - e["stall_ms"] <= EPISODE_MS
    frozen = [e for e in episodes if e["kind"] == "detached" and e["ms"] > EPISODE_MS and e["windowserver_stall"]]
    long = [e for e in episodes if e["kind"] == "detached" and e["ms"] > EPISODE_MS and not e["windowserver_stall"]]
    strips = [e for e in episodes if e["kind"] == "edge-strip" and e["ms"] > EPISODE_MS]
    tracks, pids = window_tracks(states)
    rows = ribbon_rows(gens, tracks, pids)
    by_app = {}
    for row in rows:
        by_app.setdefault(bundles.get(str(row["pid"]), str(row["pid"])), []).append(row)
    aggregates = trace_aggregates(events)
    return {
        "detached_borders": {
            "episodes_over_50ms": len(long),
            "total_ms": round(sum(e["ms"] for e in episodes if e["kind"] == "detached"), 1),
            "longest_ms": max((e["ms"] for e in long), default=0.0),
            "by_phase": {p: sum(e["phase"] == p for e in long) for p in sorted({e["phase"] for e in long})},
            "during_windowserver_stall": len(frozen),
            "windowserver_stalls": {"count": len(stalls), "total_ms": round(sum(ms for _, ms in stalls), 1),
                                    "max_ms": max((ms for _, ms in stalls), default=0.0)},
            "edge_strip_episodes_over_50ms": len(strips),
            "edge_strip_total_ms": round(sum(e["ms"] for e in episodes if e["kind"] == "edge-strip"), 1),
            "episodes": [e for e in episodes if e["ms"] > EPISODE_MS]},
        "border_lag": border_lag(states, end_t),
        "ribbon": {"overall": summarize_rows(rows),
                   "by_app": {app: summarize_rows(r) for app, r in sorted(by_app.items())},
                   "windows": rows},
        "trace": {**aggregates, "slow_motion_by_app": slow_motion_by_app(aggregates["slow_motion_by_pid"], bundles)},
        "work": {"generations_seen": len(gens), "animated_generations": len({r["g"] for r in rows}),
                 "state_changes": len(states), "trace_events": len(events)},
    }


def headline(report):
    d, r, b = report["detached_borders"], report["ribbon"]["overall"], report["border_lag"]
    return {"border_lag_p95_ms": b["lag_p95_ms"], "border_lagging_over_17ms_ms": b["lagging_over_17ms_ms"],
            "border_stuck_ms": b["stuck_ms"],"detached_episodes_over_50ms": d["episodes_over_50ms"], "detached_total_ms": d["total_ms"],
            "ribbon_stalls_per_s": r["stalls_per_s"], "ribbon_p95_max_gap_ms": r["p95_max_gap_ms"],
            "ribbon_backward_steps": r["backward_steps"]}


def repeat_summary(reports):
    heads = [headline(r) for r in reports]
    return {key: {"median": statistics.median(h[key] for h in heads),
                  "min": min(h[key] for h in heads), "max": max(h[key] for h in heads)} for key in heads[0]}


def cli_path():
    return shutil.which("defi") or str(CLI_FALLBACK)


def daemon_pid():
    out = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "defi-daemon"],
                         capture_output=True, text=True, check=False).stdout.split()
    if len(out) != 1:
        raise RuntimeError(f"Expected exactly one defi-daemon, found {len(out)}")
    return out[0]


def build():
    if not BINARY.exists() or BINARY.stat().st_mtime < SOURCE.stat().st_mtime:
        BINARY.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-swift-version", "6", str(SOURCE), "-o", str(BINARY)],
                       check=True, timeout=180)


class TraceCollector(threading.Thread):
    """Fetches `defi trace` periodically; the daemon ring holds only 512 lines."""

    def __init__(self, cli, period=2.0):
        super().__init__(daemon=True)
        self.cli, self.period, self.lines, self.gaps, self.stop = cli, period, {}, 0, threading.Event()
        self.newest = 0.0

    def fetch(self):
        try:
            text = subprocess.run([self.cli, "trace"], capture_output=True, text=True, timeout=10).stdout
        except (subprocess.SubprocessError, OSError):
            return
        events = parse_trace(text)
        if events and self.newest and events[0]["t"] > self.newest:
            self.gaps += 1  # ring wrapped between fetches; lines were lost
        for e in events:
            self.lines[e["line"]] = e
        if events:
            self.newest = max(self.newest, events[-1]["t"])

    def run(self):
        while not self.stop.wait(self.period):
            self.fetch()

    def events(self):
        return sorted(self.lines.values(), key=lambda e: e["t"])


def run_once(args, cli):
    build()
    pid = daemon_pid()
    commands, failures = [], []
    if args.passive is None:
        subprocess.run([cli, "workspace", "dev"], capture_output=True, timeout=15)
        time.sleep(1)
    collector = TraceCollector(cli)
    collector.fetch()
    out = tempfile.TemporaryFile("w+")
    sampler = subprocess.Popen([str(BINARY), "sample", pid, str(3600), str(args.interval_ms)], stdout=out)
    collector.start()
    started = uptime()
    try:
        if args.passive is not None:
            time.sleep(args.passive)
        else:
            time.sleep(1)
            for command, pause in soak_steps():
                t = uptime()
                result = subprocess.run([cli, *command], capture_output=True, text=True, timeout=15)
                commands.append({"t": t, "command": " ".join(command), "ms": round((uptime() - t) * 1000, 1),
                                 "rc": result.returncode})
                if result.returncode:
                    failures.append({"command": " ".join(command), "rc": result.returncode,
                                     "stderr": result.stderr.strip()[:200]})
                time.sleep(pause)
    finally:
        sampler.send_signal(signal.SIGTERM)
        sampler.wait(timeout=15)
        collector.stop.set()
        collector.join(timeout=15)  # a fetch in flight must finish before the final read
    time.sleep(0.2)
    collector.fetch()
    out.seek(0)
    records = [json.loads(line) for line in out]
    out.close()
    head, end = records[0], records[-1]
    states = [r for r in records if "t" in r and "apps" in r]
    events = [e for e in collector.events() if e["t"] >= started - 1]
    pids = {str(a[1]) for s in states for a in s["apps"]} | {e["f"]["pid"] for e in events if "pid" in e["f"]}
    try:
        bundles = json.loads(subprocess.run([str(BINARY), "bundles", *sorted(pids)], capture_output=True,
                                            text=True, timeout=10).stdout or "{}")
    except (subprocess.SubprocessError, ValueError):
        bundles = {}
    stalls = [(r["stall"], r["ms"]) for r in records if "stall" in r]
    report = analyze(states, end["t"], head["displays"], events, bundles, stalls)
    seconds = end["t"] - head["start"]
    report["run"] = {"mode": "passive" if args.passive is not None else "soak", "seconds": round(seconds, 2),
                     "start_uptime": head["start"], "end_uptime": end["t"], "daemon_pid": int(pid)}
    report["sampler"] = {"ticks": end["ticks"], "errors": end["errors"],
                         "interval_ms_p50": end["interval_ms_p50"], "interval_ms_p95": end["interval_ms_p95"],
                         "interval_ms_max": end.get("interval_ms_max", 0.0)}
    report["daemon"] = {"cpu_percent": round(end["cpu_s"] / seconds * 100, 2) if seconds else 0.0}
    report["errors"] = {"command_failures": len(failures), "failures": failures[:5],
                        "sampler_errors": end["errors"], "trace_gaps": collector.gaps}
    report["work"].update(commands_sent=len(commands), frames_sampled=end["ticks"])
    report["commands"] = commands
    if args.raw_out:
        args.raw_out.write_text(json.dumps({"displays": head["displays"], "states": states, "events": events}))
    return report


def print_summary(report, stream=sys.stdout):
    run, s, d, r = report["run"], report["sampler"], report["detached_borders"], report["ribbon"]["overall"]
    w, t, e = report["work"], report["trace"], report["errors"]
    p = lambda text: print(text, file=stream)
    p(f"run {run['mode']} {run['seconds']}s commands={w['commands_sent']} generations={w['generations_seen']} "
      f"animated={w['animated_generations']} frames_sampled={w['frames_sampled']} state_changes={w['state_changes']} "
      f"trace_events={w['trace_events']}")
    ws = d["windowserver_stalls"]
    p(f"windowserver_stalls count={ws['count']} total={ws['total_ms']}ms max={ws['max_ms']}ms "
      f"detached_during_stalls={d['during_windowserver_stall']}")
    p(f"sampler interval p50/p95/max={s['interval_ms_p50']}/{s['interval_ms_p95']}/{s['interval_ms_max']}ms errors={s['errors']} "
      f"daemon_cpu={report['daemon']['cpu_percent']}%")
    p(f"detached_borders episodes>50ms={d['episodes_over_50ms']} total={d['total_ms']}ms longest={d['longest_ms']}ms "
      f"by_phase={d['by_phase']} edge_strip>50ms={d['edge_strip_episodes_over_50ms']} "
      f"edge_strip_total={d['edge_strip_total_ms']}ms")
    for episode in sorted(d["episodes"], key=lambda x: -x["ms"])[:5]:
        p(f"  {episode['kind']} t={episode['start']:.3f} {episode['ms']}ms phase={episode['phase']} "
          f"edges={episode['edges']} rect={episode['rect']}")
    b = report["border_lag"]
    p(f"border_lag lagging={b['lagging_ms']}ms p50={b['lag_p50_ms']}ms p95={b['lag_p95_ms']}ms "
      f"max={b['lag_max_ms']}ms over_17ms={b['lagging_over_17ms_ms']}ms stuck={b['stuck_ms']}ms")
    p(f"ribbon windows={r['windows']} frames={r['frames']} stalls={r['stalls']} stalls/s={r['stalls_per_s']} "
      f"p95_max_gap={r['p95_max_gap_ms']}ms max_gap={r['max_gap_ms']}ms backward={r['backward_steps']} "
      f"overshoot_max={r['max_overshoot_pt']}pt p95_settle={r['p95_settle_ms']}ms")
    for app, row in report["ribbon"]["by_app"].items():
        p(f"  {app}: windows={row['windows']} stalls/s={row['stalls_per_s']} p95_max_gap={row['p95_max_gap_ms']}ms "
          f"backward={row['backward_steps']}")
    p(f"trace slow_motion={t['slow_motion_by_app']} slow_lane_enters={t['slow_lane_enters']} "
      f"max_displayGapMs={t['max_display_gap_ms']} max_cadenceGapMs={t['max_cadence_gap_ms']} "
      f"border_stale={t['border_stale']}")
    p(f"errors command_failures={e['command_failures']} sampler_errors={e['sampler_errors']} trace_gaps={e['trace_gaps']}")


def interrupt(*_):
    raise KeyboardInterrupt


def border_outset(path=CONFIG):
    """How far border edges sit outside the window rect, from the user's config defaults."""
    try:
        borders = tomllib.loads(path.read_text()).get("decorations", {}).get("borders", {})
    except FileNotFoundError:
        borders = {}
    if not borders.get("enabled", True):
        return None
    return float(borders.get("width", 4)) if borders.get("placement", "outside") == "outside" else 0.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=["soak"], default="soak")
    parser.add_argument("--passive", type=float, metavar="SECONDS", help="observe only; send no commands")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--interval-ms", type=float, default=4)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--raw-out", type=Path, help="also save sampled states and trace events")
    args = parser.parse_args()
    if args.passive is not None and args.passive < 0:
        parser.error("--passive must be zero or more seconds")
    if args.passive is None and inherited_lock() is None:  # scenario moves real windows
        os.execv(sys.executable, [sys.executable, str(ROOT / "script/desktop_lock.py"), "--wait",
                                  sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    global BORDER, RING_OUTSET
    outset = border_outset()
    if outset is None:
        parser.error("borders are disabled in the Defi config; nothing to measure")
    BORDER, RING_OUTSET = outset, outset + 2
    signal.signal(signal.SIGTERM, interrupt)
    cli, reports = cli_path(), []
    stamp = time.strftime('%Y%m%d-%H%M%S')
    session = None
    if args.passive is None:  # the scenario changes workspaces, order, and focus
        import desktop_session
        session = ROOT / f"dist/benchmarks/motion-probe-{stamp}-session"
        desktop_session.checkpoint(session)
    try:
        if session:
            desktop_session.start()
        for index in range(max(args.repeat, 1)):
            if args.repeat > 1:
                print(f"== run {index + 1}/{args.repeat}")
            reports.append(run_once(args, cli))
            print_summary(reports[-1])
    finally:
        if session:
            desktop_session.start()
            desktop_session.restore(session)
    result = {"reports": reports}
    if len(reports) > 1:
        result["headline"] = repeat_summary(reports)
        for key, v in result["headline"].items():
            print(f"headline {key}: median={v['median']} range={v['min']}..{v['max']}")
    path = args.json_out or ROOT / f"dist/benchmarks/motion-probe-{stamp}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"json {path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
