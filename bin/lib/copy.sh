# shellcheck shell=bash
# copy subcommand: one item field from pass-cli, through jq, into wl-copy (see bin/lib/clipboard.sh).

# omapass__copy_view_jq: the jq program for `item view --output json`. Every assumption about the
# item view shape lives here (docs/CONTRACT.md, "copy"; the shape is unverified):
#   {"item": {"id", "share_id", "content": {"note", "extra_fields": [...],
#             "content": {"<Variant>": {...}}}, "alias_email"?}, "attachments": [...]}
# The `item` wrapper is from the pass-cli source; the inner item is assumed to match one
# `item list --show-secrets` entry. Output (jq -j), fail closed:
#   "V<value>"  copy this value     "T<name>"  copy the TOTP code that `item totp` lists as <name>
#   "N"         field not found     "A"        TOTP name is ambiguous
#   jq error    unexpected shape (bad_output); nothing is copied
omapass__copy_view_jq() {
  cat <<'JQ'
def variants: {"Login": "login", "Alias": "alias", "Note": "note", "CreditCard": "credit-card",
  "Identity": "identity", "SshKey": "ssh-key", "Wifi": "wifi", "Custom": "custom"};
def sectioned: ["Custom", "SshKey", "Wifi"];
def kinds: {"Text": "text", "Hidden": "hidden", "Timestamp": "timestamp", "Totp": "totp"};
def table: {
  "login": {"username": ["content", "content", "Login", "username"],
            "email": ["content", "content", "Login", "email"],
            "password": ["content", "content", "Login", "password"],
            "totp": ["content", "content", "Login", "totp_uri"]},
  "alias": {"alias": ["alias_email"]},
  "note": {"note": ["content", "note"]},
  "credit-card": {"holder": ["content", "content", "CreditCard", "cardholder_name"],
                  "number": ["content", "content", "CreditCard", "number"],
                  "cvv": ["content", "content", "CreditCard", "verification_number"],
                  "expiry": ["content", "content", "CreditCard", "expiration_date"]},
  "identity": {"name": ["content", "content", "Identity", "full_name"],
               "email": ["content", "content", "Identity", "email"],
               "phone": ["content", "content", "Identity", "phone_number"],
               "address": ["content", "content", "Identity", "street_address"]},
  "ssh-key": {"private_key": ["content", "content", "SshKey", "private_key"],
              "public_key": ["content", "content", "SshKey", "public_key"]},
  "wifi": {"ssid": ["content", "content", "Wifi", "ssid"],
           "password": ["content", "content", "Wifi", "password"]},
  "custom": {}
};
def obj: if type == "object" then . else error("shape") end;
# Dynamic-field containers are read as tolerantly as list.sh reads them (same indexes), so
# every field list advertises stays copyable even when a neighbour is malformed.
def arr: if type == "array" then . else [] end;
# One dynamic field {"name": s, "content": {"<Kind>": v}} -> {name, kind, value}. A malformed
# entry or an unknown kind becomes kind "unknown", which fails only when that field is copied.
def dyn:
  if type == "object" and (.content | type) == "object" and (.content | length) == 1
  then (.content | to_entries[0]) as $e
    | {name: (.name | if type == "string" then . else "" end), kind: (kinds[$e.key] // "unknown"),
       value: $e.value}
  else {name: "", kind: "unknown", value: null} end;
def present: . != null and . != "";
# A copyable value: a string (no NUL), or a whole-number timestamp; empty or null is not found.
def emit_value:
  if . == null or . == "" then "N"
  elif type == "string" then (if test("\u0000") then error("nul") else "V" + . end)
  elif type == "number" and . == floor then "V" + tostring
  else error("value") end;
def idx($s): if $s | test("^(0|[1-9][0-9]{0,3})$") then $s | tonumber else null end;

(obj | .item | obj) as $it
| if $it.id != $iid or $it.share_id != $sid then error("wrong item") else . end
| ($it.content | obj) as $c
| ($c.content | obj | if length == 1 then keys[0] else error("variant") end) as $variant
| (variants[$variant] // error("variant")) as $type
| ($c.extra_fields | arr | map(dyn)) as $extras
| (if sectioned | index($variant) then $c.content[$variant]
   | (if type == "object" then .sections else null end) | arr
   | map(if type == "object" then .section_fields | arr | map(dyn) else [] end) else [] end) as $sections
# Every name `item totp` would list: the login TOTP as "totp", then TOTP fields by name.
| ([if $type == "login" and ($c.content.Login.totp_uri | present) then "totp" else empty end]
   + [($extras + ($sections | add // []))[] | select(.kind == "totp" and (.value | present)) | .name])
  as $totp_names
| def totp($name): if ($totp_names | map(select(. == $name)) | length) == 1 then "T" + $name else "A" end;
  def dynamic($f): if $f == null then "N"
    elif $f.kind == "unknown" then error("kind")
    elif $f.kind == "totp" then (if $f.value | present then totp($f.name) else "N" end)
    else $f.value | emit_value end;
  ($field | split(":")) as $p
| if ($p | length) == 1 then
    (table[$type][$field]) as $path
    | if $path == null then "N"
      elif $type == "login" and $field == "totp" then
        (if $it | getpath($path) | present then totp("totp") else "N" end)
      else $it | getpath($path) | emit_value end
  elif ($p | length) == 2 and $p[0] == "extra" then
    (idx($p[1])) as $i | dynamic(if $i == null then null else $extras[$i] end)
  elif ($p | length) == 3 and $p[0] == "section" then
    (idx($p[1])) as $s | (idx($p[2])) as $f
    | dynamic(if $s == null or $f == null then null else ($sections[$s] // [])[$f] end)
  else "N" end
JQ
}

# omapass__copy_totp_jq: the jq program for `item totp --output json`, a flat object of field name
# to code (pass-cli source; unverified in real output). Prints "V<code>", "N" when the name is
# absent, and errors on anything that is not a 6-10 digit code.
omapass__copy_totp_jq() {
  cat <<'JQ'
if type != "object" then error("shape")
elif has($name) | not then "N"
elif (.[$name] | type) == "string" and (.[$name] | test("^[0-9]{6,10}$")) then "V" + .[$name]
else error("code") end
JQ
}

# omapass__copy_run <label> <jq program> <jq args...> -- <pass-cli args...>: pass-cli stdout goes
# straight into jq. Sets OMAPASS_COPY_OUT (jq output, exact bytes) and fails the envelope on a
# pass-cli error (classified) or a jq error (bad_output).
omapass__copy_run() {
  local label="$1" prog="$2" out trailer prc jrc cls code reason
  local -a jqargs=()
  shift 2
  while (($# > 0)) && [[ "$1" != -- ]]; do
    jqargs+=("$1")
    shift
  done
  shift
  out="$(
    set +e
    # -n with [inputs]: exactly one JSON document, or the output is refused (jq -j would
    # otherwise run the program per document and join the results into a wrong value).
    omapass_pass "$label" "$@" |
      jq -n -j "${jqargs[@]}" "[inputs] | if length == 1 then .[0] else error(\"documents\") end | $prog" 2>/dev/null
    s=("${PIPESTATUS[@]}")
    printf '\n%s %s' "${s[0]}" "${s[1]}"
  )" || true
  trailer="${out##*$'\n'}"
  OMAPASS_COPY_OUT="${out%$'\n'*}"
  out=""
  read -r prc jrc <<<"$trailer" || true
  if [[ ! "$prc" =~ ^[0-9]+$ || ! "$jrc" =~ ^[0-9]+$ ]]; then
    OMAPASS_COPY_OUT=""
    omapass_fail failed
  fi
  if ((prc != 0)); then
    OMAPASS_COPY_OUT=""
    cls="$(omapass_classify "$prc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  if ((jrc != 0)); then
    OMAPASS_COPY_OUT=""
    omapass_fail failed bad_output
  fi
}

OMAPASS_COPY_OUT=""

# copy <share_id> <item_id> <field> [--paste-once] [--clear-after <0-300>]
omapass_cmd_copy() {
  local sid iid field once=0 after=45 value name
  local field_re='^([a-z_]{1,32}|extra:(0|[1-9][0-9]{0,3})|section:(0|[1-9][0-9]{0,3}):(0|[1-9][0-9]{0,3}))$'
  if (($# < 3)); then omapass_fail failed usage; fi
  sid="$1" iid="$2" field="$3"
  shift 3
  while (($# > 0)); do
    case "$1" in
      --paste-once)
        once=1
        shift
        ;;
      --clear-after)
        if (($# < 2)); then omapass_fail failed usage; fi
        after="$2"
        shift 2
        ;;
      *) omapass_fail failed usage ;;
    esac
  done
  if ! omapass_valid_id "$sid" || ! omapass_valid_id "$iid"; then omapass_fail failed usage; fi
  if [[ ! "$after" =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((after > 300)); then omapass_fail failed usage; fi
  # Field names are a fixed table; anything else cannot exist on any item.
  if [[ ! "$field" =~ $field_re ]]; then omapass_fail not_found; fi
  command -v wl-copy >/dev/null 2>&1 || omapass_fail failed
  if ((after > 0)); then command -v setsid >/dev/null 2>&1 || omapass_fail failed; fi
  omapass_clipboard_dir >/dev/null || omapass_fail failed
  omapass_check_version

  omapass__copy_run "item view" "$(omapass__copy_view_jq)" \
    --arg sid "$sid" --arg iid "$iid" --arg field "$field" -- \
    item view --share-id "$sid" --item-id "$iid" --output json
  case "$OMAPASS_COPY_OUT" in
    V?*) value="${OMAPASS_COPY_OUT:1}" ;;
    T?*)
      name="${OMAPASS_COPY_OUT:1}"
      OMAPASS_COPY_OUT=""
      omapass__copy_run "item totp" "$(omapass__copy_totp_jq)" --arg name "$name" -- \
        item totp --share-id "$sid" --item-id "$iid" --output json
      case "$OMAPASS_COPY_OUT" in
        V?*) value="${OMAPASS_COPY_OUT:1}" ;;
        N) OMAPASS_COPY_OUT="" && omapass_fail not_found ;;
        *) OMAPASS_COPY_OUT="" && omapass_fail failed bad_output ;;
      esac
      ;;
    N) OMAPASS_COPY_OUT="" && omapass_fail not_found ;;
    A) OMAPASS_COPY_OUT="" && omapass_fail failed ;;
    *) OMAPASS_COPY_OUT="" && omapass_fail failed bad_output ;;
  esac
  OMAPASS_COPY_OUT=""

  if ! omapass_clipboard_copy "$value" "$once" "$after"; then
    value=""
    omapass_fail failed
  fi
  value=""
  if ((after > 0)) && ! omapass_clipboard_spawn_clear "$OMAPASS_CLIP_TOKEN"; then
    # No clear could be scheduled: do not leave the secret on the clipboard.
    omapass_clipboard_clear_now || true
    omapass_fail failed
  fi
  omapass_ok "$(jq -cn --arg f "$field" --argjson c "$after" '{field:$f,clear_after:$c}')"
}
