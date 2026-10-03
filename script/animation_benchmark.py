#!/usr/bin/env python3
"""Capture ribbon navigation and a native Dia resize, correlated with AX traces."""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
CAPTURE_SOURCE = ROOT / "script/animation_capture.swift"
INPUT_SOURCE = ROOT / "script/animation_input.swift"
CLI = Path.home() / "Applications/Defi.app/Contents/MacOS/defi"


def run(*args, cwd=ROOT, timeout=20, capture_output=True):
    return subprocess.run(args, cwd=cwd, timeout=timeout, check=True,
                          text=True, capture_output=capture_output)


def build_capture():
    binary = ROOT / "dist/benchmarks/animation-capture"
    binary.parent.mkdir(parents=True, exist_ok=True)
    run("swiftc", "-O", "-swift-version", "6", "-parse-as-library",
        str(CAPTURE_SOURCE), "-framework", "ScreenCaptureKit",
        "-framework", "CoreGraphics", "-framework", "CoreVideo",
        "-o", str(binary), timeout=60)
    return binary


def build_input():
    binary = ROOT / "dist/benchmarks/animation-input"
    binary.parent.mkdir(parents=True, exist_ok=True)
    run("swiftc", "-O", "-swift-version", "6", "-parse-as-library",
        str(INPUT_SOURCE), "-framework", "AppKit", "-framework", "CoreGraphics",
        "-o", str(binary), timeout=60)
    return binary


def summarize(csv_path, markers_path):
    with csv_path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    with markers_path.open(newline="") as stream:
        marks = list(csv.DictReader(stream))
    if not rows:
        raise RuntimeError("Screen capture returned no frame measurements")
    lines = [
        f"displayFramesObserved={len(rows) + 1}",
        "ScreenCaptureKit may omit unchanged frames; phase callback gaps are reported below.",
        "Motion estimates use horizontal image correlation across four display zones; "
        "zone offsets are approximate and low-confidence matches are excluded.",
    ]
    for phase in sorted({mark["phase"] for mark in marks}):
        events = [mark for mark in marks if mark["phase"] == phase]
        start = next((float(item["uptime_s"]) for item in events if item["event"] == "start"), None)
        end = next((float(item["uptime_s"]) for item in events if item["event"] == "end"), None)
        if start is None or end is None:
            raise RuntimeError(f"Screen capture markers are incomplete for phase {phase!r}")
        captured_times = [float(row["timestamp_s"]) for row in rows]
        if min(captured_times) > start + 0.1 or max(captured_times) < end - 0.1:
            raise RuntimeError(f"Screen capture did not cover the complete {phase!r} phase")
        phase_rows = [row for row in rows if start <= float(row["timestamp_s"]) <= end]
        if len(phase_rows) < 2:
            raise RuntimeError(f"Screen capture has too few samples for phase {phase!r}")
        moving = []
        spreads = []
        for index, row in enumerate(phase_rows):
            shifts = [float(row[f"zone{zone}_dx_px"]) for zone in range(4)
                      if float(row[f"zone{zone}_confidence"]) >= 3.0
                      and row[f"zone{zone}_clipped"] == "false"
                      and abs(float(row[f"zone{zone}_dx_px"])) >= 4.0]
            if len(shifts) >= 2:
                moving.append((index, float(row["timestamp_s"])))
                spreads.append(max(shifts) - min(shifts))
        max_motion_gap = max((b[1] - a[1] for a, b in zip(moving, moving[1:])), default=None)
        phase_intervals = [(float(b["timestamp_s"]) - float(a["timestamp_s"])) * 1000
                           for a, b in zip(phase_rows, phase_rows[1:])]
        phase_intervals.sort()
        phase_p95 = phase_intervals[min(int(len(phase_intervals) * 0.95), len(phase_intervals) - 1)]
        phase_max = max(phase_intervals)
        median_spread = sorted(spreads)[len(spreads) // 2] if spreads else None
        max_motion_gap_ms = f"{max_motion_gap * 1000:.2f}" if max_motion_gap is not None else "n/a"
        median_spread_text = f"{median_spread:.1f}" if median_spread is not None else "n/a"
        lines.append(
            f"phase={phase} durationMs={(end-start)*1000:.0f} "
            f"displayFramesObserved={len(phase_rows)} captureGapP95Ms={phase_p95:.2f} "
            f"captureGapMaxMs={phase_max:.2f} "
            f"capturedMovingFrames={len(moving)} "
            f"maxGapBetweenMovingFramesMs={max_motion_gap_ms} "
            f"medianZoneOffsetSpreadPx={median_spread_text}"
        )
    return "\n".join(lines) + "\n"


def record_marker(writer, phase, event):
    writer.writerow((f"{time.monotonic():.9f}", phase, event))


def exercise(phase, directions, marker_writer, marker_stream, settle=0):
    record_marker(marker_writer, phase, "start")
    marker_stream.flush()
    for direction, delay in directions:
        run(str(CLI), "focus-column", direction)
        if delay:
            time.sleep(delay)
    if settle:
        time.sleep(settle)
    record_marker(marker_writer, phase, "end")
    marker_stream.flush()


def focused_window(status):
    return re.search(r"(?:^|\s)focused=(\S+)", status)


def focused_active_workspace(workspace_state):
    monitor = next((item for item in workspace_state["monitors"] if item["focused"]), None)
    workspace = next((
        candidate for candidate in (monitor or {}).get("workspaces", []) if candidate["active"]
    ), None)
    if monitor is None or workspace is None:
        raise RuntimeError("No active workspace found for the focused monitor")
    return monitor, workspace


def verify_restored_focus(output, desktop_session):
    initial_status = (output / "initial-status.txt").read_text()
    match = re.search(r"\bworkspace=(\S+).*?\bfocused=(\S+)", initial_status)
    initial_workspaces = json.loads((output / "initial-workspaces.json").read_text())
    monitor = next((item for item in initial_workspaces["monitors"] if item["focused"]), None)
    if match is None or monitor is None:
        raise RuntimeError("Initial focused workspace could not be resolved")

    stable_samples = 0
    reasserted = False
    for _ in range(24):
        workspaces = json.loads(run(str(CLI), "list-workspaces", "--json").stdout)
        current_monitor = next(
            (item for item in workspaces["monitors"] if item["id"] == monitor["id"]), None
        )
        status = run(str(CLI), "status").stdout
        restored = (
            current_monitor is not None
            and current_monitor["focused"]
            and current_monitor["activeWorkspace"] == match.group(1)
            and f"workspace={match.group(1)}" in status
            and focused_window(status) is not None
            and focused_window(status).group(1) == match.group(2)
            and "drift=0[" in status
            and "focusPending=false" in status
            and "axPending=false" in status
            and desktop_session.daemon_count() == 1
        )
        if restored:
            stable_samples += 1
            reasserted = False
            if stable_samples == 8:
                return
        else:
            stable_samples = 0
            if not reasserted:
                run(str(CLI), "--monitor", str(monitor["display"]), "workspace", match.group(1))
                reasserted = True
        time.sleep(0.25)
    raise RuntimeError("Initial native focus did not remain stable after the mouse resize")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", default="web", help="workspace to exercise (default: web)")
    parser.add_argument("--output", type=Path, help="output directory (default: dist/benchmarks/<timestamp>)")
    args = parser.parse_args()
    output = args.output or ROOT / "dist/benchmarks" / f"animation-benchmark-{time.time_ns()}"
    output = output.expanduser().resolve()
    if output.exists():
        raise RuntimeError(f"Output directory already exists: {output}")
    binary = build_capture()
    input_binary = build_input()

    # Re-exec beneath the shared desktop reservation when called directly.
    sys.path.insert(0, str(ROOT / "script"))
    from desktop_lock import acquire, inherited_lock
    if inherited_lock() is None:
        os.execv(sys.executable, [sys.executable, str(ROOT / "script/desktop_lock.py"),
                                 "--wait", sys.executable, str(SCRIPT),
                                 *sys.argv[1:]])
    acquire(wait=True)
    import desktop_session

    checkpointed = False
    capture = None
    try:
        initial_trace = run(str(CLI), "trace").stdout
        desktop_session.checkpoint(output)
        checkpointed = True
        (output / "trace-before.txt").write_text(initial_trace)
        (output / "initial-status.txt").write_bytes((output / "status.txt").read_bytes())
        (output / "initial-workspaces.json").write_bytes((output / "workspaces.json").read_bytes())
        desktop_session.start()
        run(str(CLI), "workspace", args.workspace)
        for _ in range(50):
            status = run(str(CLI), "status").stdout
            if f"workspace={args.workspace}" in status and "axPending=false" in status:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"Defi did not settle in workspace {args.workspace!r}")

        ready = output / "capture.ready"
        workspace_state = json.loads(run(str(CLI), "list-workspaces", "--json").stdout)
        focused_monitor, _ = focused_active_workspace(workspace_state)
        capture = subprocess.Popen(
            [str(binary), "120", str(focused_monitor["id"]), str(ready),
             str(output / "display.csv"), str(output / "capture.stop")],
            text=True, stdout=(output / "capture.log").open("w"),
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and capture.poll() is None and time.monotonic() < deadline:
            time.sleep(0.025)
        if not ready.exists():
            raise RuntimeError((output / "capture.log").read_text().strip()
                               or "Screen capture did not become ready")
        time.sleep(0.35)
        with (output / "markers.csv").open("w", newline="") as marker_stream:
            markers = csv.writer(marker_stream)
            markers.writerow(("uptime_s", "phase", "event"))
            exercise("single-right", [("right", 0)], markers, marker_stream, settle=0.22)
            time.sleep(0.1)
            exercise("single-left", [("left", 0)], markers, marker_stream, settle=0.22)
            exercise("rapid-reversal", [("right", 0.07)] * 3 + [("left", 0.07)] * 3,
                     markers, marker_stream, settle=0.22)
            workspace_state = json.loads(run(str(CLI), "list-workspaces", "--json").stdout)
            focused_monitor, active_workspace = focused_active_workspace(workspace_state)
            if active_workspace.get("focusedApplication") != "company.thebrowser.dia":
                raise RuntimeError("Mouse resize requires Dia to be the focused app in the test workspace")
            focused_window_match = re.search(r"\bfocused=(\d+)", run(str(CLI), "status").stdout)
            if focused_window_match is None:
                raise RuntimeError("Could not resolve the focused Dia window ID")
            record_marker(markers, "mouse-resize", "start")
            marker_stream.flush()
            resize_log = []
            for delta in (-80, 80):
                try:
                    resize_log.append(
                        run(str(input_binary), focused_window_match.group(1), str(delta)).stdout.strip()
                    )
                except subprocess.CalledProcessError as error:
                    detail = (error.stderr or error.stdout or str(error)).strip()
                    resize_log.append(f"delta={delta} failed: {detail}")
                    (output / "mouse-resize.txt").write_text("\n".join(resize_log) + "\n")
                    raise RuntimeError(f"Mouse resize failed: {detail}") from error
                time.sleep(0.15)
            time.sleep(0.3)
            record_marker(markers, "mouse-resize", "end")
            marker_stream.flush()
            (output / "mouse-resize.txt").write_text("\n".join(resize_log) + "\n")
        time.sleep(0.5)
        (output / "capture.stop").touch()
        capture.wait(timeout=12)
        if capture.returncode:
            raise RuntimeError((output / "capture.log").read_text().strip())
        (output / "trace-after.txt").write_text(run(str(CLI), "trace").stdout)
        status = run(str(CLI), "status").stdout
        (output / "status-after.txt").write_text(status)
        (output / "summary.txt").write_text(summarize(output / "display.csv", output / "markers.csv"))
        (output / "metadata.json").write_text(json.dumps({
            "workspace": args.workspace,
            "frameBackend": "publicAccessibility",
            "mouseResizeInput": "publicCoreGraphicsEventsOnFocusedDiaWindow",
            "gitRevision": run("git", "rev-parse", "HEAD").stdout.strip(),
            "dirtySource": bool(run("git", "status", "--porcelain").stdout.strip()),
            "screenRecordingPreflight": True,
        }, indent=2) + "\n")
        print(f"Benchmark artifacts: {output}")
        print((output / "summary.txt").read_text(), end="")
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate()
            capture.wait(timeout=5)
        if checkpointed:
            desktop_session.start()
            try:
                desktop_session.restore(output)
            except RuntimeError:
                diagnostics = [output / name for name in (
                    "workspace-topology.json", "restored-topology.json", "restored-status.txt"
                )]
                if not all(path.is_file() for path in diagnostics):
                    raise
                expected = json.loads((output / "workspace-topology.json").read_text())
                restored = json.loads((output / "restored-topology.json").read_text())
                status = (output / "restored-status.txt").read_text()
                if not (desktop_session.close_enough(
                        restored["topology"]["monitors"], expected["topology"]["monitors"])
                        and "drift=0[" in status and "focusPending=false" in status
                        and "axPending=false" in status and desktop_session.daemon_count() == 1):
                    raise
                original_status = (output / "initial-status.txt").read_text()
                match = re.search(r"\bworkspace=([^ ]+).*?\bfocused=(\S+)", original_status)
                if not match:
                    raise RuntimeError("Initial focused workspace was not recorded")
                for _ in range(30):
                    run(str(CLI), "workspace", match.group(1))
                    status = run(str(CLI), "status").stdout
                    status_focus = focused_window(status)
                    if (f"workspace={match.group(1)}" in status
                            and status_focus is not None and status_focus.group(1) == match.group(2)
                            and "drift=0[" in status):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("Could not restore the initially focused native window")
                print("Restored the initial native focus after matching stored workspace topology")
            verify_restored_focus(output, desktop_session)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(str(error))
