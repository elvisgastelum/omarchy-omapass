#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for bin/lib/copy.sh and bin/lib/clipboard.sh against the item view and totp fixtures.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT_JSON="$(sed -n '/<!-- contract:begin -->/,/<!-- contract:end -->/p' "$REPO_ROOT/docs/CONTRACT.md" | grep -v -e '^<!--' -e '^```')"

SID=""
IID=""
CLIP=""
CLIP_PRESENT=0
WANT=""
WANT_EMPTY=0

# fx_ids <variant>: sets SID and IID to the fixture item of that variant.
fx_ids() {
  local s n
  case "$1" in
    Login) s=A n=A1 ;;
    Alias) s=A n=A3 ;;
    Note) s=A n=A4 ;;
    CreditCard) s=B n=B1 ;;
    Identity) s=B n=B2 ;;
    SshKey) s=B n=B3 ;;
    Wifi) s=B n=B4 ;;
    Custom) s=B n=B5 ;;
    *) _omapass_fail "unknown variant $1" ;;
  esac
  SID="FIXTURE-SHARE-$s=="
  IID="FIXTURE-ITEM-$n=="
}

fx_dir() { printf '%s/pass-cli' "$OMAPASS_FIXTURES"; }
fx_view() { printf '%s/item__view__--share-id__%s__--item-id__%s__--output__json.json' "$(fx_dir)" "$1" "$2"; }
fx_totp() { printf '%s/item__totp__--share-id__%s__--item-id__%s__--output__json.json' "$(fx_dir)" "$1" "$2"; }

# fixture_value <view file> <path json>: sets WANT (byte-exact) and WANT_EMPTY (1 when empty or null).
fixture_value() {
  local out
  out="$(jq -j --argjson p "$2" '(.item | getpath($p)) as $v | if $v == null or $v == "" then "N" else "V\($v)x" end' "$1"; printf y)"
  out="${out%y}"
  if [[ "$out" == N ]]; then
    WANT="" WANT_EMPTY=1
  else
    WANT="${out:1}"
    WANT="${WANT%x}"
    WANT_EMPTY=0
  fi
}

# clip_get: sets CLIP (byte-exact) and CLIP_PRESENT from the mock clipboard file.
clip_get() {
  local f="$XDG_RUNTIME_DIR/omapass-mock-clipboard"
  CLIP="" CLIP_PRESENT=0
  if [[ -f "$f" ]]; then
    CLIP_PRESENT=1
    CLIP="$(cat "$f"; printf x)"
    CLIP="${CLIP%x}"
  fi
}

state_file() { printf '%s/omapass/clipboard.state' "$XDG_RUNTIME_DIR"; }

wait_state_gone() {
  local i
  for ((i = 0; i < 40; i++)); do
    [[ -e "$(state_file)" ]] || return 0
    sleep 0.2
  done
  _omapass_fail "clipboard.state still present after 8 s"
}

# kill_clearer: stop the detached clipboard-clear of the latest copy (and its sleep) so nothing
# outlives the test. setsid -f forks before it execs, so wait until the bash clearer shows up.
kill_clearer() {
  local tok pid i
  read -r _ tok _ <"$(state_file)"
  for ((i = 0; i < 30; i++)); do
    pid="$(pgrep -f "^bash .*clipboard-clear $tok" | head -n 1 || true)"
    if [[ -n "$pid" ]]; then
      kill -STOP "$pid"
      pkill -P "$pid" || true
      kill -KILL "$pid"
      return 0
    fi
    sleep 0.1
  done
  _omapass_fail "no clipboard-clear process found for the latest copy"
}

assert_log_has() { grep -qxF -- "$1" "$OMAPASS_MOCK_LOG" || _omapass_fail "mock log lacks line '$1'"; }
assert_log_lacks() { ! grep -qF -- "$1" "$OMAPASS_MOCK_LOG" || _omapass_fail "mock log has '$1'"; }
assert_no_wl_copy() { ! grep -q '^wl-copy' "$OMAPASS_MOCK_LOG" || _omapass_fail "wl-copy was called"; }

# do_copy <sid> <iid> <field> [args...]
do_copy() { run_helper copy "$@"; }

# expect_copied <field> <clear_after>: success envelope on stdout, nothing on stderr.
expect_copied() {
  assert_eq 0 "$S_RC" "exit code"
  assert_eq "$(jq -cn --arg f "$1" --argjson c "$2" '{ok:true,field:$f,clear_after:$c}')" "$S_OUT"
  assert_eq "" "$S_ERR" "stderr"
}

expect_fail() { # rc error [reason]
  local want
  want="$(jq -cn --arg e "$2" --arg r "${3:-}" '{ok:false,error:$e} + (if $r == "" then {} else {reason:$r} end)')"
  assert_eq "$1" "$S_RC" "exit code"
  assert_eq "$want" "$S_OUT"
}

# make_spy: argv-recording wrappers for the helper's external tools, first on PATH.
make_spy() {
  local spy="$OMAPASS_SANDBOX/spy" n real
  mkdir -p "$spy"
  for n in jq sha256sum od head tr cat setsid sleep timeout flock mktemp mv rm chmod stat id dirname readlink date mkdir; do
    real="$(command -v "$n")"
    # shellcheck disable=SC2016 # $* and $@ expand when the wrapper runs
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$OMAPASS_MOCK_LOG"\nexec %q "$@"\n' "$n" "$real" >"$spy/$n"
    chmod 755 "$spy/$n"
  done
  PATH="$spy:$PATH"
  export PATH
  hash -r
}

test_every_contract_field() {
  local variant field path totp
  use_fixture_scenario ok
  while IFS=$'\t' read -r variant field path totp; do
    fx_ids "$variant"
    rm -f "$XDG_RUNTIME_DIR/omapass-mock-clipboard"
    : >"$OMAPASS_MOCK_LOG"
    do_copy "$SID" "$IID" "$field" --clear-after 0
    if [[ "$totp" == true ]]; then
      WANT="$(jq -j '.totp' "$(fx_totp "$SID" "$IID")")" WANT_EMPTY=0
    else
      fixture_value "$(fx_view "$SID" "$IID")" "$path"
    fi
    clip_get
    if ((WANT_EMPTY)); then
      expect_fail 17 not_found
      assert_eq 0 "$CLIP_PRESENT" "$variant/$field clipboard untouched"
      assert_no_wl_copy
    else
      expect_copied "$field" 0
      assert_eq "$WANT" "$CLIP" "$variant/$field clipboard"
      assert_log_has "wl-copy --sensitive"
      assert_log_lacks "wl-copy --sensitive -o"
    fi
  done < <(jq -r '.types[] | .variant as $v | .copy | to_entries[] | [$v, .key, (.value.path | tojson), (.value.totp // false)] | @tsv' <<<"$CONTRACT_JSON")
}

# expect_field <variant> <field> <want|NOTFOUND>
expect_field() {
  fx_ids "$1"
  rm -f "$XDG_RUNTIME_DIR/omapass-mock-clipboard"
  do_copy "$SID" "$IID" "$2" --clear-after 0
  if [[ "$3" == NOTFOUND ]]; then
    expect_fail 17 not_found
    clip_get
    assert_eq 0 "$CLIP_PRESENT" "$2 clipboard untouched"
  else
    expect_copied "$2" 0
    clip_get
    assert_eq "$3" "$CLIP" "$1 $2"
  fi
}

test_dynamic_fields() {
  use_fixture_scenario ok
  expect_field Login extra:0 CANARY-EXTRA-TEXT-1
  expect_field Login extra:1 CANARY-EXTRA-HIDDEN-1
  expect_field Login extra:2 564738
  expect_field Login extra:3 1767225600
  expect_field SshKey section:0:0 CANARY-SSH-SECTION-1
  expect_field Custom section:0:0 CANARY-SECTION-TEXT-1
  expect_field Custom section:0:1 CANARY-SECTION-HIDDEN-1
  expect_field Custom section:0:2 192837
  expect_field Custom section:0:3 1767225600
  expect_field Custom section:0:4 NOTFOUND
  expect_field Login extra:99 NOTFOUND
  expect_field Custom section:9:0 NOTFOUND
}

test_no_leak() {
  local key case_ variant field
  use_fixture_scenario ok
  make_spy
  export OMAPASS_DEBUG=1
  for case_ in "Login password" "Login totp" "CreditCard number" "SshKey private_key"; do
    read -r variant field <<<"$case_"
    fx_ids "$variant"
    do_copy "$SID" "$IID" "$field" --clear-after 1
    expect_copied "$field" 1
    assert_eq 1 "$(wc -l <"$OMAPASS_SANDBOX/stdout" | tr -d ' ')" "stdout is one line"
    key="$(<"$XDG_RUNTIME_DIR/omapass/clipboard.key")"
    assert_eq 128 "${#key}" "key length"
    assert_file_exists "$XDG_RUNTIME_DIR/omapass/debug.log"
    [[ -s "$XDG_RUNTIME_DIR/omapass/debug.log" ]] || _omapass_fail "debug log is empty"
    assert_contains "$(<"$XDG_RUNTIME_DIR/omapass/debug.log")" clipboard
    wait_state_gone
    assert_no_leak CANARY 918273 564738 "$key"
  done
  assert_contains "$(<"$OMAPASS_MOCK_LOG")" "sha256sum"
}

test_permissions() {
  local d="$XDG_RUNTIME_DIR/omapass" f
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  assert_eq 700 "$(stat -c %a "$d")" "dir mode"
  for f in clipboard.key clipboard.state clipboard.lock; do
    assert_eq 600 "$(stat -c %a "$d/$f")" "$f mode"
  done
}

test_clear_performed() {
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 1
  expect_copied password 1
  clip_get
  assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP"
  wait_state_gone
  clip_get
  assert_eq 0 "$CLIP_PRESENT" "clipboard cleared"
  assert_log_has "wl-copy --clear"
}

test_clear_skipped_when_changed() {
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 1
  expect_copied password 1
  printf 'other-text' | wl-copy
  wait_state_gone
  clip_get
  assert_eq other-text "$CLIP"
}

test_newer_copy_supersedes() {
  use_fixture_scenario ok
  fx_ids Login
  # 2 s and 5 s leave margin for slow machines between the two copies.
  do_copy "$SID" "$IID" password --clear-after 2
  expect_copied password 2
  do_copy "$SID" "$IID" password --clear-after 5
  expect_copied password 5
  sleep 2.5
  clip_get
  assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP" "still copied after the first deadline"
  wait_state_gone
  clip_get
  assert_eq 0 "$CLIP_PRESENT" "cleared by the newer copy"
}

test_unknown_field() {
  local f
  use_fixture_scenario ok
  fx_ids Login
  for f in bogus ../x ""; do
    do_copy "$SID" "$IID" "$f"
    expect_fail 17 not_found
  done
  fx_ids Note
  do_copy "$SID" "$IID" password
  expect_fail 17 not_found
  assert_no_wl_copy
}

test_clear_delay() {
  local v tok deadline
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password
  expect_copied password 45
  kill_clearer
  make_spy
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  read -r _ tok deadline _ <"$(state_file)"
  assert_eq 0 "$deadline" "deadline"
  assert_log_lacks "setsid"
  do_copy "$SID" "$IID" password --clear-after 300
  expect_copied password 300
  kill_clearer
  : >"$OMAPASS_MOCK_LOG"
  for v in 301 -1 abc 1.5 045; do
    do_copy "$SID" "$IID" password --clear-after "$v"
    expect_fail 2 failed usage
  done
  do_copy "$SID" "$IID" password --clear-after
  expect_fail 2 failed usage
  assert_log_lacks "pass-cli item view"
}

test_paste_once() {
  local second
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 0
  assert_log_has "wl-copy --sensitive"
  assert_log_lacks " -o"
  : >"$OMAPASS_MOCK_LOG"
  do_copy "$SID" "$IID" password --paste-once --clear-after 0
  expect_copied password 0
  assert_log_has "wl-copy --sensitive -o"
  assert_eq CANARY-LOGIN-PASSWORD-1 "$(wl-paste -n)"
  second="$(wl-paste -n 2>/dev/null || true)"
  assert_ne CANARY-LOGIN-PASSWORD-1 "$second" "second paste"
}

test_errors() {
  local view totp
  use_fixture_scenario ok
  fx_ids Login
  view="$(fx_view "$SID" "$IID")"
  totp="$(fx_totp "$SID" "$IID")"

  printf 'Error: Session is locked. Please unlock your session and try again.\n' >"${view%.json}.stderr"
  printf '1\n' >"${view%.json}.exit"
  do_copy "$SID" "$IID" password
  expect_fail 11 locked
  rm -f "${view%.json}.stderr" "${view%.json}.exit"

  cp "$view" "$view.orig"
  jq '.item.id = "OTHER-ITEM"' "$view.orig" >"$view"
  do_copy "$SID" "$IID" password
  expect_fail 1 failed bad_output

  printf 'this is not json\n' >"$view"
  do_copy "$SID" "$IID" password
  expect_fail 1 failed bad_output

  jq '(.item.content.extra_fields[2].name) = "totp"' "$view.orig" >"$view"
  do_copy "$SID" "$IID" extra:2
  expect_fail 1 failed
  cp "$view.orig" "$view"

  printf '{"totp": "918273"}\n' >"$totp"
  do_copy "$SID" "$IID" extra:2
  expect_fail 17 not_found
  printf '{"totp": "12ab"}\n' >"$totp"
  do_copy "$SID" "$IID" totp
  expect_fail 1 failed bad_output

  do_copy a/b "$IID" password
  expect_fail 2 failed usage
  run_helper copy "$SID" "$IID"
  expect_fail 2 failed usage
  run_helper copy
  expect_fail 2 failed usage
  assert_no_wl_copy
}

test_multi_json() {
  local view totp
  use_fixture_scenario ok
  fx_ids Login
  view="$(fx_view "$SID" "$IID")"
  totp="$(fx_totp "$SID" "$IID")"

  cp "$view" "$view.orig"
  cat "$view.orig" "$view.orig" >"$view"
  : >"$OMAPASS_MOCK_LOG"
  do_copy "$SID" "$IID" password --clear-after 0
  expect_fail 1 failed bad_output
  assert_no_wl_copy
  cp "$view.orig" "$view"

  cp "$totp" "$totp.orig"
  cat "$totp.orig" "$totp.orig" >"$totp"
  : >"$OMAPASS_MOCK_LOG"
  do_copy "$SID" "$IID" totp --clear-after 0
  expect_fail 1 failed bad_output
  assert_no_wl_copy
  cp "$totp.orig" "$totp"
}

test_unknown_kind() {
  local view before
  use_fixture_scenario ok
  fx_ids Login
  view="$(fx_view "$SID" "$IID")"

  cp "$view" "$view.orig"
  jq '.item.content.extra_fields[0].content = {"Weird": "CANARY-WEIRD-1"}' "$view.orig" >"$view"
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  clip_get
  assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP"

  before="$(grep -c '^wl-copy' "$OMAPASS_MOCK_LOG" || true)"
  do_copy "$SID" "$IID" extra:0 --clear-after 0
  expect_fail 1 failed bad_output
  assert_eq "$before" "$(grep -c '^wl-copy' "$OMAPASS_MOCK_LOG" || true)" "wl-copy calls after extra:0"
  cp "$view.orig" "$view"
}

test_malformed_dynamic_fields() {
  local view before mut
  use_fixture_scenario ok
  fx_ids Login
  view="$(fx_view "$SID" "$IID")"

  cp "$view" "$view.orig"
  for mut in '.item.content.extra_fields[1] = null' '.item.content.extra_fields[1] = {"name":"x","content":{}}'; do
    jq "$mut" "$view.orig" >"$view"
    do_copy "$SID" "$IID" password --clear-after 0
    expect_copied password 0
    clip_get
    assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP"

    before="$(grep -c '^wl-copy' "$OMAPASS_MOCK_LOG" || true)"
    do_copy "$SID" "$IID" extra:1 --clear-after 0
    expect_fail 1 failed bad_output
    assert_eq "$before" "$(grep -c '^wl-copy' "$OMAPASS_MOCK_LOG" || true)" "wl-copy calls after extra:1"
  done
  cp "$view.orig" "$view"

  jq '.item.content.extra_fields[1].name = null' "$view.orig" >"$view"
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  clip_get
  assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP"
  do_copy "$SID" "$IID" extra:1 --clear-after 0
  expect_copied extra:1 0
  clip_get
  assert_eq CANARY-EXTRA-HIDDEN-1 "$CLIP"
  cp "$view.orig" "$view"

  fx_ids Custom
  view="$(fx_view "$SID" "$IID")"
  cp "$view" "$view.orig"
  jq '.item.content.content.Custom.sections = "x"' "$view.orig" >"$view"
  do_copy "$SID" "$IID" section:0:0 --clear-after 0
  expect_fail 17 not_found
  cp "$view.orig" "$view"
}

test_hmac_vector() {
  local got
  got="$(
    # shellcheck source=../bin/lib/core.sh
    source "$REPO_ROOT/bin/lib/core.sh"
    # shellcheck source=../bin/lib/clipboard.sh
    source "$REPO_ROOT/bin/lib/clipboard.sh"
    OMAPASS_CLIP_KEY="$(for i in $(seq 0 63); do printf '%02x' "$i"; done)"
    printf 'hello\nworld\n' | omapass__clip_hmac
  )"
  assert_eq 57e491907c8db09bcb2352da43ef3f44606817f722675ae91bf9283bbfe997a0 "$got"
}

# clear_now: run omapass_clipboard_clear_now from a sourced shell.
clear_now() {
  (
    # shellcheck source=../bin/lib/core.sh
    source "$REPO_ROOT/bin/lib/core.sh"
    # shellcheck source=../bin/lib/clipboard.sh
    source "$REPO_ROOT/bin/lib/clipboard.sh"
    omapass_clipboard_clear_now
  )
}

test_clear_now() {
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  clear_now
  clip_get
  assert_eq 0 "$CLIP_PRESENT" "clipboard cleared"
  [[ ! -e "$(state_file)" ]] || _omapass_fail "state not removed"

  do_copy "$SID" "$IID" password --clear-after 0
  printf 'other-text' | wl-copy
  clear_now
  clip_get
  assert_eq other-text "$CLIP"
  [[ ! -e "$(state_file)" ]] || _omapass_fail "state not removed"
}

test_key_regeneration() {
  local k="$XDG_RUNTIME_DIR/omapass/clipboard.key" old
  use_fixture_scenario ok
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  old="$(<"$k")"
  chmod 644 "$k"
  do_copy "$SID" "$IID" password --clear-after 0
  expect_copied password 0
  assert_eq 600 "$(stat -c %a "$k")" "key mode"
  assert_ne "$old" "$(<"$k")" "key content"
}

test_clipboard_clear_direct() {
  use_fixture_scenario ok
  run_helper clipboard-clear nothex
  expect_fail 2 failed usage
  run_helper clipboard-clear
  expect_fail 2 failed usage
  fx_ids Login
  do_copy "$SID" "$IID" password --clear-after 0
  run_helper clipboard-clear 0123456789abcdef0123456789abcdef
  assert_eq 0 "$S_RC"
  assert_eq '{"ok":true,"cleared":false}' "$S_OUT"
  clip_get
  assert_eq CANARY-LOGIN-PASSWORD-1 "$CLIP"
}

run_test "every contract copy field" test_every_contract_field
run_test "dynamic extra and section fields" test_dynamic_fields
run_test "no secret leaks into logs or argv" test_no_leak
run_test "state dir and files are private" test_permissions
run_test "clear runs when the clipboard is unchanged" test_clear_performed
run_test "clear is skipped when the clipboard changed" test_clear_skipped_when_changed
run_test "a newer copy supersedes the older clear" test_newer_copy_supersedes
run_test "unknown fields are not_found" test_unknown_field
run_test "clear delay values" test_clear_delay
run_test "paste-once" test_paste_once
run_test "errors never reach wl-copy" test_errors
run_test "multiple JSON documents are refused" test_multi_json
run_test "unknown dynamic kind fails only that field" test_unknown_kind
run_test "malformed dynamic fields fail only themselves" test_malformed_dynamic_fields
run_test "HMAC test vector" test_hmac_vector
run_test "omapass_clipboard_clear_now" test_clear_now
run_test "key regeneration" test_key_regeneration
run_test "clipboard-clear direct" test_clipboard_clear_direct
finish_tests
