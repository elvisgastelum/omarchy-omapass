#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for the list and vaults subcommands (bin/lib/list.sh) against the synthetic pass-cli fixtures.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT_LIST="$TESTS_DIR/fixtures/helper/list.json"
EXPECT_AGENT="$TESTS_DIR/fixtures/helper/list.agent_session.json"
K_VAULTS="vault__list__--output__json"
K_A="item__list__--share-id__FIXTURE-SHARE-A==__--filter-state__active__--output__json"
K_B="item__list__--share-id__FIXTURE-SHARE-B==__--filter-state__active__--output__json"
SHARE_Z_ENTRY='{"share_id":"FIXTURE-SHARE-Z==","vault_id":null,"name":null,"ok":false,"error":"not_found"}'
SHARE_B_NETWORK='{"share_id":"FIXTURE-SHARE-B==","vault_id":"FIXTURE-VAULT-B==","name":"Fixture Work","ok":false,"error":"network"}'
USAGE='{"ok":false,"error":"failed","reason":"usage"}'

# setup [scenario]: fixtures in the sandbox (default ok), debug log on.
setup() {
  use_fixture_scenario "${1:-ok}"
  export OMAPASS_DEBUG=1
  DEBUG_LOG="$XDG_RUNTIME_DIR/omapass/debug.log"
  FX="$OMAPASS_FIXTURES/pass-cli"
}

jqs() { jq -S . <<<"$1"; }

# check_envelope: no stderr, exactly one stdout line, valid JSON, no default canary anywhere.
check_envelope() {
  assert_eq "" "$S_ERR" "stderr"
  assert_eq 1 "$(wc -l <"$OMAPASS_SANDBOX/stdout" | tr -d ' ')" "stdout line count"
  jq -e type >/dev/null <<<"$S_OUT" || _omapass_fail "stdout is not JSON: $S_OUT"
  assert_no_leak
}

# assert_json <expected-json> <actual-json> [message]
assert_json() {
  assert_eq "$(jqs "$1")" "$(jqs "$2")" "${3:-json differs}"
}

# assert_out_file <file>: stdout equals the JSON file.
assert_out_file() {
  assert_json "$(<"$1")" "$S_OUT" "stdout vs $(basename "$1")"
}

# fail_vault <key> <stderr-text>: the pass-cli call fails with exit 1 and no output.
fail_vault() {
  rm -f "${FX:?}/$1.json"
  : >"$FX/$1.txt"
  printf '%s' "$2" >"$FX/$1.stderr"
  printf '1\n' >"$FX/$1.exit"
}

fail_net() { fail_vault "$1" $'Error: Error sending request\ndetail: CANARY-STDERR-net'; }
fail_agent() { fail_vault "$1" $'Error: --show-secrets is not allowed with an agent session\ndetail: CANARY-STDERR-agent'; }

# add_trashed <state>: append a trashed copy of the first SHARE-A item.
add_trashed() {
  local f="$FX/${K_A}__--show-secrets.json"
  jq --arg s "$1" '.items += [.items[0]
    | .id = "FIXTURE-ITEM-A9==" | .state = $s
    | .content.title = "Fixture Trashed CANARY-TRASHED-TITLE"
    | .content.content.Login.password = "CANARY-TRASHED-PASSWORD"]' "$f" >"$f.new"
  mv "$f.new" "$f"
}

test_list_ok() {
  setup
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_out_file "$EXPECT_LIST"
}

test_trashed_excluded() {
  local state
  for state in Trashed trashed; do
    setup
    add_trashed "$state"
    run_helper list
    assert_eq 0 "$S_RC" "exit code ($state)"
    check_envelope
    assert_no_leak CANARY-TRASHED-TITLE CANARY-TRASHED-PASSWORD
    assert_out_file "$EXPECT_LIST"
    assert_eq 4 "$(jq '.vaults[0].count' <<<"$S_OUT")" "vault A count ($state)"
    assert_not_contains "$S_OUT" FIXTURE-ITEM-A9
  done
}

test_every_canary_absent() {
  local -a canaries=()
  local c
  setup
  while IFS= read -r c; do
    canaries+=("$c")
  done < <(cat "$FX/${K_A}__--show-secrets.json" "$FX/${K_B}__--show-secrets.json" | grep -o 'CANARY[A-Za-z0-9_-]*' | sort -u)
  [[ ${#canaries[@]} -gt 0 ]] || _omapass_fail "no canaries found in fixtures"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_no_leak "${canaries[@]}"
  assert_no_leak
}

test_agent_session() {
  setup
  fail_agent "${K_A}__--show-secrets"
  fail_agent "${K_B}__--show-secrets"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_out_file "$EXPECT_AGENT"
  assert_eq agent_session "$(jq -r .notice <<<"$S_OUT")"
  assert_contains "$(<"$OMAPASS_MOCK_LOG")" "pass-cli item list --share-id FIXTURE-SHARE-A== --filter-state active --output json"
  assert_contains "$(<"$OMAPASS_MOCK_LOG")" "pass-cli item list --share-id FIXTURE-SHARE-B== --filter-state active --output json"
}

test_agent_session_one_vault() {
  setup
  fail_agent "${K_A}__--show-secrets"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_out_file "$EXPECT_AGENT"
  assert_eq agent_session "$(jq -r .notice <<<"$S_OUT")"
}

test_one_vault_fails() {
  setup
  fail_net "${K_B}__--show-secrets"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_eq true "$(jq -r .ok <<<"$S_OUT")"
  assert_eq null "$(jq -c .notice <<<"$S_OUT")"
  assert_json "$(jq -c '.vaults[0]' "$EXPECT_LIST")" "$(jq -c '.vaults[0]' <<<"$S_OUT")" "vaults[0]"
  assert_json "$SHARE_B_NETWORK" "$(jq -c '.vaults[1]' <<<"$S_OUT")" "vaults[1]"
  assert_json "$(jq -c '.items | map(select(.share_id == "FIXTURE-SHARE-A=="))' "$EXPECT_LIST")" "$(jq -c .items <<<"$S_OUT")" "items"
}

test_all_vaults_fail() {
  setup
  fail_net "${K_A}__--show-secrets"
  fail_net "${K_B}__--show-secrets"
  run_helper list
  assert_eq 15 "$S_RC" "exit code"
  check_envelope
  assert_eq '{"ok":false,"error":"network"}' "$S_OUT"
}

test_bad_output_one_vault() {
  setup
  rm -f "${FX:?}/${K_A}__--show-secrets.json"
  printf '%s' 'not json CANARY-BAD-OUTPUT {' >"$FX/${K_A}__--show-secrets.txt"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_no_leak CANARY-BAD-OUTPUT
  assert_eq false "$(jq -r '.vaults[0].ok' <<<"$S_OUT")"
  assert_eq failed "$(jq -r '.vaults[0].error' <<<"$S_OUT")"
  assert_eq true "$(jq -r '.vaults[1].ok' <<<"$S_OUT")"
}

test_vault_list_fails() {
  local sub
  for sub in list vaults; do
    setup signed_out
    run_helper "$sub"
    assert_eq 10 "$S_RC" "exit code ($sub)"
    check_envelope
    assert_eq signed_out "$(jq -r .error <<<"$S_OUT")" "error ($sub)"
  done
}

test_share_id_filter() {
  setup
  run_helper list --share-id FIXTURE-SHARE-A==
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_json "$(jq -c '.vaults[0:1]' "$EXPECT_LIST")" "$(jq -c .vaults <<<"$S_OUT")" "vaults"
  assert_json "$(jq -c '.items | map(select(.share_id == "FIXTURE-SHARE-A=="))' "$EXPECT_LIST")" "$(jq -c .items <<<"$S_OUT")" "items"
  assert_not_contains "$(<"$OMAPASS_MOCK_LOG")" FIXTURE-SHARE-B
}

test_share_id_usage() {
  setup
  run_helper list --share-id 'bad id!'
  assert_eq 2 "$S_RC" "bad id exit code"
  check_envelope
  assert_eq "$USAGE" "$S_OUT"
  run_helper list --share-id
  assert_eq 2 "$S_RC" "missing value exit code"
  check_envelope
  assert_eq "$USAGE" "$S_OUT"
  run_helper list extra
  assert_eq 2 "$S_RC" "extra arg exit code"
  check_envelope
  assert_eq "$USAGE" "$S_OUT"
}

test_share_id_unknown() {
  setup
  run_helper list --share-id FIXTURE-SHARE-Z==
  assert_eq 17 "$S_RC" "exit code"
  check_envelope
  assert_eq false "$(jq -r .ok <<<"$S_OUT")"
  assert_eq not_found "$(jq -r .error <<<"$S_OUT")"
}

test_share_id_known_and_unknown() {
  setup
  run_helper list --share-id FIXTURE-SHARE-A== --share-id FIXTURE-SHARE-Z==
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_json "$SHARE_Z_ENTRY" "$(jq -c '.vaults[1]' <<<"$S_OUT")" "vaults[1]"
}

test_zero_vaults() {
  setup
  rm -f "${FX:?}/$K_VAULTS.txt"
  printf '%s\n' '{"vaults":[]}' >"$FX/$K_VAULTS.json"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_json '{"ok":true,"notice":null,"vaults":[],"items":[]}' "$S_OUT"
}

test_vaults() {
  setup
  run_helper vaults
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_json '{"ok":true,"vaults":[{"share_id":"FIXTURE-SHARE-A==","vault_id":"FIXTURE-VAULT-A==","name":"Fixture Personal"},{"share_id":"FIXTURE-SHARE-B==","vault_id":"FIXTURE-VAULT-B==","name":"Fixture Work"}]}' "$S_OUT"
  assert_not_contains "$(<"$OMAPASS_MOCK_LOG")" "item list"
  run_helper vaults extra
  assert_eq 2 "$S_RC" "extra arg exit code"
  check_envelope
  assert_eq "$USAGE" "$S_OUT"
}

test_vaults_bad_output() {
  setup
  rm -f "${FX:?}/$K_VAULTS.txt"
  printf '%s\n' '{"vaults":"x"}' >"$FX/$K_VAULTS.json"
  run_helper vaults
  assert_eq 1 "$S_RC" "exit code"
  check_envelope
  assert_eq '{"ok":false,"error":"failed","reason":"bad_output"}' "$S_OUT"
  assert_not_contains "$(<"$OMAPASS_MOCK_LOG")" "item list"
}

test_unknown_item_variant() {
  local f
  setup
  f="$FX/${K_A}__--show-secrets.json"
  jq '.items += [.items[0]
    | .id = "FIXTURE-ITEM-A8==" | .content.content = {"Futuristic": {"secret": "CANARY-FUTURE"}}]' "$f" >"$f.new"
  mv "$f.new" "$f"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_no_leak CANARY-FUTURE
  assert_not_contains "$S_OUT" FIXTURE-ITEM-A8
  assert_out_file "$EXPECT_LIST"
}

# bad_vault_a <stdout-text> [exit]: the SHARE-A show-secrets call prints this and exits 0.
bad_vault_a() {
  rm -f "${FX:?}/${K_A}__--show-secrets.json"
  printf '%s' "$1" >"$FX/${K_A}__--show-secrets.txt"
}

test_bad_shape_one_vault() {
  local body
  for body in '' '{"items":{}}' '{}' '{"items":"CANARY-SHAPE"}' '{"items":[]} x' '{"items":[]}{"items":[]}'; do
    setup
    bad_vault_a "$body"
    run_helper list
    assert_eq 0 "$S_RC" "exit code ($body)"
    check_envelope
    assert_eq 'false failed' "$(jq -r '.vaults[0] | "\(.ok) \(.error)"' <<<"$S_OUT")" "vault A ($body)"
    assert_eq 'true 5' "$(jq -r '.vaults[1] | "\(.ok) \(.count)"' <<<"$S_OUT")" "vault B ($body)"
  done
}

test_malformed_item_skipped() {
  local f
  setup
  f="$FX/${K_A}__--show-secrets.json"
  jq '.items += [.items[0] | .id = "FIXTURE-ITEM-A7==" | .content.content.Login = "CANARY-MALFORMED"]
    | .items += [.items[0] | .id = "FIXTURE-ITEM-A6==" | .content = "CANARY-MALFORMED-2"]' "$f" >"$f.new"
  mv "$f.new" "$f"
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_no_leak CANARY-MALFORMED
  assert_out_file "$EXPECT_LIST"
}

test_share_id_duplicate() {
  setup
  run_helper list --share-id FIXTURE-SHARE-A== --share-id FIXTURE-SHARE-A==
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_eq '["FIXTURE-SHARE-A=="]' "$(jq -c '[.vaults[].share_id]' <<<"$S_OUT")" "vaults"
  assert_eq 1 "$(grep -c 'FIXTURE-SHARE-A==' "$OMAPASS_MOCK_LOG")" "one item list call"
}

# Six vaults (more than the 4-at-a-time cap): every one is listed, in vault list order.
omapass_now_ms_test() { local us="${EPOCHREALTIME/./}"; printf '%s' "$((us / 1000))"; }

test_many_vaults() {
  local i v start end
  setup
  v='{"vaults":['
  for i in 1 2 3 4 5 6; do
    [[ $i == 1 ]] || v+=','
    v+="{\"name\":\"Fixture V$i\",\"share_id\":\"FIXTURE-SHARE-M$i==\",\"vault_id\":\"FIXTURE-VAULT-M$i==\"}"
    sed "s/FIXTURE-SHARE-A==/FIXTURE-SHARE-M$i==/g" "$FX/${K_A}__--show-secrets.json" \
      >"$FX/item__list__--share-id__FIXTURE-SHARE-M$i==__--filter-state__active__--output__json__--show-secrets.json"
    printf '0.5\n' >"$FX/item__list__--share-id__FIXTURE-SHARE-M$i==__--filter-state__active__--output__json__--show-secrets.delay"
  done
  printf '%s]}\n' "$v" >"$FX/$K_VAULTS.json"
  start="$(omapass_now_ms_test)"
  run_helper list
  end="$(omapass_now_ms_test)"
  # Six 0.5 s calls, at most 4 at a time, need at least two rounds.
  ((end - start >= 950)) || _omapass_fail "6 vaults took $((end - start)) ms: parallel cap not applied"
  assert_eq 0 "$S_RC" "exit code"
  check_envelope
  assert_eq '["FIXTURE-SHARE-M1==","FIXTURE-SHARE-M2==","FIXTURE-SHARE-M3==","FIXTURE-SHARE-M4==","FIXTURE-SHARE-M5==","FIXTURE-SHARE-M6=="]' \
    "$(jq -c '[.vaults[] | select(.ok and .count == 4) | .share_id]' <<<"$S_OUT")" "vaults"
  assert_eq 24 "$(jq '.items | length' <<<"$S_OUT")" "items"
  assert_eq 6 "$(grep -c -- '--show-secrets' "$OMAPASS_MOCK_LOG")" "item list calls"
}

test_debug_log_clean() {
  local content
  setup
  run_helper list
  assert_eq 0 "$S_RC" "exit code"
  assert_file_exists "$DEBUG_LOG"
  content="$(<"$DEBUG_LOG")"
  assert_not_contains "$content" FIXTURE-SHARE
  assert_not_contains "$content" "Fixture Personal"
  assert_not_contains "$content" "Fixture Work"
  assert_no_leak
}

run_test "list returns every active item" test_list_ok
run_test "trashed items are excluded" test_trashed_excluded
run_test "no canary leaks anywhere" test_every_canary_absent
run_test "agent session falls back to title-only" test_agent_session
run_test "agent session in one vault makes every vault title-only" test_agent_session_one_vault
run_test "one failing vault is reported per vault" test_one_vault_fails
run_test "all vaults failing fails the command" test_all_vaults_fail
run_test "bad output in one vault fails only that vault" test_bad_output_one_vault
run_test "vault list failure fails list and vaults" test_vault_list_fails
run_test "--share-id limits the vaults listed" test_share_id_filter
run_test "--share-id and extra arguments are validated" test_share_id_usage
run_test "unknown --share-id is not_found" test_share_id_unknown
run_test "known and unknown --share-id mix" test_share_id_known_and_unknown
run_test "zero vaults is an empty list" test_zero_vaults
run_test "vaults lists vaults without reading items" test_vaults
run_test "vaults rejects malformed vault list" test_vaults_bad_output
run_test "unknown item variants are skipped" test_unknown_item_variant
run_test "empty or non-array item list output fails only that vault" test_bad_shape_one_vault
run_test "malformed items are skipped, not the vault" test_malformed_item_skipped
run_test "repeated --share-id is listed once" test_share_id_duplicate
run_test "more vaults than the parallel cap are all listed" test_many_vaults
run_test "debug log holds no share id or vault name" test_debug_log_clean
finish_tests
