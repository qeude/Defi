#!/usr/bin/env bash
# Build and test without the desktop, then verify a prepared bundle with the desktop reserved.
#   verify.sh local [--stage]                     build, Swift tests without the desktop, workflow tests
#   verify.sh desktop RUN [--filter F] [--wait]   install RUN's staged bundle and run the desktop tests
#   verify.sh full [--filter F]                   local --stage, then desktop, waiting for the reservation
#   verify.sh status [RUN]                        live reports and the desktop owner
# Each run writes dist/verification/<run>/result.json. Exit 75 means the desktop is busy.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script"
INSTALLED="$HOME/Applications/Defi.app"
FILTER=DesktopE2ETests
WAIT=0
STAGE=0
LOCKED=0
INTERRUPTED=0
STEP_PID=""
LOCK_PID=""

usage() { sed -n '3,6p' "$0" | sed 's/^# *//' >&2; exit 2; }

report() { # report JQ_FILTER [JQ_ARGS...]: update result.json atomically
  local filter=$1
  shift
  jq "$@" "$filter | .updated_at = now" "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
}

value() { jq -r "$@" "$REPORT"; }

source_identity() {
  local digest
  digest="$(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | LC_ALL=C sort -zu \
    | xargs -0 shasum -a 256 2>&1 | shasum -a 256 | cut -d' ' -f1)"
  jq -cn --arg commit "$(git -C "$ROOT" rev-parse HEAD)" --arg sha256 "$digest" '{commit: $commit, sha256: $sha256}'
}

bundle_digest() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | cut -d' ' -f1
}

die() { # die MESSAGE [STATUS] [EXIT]: record the failure and stop
  report '.error = $error | if .status == "running" then .status = $status else . end' \
    --arg error "$1" --arg status "${2:-failed}"
  echo "$1" >&2
  exit "${3:-1}"
}

interrupted() {
  report '.status = "interrupted"'
  exit 130
}

kill_tree() { # kill_tree SIGNAL PID: signal a process and every descendant
  local child
  for child in $(pgrep -P "$2"); do kill_tree "$1" "$child"; done
  kill "-$1" "$2" 2>/dev/null
}

# Background commands ignore SIGINT without a terminal, so interruptions travel as SIGTERM down the
# process tree. The lock holder runs in its own process group: lockf releases the reservation on
# SIGTERM while its child still runs, so a signal to our group must reach only us.
on_signal() {
  [[ "$INTERRUPTED" -eq 0 ]] || return
  INTERRUPTED=1
  if [[ -n "$LOCK_PID" ]]; then
    # The locked phase restores the session itself; stop the lock holder only while it still waits.
    local holder
    holder="$(pgrep -P "$LOCK_PID" -f -- __locked)" # not the busy probe desktop_lock.sh may run
    if [[ -n "$holder" ]]; then kill -TERM $holder; else kill -TERM "$LOCK_PID"; fi
  elif [[ -n "$STEP_PID" ]]; then
    kill_tree TERM "$STEP_PID"
    (sleep 15 && kill -0 "$STEP_PID" && kill_tree KILL "$STEP_PID") >/dev/null 2>&1 &
  fi
}

finish() {
  [[ "$(value .status)" != running ]] || report '.status = "failed" | .error = (.error // "Verification stopped unexpectedly")'
  report .
  [[ "$LOCKED" -eq 1 ]] || echo "$(value .status): $REPORT"
}

wait_for() { # wait_for PID: wait through signal interruptions, then return its exit status
  local code=0
  while :; do
    wait "$1"
    code=$?
    kill -0 "$1" 2>/dev/null || return "$code"
  done
}

run_step() { # run_step NAME COMMAND...: log the command to RUN/NAME.log and fail when it fails
  local name=$1 log="$RUN/$1.log" code
  shift
  # After an interruption only the session restore and its diagnostics still run.
  [[ "$INTERRUPTED" -eq 0 || " restore-session status-after trace-after " == *" $name "* ]] || return 1
  report '.steps += [{name: $name, command: $command, log: $log, status: "running", started_at: now}]
          | .phase = $name | .phase_started_at = now' \
    --arg name "$name" --arg log "$log" --argjson command "$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]')"
  echo "${name}… $log"
  "$@" > "$log" 2>&1 &
  STEP_PID=$!
  wait_for "$STEP_PID"
  code=$?
  STEP_PID=""
  report '.steps[-1] |= (.seconds = ((now - .started_at) * 1000 | round / 1000) | del(.started_at)
          | .exit_code = $code | .status = $status)' \
    --argjson code "$code" --arg status "$(if [[ "$code" -eq 0 ]]; then echo passed
      elif [[ "$INTERRUPTED" -eq 1 ]]; then echo interrupted; else echo failed; fi)"
  [[ "$code" -eq 0 ]] && return 0
  tail -n 25 "$log" >&2
  return 1
}

step() { # step NAME COMMAND...: run_step, stopping the run on failure or interruption
  run_step "$@" && return 0
  [[ "$INTERRUPTED" -eq 0 ]] || interrupted
  die "$1 failed"
}

same_source() { [[ "$(source_identity)" == "$(value -c .source)" ]]; }

# Reads XCTest's serial case events: SwiftPM's parallel xUnit writer reports skipped cases as passing.
# Prints {tests, failed, skipped, not_run} and writes desktop.xml; fails on missing completions.
desktop_counts() {
  local log=$1 started finished
  started="$(sed -nE "s/^Test Case '(.+)' started\.$/\1/p" "$log" | LC_ALL=C sort)"
  finished="$(sed -nE "s/^Test Case '(.+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.$/\1/p" "$log" | LC_ALL=C sort)"
  [[ "$started" == "$finished" ]] || { echo "Incomplete XCTest case events; inspect desktop-tests.log" >&2; return 1; }
  # A lane that cannot run here (two displays, opt-in perf) names itself; any other skip is a gap.
  sed -nE "s/^Test Case '(.+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.$/\1	\2	\3/p; s/^DEFI_E2E not-run lane=([^ ]+) test=(.+) reason=(.*)$/marker	\1	\2	\3/p" "$log" \
    | jq -c -R -s '
      def method: rtrimstr("]") | split(" ") | last;
      split("\n") | map(select(length > 0) | split("\t")) as $rows
      | ($rows | map(select(.[0] == "marker") | {key: (.[2] | method), value: {lane: .[1], reason: .[3]}}) | from_entries) as $markers
      | ($rows | map(select(.[0] != "marker") | {name: .[0], state: .[1], seconds: .[2]})) as $cases
      | ($cases | map(select(.state == "skipped"))) as $skipped
      | {tests: ($cases | length), failed: ($cases | map(select(.state == "failed")) | length),
         skipped: ($skipped | map(select($markers[.name | method] == null)) | length),
         not_run: (reduce ($skipped[] | (.name | method) as $m | select($markers[$m]) | {m: $m} + $markers[$m]) as $r
                   ({}; .[$r.lane][$r.m] = $r.reason)),
         xml: ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<testsuite name=\"DesktopE2ETests\" tests=\"\($cases | length)\" skipped=\"\($skipped | length)\" failures=\"\($cases | map(select(.state == "failed")) | length)\">"
               + ($cases | map("<testcase name=\"\(.name | @html)\" time=\"\(.seconds)\">"
                   + (if .state == "passed" then ""
                      else "<\(if .state == "skipped" then "skipped" else "failure" end) message=\"\(($markers[.name | method] // {}) | [.lane, .reason] | map(select(.)) | join(" ") | @html)\" />" end)
                   + "</testcase>") | join(""))
               + "</testsuite>\n")}' \
    | { read -r json; jq -r .xml <<< "$json" > "$RUN/desktop.xml"; jq -c 'del(.xml)' <<< "$json"; }
}

locked() { # The desktop phase, run by desktop_lock.sh with the reservation held.
  local bundle sha checkpoint error="" counts log daemons
  bundle="$(value .bundle)"
  sha="$(value .bundle_sha256)"
  FILTER="$(value .filter)"
  checkpoint="$RUN/checkpoint"
  report '.desktop_wait_seconds = ((now - .phase_started_at) * 1000 | round / 1000)'
  # Another writer may have changed this worktree while we waited.
  same_source || die "Source changed before desktop reservation; rerun local --stage" invalidated
  [[ -d "$bundle" && "$(bundle_digest "$bundle")" == "$sha" ]] \
    || die "Prepared bundle changed before desktop reservation; rerun local --stage" invalidated
  if ! run_step checkpoint "$SCRIPT/desktop_session.sh" checkpoint "$checkpoint"; then
    error="checkpoint failed"
  elif ! run_step install "$SCRIPT/build_and_run.sh" --install-staged "$bundle" --verify; then
    error="install failed"
  elif [[ "$(bundle_digest "$INSTALLED")" != "$sha" ]]; then
    error="Installed bundle differs from the verified artifact"
  else
    if ! run_step status-before "$INSTALLED/Contents/MacOS/defi" status; then
      error="status-before failed"
    else
      report '.daemons = {before: $count}' --argjson count "$("$SCRIPT/desktop_session.sh" daemons)"
      run_step desktop-tests "$SCRIPT/test_desktop.sh" --run-built-tests "$FILTER" || error="desktop-tests failed"
    fi
    log="$RUN/desktop-tests.log"
    [[ -e "$log" ]] || : > "$log"
    report '.accessibility = $value' --arg value "$(
      if grep -q "DEFI_E2E accessibility=unavailable" "$log"; then echo unavailable
      elif grep -q "DEFI_E2E accessibility=available" "$log"; then echo available
      else echo unknown; fi)"
    if counts="$(desktop_counts "$log" 2>&1)"; then
      report '.desktop = $counts' --argjson counts "$counts"
    else
      report '.desktop_parse_error = $error' --arg error "$counts"
    fi
    # Diagnostics only; a failure here still fails the run below.
    run_step status-after "$INSTALLED/Contents/MacOS/defi" status
    run_step trace-after "$INSTALLED/Contents/MacOS/defi" trace
    if [[ -z "$error" ]]; then
      if ! counts="$(desktop_counts "$log" 2>&1)"; then
        error="$counts"
      elif ! jq -e '.tests > 0 and .skipped == 0 and .failed == 0' <<< "$counts" >/dev/null; then
        report '.status = "incomplete"'
        error="Desktop coverage incomplete: $counts"
      fi
    fi
  fi
  if [[ -e "$checkpoint/ready" ]]; then
    if run_step restore-session "$SCRIPT/desktop_session.sh" restore "$checkpoint"; then
      report '.restoration = "passed"'
    else
      report '.restoration = "failed" | .restoration_error = "restore-session failed"'
      error="restore-session failed"
    fi
    daemons="$("$SCRIPT/desktop_session.sh" daemons)"
    report '.daemons.after = $count' --argjson count "$daemons"
    if [[ -z "$error" ]] && ! jq -e '.daemons == {before: 1, after: 1}' "$REPORT" >/dev/null; then
      error="Expected exactly one defi-daemon: $(value -c .daemons)"
    fi
  fi
  [[ "$INTERRUPTED" -eq 0 ]] || interrupted
  [[ -z "$error" ]] || die "$error"
  conclude
}

conclude() {
  [[ "$INTERRUPTED" -eq 0 ]] || interrupted
  same_source || die "Source changed during verification; results do not certify the current tree" invalidated
  jq -e 'all(.steps[]; .status == "passed")' "$REPORT" >/dev/null \
    || die "A verification or diagnostic step failed; inspect the logs"
  report '.status = "passed"'
  exit 0
}

status() {
  local path pid alive owner
  owner="$("$SCRIPT/desktop_lock.sh" --owner)"
  {
    if [[ $# -gt 0 ]]; then echo "$1/result.json"; else ls -1d "$ROOT"/dist/verification/*/result.json 2>/dev/null | sort -r | head -10; fi
  } | while IFS= read -r path; do
    pid="$(jq -r '.pid // empty' "$path")"
    alive=false
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive=true
    jq --arg report "$(cd "$(dirname "$path")" && pwd)/result.json" --argjson alive "$alive" \
      '.report = $report | if .status == "running" and .phase_started_at then
         .phase_seconds = ((now - .phase_started_at) * 10 | round / 10) | .process_alive = $alive else . end' "$path"
  done | jq -s --argjson owner "$owner" '{desktop_owner: $owner, runs: .}'
}

# Sourcing loads the functions above for tests.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
MODE="${1:-}"
[[ $# -eq 0 ]] || shift
case "$MODE" in
  status) status "$@"; exit ;;
  __locked) LOCKED=1; RUN=$1; REPORT="$RUN/result.json" ;;
  local) [[ "${1:-}" != --stage ]] || { STAGE=1; shift; } ;;
  desktop) [[ $# -gt 0 ]] || usage; PREPARED="$(cd "$1" && pwd)" || exit 2; shift ;;
  full) STAGE=1; WAIT=1 ;;
  *) usage ;;
esac
while [[ "$MODE" != __locked && $# -gt 0 ]]; do
  case "$1" in
    --filter) [[ "$MODE" != local && $# -gt 1 ]] || usage; FILTER=$2; shift 2 ;;
    --wait) [[ "$MODE" == desktop ]] || usage; WAIT=1; shift ;;
    *) usage ;;
  esac
done

trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
if [[ "$LOCKED" -eq 1 ]]; then
  trap finish EXIT
  locked
fi

RUN="$ROOT/dist/verification/$(date +%Y%m%d-%H%M%S)-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
REPORT="$RUN/result.json"
mkdir -p "$RUN"
jq -n --arg mode "$MODE" --arg root "$ROOT" --argjson pid $$ \
  '{mode: $mode, status: "running", root: $root, steps: [], visual: "not-run", pid: $pid,
    started_at: now, phase: "initializing"}' > "$REPORT"
echo "Results: $REPORT"
trap finish EXIT
report '.source = $source | .swift = $swift' --argjson source "$(source_identity)" --arg swift "$(swift --version 2>/dev/null)"

if [[ "$MODE" == local || "$MODE" == full ]]; then
  export DEFI_E2E=0
  step build swift build
  step tests swift test --skip DesktopE2ETests
  step workflow-tests bash "$ROOT/Tests/Verification/test_verification.sh"
  report '.desktop = "not-run"'
  if [[ "$STAGE" -eq 1 ]]; then
    DEFI_STAGING_ROOT="$RUN/staged" step stage "$SCRIPT/build_and_run.sh" --stage
    report '.bundle = $bundle | .bundle_sha256 = $sha' \
      --arg bundle "$RUN/staged/Defi.app" --arg sha "$(bundle_digest "$RUN/staged/Defi.app")"
  fi
  same_source || die "Source changed during preparation; rerun local --stage" invalidated
  report '.preparation = "passed"'
  unset DEFI_E2E
  [[ "$MODE" == full ]] || conclude
fi

PREPARED="${PREPARED:-$RUN}"
prepared="$(cat "$PREPARED/result.json")" || die "A successful local --stage run is required"
jq -e '((.mode == "local" and .status == "passed") or (.mode == "full" and .preparation == "passed")) and .bundle != null' \
  <<< "$prepared" >/dev/null || die "A successful local --stage run is required"
jq -e --arg root "$ROOT" --argjson source "$(value -c .source)" '.root == $root and .source == $source' <<< "$prepared" >/dev/null \
  || die "Source changed or belongs to another worktree; rerun local --stage"
BUNDLE="$(jq -r .bundle <<< "$prepared")"
SHA="$(jq -r .bundle_sha256 <<< "$prepared")"
[[ -d "$BUNDLE" && "$(bundle_digest "$BUNDLE")" == "$SHA" ]] || die "Prepared bundle changed; rerun local --stage"
[[ "$FILTER" == DesktopE2ETests* ]] || die "Desktop filter must start with DesktopE2ETests"
report '.prepared_run = $run | .bundle = $bundle | .bundle_sha256 = $sha | .filter = $filter' \
  --arg run "$PREPARED" --arg bundle "$BUNDLE" --arg sha "$SHA" --arg filter "$FILTER"
step prepare-tests "$SCRIPT/test_desktop.sh" --build-tests
same_source || die "Source changed during preparation; rerun local --stage"
[[ "$WAIT" -eq 0 ]] || echo "Waiting for desktop reservation…"
report '.phase = "waiting-desktop" | .phase_started_at = now'
export DEFI_VERIFICATION_REPORT="$REPORT"
[[ "$INTERRUPTED" -eq 0 ]] || interrupted
set -m
if [[ "$WAIT" -eq 1 ]]; then
  "$SCRIPT/desktop_lock.sh" --wait "$0" __locked "$RUN" &
else
  "$SCRIPT/desktop_lock.sh" "$0" __locked "$RUN" &
fi
set +m
LOCK_PID=$!
wait_for "$LOCK_PID"
code=$?
LOCK_PID=""
if [[ "$(value .status)" == running ]]; then
  [[ "$INTERRUPTED" -eq 0 ]] || interrupted
  [[ "$code" -ne 75 ]] || die "Desktop busy" busy 75
fi
exit "$code"
