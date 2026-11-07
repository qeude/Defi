#!/usr/bin/env bash
# Runs DesktopE2ETests in a windowless Tart VM, leaving the user's desktop untouched.
# Usage: script/test_vm.sh [DesktopE2ETests[/testName]]
# DEFI_VM_SECOND_DISPLAY=1 adds a virtual display to the guest. The VM always stops afterwards to free its memory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VM="${DEFI_VM:-defi-e2e}"
# shellcheck source=script/vm_session.sh
source "$ROOT_DIR/script/vm_session.sh"
command -v tart >/dev/null || { echo "Install Tart first: https://tart.run" >&2; exit 2; }
FILTER="${1:-DesktopE2ETests}"
[[ "$FILTER" == DesktopE2ETests* ]] || { echo "Filter must start with DesktopE2ETests" >&2; exit 2; }
tart get "$VM" >/dev/null || {
  echo "Create the VM first: tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest $VM && tart set $VM --cpu 4 --memory 4096" >&2
  exit 2
}

# Build before queueing. Concurrent runs would share one guest desktop, and one could stop the VM under another.
if [[ -z "${DEFI_VM_LOCKED:-}" ]]; then
  ./script/test_desktop.sh --build-tests
  if [[ "${DEFI_VM_SECOND_DISPLAY:-0}" == 1 ]]; then
    clang -fobjc-arc -w -framework Foundation -framework AppKit -framework CoreGraphics \
      Tests/Fixtures/VirtualDisplayFixture.m -o .build/desktop-fixtures/DefiVirtualDisplay
  fi
  export DEFI_VM_LOCKED=1
  exec lockf -k "$HOME/.tart/$VM.lock" "$ROOT_DIR/script/test_vm.sh" "$@"
fi

vm_start

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
echo "VM lane: $(vm csrutil status) A pass here does not certify SIP-enabled behavior; use verify.sh desktop for that."
# launchctl asuser places the tests in the guest's GUI session; the image already grants its SSH path TCC access.
vm "sudo -n launchctl asuser 501 sudo -n -u admin ~/defi-e2e/run.sh '$FILTER'"
