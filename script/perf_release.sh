#!/usr/bin/env bash
# Release performance check: runs the real daemon of a candidate and of the previous release in the
# windowless defi-e2e Tart VM, in alternating rounds, then reports the PERFORMANCE.md budgets and any
# regression beyond noise. Never touches the user's desktop or installed app.
# Usage: script/perf_release.sh [BASE_REF [CANDIDATE_REF]]  (default: the latest tag before HEAD, and HEAD)
# DEFI_PERF_ROUNDS (5) rounds per build and DEFI_PERF_NAVIGATIONS (120) commands per round.
# Results land in dist/perf/<run>/; a candidate with a new version is also stored as perf/releases/v<version>.*
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VM="${DEFI_VM:-defi-e2e}"
# shellcheck source=script/vm_session.sh
source "$ROOT_DIR/script/vm_session.sh"
command -v tart >/dev/null || { echo "Install Tart first: https://tart.run" >&2; exit 2; }
tart get "$VM" >/dev/null || { echo "Create the $VM VM first; see CONTRIBUTING.md" >&2; exit 2; }
ROUNDS="${DEFI_PERF_ROUNDS:-5}"
NAVIGATIONS="${DEFI_PERF_NAVIGATIONS:-120}" # the daemon keeps the latest 120 samples per metric
WINDOWS=6

# Build both refs from clean worktrees before queueing on the VM lock.
if [[ -z "${DEFI_VM_LOCKED:-}" ]]; then
  base_ref="${1:-$(git describe --tags --abbrev=0 HEAD^)}"
  candidate_ref="${2:-HEAD}"
  run="$ROOT_DIR/dist/perf/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run/out"
  builds='{}'
  labels=()
  for ref in "$base_ref" "$candidate_ref"; do
    label="$(git describe --tags --always "$ref")"
    source="$run/src/$label"
    git worktree add -q --detach "$source" "$ref"
    DEFI_STAGING_ROOT="$run/$label" "$source/script/build_and_run.sh" --stage
    git worktree remove --force "$source"
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$run/$label/Defi.app/Contents/Info.plist")"
    builds="$(jq --arg l "$label" --arg r "$ref" --arg c "$(git rev-parse "$ref^{commit}")" --arg v "$version" \
      '.[$l] = {ref: $r, commit: $c, version: $v}' <<<"$builds")"
    labels+=("$label")
  done
  [[ "${labels[0]}" != "${labels[1]}" ]] || { echo "Base and candidate are the same commit" >&2; exit 2; }
  rmdir "$run/src"

  fixture="$run/Fixture.app/Contents"
  mkdir -p "$fixture/MacOS"
  swiftc -O -swift-version 6 -parse-as-library Tests/Fixtures/PerformanceFixture.swift -o "$fixture/MacOS/PerformanceFixture"
  plutil -create xml1 "$fixture/Info.plist"
  plutil -insert CFBundleIdentifier -string com.qeude.defi.performancefixture "$fixture/Info.plist"
  plutil -insert CFBundleExecutable -string PerformanceFixture "$fixture/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$fixture/Info.plist"

  jq -n --argjson builds "$builds" --arg vm "$VM" --arg host "$(sysctl -n hw.model) macOS $(sw_vers -productVersion)" \
    --argjson rounds "$ROUNDS" --argjson navigations "$NAVIGATIONS" --argjson windows "$WINDOWS" \
    '{builds: $builds, vm: $vm, host: $host, rounds: $rounds, navigations: $navigations, windows: $windows}' \
    > "$run/meta.json"
  export DEFI_VM_LOCKED=1
  exec lockf -k "$HOME/.tart/$VM.lock" "$ROOT_DIR/script/perf_release.sh" "$run" "${labels[@]}"
fi

run="$1" base="$2" candidate="$3"
vm_start
vm 'mkdir -p ~/defi-perf && cd ~/defi-perf && find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
COPYFILE_DISABLE=1 tar -C "$run" -cf - "$base" "$candidate" Fixture.app | vm 'tar -C ~/defi-perf -xf -'
vm 'cat > ~/defi-perf/perf_guest.sh && chmod +x ~/defi-perf/perf_guest.sh' < script/perf_guest.sh
# launchctl asuser places the daemons and fixtures in the guest's GUI session.
vm "sudo -n launchctl asuser 501 sudo -n -u admin ~/defi-perf/perf_guest.sh $ROUNDS $NAVIGATIONS $WINDOWS '$base' '$candidate'"
vm 'tar -C ~/defi-perf -cf - out' | tar -C "$run" -xf -
meta="$(jq --arg guest "macOS $(vm 'sw_vers -productVersion') $(vm 'sysctl -n hw.ncpu') CPU" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {guest: $guest, measured_at: $at}' "$run/meta.json")"
printf '%s\n' "$meta" > "$run/meta.json"

python3 script/perf_report.py "$run" "$base" "$candidate"
base_version="$(jq -r --arg l "$base" '.builds[$l].version' "$run/results.json")"
candidate_version="$(jq -r --arg l "$candidate" '.builds[$l].version' "$run/results.json")"
if [[ "$candidate_version" != "$base_version" ]]; then
  mkdir -p perf/releases
  cp "$run/results.json" "perf/releases/v$candidate_version.json"
  cp "$run/report.md" "perf/releases/v$candidate_version.md"
  echo "Stored perf/releases/v$candidate_version.{json,md}; commit them with the release."
fi
echo "Report: $run/report.md"
