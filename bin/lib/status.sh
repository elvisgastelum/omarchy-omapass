# shellcheck shell=bash
# version and status subcommands.

omapass_cmd_version() {
  if (($# > 0)); then omapass_fail failed usage; fi
  omapass_check_version
  omapass_ok "$(jq -cn --arg v "$OMAPASS_PASS_CLI_VERSION" --arg m "$(omapass_min_version)" \
    '{pass_cli:$v,min_pass_cli:$m}')"
}

omapass_cmd_status() {
  if (($# > 0)); then omapass_fail failed usage; fi
  local rc=0 cls code reason out count
  omapass_check_version
  out="$OMAPASS_TMPDIR/vaults.json"
  omapass_pass "vault list" vault list --output json >"$out" || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  if ! count="$(jq -e '.vaults | if type == "array" then length else error("not an array") end' "$out" 2>/dev/null)"; then
    omapass_fail failed bad_output
  fi
  omapass_ok "$(jq -cn --arg v "$OMAPASS_PASS_CLI_VERSION" --arg m "$(omapass_min_version)" --argjson c "$count" \
    '{state:"ready",pass_cli:$v,min_pass_cli:$m,vaults:$c}')"
}
