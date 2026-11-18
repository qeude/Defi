#!/usr/bin/env bash
# Runs script/glitch_bench.py in the defi-e2e VM for one or more staged bundles, leaving the user's desktop alone.
# Usage: script/glitch_vm.sh OUT LABEL=BUNDLE... [-- BENCH ARGS]
# Each bundle runs from ~/defi-glitch/LABEL/Defi.app with its own TCC rows; the guest's installed app,
# config and grants are restored afterwards. DEFI_VM_SECOND_DISPLAY=1 adds a virtual display.
# DEFI_GLITCH_NO_CAPTURE=1 denies the daemons Screen Recording (pass --instant to the bench).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VM="${DEFI_VM:-defi-e2e}"
# shellcheck source=script/vm_session.sh
source "$ROOT_DIR/script/vm_session.sh"

OUT="$1"
shift
BUNDLES=()
while [[ $# -gt 0 && "$1" != -- ]]; do BUNDLES+=("$1"); shift; done
[[ "${1:-}" != -- ]] || shift
BENCH_ARGS=("$@")
[[ ${#BUNDLES[@]} -gt 0 ]] || { echo "usage: $0 OUT LABEL=BUNDLE... [-- BENCH ARGS]" >&2; exit 2; }

if [[ -z "${DEFI_VM_LOCKED:-}" ]]; then
  mkdir -p .build/glitch
  swiftc -O -parse-as-library Tests/Fixtures/PerformanceFixture.swift -o .build/glitch/PerformanceFixture
  swiftc -O Tests/Fixtures/GlitchCamera.swift -o .build/glitch/GlitchCamera
  if [[ "${DEFI_VM_SECOND_DISPLAY:-0}" == 1 ]]; then
    clang -fobjc-arc -w -framework Foundation -framework AppKit -framework CoreGraphics \
      Tests/Fixtures/VirtualDisplayFixture.m -o .build/glitch/DefiVirtualDisplay
  fi
  export DEFI_VM_LOCKED=1
  exec lockf -k "$HOME/.tart/$VM.lock" "$ROOT_DIR/script/glitch_vm.sh" "$OUT" "${BUNDLES[@]}" -- ${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}
fi

# DEFI_VM_RUNNING=1: reuse a guest booted under a lock this shell's parent already holds.
[[ "${DEFI_VM_RUNNING:-0}" == 1 ]] || vm_start
G=/Users/admin/defi-glitch
TCC='/Library/Application Support/com.apple.TCC/TCC.db'
INSTALLED=/Users/admin/Applications/Defi.app/Contents/MacOS/defi-daemon

cleanup() {
  vm "sudo -n launchctl asuser 501 sudo -n -u admin sh -c 'for b in $G/*/Defi.app; do \"\$b/Contents/MacOS/defi\" service stop >/dev/null 2>&1; done'; pkill -x defi-daemon; pkill -f $G/tools; pkill -f PerformanceFixture; pkill -f DefiVirtualDisplay; true" || true
  vm "sudo -n sqlite3 '$TCC' \"delete from access where client like '$G/%';\"; sudo -n pkill tccd; true" || true
  # Put the installed app's Screen Recording row back as it was before the run.
  vm "if [ -f ~/.glitch-capture.orig ]; then v=\$(cat ~/.glitch-capture.orig); [ -z \"\$v\" ] || sudo -n sqlite3 '$TCC' \"update access set auth_value=\$v where client='com.qeude.defi' and service='kTCCServiceScreenCapture';\"; rm -f ~/.glitch-capture.orig; sudo -n pkill tccd; fi; true" || true
  vm "[ ! -f ~/.glitch-approvals.orig ] || mv ~/.glitch-approvals.orig '/Users/admin/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist'" || true
  vm "if [ -f ~/.glitch-config.orig ]; then mv ~/.glitch-config.orig ~/.config/defi/config.toml; else rm -f ~/.config/defi/config.toml; fi; rm -rf $G; sync" || true
  # The guest's installed daemon runs again if it ran before the bench.
  vm "[ ! -f ~/.glitch-daemon-was-running ] || { rm -f ~/.glitch-daemon-was-running; sudo -n launchctl asuser 501 sudo -n -u admin ~/Applications/Defi.app/Contents/MacOS/defi service start >/dev/null 2>&1; }; true" || true
  [[ "${DEFI_VM_RUNNING:-0}" == 1 ]] || { sleep 3; tart stop "$VM" >/dev/null 2>&1 || true; }
}
# DEFI_GLITCH_KEEP=1 leaves the guest prepared for manual experiments; run again without it to clean.
[[ "${DEFI_GLITCH_KEEP:-0}" == 1 ]] || trap cleanup EXIT

vm "[ -f ~/.glitch-daemon-was-running ] || ! pgrep -x defi-daemon >/dev/null || touch ~/.glitch-daemon-was-running; pkill -x defi-daemon; [ ! -x ~/Applications/Defi.app/Contents/MacOS/defi ] || ~/Applications/Defi.app/Contents/MacOS/defi service stop >/dev/null 2>&1; rm -rf $G; mkdir -p $G/tools ~/.config/defi; [ -f ~/.glitch-config.orig ] || [ ! -f ~/.config/defi/config.toml ] || cp ~/.config/defi/config.toml ~/.glitch-config.orig; true"
# A config without its backup is never overwritten: cleanup would then delete it.
vm "[ -f ~/.glitch-config.orig ] || [ ! -f ~/.config/defi/config.toml ] || { echo 'config.toml has no backup' >&2; exit 1; }; printf '[layout]\ndefault_column_width = 0.6\n\n[menu_bar]\nenabled = false\n' > ~/.config/defi/config.toml"
for tool in PerformanceFixture GlitchCamera; do vm "cat > $G/tools/$tool && chmod +x $G/tools/$tool" < ".build/glitch/$tool"; done
vm "cat > $G/glitch_bench.py" < script/glitch_bench.py

grant() { # grant CLIENT SERVICE...: copies the installed daemon's row shape for a path client
  local client="$1"; shift
  for service in "$@"; do
    vm "sudo -n sqlite3 '$TCC' \"insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, flags) values ('$service', '$client', 1, 2, 4, 1, 0);\""
  done
}
grant "$G/tools/GlitchCamera" kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceAccessibility
for entry in "${BUNDLES[@]}"; do
  label="${entry%%=*}" bundle="${entry#*=}"
  vm "mkdir -p $G/$label"
  COPYFILE_DISABLE=1 tar -C "$(dirname "$bundle")" -cf - "$(basename "$bundle")" | vm "tar -C $G/$label -xf -"
  if [[ "${DEFI_GLITCH_NO_CAPTURE:-0}" == 1 ]]; then
    grant "$G/$label/Defi.app/Contents/MacOS/defi-daemon" kTCCServiceAccessibility kTCCServicePostEvent
  else
    grant "$G/$label/Defi.app/Contents/MacOS/defi-daemon" kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent
  fi
done
# macOS's monthly "bypass the private window picker" alert would cover the windows the camera reads.
APPROVALS='/Users/admin/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist'
vm "[ -f ~/.glitch-approvals.orig ] || cp '$APPROVALS' ~/.glitch-approvals.orig; /usr/bin/python3 -c \"
import plistlib, sys, datetime
path = sys.argv[1]
data = plistlib.load(open(path, 'rb'))
now = datetime.datetime.utcnow()
entry = {'kScreenCaptureAlertableUsageCount': 1, 'kScreenCaptureApprovalLastAlerted': now,
         'kScreenCaptureApprovalLastUsed': now, 'kScreenCapturePrivacyHintDate': now + datetime.timedelta(days=30),
         'kScreenCapturePrivacyHintPolicy': 2592000}
for key in sys.argv[2:]:
    data[key] = dict(entry)
plistlib.dump(data, open(path, 'wb'))
\" '$APPROVALS' com.qeude.defi $G/tools/GlitchCamera $(for e in "${BUNDLES[@]}"; do printf "file://$G/%s/Defi.app/ $G/%s/Defi.app/Contents/MacOS/defi-daemon " "${e%%=*}" "${e%%=*}"; done); killall UserNotificationCenter NotificationCenter 2>/dev/null; true"
# A staged daemon opened by its bundle also needs the bundle-id row for Screen Recording.
CAPTURE=2; [[ "${DEFI_GLITCH_NO_CAPTURE:-0}" != 1 ]] || CAPTURE=0
# Saved once, so a killed run keeps the first copy; cleanup restores it.
vm "[ -f ~/.glitch-capture.orig ] || sudo -n sqlite3 '$TCC' \"select auth_value from access where client='com.qeude.defi' and service='kTCCServiceScreenCapture';\" > ~/.glitch-capture.orig"
vm "sudo -n sqlite3 '$TCC' \"update access set auth_value=$CAPTURE where client='com.qeude.defi' and service='kTCCServiceScreenCapture';\"; sudo -n pkill tccd"

if [[ "${DEFI_VM_SECOND_DISPLAY:-0}" == 1 ]]; then
  vm "cat > $G/tools/DefiVirtualDisplay && chmod +x $G/tools/DefiVirtualDisplay" < .build/glitch/DefiVirtualDisplay
  vm "sudo -n launchctl asuser 501 sudo -n -u admin nohup $G/tools/DefiVirtualDisplay >/dev/null 2>&1 & sleep 4"
fi

mkdir -p "$OUT"
for entry in "${BUNDLES[@]}"; do
  label="${entry%%=*}"
  app="$G/$label/Defi.app"
  echo "== $label"
  vm "sudo -n launchctl asuser 501 sudo -n -u admin sh -c '\"$app/Contents/MacOS/defi\" service start >/dev/null; for i in \$(seq 60); do \"$app/Contents/MacOS/defi\" status 2>/dev/null | grep -q ^running && break; sleep 0.5; done; \"$app/Contents/MacOS/defi\" status | tr \" \" \"\\n\" | grep -E \"^(running|windows|overviewPermission|displayHz)\"'"
  vm "killall UserNotificationCenter NotificationCenter 2>/dev/null; true"
  vm "sudo -n launchctl asuser 501 sudo -n -u admin /usr/bin/python3 -u $G/glitch_bench.py $app $G/out-$label ${BENCH_ARGS[*]:-}" 2>&1 | tee "$OUT/$label.log" || true
  vm "sudo -n launchctl asuser 501 sudo -n -u admin \"$app/Contents/MacOS/defi\" service stop >/dev/null 2>&1; pkill -x defi-daemon; log show --last 30m --style compact --predicate 'process == \"defi-daemon\" and messageType == fault' 2>/dev/null | tail -20 > $G/out-$label/faults.txt; ls ~/Library/Logs/DiagnosticReports | grep -i defi > $G/out-$label/crashes.txt; true"
  vm "cd $G/out-$label && tar -cf - --exclude fixtures ." | (mkdir -p "$OUT/$label" && tar -C "$OUT/$label" -xf -)
done
