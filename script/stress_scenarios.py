#!/usr/bin/env python3
"""Real-world stress scenarios for Defi: slow-AX apps, Ghostty windows and
tabs, macOS activation events. Self-restoring: windows opened for the test
are closed by it. Polls border-audit, resources, and window-count pop-in
latency throughout."""

import os
import statistics
import subprocess
import sys
import threading
import time

from defi_ipc import Connection, find_socket

SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0


SOCK = find_socket()
DAEMON_PID = int(
    subprocess.run(
        ["pgrep", "-x", "defi-daemon"], capture_output=True, text=True
    ).stdout.split()[0]
)
CLI = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "defi")


def cli(command):
    subprocess.run([CLI, command], capture_output=True, text=True)


def osascript(script):
    return subprocess.run(
        ["osascript", "-e", script], capture_output=True, text=True
    )


def window_count():
    out = subprocess.run(
        [CLI, "status"], capture_output=True, text=True
    ).stdout
    for token in out.split():
        if token.startswith("windows="):
            return int(token[8:])
    return -1


def border_audit():
    conn = Connection(SOCK)
    message = conn.command("border-audit").get("message", "")
    conn.close()
    worst = mismatches = acceptance = 0
    compared = 0
    for token in message.replace("pt", "").split():
        if token.startswith("worst="):
            worst = float(token[6:])
        if token.startswith("mismatches>2="):
            mismatches = float(token.split("=")[1])
        if token.startswith("compared="):
            compared = int(token[9:])
        if token.startswith("appAcceptance="):
            acceptance = float(token[14:])
    return {
        "worst": worst,
        "mismatches": mismatches,
        "compared": compared,
        "acceptance": acceptance,
    }


samples = []
audits = []
popins = []           # (scenario, seconds_until_count_grew)
stop = threading.Event()
phase_box = ["startup"]


def sample_resources():
    out = subprocess.run(
        ["ps", "-o", "%cpu=,rss=", "-p", str(DAEMON_PID)],
        capture_output=True,
        text=True,
    ).stdout.split()
    return (float(out[0]), int(out[1])) if len(out) >= 2 else None


def sampler():
    while not stop.is_set():
        entry = sample_resources()
        if entry:
            samples.append((phase_box[0], *entry))
        time.sleep(0.4)


def auditor():
    while not stop.is_set():
        try:
            result = border_audit()
            result["phase"] = phase_box[0]
            audits.append(result)
        except Exception:
            pass
        time.sleep(0.5)


def wait_for_window_growth(previous, timeout=5.0):
    started = time.time()
    while time.time() - started < timeout:
        if window_count() > previous:
            return time.time() - started
        time.sleep(0.1)
    return None


def activate(app):
    osascript(f'tell application "{app}" to activate')
    time.sleep(0.3)


results = {"issues": []}

sampler_thread = threading.Thread(target=sampler, daemon=True)
audit_thread = threading.Thread(target=auditor, daemon=True)
sampler_thread.start()
audit_thread.start()


def scenario(name):
    phase_box[0] = name
    print(f"\n=== {name} ===", flush=True)


# --- 1. slow-AX navigation storm: alternate focusing into Xcode/Mail-heavy
# columns with rapid workspace toggling -------------------------------------
scenario("slow-ax-navigation")
baseline_audit = border_audit()
print("baseline:", baseline_audit)
burst_deadline = time.time() + 20 * SCALE
i = 0
while time.time() < burst_deadline:
    cli("focus-column left" if i % 2 == 0 else "focus-column right")
    if i % 6 == 0:
        cli("workspace dev-secondary")
    elif i % 6 == 3:
        cli("workspace web")
    time.sleep(0.05)
    i += 1
after = border_audit()
print("after-burst:", after)
if after["mismatches"] > 0:
    results["issues"].append(
        f"slow-ax-navigation left {after['mismatches']} border mismatches"
    )

# --- 2. new Ghostty windows: pop-in latency + border acquisition -----------
scenario("ghostty-new-windows")
for round_index in range(int(2 * SCALE) + 1):
    before = window_count()
    subprocess.run(["open", "-na", "Ghostty"], capture_output=True)
    elapsed = wait_for_window_growth(before)
    popins.append(("new-window", elapsed))
    print(
        f"window #{round_index+1}: pop-in="
        f"{f'{elapsed:.2f}s' if elapsed else 'TIMEOUT'} "
        f"(count {before}->{window_count()})"
    )
    if elapsed is None:
        results["issues"].append("ghostty window did not register within 5s")
    time.sleep(1.0)

# --- 3. Ghostty second tab (AX ambiguity probe) -----------------------------
scenario("ghostty-second-tab")
activate("Ghostty")
time.sleep(0.5)
before = window_count()
tab = osascript(
    'tell application "System Events" to keystroke "t" using command down'
)
time.sleep(1.2)
grown = window_count() > before
print("cmd+t handled:", grown, "| error:", tab.stderr.strip()[:80])
if tab.returncode != 0:
    results["issues"].append(
        "System Events keystroke failed (automation permission?)"
    )
after_tab = border_audit()
print("with-tab:", after_tab)
# restore: close what the tab opened / the whole test window
osascript(
    'tell application "System Events" to keystroke "w" using {command down}'
)
time.sleep(0.8)
osascript(
    'tell application "System Events" to keystroke "w" using {command down}'
)
time.sleep(0.8)
print("count after close:", window_count())

# --- 4. Cmd+Tab style activation cycling (Dock/alt-tab proxy) ---------------
scenario("activation-cycling")
for app in ["Slack", "Finder", "Ghostty"]:
    activate(app)
    for _ in range(8):
        cli("focus-column right")
        time.sleep(0.08)
after_cycle = border_audit()
print("after-cycling:", after_cycle)
if after_cycle["mismatches"] > 0:
    results["issues"].append(
        f"activation cycling left {after_cycle['mismatches']} mismatches"
    )

stop.set()
sampler_thread.join()
audit_thread.join()

cpus = [s[1] for s in samples]
rss = [s[2] for s in samples]
print("\n=== resources ===")
print(
    f"cpu avg={statistics.mean(cpus):.1f}% max={max(cpus):.1f}% | "
    f"rss {rss[0]/1024:.1f}->{rss[-1]/1024:.1f}MB | samples={len(samples)}"
)
if audits:
    worst_series = sorted(a["worst"] for a in audits)
    mismatch_audits = sum(1 for a in audits if a["mismatches"] > 0)
    accept = max(a["acceptance"] for a in audits)
    print(
        f"border: worst-ever={max(worst_series):.2f}pt "
        f"p95={worst_series[int(len(worst_series)*0.95)]:.2f}pt "
        f"audits-with-mismatch={mismatch_audits}/{len(audits)} "
        f"appAcceptanceMax={accept:.2f}pt"
    )
popin_times = [p[1] for p in popins if p[1] is not None]
timed_out = sum(1 for p in popins if p[1] is None)
if popin_times:
    print(
        f"pop-in: n={len(popin_times)} median="
        f"{statistics.median(popin_times):.2f}s max={max(popin_times):.2f}s "
        f"timeouts={timed_out}"
    )
status_now = subprocess.run(
    [CLI, "status"], capture_output=True, text=True
).stdout
for token in status_now.split():
    if token.startswith(("drift=", "parkingRepairs=")):
        print(token, end=" ")
print()
if results["issues"]:
    print("\nISSUES:")
    for issue in results["issues"]:
        print(" -", issue)
else:
    print("\nno issues flagged")
