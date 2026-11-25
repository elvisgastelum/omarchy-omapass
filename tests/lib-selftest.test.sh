#!/usr/bin/env bash
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
  out="$(pass-cli vault list)"
  echo "$out" | jq -e '.vaults[0].name == "Mock"' >/dev/null
  assert_contains "$(cat "$OMAPASS_MOCK_LOG")" "pass-cli vault list"
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
finish_tests
