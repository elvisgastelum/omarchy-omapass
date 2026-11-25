# shellcheck shell=bash
# vaults and list subcommands.
#
# Secret handling: `item list --show-secrets` output only ever flows through a pipe straight into
# jq, which builds every ListItem from allowlisted fields by name (it never copies or deletes keys
# of the input). jq stderr is dropped, so a parse error can never echo input. Only the projected,
# secret-free items are written to OMAPASS_TMPDIR.

# omapass_list_filter: the jq program that turns one `item list` JSON object into a ListItem array.
# $mode is "secrets" (--show-secrets output) or "title" (title-only output); $sel[0][$i] is the vault.
omapass_list_filter() {
  cat <<'JQ'
def str: if type == "string" and . != "" then . else null end;
def present: . != null and . != "" and . != [] and . != {};
def at($p): try getpath($p) catch null;
def types: {"Login": "login", "Alias": "alias", "Note": "note", "CreditCard": "credit-card",
  "Identity": "identity", "SshKey": "ssh-key", "Wifi": "wifi", "Custom": "custom"};
def kinds: {"Text": "text", "Hidden": "hidden", "Timestamp": "timestamp", "Totp": "totp"};
def copy_fields: {
  "Login": [["username", ["content", "content", "Login", "username"]],
            ["email", ["content", "content", "Login", "email"]],
            ["password", ["content", "content", "Login", "password"]],
            ["totp", ["content", "content", "Login", "totp_uri"]]],
  "Alias": [["alias", ["alias_email"]]],
  "Note": [["note", ["content", "note"]]],
  "CreditCard": [["holder", ["content", "content", "CreditCard", "cardholder_name"]],
                 ["number", ["content", "content", "CreditCard", "number"]],
                 ["cvv", ["content", "content", "CreditCard", "verification_number"]],
                 ["expiry", ["content", "content", "CreditCard", "expiration_date"]]],
  "Identity": [["name", ["content", "content", "Identity", "full_name"]],
               ["email", ["content", "content", "Identity", "email"]],
               ["phone", ["content", "content", "Identity", "phone_number"]],
               ["address", ["content", "content", "Identity", "street_address"]]],
  "SshKey": [["private_key", ["content", "content", "SshKey", "private_key"]],
             ["public_key", ["content", "content", "SshKey", "public_key"]]],
  "Wifi": [["ssid", ["content", "content", "Wifi", "ssid"]],
           ["password", ["content", "content", "Wifi", "password"]]],
  "Custom": []
};
def section_variants: ["Custom", "SshKey", "Wifi"];
def arr: if type == "array" then . else [] end;
# dyn($id): one extra field object to {field, name, kind}, or nothing when empty or of unknown kind.
def dyn($id):
  select(type == "object" and (.content | type) == "object" and (.content | length) == 1)
  | (.content | keys_unsorted[0]) as $k
  | select(kinds[$k] != null and (.content[$k] | present))
  | {field: $id, name: (.name | if type == "string" then . else "" end), kind: kinds[$k]};
def base($vault):
  {share_id: (.share_id | str), id: (.id | str), vault_id: (.vault_id | str), vault: $vault.name};
def times:
  {create_time: (.create_time | str), modify_time: (.modify_time | str), last_use_time: (.last_use_time | str)};
def secret_item($vault):
  (.content.content | if type == "object" and length == 1 then keys_unsorted[0] else "" end) as $v
  | select(types[$v] != null)
  | . as $item
  | [($item.content.extra_fields | arr | to_entries[]) as $e | $e.value | dyn("extra:\($e.key)")] as $extra
  | (if (section_variants | index($v)) != null then
      [($item.content.content[$v].sections? | arr | to_entries[]) as $s
       | ($s.value.section_fields? | arr | to_entries[]) as $f
       | $f.value | dyn("section:\($s.key):\($f.key)")]
    else [] end) as $sections
  | [copy_fields[$v][] as $c | select($item | at($c[1]) | present) | $c[0]] as $copy
  | ($extra + $sections) as $fields
  | (if $v == "Login" then $item.content.content.Login else {} end) as $login
  | base($vault) + {
      type: types[$v],
      title: ($item.content.title | if type == "string" then . else "" end),
      username: ($login.username | str),
      email: (if $v == "Alias" then ($item.alias_email | str) else ($login.email | str) end),
      urls: [($login.urls | arr)[] | str | select(. != null)]
    } + times + {
      has_totp: (($copy | index("totp")) != null or ($fields | map(select(.kind == "totp")) | length) > 0),
      secret_fields: ($copy + ($fields | map(.field))),
      fields: $fields
    };
def title_item($vault):
  (.item_type | if type == "string" then . else "" end) as $v
  | select(types[$v] != null)
  | base($vault) + {
      type: types[$v],
      title: (.title | if type == "string" then . else "" end),
      username: null, email: null, urls: []
    } + times + {has_totp: false, secret_fields: [], fields: []};
# Run with -n: exactly one JSON document is accepted; none (empty stdout), several or trailing
# garbage is an error, never an empty or partial vault.
[inputs] as $docs
| (if ($docs | length) != 1 then error("bad output") else $docs[0] end) as $doc
| $sel[0][$i] as $vault
| $doc
| if (.items | type) != "array" then error("bad output") else . end
| [.items[]
   | select(type == "object")
   | select((.state | if type == "string" then ascii_downcase else "" end) != "trashed")
   # A malformed item is skipped, never allowed to fail its whole vault.
   | try (if $mode == "secrets" then secret_item($vault) else title_item($vault) end) catch empty
   | select(.id != null and .share_id != null)]
JQ
}

# omapass_list_vault <index> <share_id> <mode>: run one vault's `item list` and write
# v<i>.items (projected array) and v<i>.status ("ok" or "code [reason]") in OMAPASS_TMPDIR.
omapass_list_vault() {
  local i="$1" sid="$2" mode="$3" t="$OMAPASS_TMPDIR" rc_pass rc_jq
  local -a args=(item list --share-id "$sid" --filter-state active --output json)
  if [[ "$mode" == secrets ]]; then args+=(--show-secrets); fi
  # shellcheck disable=SC2034 # read by omapass_pass; this runs in its own background subshell
  OMAPASS_PASS_STDERR="$t/v$i.stderr"
  set +e
  omapass_pass "item list" "${args[@]}" |
    jq -n -c --argjson i "$i" --arg mode "$mode" --slurpfile sel "$t/selected.json" \
      "$(omapass_list_filter)" >"$t/v$i.items" 2>/dev/null
  rc_pass="${PIPESTATUS[0]}" rc_jq="${PIPESTATUS[1]}"
  set -e
  if ((rc_pass != 0)); then
    rm -f -- "$t/v$i.items"
    omapass_classify "$rc_pass" "$t/v$i.stderr" >"$t/v$i.status"
  elif ((rc_jq != 0)); then
    rm -f -- "$t/v$i.items"
    printf 'failed bad_output' >"$t/v$i.status"
  else
    printf 'ok' >"$t/v$i.status"
  fi
  rm -f -- "$t/v$i.stderr"
}

# omapass_list_run <mode> <count>: run every selected vault, at most 4 at a time.
omapass_list_run() {
  local mode="$1" n="$2" i sid t="$OMAPASS_TMPDIR"
  local -a pids=()
  for ((i = 0; i < n; i++)); do
    rm -f -- "$t/v$i.status" "$t/v$i.items"
    if [[ "$(jq -r --argjson i "$i" '.[$i].missing // false' "$t/selected.json")" == true ]]; then
      printf 'not_found' >"$t/v$i.status"
      continue
    fi
    sid="$(jq -r --argjson i "$i" '.[$i].share_id // ""' "$t/selected.json")"
    if ! omapass_valid_id "$sid"; then
      printf 'failed bad_output' >"$t/v$i.status"
      continue
    fi
    omapass_list_vault "$i" "$sid" "$mode" &
    pids+=("$!")
    if ((${#pids[@]} >= 4)); then
      wait "${pids[0]}" || true
      pids=("${pids[@]:1}")
    fi
  done
  for i in "${pids[@]}"; do wait "$i" || true; done
}

# omapass_list_vaults_json <out> [share_id...]: validated vault list (or the requested share ids,
# unknown ones marked missing) as a JSON array in <out>. Fails the subcommand on error.
omapass_list_vaults_json() {
  local out="$1" rc=0 cls code reason raw="$OMAPASS_TMPDIR/vaults.json"
  shift
  omapass_pass "vault list" vault list --output json >"$raw" || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  if ! jq -c '
      def s: if type == "string" then . else null end;
      if (.vaults | type) != "array" or (.vaults | map(type == "object") | all | not) then error("bad")
      else [.vaults[] | {share_id: (.share_id | s), vault_id: (.vault_id | s), name: (.name | s)}] end
      | . as $all
      | if ($ARGS.positional | length) == 0 then $all
        else [$ARGS.positional[] as $id
              | ([$all[] | select(.share_id == $id)][0]
                 // {share_id: $id, vault_id: null, name: null, missing: true})]
        end' --args "$@" <"$raw" >"$out" 2>/dev/null; then
    omapass_fail failed bad_output
  fi
}

omapass_cmd_vaults() {
  if (($# > 0)); then omapass_fail failed usage; fi
  local t="$OMAPASS_TMPDIR"
  omapass_check_version
  omapass_list_vaults_json "$t/selected.json"
  jq -c '{vaults: .}' "$t/selected.json" >"$t/out.json" 2>/dev/null || omapass_fail failed bad_output
  omapass_ok_file "$t/out.json"
}

omapass_cmd_list() {
  local t="$OMAPASS_TMPDIR" n i s dup code reason notice="" first="" any_ok=0
  local -a ids=()
  while (($# > 0)); do
    if [[ "$1" != --share-id || $# -lt 2 ]] || ! omapass_valid_id "$2"; then
      omapass_fail failed usage
    fi
    dup=0
    for s in "${ids[@]}"; do [[ "$s" != "$2" ]] || dup=1; done
    ((dup)) || ids+=("$2")
    shift 2
  done
  omapass_check_version
  omapass_list_vaults_json "$t/selected.json" "${ids[@]}"
  n="$(jq 'length' "$t/selected.json")"

  omapass_list_run secrets "$n"
  for ((i = 0; i < n; i++)); do
    if [[ "$(cat "$t/v$i.status" 2>/dev/null)" == agent_session ]]; then
      # An agent session refuses --show-secrets: every vault falls back to the title-only list.
      notice=agent_session
      omapass_list_run title "$n"
      break
    fi
  done

  : >"$t/vaults.jsonl"
  : >"$t/items.jsonl"
  for ((i = 0; i < n; i++)); do
    code="" reason=""
    read -r code reason <"$t/v$i.status" || true
    [[ -n "$code" ]] || code=failed
    if [[ "$code" == ok && -f "$t/v$i.items" ]]; then
      any_ok=1
      jq -c --argjson i "$i" --slurpfile it "$t/v$i.items" \
        '.[$i] | {share_id, vault_id, name, ok: true, count: ($it[0] | length)}' \
        "$t/selected.json" >>"$t/vaults.jsonl" 2>/dev/null || omapass_fail failed bad_output
      cat "$t/v$i.items" >>"$t/items.jsonl"
    else
      [[ "$code" != ok ]] || code=failed
      [[ -n "$first" ]] || first="$code $reason"
      jq -c --argjson i "$i" --arg e "$code" \
        '.[$i] | {share_id, vault_id, name, ok: false, error: $e}' \
        "$t/selected.json" >>"$t/vaults.jsonl" 2>/dev/null || omapass_fail failed bad_output
    fi
  done
  if ((n > 0 && any_ok == 0)); then
    read -r code reason <<<"$first"
    omapass_fail "$code" "$reason"
  fi
  jq -n -c --arg notice "$notice" --slurpfile v "$t/vaults.jsonl" --slurpfile it "$t/items.jsonl" \
    '{notice: (if $notice == "" then null else $notice end), vaults: $v, items: [$it[][]]}' \
    >"$t/out.json" 2>/dev/null || omapass_fail failed bad_output
  omapass_ok_file "$t/out.json"
}
