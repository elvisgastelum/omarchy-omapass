# shellcheck shell=bash
# recents subcommand: add <share_id> <item_id>, list, clear. Never calls pass-cli.
# Stores share_id, id and time only, newest first, at most 8 entries.

omapass_recents_max() {
  printf '8'
}

# omapass_recents_dir: ${XDG_STATE_HOME:-$HOME/.local/state}/omapass (a relative XDG_STATE_HOME is ignored).
omapass_recents_dir() {
  local base="${XDG_STATE_HOME:-}"
  if [[ "$base" != /* ]]; then base="${HOME:-}/.local/state"; fi
  printf '%s/omapass' "$base"
}

# omapass_recents_enabled: false when OMAPASS_SHOW_RECENTS is 0 or false (the showRecents setting is off).
omapass_recents_enabled() {
  case "${OMAPASS_SHOW_RECENTS:-1}" in
    0 | false) return 1 ;;
  esac
  return 0
}

# omapass_recents_prepare_dir <dir>: create it 0700, refuse a symlink or another owner's dir.
omapass_recents_prepare_dir() {
  local dir="$1" owner
  # shellcheck disable=SC2174 # parents are 0700 too under umask 077
  mkdir -p -m 700 -- "$dir" 2>/dev/null || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  owner="$(stat -c '%u' -- "$dir" 2>/dev/null)" || return 1
  [[ "$owner" == "$(id -u)" ]] || return 1
  chmod 700 -- "$dir" 2>/dev/null || return 1
}

# omapass_recents_read <file>: print the stored entries as a sanitized JSON array ([] when missing or invalid).
# Only share_id, id and a UTC time survive, so nothing else in a tampered file can reach stdout.
omapass_recents_read() {
  local file="$1" out
  if [[ ! -f "$file" || -L "$file" ]]; then
    printf '[]'
    return 0
  fi
  if ! out="$(head -c 65536 -- "$file" 2>/dev/null | jq -cs --argjson max "$(omapass_recents_max)" '
    def id_ok: type == "string" and test("^[A-Za-z0-9_=-]{1,128}$");
    def entry_ok: type == "object" and (.share_id | id_ok) and (.id | id_ok)
      and (.time | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
    (if length == 1 then .[0] else null end)
    | (if type == "object" and (.recents | type) == "array" then .recents else [] end)
    | map(select(entry_ok) | {share_id, id, time}) | .[:$max]' 2>/dev/null)" || [[ -z "$out" ]]; then
    out='[]'
  fi
  printf '%s' "$out"
}

# omapass_recents_lock <dir>: hold an exclusive lock on <dir>/recents.lock until the process exits.
omapass_recents_lock() {
  local lock="$1/recents.lock" fd
  # A symlink or a FIFO (exec would block before flock's timeout) is refused.
  [[ ! -L "$lock" && (! -e "$lock" || -f "$lock") ]] || return 1
  exec {fd}>>"$lock" || return 1
  flock -w 5 "$fd" 2>/dev/null
}

omapass_cmd_recents() {
  local action="${1:-}" dir file entries tmp now
  if (($# > 0)); then shift; fi
  case "$action" in
    add)
      if (($# != 2)); then omapass_fail failed usage; fi
      if ! omapass_valid_id "$1" || ! omapass_valid_id "$2"; then omapass_fail failed bad_input; fi
      ;;
    list | clear)
      if (($# > 0)); then omapass_fail failed usage; fi
      ;;
    *) omapass_fail failed usage ;;
  esac
  dir="$(omapass_recents_dir)"
  file="$dir/recents.json"

  case "$action" in
    clear)
      # Clearing is allowed with showRecents off: it is how stored recents get removed.
      if [[ -e "$dir" || -L "$dir" ]]; then
        omapass_recents_prepare_dir "$dir" || omapass_fail failed
        omapass_recents_lock "$dir" || omapass_fail failed
        # Also any temp file an interrupted add left behind.
        rm -f -- "$file" "$dir"/.recents.* 2>/dev/null || omapass_fail failed
      fi
      omapass_ok '{"recents":[]}'
      ;;
    list)
      if ! omapass_recents_enabled || [[ -L "$dir" ]]; then omapass_ok '{"recents":[]}'; fi
      entries="$(omapass_recents_read "$file")"
      omapass_ok "$(jq -cn --argjson r "$entries" '{recents:$r}' 2>/dev/null)"
      ;;
    add)
      # showRecents off: write nothing at all, not even the directory.
      if ! omapass_recents_enabled; then omapass_ok '{"recents":[]}'; fi
      omapass_recents_prepare_dir "$dir" || omapass_fail failed
      omapass_recents_lock "$dir" || omapass_fail failed
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      entries="$(omapass_recents_read "$file")"
      entries="$(jq -cn --argjson r "$entries" --arg s "$1" --arg i "$2" --arg t "$now" \
        --argjson max "$(omapass_recents_max)" \
        '([{share_id:$s,id:$i,time:$t}] + ($r | map(select(.share_id != $s or .id != $i))))[:$max]' 2>/dev/null)" ||
        omapass_fail failed
      tmp="$(mktemp -- "$dir/.recents.XXXXXX" 2>/dev/null)" || omapass_fail failed
      if ! jq -cn --argjson r "$entries" '{version:1,recents:$r}' >"$tmp" 2>/dev/null ||
        ! chmod 600 -- "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$file" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        omapass_fail failed
      fi
      omapass_ok "$(jq -cn --argjson r "$entries" '{recents:$r}' 2>/dev/null)"
      ;;
  esac
}
