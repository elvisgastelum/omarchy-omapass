# shellcheck shell=bash
# create types beyond login, note and custom (OPA-23): credit-card, wifi and identity use the
# template engine in bin/lib/create.sh; alias and ssh-key have their own run hook (no template).
# Function definitions only. The same secret rules as create.sh apply: form values reach jq and
# pass-cli only through pipes fed by printf (a builtin), never through argv, the environment, a
# file or the debug log. Only non-secret form values (title, comment, key type, alias prefix) are
# passed as pass-cli flags.

# --- credit-card, wifi, identity (template types) --------------------------------------------

omapass_create_type_credit_card_check() {
  cat <<'JQ'
only(["title", "cardholder_name", "number", "cvv", "expiration_date", "pin", "note"])
and title_ok and ostr("cardholder_name"; 512) and ostr("note"; 65536)
and ostr("number"; 64) and ostr("cvv"; 16) and ostr("pin"; 32)
and (.expiration_date == null or ((.expiration_date | type) == "string"
  and (.expiration_date | test("^[0-9]{4}-(0[1-9]|1[0-2])$"))))
JQ
}

omapass_create_type_credit_card_fill() {
  cat <<'JQ'
need(["title", "cardholder_name", "number", "cvv", "expiration_date", "pin", "note"])
| .title = $f.title
| reduce ("cardholder_name", "number", "cvv", "expiration_date", "pin", "note") as $k
    (.; .[$k] = ($f[$k] // .[$k]))
JQ
}

omapass_create_type_wifi_check() {
  cat <<'JQ'
only(["title", "ssid", "password", "generate", "note"])
and title_ok and ostr("ssid"; 512) and ostr("password"; 1024) and ostr("note"; 65536)
and generate_ok and (.password == null or .generate == null)
JQ
}

omapass_create_type_wifi_fill() {
  cat <<'JQ'
need(["title", "ssid", "password", "note"])
| .title = $f.title
| .ssid = ($f.ssid // .ssid)
| .password = (if $pw != null then $pw else ($f.password // .password) end)
| .note = ($f.note // .note)
JQ
}

# Every identity form key is a template key of the same name (all strings; title is required).
omapass_create_type_identity_check() {
  cat <<'JQ'
def idkeys: ["title", "note", "full_name", "email", "phone_number", "first_name", "middle_name",
  "last_name", "birthdate", "gender", "organization", "street_address", "zip_or_postal_code", "city",
  "state_or_province", "country_or_region", "floor", "county", "social_security_number",
  "passport_number", "license_number", "website", "x_handle", "second_phone_number", "linkedin",
  "reddit", "facebook", "yahoo", "instagram", "company", "job_title", "personal_website",
  "work_phone_number", "work_email"];
. as $o
| only(idkeys) and title_ok and ostr("note"; 65536)
  and all(idkeys[] | select(. != "title" and . != "note"); . as $k | $o | ostr($k; 512))
JQ
}

omapass_create_type_identity_fill() {
  cat <<'JQ'
def idkeys: $f | keys;
need(idkeys)
| reduce idkeys[] as $k (.; .[$k] = ($f[$k] // .[$k]))
JQ
}

# --- alias -----------------------------------------------------------------------------------

# The prefix is the local part before `.<suffix>@<domain>`; it is not secret and goes on argv.
omapass_create_type_alias_check() {
  cat <<'JQ'
only(["prefix"]) and (.prefix | type) == "string" and (.prefix | test("^[a-z0-9][a-z0-9._-]{0,39}$"))
JQ
}

# item alias create --share-id <S> --prefix <P> --output json. The JSON shape is unverified, so
# stdout is discarded like item create's; the envelope carries type and share_id only.
omapass_create_type_alias_run() {
  local share="$1" prefix rc=0 cls code reason
  prefix="$(printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.prefix' 2>/dev/null)" || prefix=""
  OMAPASS_CREATE_FORM=""
  [[ "$prefix" =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]] || omapass_fail failed bad_input
  omapass_pass "alias create" item alias create --share-id "$share" --prefix "$prefix" --output json \
    >/dev/null || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  omapass_ok "$(jq -cn --arg s "$share" '{type:"alias",share_id:$s}')"
}

# --- ssh-key ---------------------------------------------------------------------------------

# mode generate: title, key_type (ed25519 | rsa2048 | rsa4096, default ed25519), comment.
# mode import: title, private_key (an OpenSSH or PEM private key). A title or comment starting
# with "-" is rejected so it can never be read as a flag, and control characters are rejected
# so the value read back with $(jq -j ...) is exactly the form value.
omapass_create_type_ssh_key_check() {
  cat <<'JQ'
def noflag($k): (.[$k] == null) or ((.[$k] | startswith("-") or test("[[:cntrl:]]")) | not);
only(["title", "mode", "key_type", "comment", "private_key"]) and title_ok and noflag("title")
and (
  (.mode == "generate" and .private_key == null and ostr("comment"; 1024) and noflag("comment")
    and (.key_type == null or (.key_type as $t | any(("ed25519", "rsa2048", "rsa4096"); . == $t))))
  or (.mode == "import" and .key_type == null and .comment == null
    and (.private_key | type) == "string" and (.private_key | length) <= 16384
    and (.private_key | startswith("-----BEGIN ")))
)
JQ
}

# The non-secret flags (title, key type, comment) are read from the form; for import the private
# key goes from the form through a jq pipe to pass-cli's stdin, which pass-cli opens as
# --from-private-key /dev/stdin (pass-cli reads the path with std::fs::read_to_string, no file-type
# check), so it is never in a shell variable of its own, argv, the environment or a file.
omapass_create_type_ssh_key_run() {
  local share="$1" mode title key_type comment rc=0 cls code reason
  local -a args=()
  mode="$(printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.mode' 2>/dev/null)" || mode=""
  title="$(printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.title' 2>/dev/null)" || title=""
  [[ -n "$title" && "$title" != -* ]] || omapass_fail failed bad_input
  case "$mode" in
    generate)
      key_type="$(printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.key_type // "ed25519"' 2>/dev/null)" || key_type=""
      comment="$(printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.comment // ""' 2>/dev/null)" || comment=""
      OMAPASS_CREATE_FORM=""
      case "$key_type" in
        ed25519 | rsa2048 | rsa4096) ;;
        *) omapass_fail failed bad_input ;;
      esac
      [[ "$comment" != -* ]] || omapass_fail failed bad_input
      args=(item create ssh-key generate --share-id "$share" --title "$title" --key-type "$key_type")
      if [[ -n "$comment" ]]; then args+=(--comment "$comment"); fi
      omapass_pass "ssh-key generate" "${args[@]}" >/dev/null || rc=$?
      ;;
    import)
      printf '%s' "$OMAPASS_CREATE_FORM" | jq -j '.private_key' 2>/dev/null |
        omapass_pass_stdin "ssh-key import" item create ssh-key import --share-id "$share" \
          --title "$title" --from-private-key /dev/stdin >/dev/null || rc=$?
      OMAPASS_CREATE_FORM=""
      ;;
    *)
      OMAPASS_CREATE_FORM=""
      omapass_fail failed bad_input
      ;;
  esac
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  omapass_ok "$(jq -cn --arg s "$share" '{type:"ssh-key",share_id:$s}')"
}
