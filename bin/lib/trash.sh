# shellcheck shell=bash
# trash and untrash subcommands: move an item to the trash or restore it, by share ID and item ID
# only. --item-title and --vault-name are never passed (titles and vault names are not unique).

# omapass__trash_run <trash|untrash> <share_id> <item_id>
omapass__trash_run() {
  local verb="$1" sid="$2" iid="$3" rc=0 cls code reason
  if ! omapass_valid_id "$sid" || ! omapass_valid_id "$iid"; then omapass_fail failed usage; fi
  omapass_check_version
  omapass_pass "item $verb" item "$verb" --share-id "$sid" --item-id "$iid" >/dev/null || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  omapass_ok '{}'
}

# trash <share_id> <item_id>
omapass_cmd_trash() {
  if (($# != 2)); then omapass_fail failed usage; fi
  omapass__trash_run trash "$1" "$2"
}

# untrash <share_id> <item_id>
omapass_cmd_untrash() {
  if (($# != 2)); then omapass_fail failed usage; fi
  omapass__trash_run untrash "$1" "$2"
}
