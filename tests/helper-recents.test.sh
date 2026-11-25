#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for the recents subcommand (bin/lib/recents.sh): cap, order, permissions, privacy, settings, errors.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

recents_dir() { printf '%s/omapass' "${XDG_STATE_HOME:-$HOME/.local/state}"; }
recents_file() { printf '%s/recents.json' "$(recents_dir)"; }

# assert_ok_envelope: the last run exited 0 with ok true and a recents array.
assert_ok_envelope() {
  assert_eq 0 "$S_RC" "exit code"
  assert_eq true "$(jq -r .ok <<<"$S_OUT")" "ok"
  assert_eq array "$(jq -r '.recents | type' <<<"$S_OUT")" "recents type"
}

# assert_fail_envelope <exit> <reason>
assert_fail_envelope() {
  assert_eq "$1" "$S_RC" "exit code"
  assert_eq false "$(jq -r .ok <<<"$S_OUT")" "ok"
  assert_eq "$2" "$(jq -r '.reason // ""' <<<"$S_OUT")" "reason"
}

add_items() { # from to: adds S1/ITEM-<n>
  local n
  for ((n = $1; n <= $2; n++)); do
    run_helper recents add S1 "ITEM-$n"
    assert_ok_envelope
  done
}

test_cap_and_order() {
  add_items 1 10
  run_helper recents list
  assert_ok_envelope
  assert_eq 8 "$(jq '.recents | length' <<<"$S_OUT")" "list length"
  assert_eq ITEM-10 "$(jq -r '.recents[0].id' <<<"$S_OUT")" "newest first"
  assert_eq ITEM-3 "$(jq -r '.recents[-1].id' <<<"$S_OUT")" "oldest kept"
  assert_eq 0 "$(jq '[.recents[] | select(.id == "ITEM-1" or .id == "ITEM-2")] | length' <<<"$S_OUT")" "dropped"
  assert_eq 8 "$(jq '.recents | length' "$(recents_file)")" "file length"
}

test_readd_moves_to_front() {
  add_items 1 3
  run_helper recents add S1 ITEM-1
  assert_ok_envelope
  run_helper recents list
  assert_eq '["ITEM-1","ITEM-3","ITEM-2"]' "$(jq -c '[.recents[].id]' <<<"$S_OUT")" "order"
  assert_eq 3 "$(jq '.recents | length' "$(recents_file)")" "no duplicate in file"
}

test_permissions() {
  add_items 1 1
  assert_eq 600 "$(stat -c %a "$(recents_file)")" "file mode"
  assert_eq 700 "$(stat -c %a "$(recents_dir)")" "dir mode"
  rm -rf "$(recents_dir)"
  mkdir -p "$(recents_dir)"
  chmod 755 "$(recents_dir)"
  add_items 2 2
  assert_eq 700 "$(stat -c %a "$(recents_dir)")" "pre-existing dir mode"
  assert_eq 600 "$(stat -c %a "$(recents_file)")" "file mode again"
}

test_no_title_or_secret_stored() {
  export OMAPASS_DEBUG=1
  add_items 1 2
  assert_eq '["id","share_id","time"]' "$(jq -c '[.recents[] | keys[]] | unique' "$(recents_file)")" "file keys"
  assert_eq 0 "$(jq '[.recents[] | keys | length | select(. != 3)] | length' "$(recents_file)")" "three keys each"
  assert_not_contains "$(<"$(recents_file)")" title
  run_helper recents list
  assert_eq 0 "$(jq '[.recents[] | keys | length | select(. != 3)] | length' <<<"$S_OUT")" "list keys"
  assert_not_contains "$S_OUT" title

  cat >"$(recents_file)" <<'JSON'
{"version":1,"recents":[
{"share_id":"S1","id":"ITEM-A","time":"2026-01-01T00:00:00Z","title":"CANARY","password":"CANARY"},
{"share_id":"S1","id":"bad id","time":"CANARY","title":"CANARY"},
"CANARY",
{"share_id":"S2","id":"ITEM-B","time":"2026-01-02T00:00:00Z","password":"CANARY"}
]}
JSON
  rm -f "$XDG_RUNTIME_DIR/omapass/debug.log"
  run_helper recents list
  assert_ok_envelope
  assert_eq '[{"share_id":"S1","id":"ITEM-A","time":"2026-01-01T00:00:00Z"},{"share_id":"S2","id":"ITEM-B","time":"2026-01-02T00:00:00Z"}]' \
    "$(jq -c .recents <<<"$S_OUT")" "sanitized"
  assert_file_exists "$XDG_RUNTIME_DIR/omapass/debug.log"
  assert_no_leak CANARY
  rm -f "$XDG_RUNTIME_DIR/omapass/debug.log"
  run_helper recents add S3 ITEM-C
  assert_ok_envelope
  assert_not_contains "$(<"$(recents_file)")" CANARY
  assert_file_exists "$XDG_RUNTIME_DIR/omapass/debug.log"
  assert_no_leak CANARY
}

test_show_recents_off() {
  local value before
  for value in 0 false; do
    rm -rf "$(recents_dir)"
    OMAPASS_SHOW_RECENTS="$value" run_helper recents add S1 ITEM-1
    assert_ok_envelope
    assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "empty ($value)"
    [[ ! -e "$(recents_dir)" ]] || _omapass_fail "state dir exists with showRecents=$value"
  done
  add_items 1 3
  before="$(sha256sum "$(recents_file)")"
  for value in 0 false; do
    OMAPASS_SHOW_RECENTS="$value" run_helper recents list
    assert_ok_envelope
    assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "list empty ($value)"
    OMAPASS_SHOW_RECENTS="$value" run_helper recents add S1 ITEM-9
    assert_ok_envelope
    assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "add empty ($value)"
  done
  assert_eq "$before" "$(sha256sum "$(recents_file)")" "file unchanged"
}

test_clear() {
  add_items 1 3
  run_helper recents clear
  assert_ok_envelope
  [[ ! -e "$(recents_file)" ]] || _omapass_fail "file still exists after clear"
  run_helper recents list
  assert_ok_envelope
  assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "list after clear"

  rm -rf "$(recents_dir)"
  run_helper recents clear
  assert_ok_envelope
  [[ ! -e "$(recents_dir)" ]] || _omapass_fail "clear created the state dir"

  add_items 1 2
  OMAPASS_SHOW_RECENTS=0 run_helper recents clear
  assert_ok_envelope
  [[ ! -e "$(recents_file)" ]] || _omapass_fail "file survived clear with showRecents off"
}

test_errors() {
  run_helper recents
  assert_fail_envelope 2 usage
  run_helper recents bogus
  assert_fail_envelope 2 usage
  run_helper recents add S1
  assert_fail_envelope 2 usage
  run_helper recents list extra
  assert_fail_envelope 2 usage
  run_helper recents add 'bad id' x
  assert_fail_envelope 1 bad_input
  [[ ! -e "$(recents_file)" ]] || _omapass_fail "file written for bad input"
}

test_corrupt_file() {
  mkdir -p "$(recents_dir)"
  printf 'not json' >"$(recents_file)"
  run_helper recents list
  assert_ok_envelope
  assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "corrupt lists empty"
  run_helper recents add S1 ITEM-1
  assert_ok_envelope
  assert_eq 1 "$(jq '.recents | length' <<<"$S_OUT")" "add after corrupt"
  assert_eq 1 "$(jq '.recents | length' "$(recents_file)")" "file after corrupt"

  printf '{"recents":[]} {"recents":[]}' >"$(recents_file)"
  run_helper recents list
  assert_ok_envelope
  assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "two values list empty"
  run_helper recents add S1 ITEM-1
  assert_ok_envelope
  assert_eq 1 "$(jq '.recents | length' "$(recents_file)")" "file after two values"
}

test_pass_cli_never_called() {
  run_helper recents add S1 ITEM-1
  run_helper recents list
  run_helper recents clear
  assert_eq "" "$(<"$OMAPASS_MOCK_LOG")" "mock log"
}

test_concurrent_adds() {
  local n pids=() pid
  for n in 1 2 3 4 5 6 7 8; do
    "$OMAPASS_HELPER" recents add S1 "ITEM-$n" >"$OMAPASS_SANDBOX/out-$n" 2>/dev/null </dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || _omapass_fail "parallel add failed"
  done
  run_helper recents list
  assert_ok_envelope
  assert_eq 8 "$(jq '.recents | length' <<<"$S_OUT")" "list length"
  assert_eq 8 "$(jq '[.recents[].id] | unique | length' <<<"$S_OUT")" "distinct ids"
}

test_state_dir_symlink() {
  local target="$OMAPASS_SANDBOX/linked-state"
  mkdir -p "$target"
  ln -s "$target" "$(recents_dir)"
  run_helper recents add S1 ITEM-1
  assert_eq 1 "$S_RC" "add exit"
  assert_eq failed "$(jq -r '.error // ""' <<<"$S_OUT")" "add error"
  run_helper recents clear
  assert_eq 1 "$S_RC" "clear exit"
  assert_eq "" "$(ls -A "$target")" "nothing created in link target"
  run_helper recents list
  assert_ok_envelope
  assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "list through symlink dir"
}

test_recents_file_symlink() {
  local target="$OMAPASS_SANDBOX/linked.json" before
  mkdir -p "$(recents_dir)"
  printf '%s' '{"version":1,"recents":[{"share_id":"S9","id":"ITEM-Z","time":"2026-01-01T00:00:00Z"}]}' >"$target"
  ln -s "$target" "$(recents_file)"
  before="$(sha256sum "$target")"
  run_helper recents list
  assert_ok_envelope
  assert_eq 0 "$(jq '.recents | length' <<<"$S_OUT")" "symlink file lists empty"
  run_helper recents add S1 ITEM-1
  assert_ok_envelope
  assert_eq "$before" "$(sha256sum "$target")" "symlink target unchanged"
  [[ -f "$(recents_file)" && ! -L "$(recents_file)" ]] || _omapass_fail "recents.json is not a regular file after add"
  assert_eq 600 "$(stat -c %a "$(recents_file)")" "file mode"
}

test_preexisting_file_mode() {
  mkdir -p "$(recents_dir)"
  printf '{"version":1,"recents":[]}' >"$(recents_file)"
  chmod 644 "$(recents_file)"
  add_items 1 1
  assert_eq 600 "$(stat -c %a "$(recents_file)")" "file mode after add"
}

test_clear_removes_temp_leftover() {
  add_items 1 1
  printf 'partial' >"$(recents_dir)/.recents.abc123"
  run_helper recents clear
  assert_ok_envelope
  [[ ! -e "$(recents_dir)/.recents.abc123" ]] || _omapass_fail "temp leftover survived clear"
}

test_lock_fifo_fails_fast() {
  mkdir -p "$(recents_dir)"
  mkfifo "$(recents_dir)/recents.lock"
  S_RC=0
  timeout 10 "$OMAPASS_HELPER" recents add S1 ITEM-1 >"$OMAPASS_SANDBOX/stdout" 2>"$OMAPASS_SANDBOX/stderr" </dev/null || S_RC=$?
  S_OUT="$(<"$OMAPASS_SANDBOX/stdout")"
  assert_eq 1 "$S_RC" "exit code (124 is a hang)"
  assert_eq failed "$(jq -r '.error // ""' <<<"$S_OUT")" "error"
}

run_test "cap keeps newest 8" test_cap_and_order
run_test "re-add moves to front" test_readd_moves_to_front
run_test "file and dir permissions" test_permissions
run_test "only share_id, id, time stored" test_no_title_or_secret_stored
run_test "showRecents off writes nothing" test_show_recents_off
run_test "clear" test_clear
run_test "usage and bad input errors" test_errors
run_test "corrupt file recovers" test_corrupt_file
run_test "pass-cli is never called" test_pass_cli_never_called
run_test "parallel adds" test_concurrent_adds
run_test "state dir symlink refused" test_state_dir_symlink
run_test "recents.json symlink replaced" test_recents_file_symlink
run_test "pre-existing file mode 600" test_preexisting_file_mode
run_test "clear removes temp leftover" test_clear_removes_temp_leftover
run_test "fifo lock fails fast" test_lock_fifo_fails_fast

finish_tests
