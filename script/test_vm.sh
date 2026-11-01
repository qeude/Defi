#!/usr/bin/env bash
# Runs DesktopE2ETests in a windowless Tart VM, leaving the user's desktop untouched.
# Usage: script/test_vm.sh [DesktopE2ETests[/testName]]
# DEFI_VM_SECOND_DISPLAY=1 adds a virtual display to the guest. The VM always stops afterwards to free its memory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VM="${DEFI_VM:-defi-e2e}"
command -v tart >/dev/null || { echo "Install Tart first: https://tart.run" >&2; exit 2; }
KEY="$HOME/.tart/${VM}_ed25519"
FILTER="${1:-DesktopE2ETests}"
[[ "$FILTER" == DesktopE2ETests* ]] || { echo "Filter must start with DesktopE2ETests" >&2; exit 2; }
tart get "$VM" >/dev/null || {
  echo "Create the VM first: tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest $VM && tart set $VM --cpu 4 --memory 4096" >&2
  exit 2
}

vm() {
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
    "admin@$(tart ip "$VM")" "$@"
}

# Build before queueing. Concurrent runs would share one guest desktop, and one could stop the VM under another.
if [[ -z "${DEFI_VM_LOCKED:-}" ]]; then
  ./script/test_desktop.sh --build-tests
  if [[ "${DEFI_VM_SECOND_DISPLAY:-0}" == 1 ]]; then
    clang -fobjc-arc -w -framework Foundation -framework AppKit -framework CoreGraphics \
      Tests/Fixtures/VirtualDisplayFixture.m -o .build/desktop-fixtures/DefiVirtualDisplay
  fi
  export DEFI_VM_LOCKED=1
  exec python3 -c 'import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.dup2(fd, 9)
os.execvp(sys.argv[2], sys.argv[2:])' "$HOME/.tart/$VM.lock" "$ROOT_DIR/script/test_vm.sh" "$@"
fi

# Restart a VM left running: it may lack the Xcode share. Holding the lock makes this safe.
tart stop "$VM" >/dev/null 2>&1 || true
XCODE="$(cd "$(xcode-select -p)/../.." && pwd)"
nohup tart run "$VM" --no-graphics "--dir=xcode:$XCODE:ro" >/dev/null 2>&1 9>&- &
trap 'tart stop "$VM" >/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tart ip "$VM" --wait 180 >/dev/null
for attempt in {1..60}; do
  tart exec "$VM" /usr/bin/true 2>/dev/null && break
  [[ "$attempt" -lt 60 ]] || { echo "The VM guest agent did not answer" >&2; exit 1; }
  sleep 2
done
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "$VM" -f "$KEY"
tart exec "$VM" /bin/sh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qsF '$(cat "$KEY.pub")' ~/.ssh/authorized_keys || echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
vm 'sudo -n mdutil -a -i off >/dev/null 2>&1; defaults write com.apple.WindowManager StandardHideWidgets -int 1; mkdir -p ~/defi-e2e'

# Trim services Defi never touches; launchd keeps this across reboots, so it applies from the next boot.
vm 'sudo -n sh -s' <<'GUEST'
[ ! -e /var/db/defi-e2e-tuned ] || exit 0
pattern='intelligen|siri|workflow|shortcut|imagent|imtransfer|facetime|cloud|bird|photo|mediaanalysis|knowledge|suggest|parsec|maps|news|weather|stocks|calendar|remind|game|music|podcast|appstore|commerce|triald|modelcatalog|generative|homed|backupd|corespotlight|biome'
for plist in /System/Library/LaunchAgents/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "gui/501/$label"; fi
done
for plist in /System/Library/LaunchDaemons/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "system/$label"; fi
done
# The image's login-item banner would otherwise stay up and block the pointer hit test.
rm -rf "/Users/admin/Library/Group Containers/group.com.apple.usernoted/db2"
pkill -x usernoted
pkill -x NotificationCenter
touch /var/db/defi-e2e-tuned
GUEST

# Post-boot daemons saturate the guest and would slow the tests' own timing.
# Read instantaneous idle time: the load average keeps decaying for minutes after the burst ends.
calm=0
for _ in {1..60}; do
  if [[ "$(vm "top -l 2 -s 3 -n 0 | awk '/CPU usage/ {idle = \$7} END {print int(idle)}'")" -ge 70 ]]; then calm=$((calm + 1)); else calm=0; fi
  [[ "$calm" -ge 3 ]] && break
done

COPYFILE_DISABLE=1 tar -C .build/debug -cf - DefiMacOSTests.xctest $(cd .build/debug && ls -d ./*.bundle 2>/dev/null) | vm 'tar -C ~/defi-e2e -xf -'
vm 'cat > ~/defi-e2e/fixture && chmod +x ~/defi-e2e/fixture' < .build/desktop-fixtures/DefiDesktopFocusFixture
if [[ "${DEFI_VM_SECOND_DISPLAY:-0}" == 1 ]]; then
  vm 'cat > ~/defi-e2e/DefiVirtualDisplay && chmod +x ~/defi-e2e/DefiVirtualDisplay' < .build/desktop-fixtures/DefiVirtualDisplay
  vm 'sudo -n launchctl asuser 501 sudo -n -u admin nohup ~/defi-e2e/DefiVirtualDisplay >/dev/null 2>&1 & sleep 4'
fi
vm 'cat > ~/defi-e2e/run.sh && chmod +x ~/defi-e2e/run.sh' <<'GUEST'
#!/bin/sh
X="/Volumes/My Shared Files/xcode/Contents/Developer"
P="$X/Platforms/MacOSX.platform/Developer"
cd ~/defi-e2e
exec /usr/bin/env DEVELOPER_DIR="$X" DEFI_E2E=1 DEFI_DESKTOP_FIXTURE_BINARY="$HOME/defi-e2e/fixture" \
  DEFI_E2E_FIXTURE_DISCOVERY_SECONDS=20 \
  DYLD_FRAMEWORK_PATH="$P/Library/Frameworks:$P/Library/PrivateFrameworks" \
  DYLD_LIBRARY_PATH="$P/usr/lib:$X/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" \
  "$X/usr/bin/xctest" -XCTest "DefiMacOSTests.$1" "$HOME/defi-e2e/DefiMacOSTests.xctest"
GUEST

# A daemon installed for manual checks would fight the tests' frame writes.
vm '[ ! -x ~/Applications/Defi.app/Contents/MacOS/defi ] || ~/Applications/Defi.app/Contents/MacOS/defi service stop >/dev/null 2>&1; pkill -x defi-daemon; for a in TextEdit Calculator Notes "System Settings"; do pkill -x "$a"; done; true'
# The first AppKit launch after boot is slow; warm it so the first test does not pay for a cold cache.
vm 'sudo -n launchctl asuser 501 sudo -n -u admin sh -c "sleep 3 | ~/defi-e2e/fixture warmup >/dev/null 2>&1"' || true
echo "VM lane: $(vm csrutil status) A pass here does not certify SIP-enabled behavior; use verify.py desktop for that."
# launchctl asuser places the tests in the guest's GUI session; the image already grants its SSH path TCC access.
vm "sudo -n launchctl asuser 501 sudo -n -u admin ~/defi-e2e/run.sh '$FILTER'"
