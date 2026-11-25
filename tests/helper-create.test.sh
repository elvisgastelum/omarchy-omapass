#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for `omapass-helper create <type> --share-id <S>` (bin/lib/create.sh) against the mock pass-cli.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHARE="FIXTURE-SHARE-A=="
CREATE_KEY_PREFIX="item__create"
GEN_RANDOM_DEFAULT="password__generate__random__--length__16__--numbers__true__--uppercase__true__--symbols__true__--output__json"
GEN_RANDOM_CUSTOM="password__generate__random__--length__24__--numbers__true__--uppercase__true__--symbols__false__--output__json"
GEN_PASS_DEFAULT="password__generate__passphrase__--separator__hyphens__--capitalise__true__--numbers__true__--count__5__--output__json"
GEN_PASS_CUSTOM="password__generate__passphrase__--separator__spaces__--capitalise__false__--numbers__true__--count__6__--output__json"
GEN_SECRET="GENSECRET-RANDOM-7q"

# fx <fixture name with extension> <content>: write a pass-cli fixture into the sandbox copy.
fx() {
  printf '%s\n' "$2" >"$OMAPASS_FIXTURES/pass-cli/$1"
}

create_key() { # type
  printf '%s__%s__--share-id__%s__--from-template__-' "$CREATE_KEY_PREFIX" "$1" "$SHARE"
}

# setup_create <type>: sandbox fixtures plus a successful item create for <type>.
setup_create() {
  use_fixture_scenario create
  fx "$(create_key "$1").txt" "created"
}

# run_create <type> <form text>: runs the helper with the form on stdin (a regular file).
run_create() {
  OMAPASS_HELPER_STDIN="$OMAPASS_SANDBOX/form.json"
  export OMAPASS_HELPER_STDIN
  printf '%s' "$2" >"$OMAPASS_HELPER_STDIN"
  run_helper create "$1" --share-id "$SHARE"
}

# captured <type>: the template that pass-cli received on stdin for item create.
captured() {
  cat "$OMAPASS_MOCK_STDIN_DIR/$(create_key "$1").stdin"
}

mock_log() {
  cat "$OMAPASS_MOCK_LOG"
}

assert_no_create_call() { # type
  assert_not_contains "$(mock_log)" "item create $1 --share-id"
}

assert_error() { # error reason rc
  assert_eq false "$(jq -r .ok <<<"$S_OUT")"
  assert_eq "$1" "$(jq -r .error <<<"$S_OUT")"
  assert_eq "$2" "$(jq -r '.reason // ""' <<<"$S_OUT")"
  assert_eq "$3" "$S_RC" "exit code"
}

assert_ok_created() { # type
  assert_eq 0 "$S_RC" "exit code"
  assert_eq "{\"ok\":true,\"type\":\"$1\",\"share_id\":\"$SHARE\"}" "$S_OUT"
  assert_eq "" "$S_ERR" "stderr"
}

test_login_explicit_password() {
  local form='{"title":"Example","username":"alice","email":"a@example.com","password":"CANARY-PW-explicit","urls":["https://example.com","https://b.example.com"],"totp_uri":"otpauth://totp/x?secret=ABC"}'
  setup_create login
  run_create login "$form"
  assert_ok_created login
  jq -e . "$OMAPASS_MOCK_STDIN_DIR/$(create_key login).stdin" >/dev/null || _omapass_fail "template is not JSON"
  assert_eq "$(jq -cS '{title,username,email,password,urls,totp_uri}' <<<"$form")" \
    "$(captured login | jq -cS '{title,username,email,password,urls,totp_uri}')" "template fields"
  assert_eq '[]' "$(captured login | jq -c .extra_fields)"
  assert_eq 3 "$(wc -l <"$OMAPASS_MOCK_LOG" | tr -d ' ')" "mock log lines"
  assert_eq "pass-cli --version
pass-cli item create login --get-template
pass-cli item create login --share-id $SHARE --from-template -" "$(mock_log)"
  assert_no_leak CANARY-PW
}

test_login_generate_random_defaults() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create login
  fx "$GEN_RANDOM_DEFAULT.json" "{\"password\":\"$GEN_SECRET\"}"
  export OMAPASS_DEBUG=1
  run_create login '{"title":"Gen","generate":{"kind":"random"}}'
  assert_ok_created login
  assert_eq "$GEN_SECRET" "$(captured login | jq -r .password)"
  assert_file_exists "$dbg"
  assert_contains "$(<"$dbg")" 'cmd="password generate"'
  assert_no_leak "$GEN_SECRET"
}

test_login_generate_random_options() {
  setup_create login
  fx "$GEN_RANDOM_CUSTOM.json" "{\"password\":\"$GEN_SECRET\"}"
  run_create login '{"title":"Gen","generate":{"kind":"random","length":24,"symbols":false}}'
  assert_ok_created login
  assert_contains "$(mock_log)" "pass-cli password generate random --length 24 --numbers true --uppercase true --symbols false --output json"
  assert_eq "$GEN_SECRET" "$(captured login | jq -r .password)"
}

test_login_generate_passphrase() {
  setup_create login
  fx "$GEN_PASS_DEFAULT.json" '{"password":"GENSECRET-PASS-one"}'
  run_create login '{"title":"P","generate":{"kind":"passphrase"}}'
  assert_ok_created login
  assert_contains "$(mock_log)" "pass-cli password generate passphrase --separator hyphens --capitalise true --numbers true --count 5 --output json"
  assert_eq "GENSECRET-PASS-one" "$(captured login | jq -r .password)"

  : >"$OMAPASS_MOCK_LOG"
  fx "$GEN_PASS_CUSTOM.json" '{"password":"GENSECRET-PASS-two"}'
  run_create login '{"title":"P","generate":{"kind":"passphrase","separator":"spaces","capitalise":false,"count":6}}'
  assert_ok_created login
  assert_contains "$(mock_log)" "pass-cli password generate passphrase --separator spaces --capitalise false --numbers true --count 6 --output json"
  assert_eq "GENSECRET-PASS-two" "$(captured login | jq -r .password)"
  assert_no_leak GENSECRET-PASS-one GENSECRET-PASS-two
}

test_generator_output_shapes() {
  local shape name
  setup_create login
  for shape in '"GENSECRET-BARE"' '{"passphrase":"GENSECRET-BARE"}' '{"value":"GENSECRET-BARE"}'; do
    : >"$OMAPASS_MOCK_LOG"
    fx "$GEN_RANDOM_DEFAULT.json" "$shape"
    run_create login '{"title":"S","generate":{"kind":"random"}}'
    assert_ok_created login
    assert_eq "GENSECRET-BARE" "$(captured login | jq -r .password)" "password for $shape"
    assert_no_leak GENSECRET-BARE
  done
  rm -f "$OMAPASS_FIXTURES/pass-cli/$GEN_RANDOM_DEFAULT.json"
  for name in '{}' '{"password":""}' '[1]' 'GENSECRET-PLAIN'; do
    : >"$OMAPASS_MOCK_LOG"
    rm -f "$OMAPASS_FIXTURES/pass-cli/$GEN_RANDOM_DEFAULT".{json,txt}
    case "$name" in
      GENSECRET-PLAIN) fx "$GEN_RANDOM_DEFAULT.txt" "$name" ;;
      *) fx "$GEN_RANDOM_DEFAULT.json" "$name" ;;
    esac
    run_create login '{"title":"S","generate":{"kind":"random"}}'
    assert_error failed bad_output 1
    assert_no_create_call login
    assert_no_leak GENSECRET-PLAIN
  done
}

test_generator_failure() {
  setup_create login
  fx "$GEN_RANDOM_DEFAULT.json" '{}'
  fx "$GEN_RANDOM_DEFAULT.stderr" "Session is locked"
  fx "$GEN_RANDOM_DEFAULT.exit" "1"
  run_create login '{"title":"S","generate":{"kind":"random"}}'
  assert_eq false "$(jq -r .ok <<<"$S_OUT")"
  assert_eq locked "$(jq -r .error <<<"$S_OUT")"
  assert_eq 11 "$S_RC" "locked exit code"
  assert_no_create_call login
}

test_note() {
  setup_create note
  run_create note '{"title":"My note","note":"line one\nline two"}'
  assert_ok_created note
  assert_eq '{"title":"My note","note":"line one\nline two","extra_fields":[]}' "$(captured note | jq -c .)"

  run_create note '{"title":"Bare"}'
  assert_ok_created note
  assert_eq '{"title":"Bare","note":null,"extra_fields":[]}' "$(captured note | jq -c .)"
}

test_custom() {
  setup_create custom
  run_create custom '{"title":"C","note":"n","section":"Logins","fields":[{"name":"PIN","value":"CANARY-PIN","hidden":true},{"name":"Site","value":"x"}]}'
  assert_ok_created custom
  assert_eq '{"title":"C","note":"n"}' "$(captured custom | jq -c '{title,note}')"
  assert_eq '[{"section_name":"Logins","fields":[{"field_name":"PIN","field_type":"hidden","value":"CANARY-PIN"},{"field_name":"Site","field_type":"text","value":"x"}]}]' \
    "$(captured custom | jq -c .sections)"
  assert_no_leak CANARY-PIN

  run_create custom '{"title":"C"}'
  assert_ok_created custom
  assert_eq '[]' "$(captured custom | jq -c .sections)"
  assert_eq '""' "$(captured custom | jq -c .note)"

  run_create custom '{"title":"C","fields":[{"name":"A","value":"v"}]}'
  assert_ok_created custom
  assert_eq 'Fields' "$(captured custom | jq -r '.sections[0].section_name')"
}

test_invalid_form() {
  local form big i=0 label
  setup_create login
  big="$(printf '%070000d' 0)"
  local -a forms=(
    '' 'not json' '[1]' '{} {}' '{"note":"x"}' '{"title":""}' '{"title":"t","bogus":1}'
    '{"title":"t","username":5}'
    '{"title":"t","password":"CANARY-PW","generate":{"kind":"random"}}'
    '{"title":"t","generate":{"kind":"bogus"}}'
    '{"title":"t","generate":{"kind":"random","length":7}}'
    '{"title":"t","generate":{"kind":"random","length":65}}'
    '{"title":"t","generate":{"kind":"passphrase","separator":"dashes"}}'
    "{\"title\":\"$big\"}"
  )
  for form in "${forms[@]}"; do
    i=$((i + 1))
    label="login form #$i"
    : >"$OMAPASS_MOCK_LOG"
    run_create login "$form"
    assert_eq '{"ok":false,"error":"failed","reason":"bad_input"}' "$S_OUT" "$label"
    assert_eq 1 "$S_RC" "$label exit code"
    assert_eq "" "$(mock_log)" "$label mock log"
  done
  setup_create custom
  : >"$OMAPASS_MOCK_LOG"
  run_create custom '{"title":"t","fields":[{"value":"x"}]}'
  assert_eq '{"ok":false,"error":"failed","reason":"bad_input"}' "$S_OUT"
  assert_eq 1 "$S_RC" "exit code"
  assert_eq "" "$(mock_log)" "mock log"
  assert_no_leak CANARY-PW
}

test_usage() {
  local -a argsets=(
    "bogus --share-id $SHARE"
    "ssh-key --share-id $SHARE"
    "login"
    "login --share-id $SHARE extra"
    "login --share-id a/b"
  )
  local args
  setup_create login
  for args in "${argsets[@]}"; do
    : >"$OMAPASS_MOCK_LOG"
    OMAPASS_HELPER_STDIN="$OMAPASS_SANDBOX/form.json"
    export OMAPASS_HELPER_STDIN
    printf '%s' '{"title":"t"}' >"$OMAPASS_HELPER_STDIN"
    # shellcheck disable=SC2086 # the argument sets are split on purpose
    run_helper create $args
    assert_error failed usage 2
    assert_eq "" "$(mock_log)" "mock log for: $args"
  done
}

test_item_create_failure() {
  setup_create login
  fx "$(create_key login).stderr" "Session is locked"
  fx "$(create_key login).exit" "1"
  run_create login '{"title":"t","password":"CANARY-PW"}'
  assert_eq false "$(jq -r .ok <<<"$S_OUT")"
  assert_eq locked "$(jq -r .error <<<"$S_OUT")"
  assert_eq 11 "$S_RC" "locked exit code"
  assert_no_leak CANARY-PW
}

test_template_missing_key() {
  setup_create login
  fx "item__create__login__--get-template.json" '{"title":""}'
  run_create login '{"title":"t"}'
  assert_error failed bad_output 1
  assert_no_create_call login
}

test_secrets_not_exported() {
  local envlog="$OMAPASS_SANDBOX/mock.env"
  setup_create login
  fx "$GEN_RANDOM_DEFAULT.json" "{\"password\":\"$GEN_SECRET\"}"
  export OMAPASS_CREATE_FORM=inherited OMAPASS_CREATE_SECRET=inherited OMAPASS_CREATE_FILLED=inherited
  export OMAPASS_MOCK_ENV_LOG="$envlog"
  run_create login '{"title":"Env","username":"CANARY-ENV-user","generate":{"kind":"random"}}'
  assert_ok_created login
  assert_eq "$GEN_SECRET" "$(captured login | jq -r .password)"
  assert_file_exists "$envlog"
  assert_not_contains "$(<"$envlog")" "$GEN_SECRET" "generated password in pass-cli env"
  assert_not_contains "$(<"$envlog")" "CANARY-ENV-user" "form in pass-cli env"
  assert_not_contains "$(<"$envlog")" "OMAPASS_CREATE_" "create globals exported"
  assert_no_leak "$GEN_SECRET" CANARY-ENV-user
}

run_test "login with explicit password creates the item" test_login_explicit_password
run_test "login generate random defaults keeps the secret out of logs" test_login_generate_random_defaults
run_test "login generate random with explicit false option" test_login_generate_random_options
run_test "login generate passphrase defaults and options" test_login_generate_passphrase
run_test "generator output shapes and fail-closed parsing" test_generator_output_shapes
run_test "generator pass-cli failure is classified and creates nothing" test_generator_failure
run_test "note fills title and note" test_note
run_test "custom builds sections from fields" test_custom
run_test "invalid form JSON fails before pass-cli runs" test_invalid_form
run_test "usage errors fail before pass-cli runs" test_usage
run_test "item create failure is classified" test_item_create_failure
run_test "template missing a needed key is bad_output" test_template_missing_key
run_test "create globals inherited from the environment are not exported" test_secrets_not_exported

finish_tests
