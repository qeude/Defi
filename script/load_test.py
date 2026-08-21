#!/usr/bin/env python3
"""Load test for the Defi daemon.

Phases (scale factor as first arg, default 1.0):
  idle    20s  no commands - resource baseline
  warm    15s  ~20 cmd/s  focus-column alternation
  burst   45s  ~60 cmd/s  mixed navigation, workspace switches, resizes
  cooldown 15s no commands

Samples daemon %CPU / RSS / thread count at 2.5 Hz and polls the
border-audit probe at 1 Hz throughout. Prints a per-phase report.
"""

import glob
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time

SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0


def find_socket():
    candidates = (
        glob.glob("/tmp/defi-*.sock")
        + glob.glob("/var/folders/*/*/T/defi-*.sock")
        + glob.glob(os.path.join(os.environ.get("TMPDIR", ""), "defi-*.sock"))
    )
    live = [c for c in candidates if os.path.exists(c)]
    if not live:
        sys.exit("defi socket not found")
    return max(live, key=os.path.getmtime)


SOCK = find_socket()
DAEMON_PID = int(
    subprocess.run(
        ["pgrep", "-x", "defi-daemon"], capture_output=True, text=True
    ).stdout.split()[0]
)


class Connection:
    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)
        self.file = self.sock.makefile("rb")

    def command(self, command):
        payload = json.dumps({"command": command, "monitorIndex": None})
        self.sock.sendall((payload + "\n").encode())
        line = self.file.readline()
        return json.loads(line) if line else {"ok": False}


def sample_resources():
    out = subprocess.run(
        ["ps", "-o", "%cpu=,rss=", "-p", str(DAEMON_PID)],
        capture_output=True,
        text=True,
    ).stdout.split()
    if len(out) < 2:
        return None
    cpu, rss = float(out[0]), int(out[1])
    threads_out = subprocess.run(
        ["ps", "-M", str(DAEMON_PID)], capture_output=True, text=True
    ).stdout
    threads = max(threads_out.count("\n") - 1, 0)
    return cpu, rss, threads


samples = []          # (phase, t, cpu, rss_kb, threads)
audits = []           # (phase, worst_pt, mismatches)
cmd_stats = {"sent": 0, "errors": 0, "rejected": 0, "recycled": 0}
stop_sampler = threading.Event()


def sampler(phase_box):
    while not stop_sampler.is_set():
        entry = sample_resources()
        if entry:
            samples.append((phase_box[0], time.time(), *entry))
        time.sleep(0.4)


def audit_loop(phase_box):
    while not stop_sampler.is_set():
        try:
            conn = Connection()
            answer = conn.command("border-audit")
            conn.sock.close()
            message = answer.get("message", "")
            worst = mismatches = acceptance = 0
            for token in message.replace("pt", "").split():
                if token.startswith("worst="):
                    worst = float(token[6:])
                if token.startswith("mismatches>2="):
                    mismatches = float(token.split("=")[1])
                if token.startswith("appAcceptance="):
                    acceptance = float(token.split("=")[1])
            audits.append((phase_box[0], worst, mismatches, acceptance))
        except Exception:
            pass
        time.sleep(1.0)


def drive_load(duration, rate, commands):
    try:
        conn = Connection()
    except Exception:
        return
    interval = 1.0 / rate
    deadline = time.time() + duration
    next_send = time.time()
    while time.time() < deadline:
        cmd = commands[cmd_stats["sent"] % len(commands)]
        try:
            answer = conn.command(cmd)
            cmd_stats["sent"] += 1
            if not answer.get("ok"):
                cmd_stats["rejected"] += 1
        except Exception:
            cmd_stats["recycled"] += 1
            try:
                conn.sock.close()
            except Exception:
                pass
            time.sleep(0.05)
            try:
                conn = Connection()
            except Exception:
                return
        next_send += interval
        sleep_for = next_send - time.time()
        if sleep_for > 0:
            time.sleep(sleep_for)
        else:
            next_send = time.time()
    conn.sock.close()


navigation = ["focus-column left", "focus-column right"]
import glob as _glob
_ws = []
try:
    _probe = Connection()
    for line in _probe.command("list-workspaces")["message"].split("\n"):
        name = line.strip()
        if name:
            _ws.append("workspace " + name)
    _probe.sock.close()
except Exception:
    pass
if len(_ws) < 2:
    sys.exit("need at least two named workspaces for the mixed phase")

mixed = [
    "focus-column left",
    "focus-column right",
    _ws[0],
    _ws[1],
    "cycle-width left",
    "cycle-width right",
    "maximize-column",
]

phases = [
    ("idle", 20 * SCALE, 0, None),
    ("warm", 15 * SCALE, 20, navigation),
    ("burst", 45 * SCALE, 60, mixed),
    ("cooldown", 15 * SCALE, 0, None),
]

phase_box = ["startup"]
sampler_thread = threading.Thread(target=sampler, args=(phase_box,))
audit_thread = threading.Thread(target=audit_loop, args=(phase_box,))
sampler_thread.start()
audit_thread.start()

for name, duration, rate, commands in phases:
    phase_box[0] = name
    print(f"[{name}] {duration:.0f}s ...", flush=True)
    if rate:
        drive_load(duration, rate, commands)
    else:
        time.sleep(duration)

stop_sampler.set()
sampler_thread.join()
audit_thread.join()


def report_phase(name):
    rows = [s for s in samples if s[0] == name]
    if not rows:
        return f"{name:9} no samples"
    cpus = [r[2] for r in rows]
    rss = [r[3] for r in rows]
    threads = [r[4] for r in rows]
    span_minutes = max(rows[-1][1] - rows[0][1], 0.001) / 60
    slope = (rss[-1] - rss[0]) / 1024 / span_minutes
    return (
        f"{name:9} cpu avg={statistics.mean(cpus):5.1f}% max={max(cpus):5.1f}% "
        f"rss {rss[0]/1024:5.1f}->{rss[-1]/1024:5.1f}MB "
        f"(slope {slope:+.2f}MB/min) threads max={max(threads)}"
    )


print("\n=== resources ===")
for name, *_ in phases:
    print(report_phase(name))
border_rows = [(a[1], a[2], a[3]) for a in audits]
if border_rows:
    target_worst = sorted(w for w, _, _ in border_rows)
    acceptance_worst = sorted(a for _, _, a in border_rows)
    mismatch_samples = sum(1 for _, m, _ in border_rows if m > 0)
    print("\n=== border alignment ===")
    print(
        f"audits={len(border_rows)} "
        f"daemon-sync(target) p95={target_worst[int(len(target_worst)*0.95)]:.2f}pt "
        f"ever={max(target_worst):.2f}pt | "
        f"app-acceptance p95={acceptance_worst[int(len(acceptance_worst)*0.95)]:.2f}pt "
        f"ever={max(acceptance_worst):.2f}pt | "
        f"pass-with-mismatch={mismatch_samples}"
    )
else:
    print("\nno border audits collected")
print(
    f"\ncommands sent={cmd_stats['sent']} "
    f"rejected={cmd_stats['rejected']} "
    f"connections-recycled={cmd_stats['recycled']}"
)
