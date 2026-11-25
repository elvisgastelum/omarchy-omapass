#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for bin/omapass-helper and bin/lib/core.sh, status.sh against the scenario fixtures.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT_JSON="$(sed -n '/<!-- contract:begin -->/,/<!-- contract:end -->/p' "$REPO_ROOT/docs/CONTRACT.md" | grep -v -e '^<!--' -e '^```')"
SCEN=""
SCENARIOS=()
for d in "$TESTS_DIR"/fixtures/scenarios/*/; do
  SCENARIOS+=("$(basename "$d")")
done

contract_exit() { # error [reason]
  case "${2:-}" in
    usage | unknown_subcommand)
      jq -r '.exit_codes.usage' <<<"$CONTRACT_JSON"
      return
      ;;
  esac
  jq -r --arg e "$1" '.exit_codes[$e]' <<<"$CONTRACT_JSON"
}

# run_scenario <name>: sets up the fixtures and runs the scenario's subcommand with its env.
run_scenario() {
  local name="$1" dir="$TESTS_DIR/fixtures/scenarios/$1" sub line
  local -a envs=()
  use_fixture_scenario "$name"
  sub="$(jq -r .subcommand "$dir/expect.json")"
  while IFS= read -r line; do
    envs+=("$line")
  done < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$dir/expect.json")
  S_RC=0
  env "${envs[@]}" "$OMAPASS_HELPER" "$sub" >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  S_ERR="$(<"$OMAPASS_SANDBOX/stderr")"
}

assert_one_json_line() {
  assert_eq 1 "$(wc -l <"$OMAPASS_SANDBOX/stdout" | tr -d ' ')" "stdout line count"
  jq -e type >/dev/null <<<"$S_OUT" || _omapass_fail "stdout is not JSON: $S_OUT"
}

test_scenario() {
  local dir="$TESTS_DIR/fixtures/scenarios/$SCEN" error reason
  run_scenario "$SCEN"
  assert_one_json_line
  assert_eq "" "$S_ERR" "stderr"
  assert_no_leak CANARY
  if [[ "$(jq -r '.ok // false' "$dir/expect.json")" == true ]]; then
    assert_eq 0 "$S_RC" "exit code"
    assert_eq true "$(jq -r .ok <<<"$S_OUT")"
    assert_eq "$(jq -r .state "$dir/expect.json")" "$(jq -r .state <<<"$S_OUT")"
  else
    error="$(jq -r .error "$dir/expect.json")"
    reason="$(jq -r '.reason // ""' "$dir/expect.json")"
    assert_eq false "$(jq -r .ok <<<"$S_OUT")"
    assert_eq "$error" "$(jq -r .error <<<"$S_OUT")"
    assert_eq "$reason" "$(jq -r '.reason // ""' <<<"$S_OUT")"
    assert_eq "$(contract_exit "$error" "$reason")" "$S_RC" "exit code"
  fi
}

test_timeout_is_quick() {
  local start end
  start="$(omapass_now_ms_test)"
  run_scenario timeout
  end="$(omapass_now_ms_test)"
  assert_eq 16 "$S_RC"
  [[ $((end - start)) -lt 4000 ]] || _omapass_fail "timeout scenario took $((end - start)) ms"
}

omapass_now_ms_test() {
  local us="${EPOCHREALTIME/./}"
  printf '%s' "$((us / 1000))"
}

test_ok_mock_log() {
  run_scenario ok
  assert_eq 0 "$S_RC"
  assert_eq $'pass-cli --version\npass-cli vault list --output json' "$(cat "$OMAPASS_MOCK_LOG")"
  assert_eq 2 "$(jq -r .vaults <<<"$S_OUT")"
  assert_not_contains "$S_OUT" "Fixture Personal"
}

test_version_ok() {
  use_fixture_scenario ok
  run_helper version
  assert_eq 0 "$S_RC"
  assert_eq '{"ok":true,"pass_cli":"2.7.1","min_pass_cli":"2.7.1"}' "$S_OUT"
  assert_eq "" "$S_ERR"
  run_helper version extra
  assert_eq 2 "$S_RC"
  assert_eq '{"ok":false,"error":"failed","reason":"usage"}' "$S_OUT"
}

test_version_too_old() {
  use_fixture_scenario too_old
  run_helper version
  assert_eq 12 "$S_RC"
  assert_eq '{"ok":false,"error":"too_old"}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_version_ge() {
  local v1 v2 want
  while read -r v1 v2 want; do
    if (
      # shellcheck source=../bin/lib/core.sh
      source "$REPO_ROOT/bin/lib/core.sh"
      omapass_version_ge "$v1" "$v2"
    ); then
      assert_eq "$want" ge "$v1 vs $v2"
    else
      assert_eq "$want" lt "$v1 vs $v2"
    fi
  done <<'EOF'
2.7.1 2.7.1 ge
2.10.0 2.7.1 ge
2.7.0 2.7.1 lt
2.6.99 2.7.1 lt
3.0.0 2.7.1 ge
EOF
}

test_classify() {
  local crc text want f got
  f="$OMAPASS_SANDBOX/err.txt"
  while IFS='|' read -r crc text want; do
    printf '%s\n' "$text" >"$f"
    got="$(
      # shellcheck source=../bin/lib/core.sh
      source "$REPO_ROOT/bin/lib/core.sh"
      omapass_classify "$crc" "$f"
    )"
    assert_eq "$want" "$got" "rc=$crc text=$text"
  done <<'EOF'
124|Error: Session is locked|timeout
137||timeout
127||failed missing_pass_cli
126||failed missing_pass_cli
1|Error: --show-secrets is not allowed with an agent session|agent_session
1|Agent sessions must set the PROTON_PASS_AGENT_REASON environment variable before running commands.|agent_session
1|Session is locked. Please unlock your session and try again.|locked
1|Error: Could not perform operation. Reason: SessionLocked|locked
1|Error: This operation requires an authenticated client|signed_out
1|Error: No active session|signed_out
1|Your session has been invalidated and you have been logged out automatically.|signed_out
1|Please log in again with: pass login|signed_out
1|Your account is not yet allowed to use our CLI|plan_required
1|Error: Error sending request|network
1|Error: dns error: failed to lookup address information|network
1|Error: Could not find vault FIXTURE-SHARE-Z==|not_found
1|Error: Error finding vault [Fixture Missing]: gone|not_found
1|Error: No item found with title: Fixture Missing|not_found
1|Error: Field does not exist: fixture_field|not_found
1|Error: unexpected internal failure|failed
1|Error: an explanation of the plan to upgrade later|failed
1||failed
EOF
}

test_unknown_subcommands() {
  local sub
  for sub in nope Status 'status;id' '../x'; do
    run_helper "$sub"
    assert_eq '{"ok":false,"error":"failed","reason":"unknown_subcommand"}' "$S_OUT" "sub=$sub"
    assert_eq 2 "$S_RC" "sub=$sub"
    assert_eq "" "$S_ERR" "sub=$sub"
  done
  run_helper
  assert_eq '{"ok":false,"error":"failed","reason":"usage"}' "$S_OUT"
  assert_eq 2 "$S_RC"
  assert_eq "" "$S_ERR"
}

copy_bin() {
  mkdir -p "$OMAPASS_SANDBOX/copy"
  cp -R "$REPO_ROOT/bin" "$OMAPASS_SANDBOX/copy/bin"
}

test_autoload() {
  copy_bin
  printf '%s\n' "omapass_cmd_probe_thing() { omapass_ok '{\"probe\":true}'; }" \
    >"$OMAPASS_SANDBOX/copy/bin/lib/zz-probe.sh"
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-probe.sh"
  S_RC=0
  S_OUT="$("$OMAPASS_SANDBOX/copy/bin/omapass-helper" probe-thing 2>/dev/null)" || S_RC=$?
  assert_eq 0 "$S_RC"
  assert_eq '{"ok":true,"probe":true}' "$S_OUT"
  cmp "$OMAPASS_HELPER" "$OMAPASS_SANDBOX/copy/bin/omapass-helper"
}

run_copied() {
  S_RC=0
  "$OMAPASS_SANDBOX/copy/bin/omapass-helper" "$@" >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  S_ERR="$(<"$OMAPASS_SANDBOX/stderr")"
}

test_errexit_fallback() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-fail.sh" <<'EOF'
omapass_cmd_probe_fail() { false; omapass_ok '{"reached":true}'; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-fail.sh"
  run_copied probe-fail
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed"}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_return_without_envelope() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-return.sh" <<'EOF'
omapass_cmd_probe_return() { return 0; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-return.sh"
  run_copied probe-return
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed"}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_unknown_reason_dropped() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-reason.sh" <<'EOF'
omapass_cmd_probe_reason() { omapass_fail locked 'evil"reason'; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-reason.sh"
  run_copied probe-reason
  assert_eq 11 "$S_RC"
  assert_eq '{"ok":false,"error":"locked"}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_bad_lib_dir_writable() {
  copy_bin
  chmod g+w "$OMAPASS_SANDBOX/copy/bin/lib"
  run_copied status
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed","reason":"bad_lib"}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_tmpdir_removed() {
  use_fixture_scenario ok
  run_helper status
  assert_eq 0 "$S_RC"
  assert_eq "" "$(find "$XDG_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -name 'omapass.*' -print)" "temp dir left behind"
}

test_bad_lib_group_writable() {
  copy_bin
  chmod g+w "$OMAPASS_SANDBOX/copy/bin/lib/status.sh"
  S_RC=0
  S_OUT="$("$OMAPASS_SANDBOX/copy/bin/omapass-helper" status 2>"$OMAPASS_SANDBOX/stderr")" || S_RC=$?
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed","reason":"bad_lib"}' "$S_OUT"
  assert_eq "" "$(<"$OMAPASS_SANDBOX/stderr")"
}

test_bad_lib_symlink() {
  copy_bin
  ln -s core.sh "$OMAPASS_SANDBOX/copy/bin/lib/zz-link.sh"
  S_RC=0
  S_OUT="$("$OMAPASS_SANDBOX/copy/bin/omapass-helper" status 2>"$OMAPASS_SANDBOX/stderr")" || S_RC=$?
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed","reason":"bad_lib"}' "$S_OUT"
  assert_eq "" "$(<"$OMAPASS_SANDBOX/stderr")"
}

test_debug_log() {
  local name mode log="$XDG_RUNTIME_DIR/omapass/debug.log" content
  export OMAPASS_DEBUG=1
  for name in "${SCENARIOS[@]}"; do
    run_scenario "$name"
    assert_eq "" "$S_ERR" "scenario $name"
  done
  use_fixture_scenario ok
  use_hostile_pass_cli
  for mode in stderr garbage fail huge; do
    S_RC=0
    OMAPASS_HOSTILE_MODE="$mode" OMAPASS_HOSTILE_CANARY=CANARY-HOSTILE \
      "$OMAPASS_HELPER" status >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
    S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
    S_ERR="$(<"$OMAPASS_SANDBOX/stderr")"
    assert_ne 0 "$S_RC" "hostile $mode exit"
    assert_eq false "$(jq -r .ok <<<"$S_OUT")" "hostile $mode"
    assert_eq failed "$(jq -r .error <<<"$S_OUT")" "hostile $mode"
    assert_eq "" "$S_ERR" "hostile $mode stderr"
    assert_no_leak CANARY
  done
  assert_file_exists "$log"
  assert_eq 600 "$(stat -c %a "$log")"
  assert_eq 700 "$(stat -c %a "$XDG_RUNTIME_DIR/omapass")"
  content="$(<"$log")"
  [[ "$content" =~ event=pass-cli\ cmd=\"vault\ list\"\ rc=[0-9]+\ ms=[0-9]+ ]] || _omapass_fail "no vault list line in log"
  [[ "$content" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.[0-9]{3}Z\ pid=[0-9]+\ sub=status\ event=start ]] || _omapass_fail "no start line"
  assert_no_leak CANARY
  assert_not_contains "$content" "FIXTURE-"
  assert_not_contains "$content" "Fixture Personal"
  assert_not_contains "$content" "--output"
}

test_no_debug_no_log() {
  unset OMAPASS_DEBUG
  run_scenario ok
  assert_eq 0 "$S_RC"
  [[ ! -e "$XDG_RUNTIME_DIR/omapass" ]] || _omapass_fail "runtime log dir created"
  [[ ! -e "$XDG_STATE_HOME/omapass" ]] || _omapass_fail "state log dir created"
  assert_eq "" "$(ls -A "$XDG_RUNTIME_DIR")" "temp dir not cleaned up"
}

test_ok_forces_ok_true() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-okfalse.sh" <<'EOF'
omapass_cmd_probe_okfalse() { omapass_ok '{"ok":false,"x":1}'; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-okfalse.sh"
  run_copied probe-okfalse
  assert_eq 0 "$S_RC"
  assert_eq '{"ok":true,"x":1}' "$S_OUT"
}

test_ok_large_payload() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-big.sh" <<'EOF'
omapass_cmd_probe_big() { local big; big="$(head -c 300000 /dev/zero | tr '\0' a)"; omapass_ok "$(jq -cn --rawfile b /dev/stdin '{big:$b}' <<<"$big")"; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-big.sh"
  run_copied probe-big
  assert_eq 0 "$S_RC"
  assert_eq true "$(jq -r .ok <<<"$S_OUT")"
  [[ "$(jq -r '.big | length' <<<"$S_OUT")" -ge 300000 ]] || _omapass_fail "big payload is shorter than 300000"
}

test_ok_file() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-file.sh" <<'EOF'
omapass_cmd_probe_file() { printf '%s' '{"n":2}' >"$OMAPASS_TMPDIR/out.json"; omapass_ok_file "$OMAPASS_TMPDIR/out.json"; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-file.sh"
  run_copied probe-file
  assert_eq 0 "$S_RC"
  assert_eq '{"ok":true,"n":2}' "$S_OUT"
  assert_eq "" "$S_ERR"
}

test_ok_empty_payload_fails() {
  copy_bin
  cat >"$OMAPASS_SANDBOX/copy/bin/lib/zz-empty.sh" <<'EOF'
omapass_cmd_probe_empty() { omapass_ok "$(false)"; }
EOF
  chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-empty.sh"
  run_copied probe-empty
  assert_eq 1 "$S_RC"
  assert_eq '{"ok":false,"error":"failed","reason":"bad_output"}' "$S_OUT"
}

test_bad_lib_broken() {
  local body
  for body in 'omapass_cmd_probe_x() {' 'false' 'exit 0'; do
    copy_bin
    printf '%s\n' "$body" >"$OMAPASS_SANDBOX/copy/bin/lib/zz-broken.sh"
    chmod 644 "$OMAPASS_SANDBOX/copy/bin/lib/zz-broken.sh"
    run_copied status
    assert_eq 1 "$S_RC" "lib body: $body"
    assert_eq '{"ok":false,"error":"failed","reason":"bad_lib"}' "$S_OUT" "lib body: $body"
    rm -rf "$OMAPASS_SANDBOX/copy"
  done
}

test_env_sub_ignored() {
  local log="$XDG_RUNTIME_DIR/omapass/debug.log" content
  S_RC=0
  OMAPASS_DEBUG=1 OMAPASS_SUB='CANARY x=1' "$OMAPASS_HELPER" nope >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  assert_eq 2 "$S_RC"
  content="$(<"$log")"
  assert_contains "$content" "sub=unknown" "debug log sub"
  assert_not_contains "$content" CANARY
}

test_env_pass_stderr_ignored() {
  use_fixture_scenario signed_out
  S_RC=0
  OMAPASS_PASS_STDERR="$OMAPASS_SANDBOX/outside.err" "$OMAPASS_HELPER" status >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  assert_eq signed_out "$(jq -r .error <<<"$S_OUT")"
  [[ ! -e "$OMAPASS_SANDBOX/outside.err" ]] || _omapass_fail "OMAPASS_PASS_STDERR was honored"
}

test_env_functions_ignored() {
  printf 'printf "from-bash-env\\n"\n' >"$OMAPASS_SANDBOX/bash_env"
  S_RC=0
  env 'BASH_FUNC_omapass_cmd_evil%%=() { echo injected; exit 0; }' \
    'BASH_FUNC_printf%%=() { echo hijacked; }' \
    BASH_ENV="$OMAPASS_SANDBOX/bash_env" \
    "$OMAPASS_HELPER" evil >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  assert_one_json_line
  assert_eq '{"ok":false,"error":"failed","reason":"unknown_subcommand"}' "$S_OUT"
  assert_eq 2 "$S_RC"
}
run_test "functions and BASH_ENV from the environment are ignored" test_env_functions_ignored

for SCEN in "${SCENARIOS[@]}"; do
  run_test "scenario $SCEN" test_scenario
done
run_test "timeout scenario returns quickly" test_timeout_is_quick
run_test "ok scenario makes exactly two pass-cli calls" test_ok_mock_log
run_test "version subcommand" test_version_ok
run_test "version subcommand too old" test_version_too_old
run_test "omapass_version_ge" test_version_ge
run_test "omapass_classify" test_classify
run_test "unknown and missing subcommands" test_unknown_subcommands
run_test "libs are auto-loaded without editing the dispatcher" test_autoload
run_test "errexit in a subcommand still prints the failure envelope" test_errexit_fallback
run_test "subcommand that returns without an envelope fails" test_return_without_envelope
run_test "unknown failure reason is dropped" test_unknown_reason_dropped
run_test "group-writable lib directory is refused" test_bad_lib_dir_writable
run_test "temp dir is removed after a run" test_tmpdir_removed
run_test "group-writable lib is refused" test_bad_lib_group_writable
run_test "symlinked lib is refused" test_bad_lib_symlink
run_test "debug log is private and leaks nothing" test_debug_log
run_test "no log without OMAPASS_DEBUG" test_no_debug_no_log
run_test "omapass_ok forces ok true" test_ok_forces_ok_true
run_test "omapass_ok accepts a large payload" test_ok_large_payload
run_test "omapass_ok_file prints the file object" test_ok_file
run_test "an empty omapass_ok payload fails" test_ok_empty_payload_fails
run_test "a lib with a syntax error or failing top level is refused" test_bad_lib_broken
run_test "OMAPASS_SUB from the environment is ignored" test_env_sub_ignored
run_test "OMAPASS_PASS_STDERR from the environment is ignored" test_env_pass_stderr_ignored
finish_tests
