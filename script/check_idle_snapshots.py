#!/usr/bin/env python3
"""Detect a self-sustaining snapshot loop in the installed, idle daemon."""

import pathlib
import subprocess
import time

cli = pathlib.Path.home() / "Applications/Defi.app/Contents/MacOS/defi"


def status():
    output = subprocess.check_output([str(cli), "status"], text=True)
    return dict(part.split("=", 1) for part in output.split() if "=" in part)


before = status()
time.sleep(2)
after = status()
if before["events"] != after["events"]:
    raise SystemExit("Desktop events occurred; retry with the desktop idle.")
count = sum(map(int, after["snapshots"].split("/"))) - sum(
    map(int, before["snapshots"].split("/"))
)
print(f"Idle snapshots in two seconds: {count}")
# Fallback discovery may run at 0.3 s; snapshot completion must not drive a loop.
if not 0 <= count <= 10:
    raise SystemExit("Unexpected idle snapshot rate (or daemon restart).")
