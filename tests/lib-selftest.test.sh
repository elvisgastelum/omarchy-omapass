#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Self-test for tests/lib.sh: guard, sandbox, isolation and the mocks.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_guard_passes() {
  omapass_guard
  local p
  p="$(command -v pass-cli)"
  assert_contains "$p" "$OMAPASS_MOCKS/"
}

test_guard_fails_on_foreign_pass_cli() {
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/fakebin/pass-cli"
  chmod +x "$HOME/fakebin/pass-cli"
  local err rc=0
  err="$(PATH="$HOME/fakebin:$PATH" omapass_guard 2>&1)" || rc=$?
  assert_ne 0 "$rc"
  assert_contains "$err" "$HOME/fakebin/pass-cli"
  assert_contains "$err" "refusing to run"
}

test_guard_fails_on_system_pass_cli() {
  if [[ ! -x /usr/bin/pass-cli ]]; then
    echo "  notice: /usr/bin/pass-cli not present; skipping" >&2
    return 0
  fi
  local rc=0
  PATH="/usr/bin:$PATH" omapass_guard >/dev/null 2>&1 || rc=$?
  assert_ne 0 "$rc"
}

test_guard_fails_on_foreign_wl_copy() {
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/fakebin/wl-copy"
  chmod +x "$HOME/fakebin/wl-copy"
  local err rc=0
  err="$(PATH="$HOME/fakebin:$PATH" omapass_guard 2>&1)" || rc=$?
  assert_ne 0 "$rc"
  assert_contains "$err" "wl-copy"
}

test_sandbox_paths() {
  assert_ne "$OMAPASS_REAL_HOME" "$HOME"
  assert_contains "$HOME" "$OMAPASS_SANDBOX/"
  assert_contains "$XDG_RUNTIME_DIR" "$OMAPASS_SANDBOX/"
  assert_eq 700 "$(stat -c %a "$XDG_RUNTIME_DIR")"
  echo marker >"$HOME/marker"
  assert_file_exists "$HOME/marker"
  echo "$HOME" >"$OMAPASS_TEST_SCRATCH"
}

test_sandbox_fresh() {
  [[ ! -e "$HOME/marker" ]] || return 1
  assert_ne "$(cat "$OMAPASS_TEST_SCRATCH")" "$HOME"
}

test_wayland_unset() {
  assert_eq "" "${WAYLAND_DISPLAY:-}"
  assert_eq "" "${DISPLAY:-}"
  assert_eq "" "${DBUS_SESSION_BUS_ADDRESS:-}"
  assert_eq "" "${SSH_AUTH_SOCK:-}"
  assert_eq "" "${WAYLAND_SOCKET:-}"
}

test_network() {
  if [[ "$OMAPASS_TEST_NETNS" != 1 ]]; then
    echo "  notice: no network namespace; skipping" >&2
    return 0
  fi
  # /sys/class/net shows the host's sysfs mount; /proc/net/dev follows the namespace.
  assert_eq "lo" "$(awk -F: 'NR>2 {gsub(/ /,"",$1); print $1}' /proc/net/dev | tr '\n' ' ' | sed 's/ $//')"
}

test_pass_cli_mock() {
  local out
  out="$(pass-cli vault list --output json)"
  echo "$out" | jq -e '.vaults[0].name == "Fixture Personal"' >/dev/null
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "pass-cli vault list --output json"
  assert_status 4 pass-cli fails
  local err
  err="$(pass-cli fails 2>&1 >/dev/null || true)"
  assert_contains "$err" "simulated failure"
  assert_status 2 pass-cli no such thing
}

test_hostile_garbage() {
  use_hostile_pass_cli
  local out
  out="$(pass-cli vault list)"
  assert_status 5 jq empty <<<"$out"
  assert_contains "$out" $'\033['
}

test_hostile_fail() {
  use_hostile_pass_cli
  OMAPASS_HOSTILE_MODE=fail assert_status 1 pass-cli vault list
}

test_hostile_stderr() {
  use_hostile_pass_cli
  local err
  err="$(OMAPASS_HOSTILE_MODE=stderr pass-cli vault list 2>&1 >/dev/null)"
  assert_contains "$err" "HOSTILE-CANARY"
}

test_clipboard() {
  printf 'secret' | wl-copy
  assert_eq "secret" "$(wl-paste -n)"
  wl-copy -c
  assert_eq "mock-clipboard-default" "$(wl-paste -n)"
}

test_clipboard_paste_once() {
  printf 'secret-once' | wl-copy -o
  assert_eq "secret-once" "$(wl-paste -n)"
  assert_eq "mock-clipboard-default" "$(wl-paste -n)"
  assert_not_contains "$(cat "$OMAPASS_MOCK_LOG")" "secret-once"
}

test_guard_fails_on_foreign_terminal() {
  local name err rc
  for name in xdg-terminal-exec omarchy-launch-tui; do
    mkdir -p "$HOME/fakebin"
    printf '#!/bin/sh\nexit 0\n' >"$HOME/fakebin/$name"
    chmod +x "$HOME/fakebin/$name"
    rc=0
    err="$(PATH="$HOME/fakebin:$PATH" omapass_guard 2>&1)" || rc=$?
    assert_ne 0 "$rc" "$name"
    assert_contains "$err" "$name"
    rm -f "$HOME/fakebin/$name"
  done
}

test_assert_no_leak_clean() {
  assert_no_leak
  assert_no_leak CANARY CANARY-X
}

test_assert_no_leak_sources() {
  local f rc
  mkdir -p "$XDG_RUNTIME_DIR/omapass"
  for f in "$OMAPASS_SANDBOX/stdout" "$OMAPASS_SANDBOX/stderr" \
    "$XDG_RUNTIME_DIR/omapass/debug.log" "$OMAPASS_MOCK_LOG"; do
    : >"$f"
    assert_no_leak CANARY-X
    echo "x CANARY-X y" >"$f"
    rc=0
    (assert_no_leak CANARY-X) >/dev/null 2>&1 || rc=$?
    assert_ne 0 "$rc" "leak in $f"
    : >"$f"
  done
  # The stdin capture dir is not a checked source.
  echo CANARY-X >"$OMAPASS_MOCK_STDIN_DIR/last.stdin"
  assert_no_leak CANARY-X
}

test_pass_cli_records_stdin() {
  local dir="$OMAPASS_SANDBOX/fx" tpl
  mkdir -p "$dir/pass-cli"
  echo '{}' >"$dir/pass-cli/item__create__login.txt"
  OMAPASS_FIXTURES="$dir"
  tpl=$'{\n  "title": "TPL-BODY",\n  "password": "TPL-PW"\n}\n'
  printf '%s' "$tpl" | pass-cli item create login >/dev/null
  printf '%s' "$tpl" >"$OMAPASS_SANDBOX/expected"
  cmp "$OMAPASS_SANDBOX/expected" "$OMAPASS_MOCK_STDIN_DIR/item__create__login.stdin"
  cmp "$OMAPASS_SANDBOX/expected" "$OMAPASS_MOCK_STDIN_DIR/last.stdin"
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "pass-cli item create login"
  assert_not_contains "$(cat "$OMAPASS_MOCK_LOG")" "TPL-"
}

test_wl_copy_sensitive() {
  printf 'secret' | wl-copy --sensitive
  assert_eq "secret" "$(wl-paste -n)"
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "wl-copy --sensitive"
  assert_not_contains "$(cat "$OMAPASS_MOCK_LOG")" "secret"
  printf 's' | wl-copy --sensitive -o
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "wl-copy --sensitive -o"
  assert_eq "s" "$(wl-paste -n)"
  assert_ne "s" "$(wl-paste -n)" "paste-once survived a second read"
}

test_wl_copy_unknown_option() {
  local err rc=0
  printf 'keep' | wl-copy
  err="$(wl-copy --bogus 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$err" "unsupported option: --bogus"
  assert_eq "keep" "$(wl-paste -n)"
}

test_terminal_mock() {
  local rc=0 err
  xdg-terminal-exec --app-id=org.omarchy.pass-cli -e pass-cli login
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "xdg-terminal-exec --app-id=org.omarchy.pass-cli -e pass-cli login"
  : >"$OMAPASS_MOCK_LOG"
  omarchy-launch-tui --app-id=org.omarchy.pass-cli -e pass-cli login
  assert_eq "omarchy-launch-tui --app-id=org.omarchy.pass-cli -e pass-cli login" "$(cat "$OMAPASS_MOCK_LOG")"
  assert_status 1 env OMAPASS_MOCK_TERMINAL=fail xdg-terminal-exec -e pass-cli login
  err="$(OMAPASS_MOCK_TERMINAL=fail xdg-terminal-exec -e pass-cli login 2>&1 || true)"
  assert_contains "$err" "simulated failure"
  assert_status 2 env OMAPASS_MOCK_TERMINAL=bogus xdg-terminal-exec -e pass-cli login
  assert_status 2 xdg-terminal-exec --app-id=x -e
  : >"$OMAPASS_MOCK_LOG"
  mkdir -p "$OMAPASS_SANDBOX/fx/pass-cli"
  echo ok >"$OMAPASS_SANDBOX/fx/pass-cli/login.txt"
  OMAPASS_FIXTURES="$OMAPASS_SANDBOX/fx"
  OMAPASS_MOCK_TERMINAL=run xdg-terminal-exec --title=t -e pass-cli login >/dev/null || rc=$?
  assert_eq 0 "$rc"
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" $'\npass-cli login'
}

test_run_helper() {
  printf '#!/usr/bin/env bash\necho to-out\necho to-err >&2\nexit 3\n' >"$OMAPASS_SANDBOX/fake-helper"
  chmod +x "$OMAPASS_SANDBOX/fake-helper"
  OMAPASS_HELPER="$OMAPASS_SANDBOX/fake-helper"
  run_helper a b
  assert_eq 3 "$S_RC"
  assert_eq to-out "$S_OUT"
  assert_eq to-err "$S_ERR"
  assert_eq to-out "$(<"$OMAPASS_SANDBOX/stdout")"
}

OMAPASS_TEST_SCRATCH="$(mktemp)"
trap 'rm -f "$OMAPASS_TEST_SCRATCH"' EXIT
export OMAPASS_TEST_SCRATCH

run_test "guard passes with mocks on PATH" test_guard_passes
run_test "guard fails on a foreign pass-cli" test_guard_fails_on_foreign_pass_cli
run_test "guard fails on the system pass-cli" test_guard_fails_on_system_pass_cli
run_test "guard fails on a foreign wl-copy" test_guard_fails_on_foreign_wl_copy
run_test "sandbox paths are temporary" test_sandbox_paths
run_test "sandbox is fresh per test" test_sandbox_fresh
run_test "wayland env is unset" test_wayland_unset
run_test "network is isolated" test_network
run_test "pass-cli mock replays fixtures" test_pass_cli_mock
run_test "hostile garbage is not JSON" test_hostile_garbage
run_test "hostile fail exits 1" test_hostile_fail
run_test "hostile stderr carries the canary" test_hostile_stderr
run_test "wl-copy and wl-paste round trip" test_clipboard
run_test "paste-once clears after one paste" test_clipboard_paste_once
run_test "guard fails on a foreign terminal launcher" test_guard_fails_on_foreign_terminal
run_test "assert_no_leak passes when clean" test_assert_no_leak_clean
run_test "assert_no_leak fails per source" test_assert_no_leak_sources
run_test "pass-cli mock records stdin" test_pass_cli_records_stdin
run_test "wl-copy accepts --sensitive" test_wl_copy_sensitive
run_test "wl-copy rejects unknown options" test_wl_copy_unknown_option
run_test "terminal mock modes" test_terminal_mock
run_test "run_helper sets status and output" test_run_helper
finish_tests
