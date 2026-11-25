#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for bin/lib/session.sh (lock, logout, login, unlock) and bin/lib/trash.sh (trash, untrash).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SID="FIXTURE-SHARE-A=="
IID="FIXTURE-ITEM-A1=="

fx_dir() { printf '%s/pass-cli' "$OMAPASS_FIXTURES"; }
state_file() { printf '%s/omapass/clipboard.state' "$XDG_RUNTIME_DIR"; }

assert_log_has() { grep -qxF -- "$1" "$OMAPASS_MOCK_LOG" || _omapass_fail "mock log lacks line '$1'"; }
assert_log_lacks() { ! grep -qF -- "$1" "$OMAPASS_MOCK_LOG" || _omapass_fail "mock log has '$1'"; }

# expect_clean: one-line stdout, empty stderr, no canary anywhere.
expect_clean() {
  assert_eq 1 "$(wc -l <"$OMAPASS_SANDBOX/stdout" | tr -d ' ')" "stdout line count"
  assert_eq "" "$S_ERR" "stderr"
  assert_no_leak CANARY
}

expect_ok() { # [json]
  assert_eq 0 "$S_RC" "exit code"
  assert_eq "${1:-{\"ok\":true\}}" "$S_OUT"
  expect_clean
}

expect_fail() { # rc error [reason]
  local want
  want="$(jq -cn --arg e "$2" --arg r "${3:-}" '{ok:false,error:$e} + (if $r == "" then {} else {reason:$r} end)')"
  assert_eq "$1" "$S_RC" "exit code"
  assert_eq "$want" "$S_OUT"
  expect_clean
}

# fail_override <key> <stderr text> [exit]: make the pass-cli mock fail for that fixture key.
fail_override() {
  printf '%s\n' "$2" >"$(fx_dir)/$1.stderr"
  printf '%s\n' "${3:-1}" >"$(fx_dir)/$1.exit"
}

# wait_log_line <line>: poll up to about 5 s for an exact line in the mock log.
wait_log_line() {
  local i
  for ((i = 0; i < 50; i++)); do
    ! grep -qxF -- "$1" "$OMAPASS_MOCK_LOG" || return 0
    sleep 0.1
  done
  _omapass_fail "mock log never got line '$1'"
}

# make_copy: copy the fixture login password (no detached clearer with --clear-after 0).
make_copy() {
  run_helper copy "$SID" "$IID" password --clear-after 0
  assert_eq 0 "$S_RC" "copy exit code"
  assert_file_exists "$(state_file)"
  assert_eq CANARY-LOGIN-PASSWORD-1 "$(wl-paste -n)" "clipboard holds the copy"
  : >"$OMAPASS_MOCK_LOG"
}

# expect_clipboard_cleared: state gone, mock clipboard empty, wl-copy --clear called.
expect_clipboard_cleared() {
  [[ ! -e "$(state_file)" ]] || _omapass_fail "clipboard.state still present"
  [[ ! -e "$XDG_RUNTIME_DIR/omapass-mock-clipboard" ]] || _omapass_fail "mock clipboard not cleared"
  assert_log_has "wl-copy --clear"
}

test_trash_untrash_ok() {
  local verb
  use_fixture_scenario ok
  for verb in trash untrash; do
    : >"$OMAPASS_MOCK_LOG"
    run_helper "$verb" "$SID" "$IID"
    expect_ok '{"ok":true}'
    assert_log_has "pass-cli item $verb --share-id $SID --item-id $IID"
    assert_log_lacks "--item-title"
    assert_log_lacks "--vault-name"
  done
}

test_trash_usage() {
  local verb
  use_fixture_scenario ok
  for verb in trash untrash; do
    run_helper "$verb"
    expect_fail 2 failed usage
    run_helper "$verb" "$SID"
    expect_fail 2 failed usage
    run_helper "$verb" "$SID" "$IID" extra
    expect_fail 2 failed usage
    run_helper "$verb" "a b" "$IID"
    expect_fail 2 failed usage
    run_helper "$verb" "$SID" "a b"
    expect_fail 2 failed usage
    run_helper "$verb" "../x" "$IID"
    expect_fail 2 failed usage
    run_helper "$verb" "$SID" "../x"
    expect_fail 2 failed usage
  done
  assert_log_lacks "pass-cli item"
}

test_trash_failures() {
  local verb key
  use_fixture_scenario ok
  for verb in trash untrash; do
    key="item__${verb}__--share-id__${SID}__--item-id__${IID}"
    fail_override "$key" "Error: Session is locked. Please unlock your session and try again."
    run_helper "$verb" "$SID" "$IID"
    expect_fail 11 locked
    fail_override "$key" "Error: Item does not exist"
    run_helper "$verb" "$SID" "$IID"
    expect_fail 17 not_found
  done
}

test_lock_ok() {
  use_fixture_scenario ok
  make_copy
  run_helper lock
  expect_ok '{"ok":true,"state":"locked"}'
  expect_clipboard_cleared
  assert_log_has "pass-cli session lock"
  assert_log_lacks "pass-cli logout"
}

test_lock_no_lock() {
  use_fixture_scenario no_lock
  make_copy
  run_helper lock
  assert_eq 1 "$S_RC" "exit code"
  assert_eq '{"ok":false,"error":"failed","reason":"no_lock"}' "$S_OUT"
  expect_clean
  expect_clipboard_cleared
  assert_log_has "pass-cli session lock"
  assert_log_lacks "pass-cli logout"
}

test_lock_other_failure() {
  use_fixture_scenario ok
  fail_override session__lock "Error: This operation requires an authenticated client"
  run_helper lock
  expect_fail 10 signed_out
  assert_log_lacks "pass-cli logout"
}

test_logout() {
  use_fixture_scenario ok
  make_copy
  run_helper logout
  expect_ok '{"ok":true,"state":"signed_out"}'
  expect_clipboard_cleared
  assert_log_has "pass-cli logout"
  assert_log_lacks "--force"
}

test_login_and_unlock() {
  local sub want
  use_fixture_scenario ok
  for sub in login unlock; do
    : >"$OMAPASS_MOCK_LOG"
    run_helper "$sub"
    expect_ok '{"ok":true}'
    if [[ "$sub" == login ]]; then want="-e pass-cli login"; else want="-e pass-cli session unlock"; fi
    wait_log_line "xdg-terminal-exec --app-id=org.omarchy.omapass $want"
  done
}

test_login_detaches() {
  local wrap="$OMAPASS_SANDBOX/wrap" rec="$OMAPASS_SANDBOX/login.rec" done_f="$OMAPASS_SANDBOX/login.done" start end ms i v fds
  use_fixture_scenario ok
  # Only the login call logs its environment: the version check shares the mock's env log.
  mkdir -p "$wrap"
  # shellcheck disable=SC2016 # the wrapper expands these when it runs
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${1:-}" == login ]] || unset OMAPASS_MOCK_ENV_LOG' \
    'if [[ "${1:-}" == login ]]; then' \
    "  { ps -o sid= \$\$; for f in /proc/\$\$/fd/*; do printf 'fd=%s\n' \"\${f##*/}\"; done; printf 'LC_ALL=%s\n' \"\${LC_ALL-unset}\"; } >\"$rec\"" \
    "  \"$OMAPASS_MOCKS/pass-cli\" \"\$@\" || true" \
    "  : >\"$done_f\"" \
    '  exit 0' \
    'fi' \
    "exec \"$OMAPASS_MOCKS/pass-cli\" \"\$@\"" >"$wrap/pass-cli"
  chmod 755 "$wrap/pass-cli"
  PATH="$wrap:$PATH"
  hash -r
  printf '3\n' >"$(fx_dir)/login.delay"
  export OMAPASS_MOCK_TERMINAL=run
  export OMAPASS_MOCK_ENV_LOG="$OMAPASS_SANDBOX/env.log"
  : >"$OMAPASS_MOCK_ENV_LOG"
  # Inherited names stay exported after core.sh resets them: the spawn must still drop them.
  start="$(date +%s%N)"
  export LC_ALL=C
  OMAPASS_TMPDIR=/nonexistent OMAPASS_SUB=x OMAPASS_MAIN_PID=1 OMAPASS_CLIP_KEY=CANARY-CLIP-KEY run_helper login 9>/dev/null
  end="$(date +%s%N)"
  ms=$(((end - start) / 1000000))
  expect_ok '{"ok":true}'
  ((ms < 2500)) || _omapass_fail "helper took ${ms} ms, it waited for the terminal"
  wait_log_line "pass-cli login"
  for ((i = 0; i < 50; i++)); do
    [[ -s "$OMAPASS_MOCK_ENV_LOG" ]] && break
    sleep 0.1
  done
  [[ -s "$OMAPASS_MOCK_ENV_LOG" ]] || _omapass_fail "login call left no env log"
  assert_contains "$(<"$OMAPASS_MOCK_ENV_LOG")" "OMAPASS_MOCK_LOG=" "env log is the login call's"
  for v in OMAPASS_TMPDIR OMAPASS_MAIN_PID OMAPASS_SUB OMAPASS_CLIP_; do
    ! grep -q "^$v" "$OMAPASS_MOCK_ENV_LOG" || _omapass_fail "login environment has $v"
  done
  assert_not_contains "$(<"$OMAPASS_MOCK_ENV_LOG")" CANARY-CLIP-KEY "clipboard key in login environment"
  assert_eq 1 "$(wc -l <"$OMAPASS_SANDBOX/stdout" | tr -d ' ')" "stdout is one line"
  # The delayed mock must finish before the next test starts.
  for ((i = 0; i < 60; i++)); do
    [[ -e "$done_f" ]] && break
    sleep 0.1
  done
  [[ -e "$done_f" ]] || _omapass_fail "delayed login mock never finished"
  [[ -s "$rec" ]] || _omapass_fail "login call left no process record"
  v="$(head -n1 "$rec" | tr -d ' ')"
  assert_eq 0 "$([[ -n "$v" && "$v" != "$(ps -o sid= $$ | tr -d ' ')" ]] && echo 0 || echo 1)" "login runs in a new session"
  fds="$(grep '^fd=' "$rec" | tr '\n' ' ')"
  # Only fd 9 (opened by the test) is asserted: the wrapper's glob and the terminal mock's
  # redirect add fds 3, 10 and 255 of their own.
  [[ " $fds " != *" fd=9 "* ]] || _omapass_fail "login inherited fd 9"
  grep -qxF 'LC_ALL=unset' "$rec" || _omapass_fail "login environment has LC_ALL"
}

test_logout_signed_out() {
  use_fixture_scenario ok
  fail_override logout "Error: This operation requires an authenticated client"
  run_helper logout
  expect_ok '{"ok":true,"state":"signed_out"}'
}

test_logout_network() {
  use_fixture_scenario ok
  fail_override logout "Error: error sending request"
  run_helper logout
  expect_fail 15 network
}

test_extra_args_usage() {
  local sub
  use_fixture_scenario ok
  for sub in lock logout login unlock; do
    run_helper "$sub" extra
    expect_fail 2 failed usage
  done
  assert_log_lacks "pass-cli session"
  assert_log_lacks "pass-cli logout"
  assert_log_lacks "pass-cli login"
  assert_log_lacks "xdg-terminal-exec"
}

run_test "trash and untrash by ids only" test_trash_untrash_ok
run_test "trash and untrash usage errors" test_trash_usage
run_test "trash failures are classified" test_trash_failures
run_test "lock clears the clipboard and locks" test_lock_ok
run_test "lock with no lock is no_lock" test_lock_no_lock
run_test "lock other failures keep their class" test_lock_other_failure
run_test "logout clears the clipboard and signs out" test_logout
run_test "logout when already signed out succeeds" test_logout_signed_out
run_test "logout network error is classified" test_logout_network
run_test "login and unlock open the terminal" test_login_and_unlock
run_test "login detaches and does not leak state" test_login_detaches
run_test "extra args are usage errors" test_extra_args_usage
finish_tests
