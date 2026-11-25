# shellcheck shell=bash
# Core helpers for omapass-helper. Function definitions only; sourced by bin/omapass-helper.

omapass_min_version() {
  printf '%s' '2.7.1'
}

# omapass_exit_code <code>: exit status for an error code (contract table).
omapass_exit_code() {
  case "${1:-}" in
    ok) printf '0' ;;
    usage) printf '2' ;;
    signed_out) printf '10' ;;
    locked) printf '11' ;;
    too_old) printf '12' ;;
    plan_required) printf '13' ;;
    agent_session) printf '14' ;;
    network) printf '15' ;;
    timeout) printf '16' ;;
    not_found) printf '17' ;;
    *) printf '1' ;;
  esac
}

omapass_now_ms() {
  local us="${EPOCHREALTIME/./}"
  printf '%s' "$((us / 1000))"
}

# omapass_debug <event> [key=value...]: one log line, only when OMAPASS_DEBUG=1. Never fails, never prints.
omapass_debug() {
  [[ "${OMAPASS_DEBUG:-}" == 1 ]] || return 0
  {
    local event="${1:-}" file dir us sec ts line
    if (($# > 0)); then shift; fi
    if [[ -n "${OMAPASS_DEBUG_LOG:-}" ]]; then
      file="$OMAPASS_DEBUG_LOG"
    elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
      file="$XDG_RUNTIME_DIR/omapass/debug.log"
    else
      file="${XDG_STATE_HOME:-$HOME/.local/state}/omapass/debug.log"
    fi
    dir="$(dirname "$file")"
    us="${EPOCHREALTIME/./}"
    sec=$((us / 1000000))
    ts="$(date -u -d "@$sec" +%Y-%m-%dT%H:%M:%S)"
    line="$(printf '%s.%03dZ pid=%s sub=%s event=%s' "$ts" "$(((us / 1000) % 1000))" "$$" "${OMAPASS_SUB:-unknown}" "$event")"
    if (($# > 0)); then line="$line $*"; fi
    # shellcheck disable=SC2174 # parents are 0700 too under umask 077
    mkdir -p -m 700 "$dir" && printf '%s\n' "$line" >>"$file"
  } 2>/dev/null || true
  return 0
}

# omapass_end_debug <rc>: log the end event with total elapsed ms.
omapass_end_debug() {
  [[ "${OMAPASS_DEBUG:-}" == 1 ]] || return 0
  local now
  now="$(omapass_now_ms)"
  omapass_debug end "rc=$1" "ms=$((now - ${OMAPASS_START_MS:-$now}))"
}

# omapass_ok '<json object>': print {"ok":true,...} on one line and exit 0.
# omapass_ok and omapass_fail end the process: call them from the main shell only, never inside $(...) or a pipeline.
# omapass_ok '<json object>': print {"ok":true,...} on one line and exit 0. The object goes to jq on
# stdin (printf is a builtin), never on argv, and "ok" is always forced to true.
omapass_ok() {
  local json='{}'
  # An empty argument means the caller's payload builder failed: never turn it into success.
  if (($# > 0)); then json="$1"; fi
  [[ -n "$json" ]] || omapass_fail failed bad_output
  omapass__ok_from <(printf '%s' "$json")
}

# omapass_ok_file <path>: same as omapass_ok for a large object already written to a file (in OMAPASS_TMPDIR).
omapass_ok_file() {
  omapass__ok_from "${1:-/dev/null}"
}

omapass__ok_from() {
  local out
  if ! out="$(jq -c 'if type == "object" then {ok: true} + . + {ok: true} else error("not an object") end' <"$1" 2>/dev/null)" ||
    [[ -z "$out" || "$out" == *$'\n'* ]]; then
    omapass_fail failed bad_output
  fi
  OMAPASS_DONE=1
  printf '%s\n' "$out"
  omapass_end_debug 0
  exit 0
}

# omapass_fail <code> [reason]: print the failure envelope and exit with the contract code.
omapass_fail() {
  local code="${1:-failed}" reason="${2:-}" status
  case "$code" in
    signed_out | locked | too_old | plan_required | agent_session | network | timeout | not_found | failed) ;;
    *) code=failed ;;
  esac
  case "$reason" in
    usage | unknown_subcommand | missing_pass_cli | bad_version | bad_output | bad_input | bad_lib) ;;
    *) reason="" ;;
  esac
  status="$(omapass_exit_code "$code")"
  case "$reason" in
    usage | unknown_subcommand) status=2 ;;
  esac
  OMAPASS_DONE=1
  if [[ -n "$reason" ]]; then
    printf '{"ok":false,"error":"%s","reason":"%s"}\n' "$code" "$reason"
  else
    printf '{"ok":false,"error":"%s"}\n' "$code"
  fi
  omapass_end_debug "$status"
  exit "$status"
}

# Reset at source time so nothing inherited from the environment is trusted.
OMAPASS_TMPDIR=""
OMAPASS_TMPDIR_OWNER=""
OMAPASS_MAIN_PID=""
OMAPASS_DONE=0
OMAPASS_SUB=""
OMAPASS_PASS_STDERR=""
OMAPASS_PASS_CLI_VERSION=""
OMAPASS_START_MS=""

omapass_tmpdir_cleanup() {
  if [[ -n "$OMAPASS_TMPDIR" && "$BASHPID" == "$OMAPASS_TMPDIR_OWNER" ]]; then
    rm -rf -- "$OMAPASS_TMPDIR" 2>/dev/null || true
  fi
}

# omapass_on_exit: EXIT trap set once by the dispatcher (libs never set their own EXIT trap).
# Removes the temp dir and, if the main shell dies without printing an envelope
# (for example set -e stopped a subcommand), prints the generic failure.
omapass_on_exit() {
  omapass_tmpdir_cleanup
  if [[ "$BASHPID" == "${OMAPASS_MAIN_PID:-}" && "${OMAPASS_DONE:-0}" != 1 ]]; then
    OMAPASS_DONE=1
    printf '%s\n' '{"ok":false,"error":"failed"}'
    omapass_end_debug 1
    exit 1
  fi
}

# omapass_tmpdir: create the private temp dir (0700) once, in the main shell, and set OMAPASS_TMPDIR.
# The dispatcher calls it before any subcommand, so subshells and pipelines inherit it.
omapass_tmpdir() {
  if [[ -z "$OMAPASS_TMPDIR" || ! -d "$OMAPASS_TMPDIR" ]]; then
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    if ! OMAPASS_TMPDIR="$(mktemp -d "$base/omapass.XXXXXX" 2>/dev/null)"; then
      OMAPASS_TMPDIR=""
      omapass_fail failed
    fi
    OMAPASS_TMPDIR_OWNER="$BASHPID"
  fi
}

omapass_timeout() {
  local t="${OMAPASS_TIMEOUT:-}"
  if [[ "$t" =~ ^[0-9]{1,3}$ ]] && ((10#$t >= 1 && 10#$t <= 300)); then
    printf '%s' "$((10#$t))"
  else
    printf '20'
  fi
}

# omapass__run <stdin 0|1> <label> <args...>: stdout inherited, stderr to a private file.
omapass__run() {
  local keep_stdin="$1" label="${2:-}" t errfile start end rc=0 re='^[a-z][a-z -]*$'
  shift 2 || return 2
  [[ "$label" =~ $re ]] || return 2
  command -v pass-cli >/dev/null 2>&1 || return 127
  [[ -n "$OMAPASS_TMPDIR" && -d "$OMAPASS_TMPDIR" ]] || return 1
  errfile="${OMAPASS_PASS_STDERR:-$OMAPASS_TMPDIR/pass.stderr}"
  t="$(omapass_timeout)"
  start="$(omapass_now_ms)"
  if [[ "$keep_stdin" == 1 ]]; then
    timeout -k 2 "$t" pass-cli "$@" 2>"$errfile" || rc=$?
  else
    timeout -k 2 "$t" pass-cli "$@" </dev/null 2>"$errfile" || rc=$?
  fi
  end="$(omapass_now_ms)"
  omapass_debug pass-cli "cmd=\"$label\"" "rc=$rc" "ms=$((end - start))"
  return "$rc"
}

# omapass_pass <label> <args...>: run pass-cli with stdin closed. The label is logged, never the args.
omapass_pass() {
  omapass__run 0 "$@"
}

# omapass_pass_stdin <label> <args...>: same, with stdin inherited.
omapass_pass_stdin() {
  omapass__run 1 "$@"
}

# omapass_classify <rc> [errfile]: print "code" or "code reason" (contract classification table).
omapass_classify() {
  local rc="${1:-1}" f="${2:-${OMAPASS_PASS_STDERR:-${OMAPASS_TMPDIR:-}/pass.stderr}}" txt="" p
  case "$rc" in
    124 | 137)
      printf 'timeout'
      return 0
      ;;
    126 | 127)
      printf 'failed missing_pass_cli'
      return 0
      ;;
  esac
  if [[ -n "$f" && -r "$f" ]]; then
    txt="$(head -c 65536 "$f" 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')" || txt=""
  fi
  for p in 'agent session' 'proton_pass_agent_reason'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'agent_session'; return 0; fi
  done
  for p in 'session is locked' 'sessionlocked'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'locked'; return 0; fi
  done
  for p in 'requires an authenticated client' 'no active session' 'session has been invalidated' \
    'please log in again' 'non-existent session'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'signed_out'; return 0; fi
  done
  for p in 'not yet allowed to use' 'requires a paid plan' 'upgrade your plan'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'plan_required'; return 0; fi
  done
  for p in 'error sending request' 'network is unreachable' 'failed to connect' 'error trying to connect' \
    'error while connecting' 'name or service not known' 'temporary failure in name resolution' \
    'dns error' 'connection refused' 'connection reset' 'connection timed out'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'network'; return 0; fi
  done
  for p in 'could not find' 'error finding vault' 'no item found' 'does not exist' 'not found' \
    'no totp fields found'; do
    if [[ "$txt" == *"$p"* ]]; then printf 'not_found'; return 0; fi
  done
  printf 'failed'
}

omapass_valid_id() {
  local re='^[A-Za-z0-9_=-]{1,128}$'
  [[ "${1-}" =~ $re ]]
}

# omapass_version_ge <a> <b>: true when numeric X.Y.Z a >= b.
omapass_version_ge() {
  local re='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$' i
  local -a a b
  [[ "${1-}" =~ $re && "${2-}" =~ $re ]] || return 1
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
    if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
  done
  return 0
}

# omapass_check_version: sets OMAPASS_PASS_CLI_VERSION or fails with the contract error.
omapass_check_version() {
  local rc=0 line="" ver verfile cls code reason re='([0-9]+)\.([0-9]+)\.([0-9]+)'
  omapass_tmpdir
  verfile="$OMAPASS_TMPDIR/version.out"
  omapass_pass version --version >"$verfile" || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  line="$(head -n 1 "$verfile" 2>/dev/null | head -c 256 | tr -d '\0')" || line=""
  if [[ ! "$line" =~ $re ]]; then
    omapass_fail failed bad_version
  fi
  ver="${BASH_REMATCH[0]}"
  if ! omapass_version_ge "$ver" "$(omapass_min_version)"; then
    omapass_fail too_old
  fi
  # shellcheck disable=SC2034 # read by the subcommands
  OMAPASS_PASS_CLI_VERSION="$ver"
}
