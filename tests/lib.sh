#!/usr/bin/env bash
# Shared helpers for every bash suite (tests/*.test.sh). Source it, do not run it.
#
# Rules:
#   - Tests run offline, against the mocks in tests/mocks only. The real
#     pass-cli, wl-copy, wl-paste, xdg-terminal-exec and omarchy-launch-tui
#     reach a real vault, clipboard and terminal and must never run.
#     omapass_guard refuses to continue if any of them would resolve outside
#     tests/mocks, and it never executes the binaries it checks.
#   - Every test gets a throwaway HOME/XDG sandbox; nothing touches the real home.
#   - The suite re-executes itself inside `unshare -rn` (no network) when possible.

# Captured before any sandboxing so tests can assert they are not using it.
OMAPASS_REAL_HOME="${OMAPASS_REAL_HOME:-${HOME:-}}"
export OMAPASS_REAL_HOME

if [[ -z "${OMAPASS_TEST_NETNS:-}" ]]; then
  # Prefer keeping our own uid, so permission checks behave as outside; fall back to -rn.
  if unshare -n --map-current-user true 2>/dev/null; then
    exec unshare -n --map-current-user env OMAPASS_TEST_NETNS=1 bash "$0" "$@"
  elif unshare -rn true 2>/dev/null; then
    exec unshare -rn env OMAPASS_TEST_NETNS=1 bash "$0" "$@"
  fi
  export OMAPASS_TEST_NETNS=0
  echo "notice: unshare -rn unavailable; running without network isolation" >&2
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$TESTS_DIR")"
OMAPASS_MOCKS="$TESTS_DIR/mocks"
OMAPASS_FIXTURES="${OMAPASS_FIXTURES:-$TESTS_DIR/fixtures}"
OMAPASS_HELPER="${OMAPASS_HELPER:-$REPO_ROOT/bin/omapass-helper}"
export TESTS_DIR REPO_ROOT OMAPASS_MOCKS OMAPASS_FIXTURES OMAPASS_HELPER

PATH="$OMAPASS_MOCKS:$PATH"
export PATH
hash -r

# No compositor, session bus or agent sockets: unshare -n does not block filesystem sockets.
unset WAYLAND_DISPLAY WAYLAND_SOCKET DISPLAY DBUS_SESSION_BUS_ADDRESS SSH_AUTH_SOCK
while IFS= read -r _omapass_var; do
  unset "$_omapass_var"
done < <(compgen -e | grep '^PROTON_PASS_' || true)
unset _omapass_var

OMAPASS_PASSED=0
OMAPASS_FAILED=0

# External commands the code under test may call; each must resolve to a mock.
OMAPASS_GUARDED=(pass-cli wl-copy wl-paste xdg-terminal-exec omarchy-launch-tui)

# Fail unless every command in OMAPASS_GUARDED resolves inside the mocks dir.
omapass_guard() {
  local mocks name path real
  mocks="$(realpath "$OMAPASS_MOCKS")"
  for name in "${OMAPASS_GUARDED[@]}"; do
    path="$(command -v "$name" 2>/dev/null || true)"
    real=""
    if [[ "$path" == /* ]]; then
      # Resolve the file itself, so a symlink in mocks/ to a real binary fails too.
      real="$(realpath "$path" 2>/dev/null || true)"
    fi
    if [[ -z "$real" || "$real" != "$mocks"/* ]]; then
      echo "guard: $name resolves to ${path:-<nothing>}; refusing to run" >&2
      return 1
    fi
  done
  return 0
}

omapass_guard || exit 1

omapass_sandbox_new() {
  OMAPASS_SANDBOX="$(mktemp -d)"
  export OMAPASS_SANDBOX
  export HOME="$OMAPASS_SANDBOX/home"
  export XDG_RUNTIME_DIR="$OMAPASS_SANDBOX/run"
  export XDG_CONFIG_HOME="$OMAPASS_SANDBOX/config"
  export XDG_CACHE_HOME="$OMAPASS_SANDBOX/cache"
  export XDG_DATA_HOME="$OMAPASS_SANDBOX/data"
  export XDG_STATE_HOME="$OMAPASS_SANDBOX/state"
  export OMAPASS_MOCK_LOG="$OMAPASS_SANDBOX/mock.log"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
    "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  chmod 700 "$XDG_RUNTIME_DIR"
  export OMAPASS_MOCK_STDIN_DIR="$OMAPASS_SANDBOX/pass-cli-stdin"
  mkdir -p "$OMAPASS_MOCK_STDIN_DIR"
  unset OMAPASS_MOCK_TERMINAL OMAPASS_MOCK_NAME
  : >"$OMAPASS_MOCK_LOG"
}

# run_test <name> <function>
run_test() {
  local name="$1" fn="$2" rc
  set +e
  (
    set -e
    omapass_sandbox_new
    trap 'rm -rf "$OMAPASS_SANDBOX"' EXIT
    omapass_guard
    "$fn" </dev/null
  )
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "ok - $name"
    OMAPASS_PASSED=$((OMAPASS_PASSED + 1))
  else
    echo "not ok - $name"
    OMAPASS_FAILED=$((OMAPASS_FAILED + 1))
  fi
}

_omapass_fail() {
  echo "  assertion failed: $*" >&2
  return 1
}

assert_eq() { # expected actual [message]
  [[ "$1" == "$2" ]] || _omapass_fail "${3:-values differ}: expected '$1', got '$2'"
}

assert_ne() { # unexpected actual [message]
  [[ "$1" != "$2" ]] || _omapass_fail "${3:-values equal}: both '$1'"
}

assert_contains() { # haystack needle [message]
  [[ "$1" == *"$2"* ]] || _omapass_fail "${3:-missing text}: '$2' not in '$1'"
}

assert_not_contains() { # haystack needle [message]
  [[ "$1" != *"$2"* ]] || _omapass_fail "${3:-unexpected text}: '$2' found in '$1'"
}

# assert_no_leak [canary...]: no canary (default CANARY) in captured stdout/stderr, debug log or mock log.
# The pass-cli stdin capture dir ($OMAPASS_MOCK_STDIN_DIR) is deliberately NOT checked:
# that is where create templates are expected to go. Missing sources are skipped, so a
# test that expects the debug log should assert_file_exists it first.
assert_no_leak() {
  local -a canaries=("$@") sources=()
  local c f bad=0
  [[ ${#canaries[@]} -gt 0 ]] || canaries=(CANARY)
  sources=("$OMAPASS_SANDBOX/stdout" "$OMAPASS_SANDBOX/stderr" "${XDG_RUNTIME_DIR:-}/omapass/debug.log" "${OMAPASS_MOCK_LOG:-}")
  for f in "${sources[@]}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    for c in "${canaries[@]}"; do
      if grep -qF -- "$c" "$f"; then
        _omapass_fail "canary '$c' leaked into $f" || bad=1
      fi
    done
  done
  return "$bad"
}

# shellcheck disable=SC2034 # S_RC, S_OUT, S_ERR are read by the suites that source this file
# run_helper <args...>: runs $OMAPASS_HELPER; sets S_RC, S_OUT, S_ERR (also kept in $OMAPASS_SANDBOX/stdout, stderr).
# stdin is /dev/null, or OMAPASS_HELPER_STDIN: a regular file (a pipe would block the pass-cli mock's stdin capture).
run_helper() {
  S_RC=0
  "$OMAPASS_HELPER" "$@" >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" <"${OMAPASS_HELPER_STDIN:-/dev/null}" || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  S_ERR="$(<"$OMAPASS_SANDBOX/stderr")"
}

assert_status() { # expected cmd...
  local expected="$1" rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq "$expected" ]] || _omapass_fail "'$*' exited $rc, expected $expected"
}

assert_file_exists() {
  [[ -e "$1" ]] || _omapass_fail "file does not exist: $1"
}

use_hostile_pass_cli() {
  PATH="$OMAPASS_MOCKS/hostile:$PATH"
  export PATH
  hash -r
  omapass_guard
}

# use_fixture_scenario <name>: sandbox copy of the pass-cli fixtures with tests/fixtures/scenarios/<name>/pass-cli laid over it.
use_fixture_scenario() {
  local name="$1" dst over f base
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || _omapass_fail "bad scenario name: $name" || return 1
  dst="$OMAPASS_SANDBOX/fixtures/pass-cli"
  over="$TESTS_DIR/fixtures/scenarios/$name/pass-cli"
  rm -rf "$OMAPASS_SANDBOX/fixtures"
  mkdir -p "$dst"
  cp -R "$TESTS_DIR/fixtures/pass-cli/." "$dst/"
  if [[ -d "$over" ]]; then
    for f in "$over"/*; do
      [[ -e "$f" ]] || continue
      base="${f##*/}"
      # The mock prefers .json over .txt, so an override of one drops the other.
      case "$base" in
        *.txt) rm -f "$dst/${base%.txt}.json" ;;
        *.json) rm -f "$dst/${base%.json}.txt" ;;
      esac
      cp "$f" "$dst/$base"
    done
  fi
  OMAPASS_FIXTURES="$OMAPASS_SANDBOX/fixtures"
  export OMAPASS_FIXTURES
}

finish_tests() {
  echo "$OMAPASS_PASSED passed, $OMAPASS_FAILED failed"
  if [[ $OMAPASS_FAILED -gt 0 || $((OMAPASS_PASSED + OMAPASS_FAILED)) -eq 0 ]]; then
    exit 1
  fi
  exit 0
}
