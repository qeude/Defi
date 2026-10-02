#!/usr/bin/env python3
"""Probe SkyLight frame movement on an invisible, helper-owned panel."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE = ROOT / "script/private_frame_probe.swift"
BINARY = ROOT / "dist/benchmarks/private-frame-probe"


def main():
    sys.path.insert(0, str(ROOT / "script"))
    from desktop_lock import acquire, inherited_lock
    if inherited_lock() is None:
        os.execv(sys.executable, [sys.executable, str(ROOT / "script/desktop_lock.py"),
                                 "--wait", sys.executable, str(SCRIPT), *sys.argv[1:]])
    acquire(wait=True)
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "swiftc", "-O", "-swift-version", "6", "-parse-as-library", str(SOURCE),
        "-framework", "AppKit", "-framework", "CoreGraphics", "-o", str(BINARY),
    ], check=True, timeout=60)
    output = ROOT / "dist/benchmarks" / f"private-frame-probe-{time.strftime('%Y%m%d-%H%M%S')}"
    output.mkdir(parents=True, exist_ok=False)
    result = subprocess.run([str(BINARY)], check=False, text=True, capture_output=True, timeout=10)
    (output / "stdout.txt").write_text(result.stdout)
    (output / "stderr.txt").write_text(result.stderr)
    (output / "metadata.json").write_text(json.dumps({
        "probeSurface": "invisible helper-owned NSPanel",
        "privateBackend": "SLSMoveWindow",
        "exitCode": result.returncode,
        "gitRevision": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       check=True, text=True, capture_output=True).stdout.strip(),
        "dirtySource": bool(subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                                           check=True, text=True, capture_output=True).stdout.strip()),
    }, indent=2) + "\n")
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    print(f"Probe artifacts: {output}")
    if result.returncode:
        sys.exit(result.returncode if result.returncode > 0 else 1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, TimeoutError, ValueError) as error:
        sys.exit(str(error))
