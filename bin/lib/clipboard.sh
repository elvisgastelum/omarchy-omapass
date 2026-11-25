# shellcheck shell=bash
# Clipboard ownership: HMAC guard, per-session key, state file and the detached clipboard-clear.
#
# Files, all in $XDG_RUNTIME_DIR/omapass (0700), each 0600:
#   clipboard.key    128 hex chars: a random 64-byte HMAC-SHA256 key, created once per login session
#   clipboard.state  one line "v1 <token> <deadline> <hmac>": the latest copy (deadline in epoch ms, 0 = never clear)
#   clipboard.lock   flock target that serializes copy, clear and lock
# The copied value and the key never reach argv: the value is piped to wl-copy and sha256sum,
# and the key only ever goes through the printf builtin into sha256sum's stdin.

OMAPASS_CLIP_KEY=""
OMAPASS_CLIP_LOCK_FD=""
OMAPASS_CLIP_TOKEN=""
OMAPASS_CLIP_STATE_TOKEN=""
OMAPASS_CLIP_STATE_DEADLINE=""
OMAPASS_CLIP_STATE_HMAC=""
OMAPASS_CLIP_ACTION=""

# omapass_clipboard_dir: print the private state dir, creating it 0700. Fails unless it is a real
# directory owned by us with no group or other access.
omapass_clipboard_dir() {
  local base="${XDG_RUNTIME_DIR:-}" dir st uid
  [[ "$base" == /* && -d "$base" && ! -L "$base" ]] || return 1
  dir="$base/omapass"
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    mkdir -m 700 -- "$dir" 2>/dev/null || [[ -d "$dir" ]] || return 1
  fi
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  uid="$(id -u)" || return 1
  st="$(stat -c '%u %a' -- "$dir" 2>/dev/null)" || return 1
  [[ "${st%% *}" == "$uid" ]] || return 1
  ((8#${st##* } & 8#077)) && return 1
  printf '%s' "$dir"
}

# omapass__clip_file_ok <path>: a regular file, not a symlink, owned by us, mode exactly 0600.
omapass__clip_file_ok() {
  local st uid
  [[ -f "$1" && ! -L "$1" ]] || return 1
  uid="$(id -u)" || return 1
  st="$(stat -c '%u %a' -- "$1" 2>/dev/null)" || return 1
  [[ "$st" == "$uid 600" ]]
}

# omapass__clip_random_hex <bytes>: lowercase hex from /dev/urandom (bytes travel on pipes only).
omapass__clip_random_hex() {
  local out
  out="$(head -c "$1" /dev/urandom | od -An -v -tx1 | tr -d ' \n')" || return 1
  [[ ${#out} -eq $(($1 * 2)) && "$out" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "$out"
}

# omapass__clip_write <dir> <name> <content>: write <dir>/<name> 0600 atomically (temp file + rename).
omapass__clip_write() {
  local tmp
  tmp="$(mktemp "$1/.$2.XXXXXX" 2>/dev/null)" || return 1
  if ! chmod 600 -- "$tmp" || ! printf '%s\n' "$3" >"$tmp" || ! mv -f -- "$tmp" "$1/$2"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# omapass__clip_lock <dir>: take the clipboard lock (waits up to 10 s). Callers must close
# OMAPASS_CLIP_LOCK_FD on every child that may outlive them (wl-copy forks a server that would
# otherwise hold the lock forever): run it with {OMAPASS_CLIP_LOCK_FD}>&-.
omapass__clip_lock() {
  local f="$1/clipboard.lock"
  [[ ! -L "$f" ]] || return 1
  exec {OMAPASS_CLIP_LOCK_FD}>>"$f" || return 1
  omapass__clip_file_ok "$f" || { omapass__clip_unlock; return 1; }
  flock -w 10 "$OMAPASS_CLIP_LOCK_FD" || { omapass__clip_unlock; return 1; }
}

omapass__clip_unlock() {
  if [[ -n "$OMAPASS_CLIP_LOCK_FD" ]]; then
    exec {OMAPASS_CLIP_LOCK_FD}>&- || true
    OMAPASS_CLIP_LOCK_FD=""
  fi
}

# omapass__clip_key <dir>: load the session key into OMAPASS_CLIP_KEY, creating it when missing.
# A key file that is not ours, not 0600 or malformed is replaced (and the state with it, since
# its HMAC no longer verifies). Call with the lock held.
omapass__clip_key() {
  local f="$1/clipboard.key" key=""
  OMAPASS_CLIP_KEY=""
  if omapass__clip_file_ok "$f"; then
    IFS= read -r key <"$f" || key=""
  fi
  if [[ ! "$key" =~ ^[0-9a-f]{128}$ ]]; then
    rm -f -- "$f" "$1/clipboard.state"
    key="$(omapass__clip_random_hex 64)" || return 1
    omapass__clip_write "$1" clipboard.key "$key" || return 1
  fi
  OMAPASS_CLIP_KEY="$key"
}

# omapass__clip_hmac: HMAC-SHA256 (RFC 2104) of stdin with OMAPASS_CLIP_KEY (64 bytes = one
# SHA-256 block, so no key hashing or padding). Prints 64 hex chars. Only builtins see the key.
omapass__clip_hmac() {
  local key="$OMAPASS_CLIP_KEY" ipad="" opad="" hx inner="" ib="" i b
  [[ "$key" =~ ^[0-9a-f]{128}$ ]] || return 1
  for ((i = 0; i < 128; i += 2)); do
    b=$((16#${key:i:2}))
    printf -v hx '\\x%02x' $((b ^ 0x36))
    ipad+="$hx"
    printf -v hx '\\x%02x' $((b ^ 0x5c))
    opad+="$hx"
  done
  # shellcheck disable=SC2059 # the format is our own \xHH escapes
  inner="$({ printf "$ipad"; cat; } | sha256sum)" || return 1
  inner="${inner%% *}"
  [[ "$inner" =~ ^[0-9a-f]{64}$ ]] || return 1
  for ((i = 0; i < 64; i += 2)); do ib+="\\x${inner:i:2}"; done
  # shellcheck disable=SC2059
  inner="$(printf "$opad$ib" | sha256sum)" || return 1
  inner="${inner%% *}"
  [[ "$inner" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$inner"
}

# omapass__clip_read_state <dir>: set OMAPASS_CLIP_STATE_*; fails when absent or malformed.
omapass__clip_read_state() {
  local f="$1/clipboard.state" line="" re='^v1 ([0-9a-f]{32}) (0|[1-9][0-9]{0,15}) ([0-9a-f]{64})$'
  OMAPASS_CLIP_STATE_TOKEN="" OMAPASS_CLIP_STATE_DEADLINE="" OMAPASS_CLIP_STATE_HMAC=""
  omapass__clip_file_ok "$f" || return 1
  IFS= read -r line <"$f" || return 1
  [[ "$line" =~ $re ]] || return 1
  OMAPASS_CLIP_STATE_TOKEN="${BASH_REMATCH[1]}"
  OMAPASS_CLIP_STATE_DEADLINE="${BASH_REMATCH[2]}"
  OMAPASS_CLIP_STATE_HMAC="${BASH_REMATCH[3]}"
}

# omapass__clip_matches: true when the clipboard still holds the value recorded in the state.
# Call with the lock held, key and state loaded.
omapass__clip_matches() {
  local h rc=0
  h="$(timeout -k 1 5 wl-paste -n </dev/null 2>/dev/null {OMAPASS_CLIP_LOCK_FD}>&- | omapass__clip_hmac)" || rc=$?
  ((rc == 0)) && [[ -n "$h" && "$h" == "$OMAPASS_CLIP_STATE_HMAC" ]]
}

# omapass__clip_clear_owned <dir>: with the lock held, clear the clipboard if it still holds our
# copy, then forget the state. Sets OMAPASS_CLIP_ACTION (cleared, skipped or clear_failed).
# Returns 1 only when wl-copy --clear failed.
omapass__clip_clear_owned() {
  local rc=0 action=skipped
  if omapass__clip_read_state "$1" && omapass__clip_key "$1" && omapass__clip_matches; then
    if wl-copy --clear </dev/null >/dev/null 2>&1 {OMAPASS_CLIP_LOCK_FD}>&-; then
      action=cleared
    else
      action=clear_failed
      rc=1
    fi
  fi
  rm -f -- "$1/clipboard.state"
  OMAPASS_CLIP_ACTION="$action"
  omapass_debug clipboard "action=$action"
  return "$rc"
}

# omapass_clipboard_copy <value> <paste_once 0|1> <clear_after 0-300>: pipe the value into
# wl-copy --sensitive (-o when paste-once) and record its HMAC as the latest copy. Sets
# OMAPASS_CLIP_TOKEN. The value is a function argument (no exec), never a process argument.
omapass_clipboard_copy() {
  local value="$1" once="$2" after="$3" dir token mac deadline=0 rc=0
  local -a opts=(--sensitive)
  OMAPASS_CLIP_TOKEN=""
  [[ "$once" == 0 || "$once" == 1 ]] || return 1
  [[ "$after" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((after <= 300)) || return 1
  if [[ "$once" == 1 ]]; then opts+=(-o); fi
  dir="$(omapass_clipboard_dir)" || return 1
  token="$(omapass__clip_random_hex 16)" || return 1
  if ((after > 0)); then deadline=$(($(omapass_now_ms) + after * 1000)); fi
  omapass__clip_lock "$dir" || return 1
  if ! omapass__clip_key "$dir" || ! mac="$(printf '%s' "$value" | omapass__clip_hmac)"; then
    omapass__clip_unlock
    return 1
  fi
  printf '%s' "$value" | wl-copy "${opts[@]}" >/dev/null 2>&1 {OMAPASS_CLIP_LOCK_FD}>&- || rc=$?
  if ((rc != 0)); then
    # Whatever wl-copy managed to set is not tracked; forget any older state too.
    rm -f -- "$dir/clipboard.state"
    omapass__clip_unlock
    return 1
  fi
  # A newer state (new token) makes every older clipboard-clear stand down.
  if ! omapass__clip_write "$dir" clipboard.state "v1 $token $deadline $mac"; then
    # The value is on the clipboard but no clear can be scheduled: take it back off.
    wl-copy --clear </dev/null >/dev/null 2>&1 {OMAPASS_CLIP_LOCK_FD}>&- || true
    rm -f -- "$dir/clipboard.state"
    omapass__clip_unlock
    return 1
  fi
  omapass__clip_unlock
  # shellcheck disable=SC2034 # read by omapass_cmd_copy (bin/lib/copy.sh)
  OMAPASS_CLIP_TOKEN="$token"
  omapass_debug clipboard "action=copied" "clear_after=$after" "paste_once=$once"
}

# omapass_clipboard_spawn_clear <token>: start the detached clipboard-clear for that copy.
omapass_clipboard_spawn_clear() {
  local token="$1" helper
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
  helper="$(readlink -f -- "${BASH_SOURCE[0]}")" || return 1
  helper="$(dirname -- "$(dirname -- "$helper")")/omapass-helper"
  [[ -f "$helper" && -x "$helper" ]] || return 1
  command -v setsid >/dev/null 2>&1 || return 1
  setsid -f -- "$helper" clipboard-clear "$token" </dev/null >/dev/null 2>&1
}

# omapass_clipboard_clear_now: clear the clipboard if it still holds the latest omapass copy and
# forget the clipboard state, so every pending clipboard-clear stands down. For lock (OPA-16) and
# any other caller that must drop the copied secret now. Returns 1 when the lock could not be
# taken or wl-copy --clear failed; never prints.
omapass_clipboard_clear_now() {
  local dir rc=0
  dir="$(omapass_clipboard_dir)" || return 1
  omapass__clip_lock "$dir" || return 1
  omapass__clip_clear_owned "$dir" || rc=1
  omapass__clip_unlock
  return "$rc"
}

# clipboard-clear <token>: internal, run detached by copy. Waits until the copy's deadline, then
# clears the clipboard only if <token> is still the latest copy and the clipboard still matches
# its HMAC.
omapass_cmd_clipboard_clear() {
  if (($# != 1)) || [[ ! "$1" =~ ^[0-9a-f]{32}$ ]]; then omapass_fail failed usage; fi
  local token="$1" dir wait now
  dir="$(omapass_clipboard_dir)" || omapass_fail failed
  if ! omapass__clip_read_state "$dir" || [[ "$OMAPASS_CLIP_STATE_TOKEN" != "$token" ]] ||
    [[ "$OMAPASS_CLIP_STATE_DEADLINE" == 0 ]]; then
    omapass_ok '{"cleared":false}'
  fi
  now="$(omapass_now_ms)"
  wait=$((OMAPASS_CLIP_STATE_DEADLINE - now))
  if ((wait > 300000)); then wait=300000; fi
  if ((wait > 0)); then sleep "$((wait / 1000)).$(printf '%03d' $((wait % 1000)))"; fi
  omapass__clip_lock "$dir" || omapass_fail failed
  # Re-check under the lock: a newer copy, a lock or another clear may have run meanwhile.
  if ! omapass__clip_read_state "$dir" || [[ "$OMAPASS_CLIP_STATE_TOKEN" != "$token" ]]; then
    omapass__clip_unlock
    omapass_ok '{"cleared":false}'
  fi
  if ! omapass__clip_clear_owned "$dir"; then
    omapass__clip_unlock
    omapass_fail failed
  fi
  omapass__clip_unlock
  if [[ "$OMAPASS_CLIP_ACTION" == cleared ]]; then
    omapass_ok '{"cleared":true}'
  fi
  omapass_ok '{"cleared":false}'
}
