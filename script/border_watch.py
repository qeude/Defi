#!/usr/bin/env python3
"""Watches border/window alignment at 5 Hz. When divergence exceeds 8 pt,
captures ground truth (on-screen frames + engine view + trace tail) to
/tmp/border-stuck-<ts>.txt once per episode. Run while reproducing."""

import os
import re
import subprocess
import time

from defi_ipc import Connection, find_socket

CLI = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "defi")
THRESHOLD_PT = 8.0


SOCK = find_socket()


def command(name):
    conn = Connection(SOCK)
    try:
        return conn.command(name).get("message", "")
    except (ValueError, TypeError):
        return ""
    finally:
        conn.close()


def daemon_frames():
    out = subprocess.run(
        ["swift", os.path.join(os.path.dirname(__file__), "frame_dump.swift")],
        capture_output=True,
        text=True,
        env={**os.environ, "DAEMON_PID": daemon_pid()},
    ).stdout
    return out


def daemon_pid():
    return subprocess.run(
        ["pgrep", "-x", "defi-daemon"], capture_output=True, text=True
    ).stdout.strip()


def trace_tail():
    return subprocess.run(
        [CLI, "trace"], capture_output=True, text=True
    ).stdout[-3000:]


episode_cooldown_until = 0.0

print(f"watching (threshold {THRESHOLD_PT}pt) — reproduce now, ctrl+c to stop")
while True:
    message = command("border-audit")
    m = re.search(r"worst=([\d.]+)", message)
    worst = float(m.group(1)) if m else 0.0
    stamp = time.strftime("%H:%M:%S")
    flag = ""
    now = time.time()
    if worst > THRESHOLD_PT and now > episode_cooldown_until:
        episode_cooldown_until = now + 5
        path = f"/tmp/border-stuck-{int(now)}.txt"
        with open(path, "w") as fh:
            fh.write(f"=== border-audit ===\n{message}\n")
            fh.write(f"=== real frames ===\n{daemon_frames()}\n")
            fh.write(f"=== status (border/drift) ===\n")
            fh.write(
                "\n".join(
                    t
                    for t in command("status").split()
                    if t.startswith(("drift", "border", "focused", "windows"))
                )
                + "\n"
            )
            fh.write(f"=== trace tail ===\n{trace_tail()}\n")
        flag = f"  CAPTURED -> {path}"
    print(f"\r{stamp} worst={worst:7.2f}pt {message[:60]}{flag}", end="", flush=True)
    time.sleep(0.2)
