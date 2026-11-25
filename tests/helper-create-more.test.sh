#!/usr/bin/env bash
# shellcheck disable=SC2329 # test_* functions are invoked indirectly by name by the test runner
# Tests for the create types in bin/lib/create-types.sh (credit-card, wifi, identity, alias, ssh-key)
# against the mock pass-cli.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHARE="FIXTURE-SHARE-A=="
GEN_RANDOM_DEFAULT="password__generate__random__--length__16__--numbers__true__--uppercase__true__--symbols__true__--output__json"
GEN_SECRET="GENSECRET-RANDOM-7q"
ALIAS_KEY="item__alias__create__--share-id__${SHARE}__--prefix__shop.news__--output__json"
SSH_GEN_BASE="item__create__ssh-key__generate__--share-id__${SHARE}"
SSH_IMPORT_KEY="item__create__ssh-key__import__--share-id__${SHARE}__--title__Imported__--from-private-key___dev_stdin"
PEM=$'-----BEGIN OPENSSH PRIVATE KEY-----\nCANARY-SSHKEY-b3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\n'

# fx <fixture name with extension> <content>: write a pass-cli fixture into the sandbox copy.
fx() {
  printf '%s\n' "$2" >"$OMAPASS_FIXTURES/pass-cli/$1"
}

create_key() { # type
  printf 'item__create__%s__--share-id__%s__--from-template__-' "$1" "$SHARE"
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

assert_bad_input() {
  assert_error failed bad_input 1
}

# assert_no_pass_create: no item create, alias create or generator call reached pass-cli.
assert_no_pass_create() {
  assert_not_contains "$(mock_log)" "item create" "item create call"
  assert_not_contains "$(mock_log)" "item alias" "alias call"
}

test_credit_card() {
  local form='{"title":"Visa","cardholder_name":"A Tester","number":"CANARY-CARDNUM-4111","cvv":"CANARY-CVV-77","pin":"CANARY-PIN-9","expiration_date":"2031-07","note":"n"}'
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create credit-card
  export OMAPASS_DEBUG=1
  run_create credit-card "$form"
  assert_ok_created credit-card
  jq -e . "$OMAPASS_MOCK_STDIN_DIR/$(create_key credit-card).stdin" >/dev/null || _omapass_fail "template is not JSON"
  local keys='{title,cardholder_name,number,cvv,pin,expiration_date,note}'
  assert_eq "$(jq -cS "$keys" <<<"$form")" "$(captured credit-card | jq -cS "$keys")" "template fields"
  assert_eq "pass-cli --version
pass-cli item create credit-card --get-template
pass-cli item create credit-card --share-id $SHARE --from-template -" "$(mock_log)"
  assert_file_exists "$dbg"
  assert_no_leak CANARY

  : >"$OMAPASS_MOCK_LOG"
  run_create credit-card '{"title":"Visa","expiration_date":"2031-13"}'
  assert_bad_input
  assert_eq "" "$(mock_log)" "mock log"
}

test_wifi_explicit_password() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create wifi
  export OMAPASS_DEBUG=1
  run_create wifi '{"title":"Home","ssid":"HomeNet","password":"CANARY-WIFI-pw","note":"router"}'
  assert_ok_created wifi
  assert_eq '{"title":"Home","ssid":"HomeNet","password":"CANARY-WIFI-pw","note":"router"}' \
    "$(captured wifi | jq -c '{title,ssid,password,note}')"
  assert_file_exists "$dbg"
  assert_no_leak CANARY
}

test_wifi_generate() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create wifi
  fx "$GEN_RANDOM_DEFAULT.json" "{\"password\":\"$GEN_SECRET\"}"
  export OMAPASS_DEBUG=1
  run_create wifi '{"title":"Gen","ssid":"Net","generate":{"kind":"random"}}'
  assert_ok_created wifi
  assert_eq "$GEN_SECRET" "$(captured wifi | jq -r .password)"
  assert_eq Net "$(captured wifi | jq -r .ssid)"
  assert_file_exists "$dbg"
  assert_no_leak "$GEN_SECRET"
}

test_wifi_password_and_generate() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create wifi
  fx "$GEN_RANDOM_DEFAULT.json" "{\"password\":\"$GEN_SECRET\"}"
  export OMAPASS_DEBUG=1
  run_create wifi '{"title":"Both","password":"CANARY-WIFI-pw","generate":{"kind":"random"}}'
  assert_bad_input
  assert_no_pass_create
  assert_not_contains "$(mock_log)" "password generate"
  assert_file_exists "$dbg"
  assert_no_leak CANARY-WIFI-pw
}

test_identity() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create identity
  export OMAPASS_DEBUG=1
  run_create identity '{"title":"Me","full_name":"Ann Tester","email":"ann@example.com","city":"Testville","social_security_number":"CANARY-SSN-1","passport_number":"CANARY-PASSPORT-2","note":"id note"}'
  assert_ok_created identity
  assert_eq '{"title":"Me","full_name":"Ann Tester","email":"ann@example.com","city":"Testville","social_security_number":"CANARY-SSN-1","passport_number":"CANARY-PASSPORT-2","note":"id note"}' \
    "$(captured identity | jq -c '{title,full_name,email,city,social_security_number,passport_number,note}')"
  assert_eq '{"phone_number":"","first_name":"","work_email":"","company":""}' \
    "$(captured identity | jq -c '{phone_number,first_name,work_email,company}')" "unset keys stay empty"
  assert_file_exists "$dbg"
  assert_no_leak CANARY

  run_create identity '{"title":"Me","email":null}'
  assert_ok_created identity
  assert_eq '""' "$(captured identity | jq -c .email)" "explicit null keeps the template value"

  : >"$OMAPASS_MOCK_LOG"
  run_create identity '{"title":"Me","bogus":"x"}'
  assert_bad_input
  assert_eq "" "$(mock_log)" "mock log"
}

test_alias() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  setup_create alias
  fx "$ALIAS_KEY.json" '{"alias":"shop.news.abc@example.test"}'
  export OMAPASS_DEBUG=1
  run_create alias '{"prefix":"shop.news"}'
  assert_ok_created alias
  assert_contains "$(mock_log)" "pass-cli item alias create --share-id $SHARE --prefix shop.news --output json"
  assert_not_contains "$(mock_log)" "get-template"

  local prefix
  for prefix in "Bad Prefix" "-x" "" "CANARY-ALIAS bad"; do
    rm -f "$dbg"
    : >"$OMAPASS_MOCK_LOG"
    run_create alias "$(jq -cn --arg p "$prefix" '{prefix:$p}')"
    assert_bad_input
    assert_not_contains "$(mock_log)" "item alias" "alias call for '$prefix'"
  done
  assert_file_exists "$dbg"
  assert_no_leak CANARY-ALIAS
}

test_alias_failure() {
  setup_create alias
  fx "$ALIAS_KEY.json" '{}'
  fx "$ALIAS_KEY.stderr" "something broke"
  fx "$ALIAS_KEY.exit" "1"
  run_create alias '{"prefix":"shop.news"}'
  assert_error failed "" 1
}

test_ssh_key_generate() {
  setup_create ssh-key
  fx "${SSH_GEN_BASE}__--title__Dev_box__--key-type__rsa4096__--comment__me@host.txt" "created"
  run_create ssh-key '{"title":"Dev box","mode":"generate","key_type":"rsa4096","comment":"me@host"}'
  assert_ok_created ssh-key
  assert_contains "$(mock_log)" "pass-cli item create ssh-key generate --share-id $SHARE --title Dev box --key-type rsa4096 --comment me@host"

  : >"$OMAPASS_MOCK_LOG"
  fx "${SSH_GEN_BASE}__--title__Plain__--key-type__ed25519.txt" "created"
  run_create ssh-key '{"title":"Plain","mode":"generate"}'
  assert_ok_created ssh-key
  assert_eq "pass-cli --version
pass-cli item create ssh-key generate --share-id $SHARE --title Plain --key-type ed25519" "$(mock_log)"
  assert_not_contains "$(mock_log)" "--comment"
}

test_ssh_key_import() {
  local dbg="$XDG_RUNTIME_DIR/omapass/debug.log" form
  setup_create ssh-key
  fx "$SSH_IMPORT_KEY.txt" "created"
  form="$(jq -cn --arg k "$PEM" '{title:"Imported",mode:"import",private_key:$k}')"
  export OMAPASS_DEBUG=1
  run_create ssh-key "$form"
  assert_ok_created ssh-key
  assert_contains "$(mock_log)" "pass-cli item create ssh-key import --share-id $SHARE --title Imported --from-private-key /dev/stdin"
  # the trailing x keeps $(...) from stripping the key's final newline
  assert_eq "${PEM}x" "$(cat "$OMAPASS_MOCK_STDIN_DIR/$SSH_IMPORT_KEY.stdin"; printf x)" "private key on stdin"
  assert_file_exists "$dbg"
  assert_no_leak CANARY-SSHKEY
}

test_secrets_not_in_env() {
  local envlog="$OMAPASS_SANDBOX/mock.env" form dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  export OMAPASS_CREATE_FORM=x OMAPASS_CREATE_SECRET=x OMAPASS_CREATE_FILLED=x
  export OMAPASS_MOCK_ENV_LOG="$envlog" OMAPASS_DEBUG=1

  setup_create credit-card
  run_create credit-card '{"title":"Visa","number":"CANARY-CARDNUM-4111","cvv":"CANARY-CVV-77","pin":"CANARY-PIN-9"}'
  assert_ok_created credit-card
  assert_file_exists "$envlog"
  assert_not_contains "$(<"$envlog")" CANARY "card secrets in pass-cli env"
  assert_not_contains "$(<"$envlog")" "OMAPASS_CREATE_" "create globals exported"
  assert_file_exists "$dbg"
  assert_no_leak CANARY

  rm -f "$dbg"
  : >"$envlog"
  setup_create ssh-key
  fx "$SSH_IMPORT_KEY.txt" "created"
  form="$(jq -cn --arg k "$PEM" '{title:"Imported",mode:"import",private_key:$k}')"
  run_create ssh-key "$form"
  assert_ok_created ssh-key
  assert_file_exists "$envlog"
  assert_not_contains "$(<"$envlog")" CANARY "ssh key in pass-cli env"
  assert_not_contains "$(<"$envlog")" "OMAPASS_CREATE_" "create globals exported"
  assert_file_exists "$dbg"
  assert_no_leak CANARY
}

test_ssh_key_bad_input() {
  local form i=0 dbg="$XDG_RUNTIME_DIR/omapass/debug.log"
  local -a forms=(
    '{"title":"-oops","mode":"generate"}'
    '{"title":"T","mode":"import","key_type":"ed25519","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nCANARY-SSHKEY-x"}'
    '{"title":"T","mode":"generate","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nCANARY-SSHKEY-x"}'
    '{"title":"T","mode":"generate","key_type":"dsa"}'
    '{"title":"T","mode":"import","private_key":"CANARY-SSHKEY-notpem"}'
    '{"title":"T"}'
    '{"title":"line\nbreak","mode":"generate"}'
    '{"title":"T","mode":"generate","comment":"tab\there"}'
  )
  setup_create ssh-key
  export OMAPASS_DEBUG=1
  for form in "${forms[@]}"; do
    i=$((i + 1))
    rm -f "$dbg"
    : >"$OMAPASS_MOCK_LOG"
    run_create ssh-key "$form"
    assert_error failed bad_input 1
    assert_no_pass_create
    assert_eq "" "$(mock_log)" "ssh-key form #$i mock log"
    assert_file_exists "$dbg"
    assert_no_leak CANARY
  done
}

run_test "credit-card fills the template and rejects a bad expiry" test_credit_card
run_test "wifi with explicit password" test_wifi_explicit_password
run_test "wifi generate keeps the secret out of logs" test_wifi_generate
run_test "wifi password plus generate is bad_input" test_wifi_password_and_generate
run_test "identity fills fields and rejects unknown keys" test_identity
run_test "alias validates the prefix and calls item alias create" test_alias
run_test "alias failure is classified" test_alias_failure
run_test "ssh-key generate argv and defaults" test_ssh_key_generate
run_test "ssh-key import passes the key on stdin only" test_ssh_key_import
run_test "card and ssh-key secrets never reach the pass-cli environment" test_secrets_not_in_env
run_test "ssh-key bad input creates nothing" test_ssh_key_bad_input

finish_tests
