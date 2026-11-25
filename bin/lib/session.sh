# shellcheck shell=bash
# Session subcommands: lock, logout, login, unlock (contract: "trash, untrash, lock, logout, login, unlock").
# login and unlock only open a terminal running pass-cli; the password or lock code is typed
# there and never reaches the helper.

# pass-cli's error when `session lock` runs on a session without a lock (lowercased, matched as a
# substring). Source (pass-cli main, src/commands/session/lock.rs), not seen in real output:
# "Session has no lock. Create one first with `pass-cli session create-lock`".
OMAPASS_NO_LOCK_TEXT="session has no lock"

# omapass__session_fail <rc>: fail with the classified error of the last pass-cli call.
omapass__session_fail() {
  local cls code reason
  cls="$(omapass_classify "$1")"
  read -r code reason <<<"$cls"
  omapass_fail "$code" "$reason"
}

# omapass__session_no_lock <rc>: true when the last pass-cli call failed because there is no lock.
omapass__session_no_lock() {
  local f="${OMAPASS_PASS_STDERR:-$OMAPASS_TMPDIR/pass.stderr}" txt=""
  case "$1" in 124 | 137 | 126 | 127) return 1 ;; esac
  [[ -r "$f" ]] || return 1
  txt="$(head -c 65536 "$f" 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')" || return 1
  [[ "$txt" == *"$OMAPASS_NO_LOCK_TEXT"* ]]
}

omapass_cmd_lock() {
  if (($# > 0)); then omapass_fail failed usage; fi
  local rc=0
  # Drop our copied secret first, whatever pass-cli then says.
  omapass_clipboard_clear_now || true
  omapass_check_version
  omapass_pass "session lock" session lock >/dev/null || rc=$?
  if ((rc != 0)); then
    if omapass__session_no_lock "$rc"; then omapass_fail failed no_lock; fi
    omapass__session_fail "$rc"
  fi
  omapass_ok '{"state":"locked"}'
}

omapass_cmd_logout() {
  if (($# > 0)); then omapass_fail failed usage; fi
  local rc=0
  omapass_clipboard_clear_now || true
  omapass_check_version
  omapass_pass "logout" logout >/dev/null || rc=$?
  if ((rc != 0)); then
    # Already signed out is the state the caller asked for.
    if [[ "$(omapass_classify "$rc")" == signed_out ]]; then omapass_ok '{"state":"signed_out"}'; fi
    omapass__session_fail "$rc"
  fi
  omapass_ok '{"state":"signed_out"}'
}

# omapass__session_terminal <pass-cli args...>: open the user's terminal (xdg-terminal-exec, the
# launcher Omarchy's own scripts use) running pass-cli, in its own session so it outlives the
# helper, with stdio on /dev/null, no other inherited fds, and without the helper's internal
# state (OMAPASS_* variables, LC_ALL=C) in its environment.
omapass__session_terminal() {
  command -v xdg-terminal-exec >/dev/null 2>&1 || omapass_fail failed
  command -v setsid >/dev/null 2>&1 || omapass_fail failed
  if ! (
    local -a names=(OMAPASS_TMPDIR OMAPASS_TMPDIR_OWNER OMAPASS_MAIN_PID OMAPASS_DONE OMAPASS_SUB
      OMAPASS_PASS_STDERR OMAPASS_PASS_CLI_VERSION OMAPASS_START_MS OMAPASS_NO_LOCK_TEXT)
    local v
    while IFS= read -r v; do names+=("$v"); done < <(compgen -v OMAPASS_CLIP_; compgen -v OMAPASS_COPY_)
    for v in "${names[@]}"; do unset -v "$v" 2>/dev/null || true; done
    # The dispatcher exported LC_ALL=C for itself; the terminal gets the user's LANG/LC_* instead.
    unset -v LC_ALL
    # Close every fd above 2 (ours or inherited from the caller) before the long-lived terminal starts.
    local fd
    for fd in /proc/"$BASHPID"/fd/*; do
      fd="${fd##*/}"
      if [[ "$fd" =~ ^[0-9]+$ ]] && ((fd > 2)); then eval "exec $fd>&-" 2>/dev/null || true; fi
    done
    cd -- "${HOME:-/}" 2>/dev/null || cd /
    exec setsid -f -- xdg-terminal-exec --app-id=org.omarchy.omapass -e pass-cli "$@" \
      </dev/null >/dev/null 2>&1
  ); then
    omapass_fail failed
  fi
}

omapass_cmd_login() {
  if (($# > 0)); then omapass_fail failed usage; fi
  omapass_check_version
  omapass__session_terminal login
  omapass_ok '{}'
}

omapass_cmd_unlock() {
  if (($# > 0)); then omapass_fail failed usage; fi
  omapass_check_version
  omapass__session_terminal session unlock
  omapass_ok '{}'
}
