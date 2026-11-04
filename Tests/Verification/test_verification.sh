#!/usr/bin/env bash
# Offline checks for verification isolation, contention, session restoration, and result reporting.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
FAILURES=0
CURRENT=""

check() { # check DESCRIPTION COMMAND...: record a failed expectation without stopping
  local description=$1
  shift
  "$@" && return 0
  echo "FAIL [$CURRENT] $description" >&2
  FAILURES=$((FAILURES + 1))
}
equal() { [[ "$1" == "$2" ]] || { echo "  expected: $2" >&2; echo "  actual:   $1" >&2; return 1; }; }
contains() { [[ "$1" == *"$2"* ]] || { echo "  missing '$2' in: $1" >&2; return 1; }; }
fake() { # fake DIR NAME BODY: an executable shell fake
  mkdir -p "$1"
  printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}
case_dir() { CURRENT=$1; dir="$SCRATCH/$1"; mkdir -p "$dir"; }
not() { ! "$@"; }

# A worktree copy holding the real verification scripts and fakes for everything they drive.
fixture_root() {
  local root=$1
  mkdir -p "$root/script" "$root/Tests/Verification" "$root/bin"
  cp "$ROOT/script/verify.sh" "$ROOT/script/desktop_lock.sh" "$root/script/"
  echo "echo fixture workflow check" > "$root/Tests/Verification/test_verification.sh"
  printf 'dist/\nbin/\nprepared/\n*.out\nsession\nlive.json\n' > "$root/.gitignore"
  echo original > "$root/input.txt"
  git -C "$root" init -q
  git -C "$root" add .
  git -C "$root" -c user.name=Test -c user.email=test@example.invalid commit -qm Fixture
}

test_lock_excludes_waits_and_nests() {
  local dir out holder waiter
  case_dir lock
  export DEFI_DESKTOP_LOCK_PATH="$SCRATCH/$CURRENT.lock"
  local lock="$ROOT/script/desktop_lock.sh"
  "$lock" sh -c "\"$lock\" --check && echo held > \"$dir/nested\"; \"$lock\" echo inner > \"$dir/inner\"; sleep 1" &
  holder=$!
  sleep 0.4
  check "the holder's child sees the reservation" equal "$(cat "$dir/nested" 2>/dev/null)" held
  check "a nested reservation runs at once" equal "$(cat "$dir/inner" 2>/dev/null)" inner
  check "owner names the holder" equal "$("$lock" --owner | jq -r .cwd)" "$PWD"
  out="$("$lock" true 2>&1)"
  check "a contender exits 75" equal "$?" 75
  check "a contender names the owner" contains "$out" "Desktop busy"
  check "an outside process is not the holder" bash -c "! \"$lock\" --check"
  "$lock" --wait sh -c "echo acquired > \"$dir/waited\"" &
  waiter=$!
  sleep 0.2
  check "a waiter blocks while held" test ! -e "$dir/waited"
  wait "$holder"
  wait "$waiter"
  check "a waiter runs after release" equal "$(cat "$dir/waited" 2>/dev/null)" acquired
  check "the kernel releases the lock with its holder" equal "$("$lock" --owner)" null
  check "the lock file keeps its inode" test -e "$DEFI_DESKTOP_LOCK_PATH"
  unset DEFI_DESKTOP_LOCK_PATH
}

test_local_never_enables_desktop_and_reports_failure_or_drift() {
  local behavior expected dir report code body
  for behavior in pass fail drift; do
    case_dir "local-$behavior"
    fixture_root "$dir"
    case "$behavior" in
      pass) expected=passed; body="exit 0" ;;
      fail) expected=failed; body="exit 3" ;;
      drift) expected=invalidated; body='echo changed >> input.txt' ;;
    esac
    fake "$dir/bin" swift "[ \"\$1\" = --version ] && { echo Fixture; exit 0; }
[ \"\$DEFI_E2E\" = 0 ] || exit 99
[ \"\$(pwd -P)\" = \"$(cd "$dir" && pwd -P)\" ] || exit 98
$body"
    # Called from another directory, it still builds and tests its own worktree.
    (cd "$SCRATCH" && PATH="$dir/bin:$PATH" DEFI_E2E=1 "$dir/script/verify.sh" local > "$dir/run.out" 2>&1)
    code=$?
    report="$(ls "$dir"/dist/verification/*/result.json)"
    check "status is $expected" equal "$(jq -r .status "$report")" "$expected"
    check "exit code matches status" equal "$([[ $code -eq 0 ]] && echo passed || echo other)" \
      "$([[ $expected == passed ]] && echo passed || echo other)"
    check "every step has a log" bash -c "jq -r '.steps[].log' '$report' | while read -r log; do [ -f \"\$log\" ] || exit 1; done"
    [[ "$behavior" != fail ]] || check "a failed build stops the run" equal "$(jq '.steps | length' "$report")" 1
  done
}

prepared_run() { # prepared_run ROOT: a passing local --stage report with a bundle
  local root=$1 run="$1/prepared"
  mkdir -p "$run/staged/Defi.app"
  echo original > "$run/staged/Defi.app/binary"
  (
    # shellcheck source=/dev/null
    source "$root/script/verify.sh"
    jq -n --arg root "$root" --argjson source "$(source_identity)" --arg bundle "$run/staged/Defi.app" \
      --arg sha "$(bundle_digest "$run/staged/Defi.app")" \
      '{mode: "local", status: "passed", root: $root, source: $source, bundle: $bundle, bundle_sha256: $sha}' \
      > "$run/result.json"
  )
}

test_desktop_rechecks_after_wait_before_installing() {
  local mutation dir report holder expected
  for mutation in none source bundle; do
    case_dir "desktop-$mutation"
    fixture_root "$dir"
    export DEFI_DESKTOP_LOCK_PATH="$SCRATCH/$CURRENT.lock"
    fake "$dir/bin" swift 'echo Fixture'
    fake "$dir/script" test_desktop.sh "[ \"\$1\" = --build-tests ] && ! \"$dir/script/desktop_lock.sh\" --check"
    fake "$dir/script" desktop_session.sh "echo \"\$1\" >> \"$dir/session\""
    fake "$dir/script" build_and_run.sh 'exit 1'
    git -C "$dir" add . && git -C "$dir" -c user.name=T -c user.email=t@t commit -qm fakes
    prepared_run "$dir"
    "$dir/script/desktop_lock.sh" sleep 2 &
    holder=$!
    sleep 0.3
    (cd "$dir" && PATH="$dir/bin:$PATH" script/verify.sh desktop prepared --wait > "$dir/run.out" 2>&1) &
    sleep 1
    case "$mutation" in
      source) echo changed >> "$dir/input.txt" ;;
      bundle) echo changed > "$dir/prepared/staged/Defi.app/binary" ;;
    esac
    wait "$holder"
    wait $!
    report="$(ls -d "$dir"/dist/verification/*/result.json)"
    if [[ "$mutation" == none ]]; then
      check "installs after the wait" equal "$(jq -c '[.steps[].name]' "$report")" '["prepare-tests","checkpoint","install"]'
      check "a failed install fails the run" equal "$(jq -r .status "$report")" failed
    else
      check "never touches the desktop after a change" equal "$(jq -c '[.steps[].name]' "$report")" '["prepare-tests"]'
      check "a change invalidates the run" equal "$(jq -r .status "$report")" invalidated
      check "no checkpoint" test ! -e "$dir/session"
    fi
    check "records the wait" jq -e 'has("desktop_wait_seconds")' "$report" >/dev/null
    unset DEFI_DESKTOP_LOCK_PATH
  done
}

test_full_prepares_then_enters_desktop_and_publishes_progress() {
  local dir report
  case_dir full
  fixture_root "$dir"
  export DEFI_DESKTOP_LOCK_PATH="$SCRATCH/$CURRENT.lock"
  fake "$dir/bin" swift 'echo Fixture'
  fake "$dir/script" build_and_run.sh 'mkdir -p "$DEFI_STAGING_ROOT/Defi.app" && echo signed > "$DEFI_STAGING_ROOT/Defi.app/binary"'
  fake "$dir/script" test_desktop.sh 'exit 0'
  fake "$dir/script" desktop_session.sh "cp \"\$DEFI_VERIFICATION_REPORT\" \"$dir/live.json\"; exit 1"
  git -C "$dir" add . && git -C "$dir" -c user.name=T -c user.email=t@t commit -qm fakes
  (cd "$dir" && PATH="$dir/bin:$PATH" script/verify.sh full > "$dir/run.out" 2>&1)
  check "full fails when the checkpoint fails" equal "$?" 1
  report="$(ls "$dir"/dist/verification/*/result.json)"
  check "phases run in order" equal "$(jq -c '[.steps[].name]' "$report")" \
    '["build","tests","workflow-tests","stage","prepare-tests","checkpoint"]'
  check "progress is live under the reservation" equal \
    "$(jq -c '[.status, .preparation, (.desktop_wait_seconds != null)]' "$dir/live.json")" '["running","passed",true]'
  unset DEFI_DESKTOP_LOCK_PATH
}

test_interruption_stops_the_step_and_still_restores_the_session() {
  local report run
  case_dir interrupted
  fixture_root "$dir"
  export DEFI_DESKTOP_LOCK_PATH="$SCRATCH/$CURRENT.lock"
  fake "$dir/bin" swift 'echo Fixture'
  fake "$dir/bin" defi 'echo "running focused=1"'
  # The staged bundle carries the fake CLI that the run calls once it is installed.
  fake "$dir/script" build_and_run.sh "if [ \"\$1\" = --stage ]; then
  mkdir -p \"\$DEFI_STAGING_ROOT/Defi.app/Contents/MacOS\" && cp \"$dir/bin/defi\" \"\$DEFI_STAGING_ROOT/Defi.app/Contents/MacOS/\"
else rm -rf \"$dir/Applications/Defi.app\" && mkdir -p \"$dir/Applications\" && cp -R \"\$2\" \"$dir/Applications/Defi.app\"; fi"
  fake "$dir/script" test_desktop.sh "[ \"\$1\" = --build-tests ] && exit 0; touch \"$dir/tests-started\"; sleep 30; touch \"$dir/tests-finished\""
  fake "$dir/script" desktop_session.sh "case \"\$1\" in
  checkpoint) mkdir -p \"\$2\" && touch \"\$2/ready\" ;;
  restore) echo restored > \"$dir/session\"
    if lockf -k -s -t 0 \"$DEFI_DESKTOP_LOCK_PATH\" true; then echo released > \"$dir/lock-at-restore\"; fi ;;
  daemons) echo 1 ;;
esac"
  git -C "$dir" add . && git -C "$dir" -c user.name=T -c user.email=t@t commit -qm fakes
  # Its own process group, so the TERM below reaches the whole run as a supervisor would send it.
  set -m
  (cd "$dir" && HOME="$dir" PATH="$dir/bin:$PATH" exec script/verify.sh full > "$dir/run.out" 2>&1) &
  run=$!
  set +m
  for _ in {1..100}; do [[ -e "$dir/tests-started" ]] && break; sleep 0.1; done
  kill -TERM -- "-$run"
  wait "$run"
  check "an interrupted run exits 130" equal "$?" 130
  report="$(ls "$dir"/dist/verification/*/result.json)"
  check "the run is interrupted" equal "$(jq -r .status "$report")" interrupted
  check "the desktop tests stop" test ! -e "$dir/tests-finished"
  check "the session is restored" equal "$(cat "$dir/session" 2>/dev/null)" restored
  check "the reservation is held through the restore" test ! -e "$dir/lock-at-restore"
  check "steps after the tests are only diagnostics and restore" equal \
    "$(jq -c '[.steps[] | select(.name | IN("desktop-tests","status-after","trace-after","restore-session")) | [.name, .status]]' "$report")" \
    '[["desktop-tests","interrupted"],["status-after","passed"],["trace-after","passed"],["restore-session","passed"]]'
  unset DEFI_DESKTOP_LOCK_PATH
}

test_desktop_counts_keep_skips_and_failures_apart() {
  local dir log counts
  case_dir counts
  (
    # shellcheck source=/dev/null
    source "$ROOT/script/verify.sh"
    RUN=$dir
    for i in 0 1 2; do
      state=(passed skipped failed)
      printf "Test Case 'case-%s' started.\nTest Case 'case-%s' %s (0.001 seconds).\n" "$i" "$i" "${state[$i]}"
    done > "$dir/log"
    check "counts" equal "$(desktop_counts "$dir/log")" '{"tests":3,"failed":1,"skipped":1,"not_run":{}}'
    check "xml marks the skip" contains "$(cat "$dir/desktop.xml")" "<skipped"
    cat >> "$dir/log" <<'LOG'
Test Case '-[DefiMacOSTests.DesktopE2ETests testTwoDisplay]' started.
DEFI_E2E not-run lane=two-display test=-[DesktopE2ETests testTwoDisplay] reason=requires 2 displays, found 1
Test Case '-[DefiMacOSTests.DesktopE2ETests testTwoDisplay]' skipped (0.001 seconds).
LOG
    check "a named lane is not run, not skipped" equal "$(desktop_counts "$dir/log")" \
      '{"tests":4,"failed":1,"skipped":1,"not_run":{"two-display":{"testTwoDisplay":"requires 2 displays, found 1"}}}'
    : > "$dir/empty"
    check "an empty log runs nothing" equal "$(desktop_counts "$dir/empty" | jq .tests)" 0
    echo "Test Case 'truncated' started." > "$dir/truncated"
    check "a truncated log fails" bash -c "! (source \"$ROOT/script/verify.sh\"; RUN=$dir desktop_counts $dir/truncated) 2>/dev/null"
    exit "$FAILURES"
  )
  FAILURES=$((FAILURES + $?))
}

# A daemon whose service and status calls are driven by files in DIR.
session_fakes() {
  local dir=$1
  mkdir -p "$dir/state"
  fake "$dir/bin" pgrep "[ -f \"$dir/running\" ] && echo 123; [ -f \"$dir/running\" ]"
  fake "$dir/bin" defi "case \"\$1 \${2:-}\" in
  'service stop') echo stop >> \"$dir/events\"; n=\$(grep -c stop \"$dir/events\"); [ \"\$n\" = \"\${STOP_FAILS_AT:-0}\" ] && exit 1; rm -f \"$dir/running\" ;;
  'service start') echo start >> \"$dir/events\"
    [ -f \"$dir/refuse-first\" ] && { rm \"$dir/refuse-first\"; exit 1; }
    grep -q '\"new\"' \"$dir/state/workspace-topology.json\" 2>/dev/null && [ -n \"\${NEW_STORE_FAILS:-}\" ] && exit 1
    touch \"$dir/running\" ;;
  'status '*) [ -f \"$dir/running\" ] && echo 'running focused=42 drift=0[] focusPending=false axPending=false monitors=1[1] snapshots=3/3' ;;
  'list-workspaces '*) echo '{\"monitors\": []}' ;;
esac"
}

in_session() { # in_session DIR COMMAND...: run with the fake daemon under a reservation
  local dir=$1
  shift
  DEFI_DESKTOP_LOCK_PATH="$dir/desktop.lock" PATH="$dir/bin:$PATH" DEFI_CLI="$dir/bin/defi" \
    DEFI_STATE_DIR="$dir/state" DEFI_SESSION_POLL=0 "$ROOT/script/desktop_lock.sh" "$@"
}

test_session_restore_reinstates_store_and_checks_monitors() {
  local dir topology
  case_dir session-restore
  session_fakes "$dir"
  mkdir -p "$dir/saved"
  topology='{"sessionID":"same","topology":{"monitors":[{"id":1,"workspaces":[{"width":0.8}]}]}}'
  echo "$topology" > "$dir/saved/workspace-topology.json"
  echo '{"sessionID":"same","topology":{"monitors":[]}}' > "$dir/state/workspace-topology.json"
  touch "$dir/saved/ready" "$dir/running"
  echo 'focused=42' > "$dir/saved/status.txt"
  echo '{"monitors": []}' > "$dir/saved/workspaces.json"
  in_session "$dir" "$ROOT/script/desktop_session.sh" restore "$dir/saved" > "$dir/run.out" 2>&1
  check "restore succeeds" equal "$?" 0
  check "the checkpointed store is back" equal "$(jq -c . "$dir/state/workspace-topology.json")" "$topology"
  check "one stop, one start" equal "$(tr '\n' ' ' < "$dir/events")" "stop start "
  check "evidence is kept" test -e "$dir/saved/restored-topology.json"
  (
    # shellcheck source=/dev/null
    source "$ROOT/script/desktop_session.sh"
    close() { jq -en --argjson a "$1" --argjson b "$2" "$CLOSE close(\$a; \$b)" >/dev/null; }
    check "widths beyond tolerance differ" not close '[{"width":1}]' '[{"width":0.8}]'
    check "identifiers differ" not close '[{"id":1}]' '[{"id":2}]'
    check "tiny float noise is equal" close '[{"width":0.8}]' '[{"width":0.8000000001}]'
    exit "$FAILURES"
  )
  FAILURES=$((FAILURES + $?))
}

test_session_restore_recovers_store_on_failure() {
  local failure dir events
  for failure in replace start recovery-stop; do
    case_dir "session-$failure"
    session_fakes "$dir"
    mkdir -p "$dir/saved"
    echo '{"version": "old"}' > "$dir/state/workspace-topology.json"
    echo '{"version": "new"}' > "$dir/saved/workspace-topology.json"
    touch "$dir/running"
    [[ "$failure" != replace ]] || fake "$dir/bin" mv "[ -f \"$dir/mv-failed\" ] || { touch \"$dir/mv-failed\"; exit 1; }; /bin/mv \"\$@\""
    touch "$dir/saved/ready"
    echo 'focused=42' > "$dir/saved/status.txt"
    echo '{"monitors": []}' > "$dir/saved/workspaces.json"
    NEW_STORE_FAILS=1 STOP_FAILS_AT=$([[ $failure == recovery-stop ]] && echo 2 || echo 0) \
      in_session "$dir" "$ROOT/script/desktop_session.sh" restore "$dir/saved" > "$dir/run.out" 2>&1
    check "replacement reports failure" equal "$?" 1
    events="$(uniq < "$dir/events" | tr '\n' ' ')"
    if [[ "$failure" == recovery-stop ]]; then
      check "recovery stops once more" equal "$events" "stop start stop "
      check "the backup is retained" equal "$(jq -r .version "$dir"/state/.restore-*/workspace-topology.json.backup)" old
      check "the backup path is reported" contains "$(cat "$dir/run.out")" "backup retained"
    else
      check "the previous store is back" equal "$(jq -r .version "$dir/state/workspace-topology.json")" old
      check "never starts with the new store after failure" equal "$events" \
        "$([[ $failure == replace ]] && echo "stop start " || echo "stop start stop start ")"
      check "no transaction is left" bash -c "! ls -d '$dir'/state/.restore-* 2>/dev/null"
    fi
  done
}

test_session_start_retries_a_refused_launch() {
  local dir
  case_dir session-launch
  session_fakes "$dir"
  touch "$dir/refuse-first"
  in_session "$dir" "$ROOT/script/desktop_session.sh" start > "$dir/run.out" 2>&1
  check "start succeeds" equal "$?" 0
  check "launches twice, never with a daemon running" equal "$(tr '\n' ' ' < "$dir/events")" "start start "
}

test_failed_install_recovers_old_bundle_and_service() {
  local dir bundle version
  case_dir install
  for bundle in installed staged; do
    version=$([[ $bundle == installed ]] && echo old || echo broken)
    mkdir -p "$dir/$bundle/Contents/MacOS"
    plutil -create xml1 "$dir/$bundle/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string com.qeude.defi "$dir/$bundle/Contents/Info.plist"
    echo "$version" > "$dir/$bundle/version"
    fake "$dir/$bundle/Contents/MacOS" defi "if [ \"\$1 \$2\" = 'service stop' ]; then rm -f \"\$HOME/running\"; exit 0; fi
if [ \"\$1 \$2\" = 'service start' ]; then $([[ $version == broken ]] && echo 'exit 3' || echo 'touch "$HOME/running"; exit 0'); fi
[ \"\$1\" = status ] && [ -f \"\$HOME/running\" ]"
  done
  mkdir -p "$dir/Applications"
  mv "$dir/installed" "$dir/Applications/Defi.app"
  touch "$dir/running"
  fake "$dir/bin" codesign 'for a in "$@"; do case "$a" in --extract-certificates=*) echo same-cert > "${a#*=}0" ;; esac; done
for a in "$@"; do [ "$a" = -dr ] && echo "designated => same-requirement"; done; exit 0'
  fake "$dir/bin" pgrep '[ -f "$HOME/running" ] && echo 123'
  fake "$dir/bin" pkill 'rm -f "$HOME/running"'
  fake "$dir/bin" ditto 'cp -R "$1" "$2"'
  HOME="$dir" PATH="$dir/bin:$PATH" "$ROOT/script/build_and_run.sh" --install-staged "$dir/staged" --verify > "$dir/run.out" 2> "$dir/err"
  check "a broken bundle fails installation" bash -c "[ $? -ne 0 ]"
  check "it says it restores" contains "$(cat "$dir/err")" "restoring the previous bundle"
  check "the old bundle is back" equal "$(cat "$dir/Applications/Defi.app/version")" old
  check "the old service runs again" test -e "$dir/running"
  check "no install transaction is left" bash -c "! ls -d '$dir'/Applications/.Defi-install.* 2>/dev/null"
}

test_signing_requires_same_certificate_and_requirement() {
  local dir certificate requirement expected
  case_dir signing
  mkdir -p "$dir/installed" "$dir/staged"
  fake "$dir/bin" codesign 'p="${!#}"; for a in "$@"; do case "$a" in --extract-certificates=*) cp "$p/certificate" "${a#*=}0" ;; -dr) echo "designated => $(cat "$p/requirement")" ;; esac; done; exit 0'
  echo certificate-A > "$dir/installed/certificate"
  echo requirement-A > "$dir/installed/requirement"
  while read -r certificate requirement expected; do
    echo "$certificate" > "$dir/staged/certificate"
    echo "$requirement" > "$dir/staged/requirement"
    PATH="$dir/bin:$PATH" "$ROOT/script/check_signing.sh" "$dir/installed" "$dir/staged" >/dev/null 2>&1
    check "$certificate with $requirement exits $expected" equal "$?" "$expected"
  done <<'CASES'
certificate-A requirement-A 0
certificate-B requirement-A 1
certificate-A requirement-B 1
CASES
}

test_invalid_build_mode_fails_before_build_or_install() {
  local out
  CURRENT=build-mode
  out="$("$ROOT/script/build_and_run.sh" --typo 2>&1)"
  check "exits 2" equal "$?" 2
  check "prints usage" contains "$out" "usage:"
}

test_product_does_not_depend_on_disabled_sip() {
  CURRENT=sip
  # The test VM runs with SIP off; shipped code must never need that.
  check "no SIP-disabled dependency" bash -c "! grep -rliE 'csrutil|csr_check|csr_get|TCC\\.db|DYLD_|task_for_pid|mach_inject|scripting.?addition|com\\.apple\\.private\\.|com\\.apple\\.security\\.(cs\\.disable|get-task-allow)' \
    '$ROOT/Sources' '$ROOT/Support' '$ROOT/script/install.sh' '$ROOT/script/package_release.sh'"
}

for test in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$test"
done
if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES verification workflow check(s) failed" >&2
  exit 1
fi
echo "All verification workflow checks passed"
