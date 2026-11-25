# shellcheck shell=bash
# create subcommand: the template engine (form JSON on stdin -> --get-template -> jq -> --from-template -).
#
# Secret handling (contract rule 4): the form and any generated password live only in shell
# variables that are never exported. They reach jq and pass-cli through pipes fed by the printf
# builtin, never through argv (no --arg/--argjson with values), never through a temp file and
# never in the debug log (pass-cli calls log a fixed label only). Only the template, which holds
# no secret, is written to OMAPASS_TMPDIR.
#
# Types: a template type <t> (dashes become underscores in function names) provides
#   omapass_create_type_<t>_check  prints a jq expression, true when the form (.) is valid
#   omapass_create_type_<t>_fill   prints a jq expression applied to the template (.), with
#                                  $f the form and $pw the generated password (a string or null)
# A type that does not use a template (ssh-key, alias: OPA-23) instead provides
#   omapass_create_type_<t>_run <share_id>  called after the form is read and the version checked;
#                                           it must end with omapass_ok or omapass_fail.
# login, note and custom live here; later types go in bin/lib/create-types.sh.

# unset first: a name inherited from the environment would stay marked for export.
unset OMAPASS_CREATE_FORM OMAPASS_CREATE_SECRET OMAPASS_CREATE_FILLED
OMAPASS_CREATE_FORM=""
OMAPASS_CREATE_SECRET="null"
OMAPASS_CREATE_FILLED=""

omapass_create_max_form() {
  printf '65536'
}

# jq definitions shared by every check and fill expression.
omapass_create_jq_defs() {
  cat <<'JQ'
def only($allowed): type == "object" and ((keys - $allowed) == []);
def ostr($k; $max): (.[$k] == null) or ((.[$k] | type) == "string" and (.[$k] | length) <= $max);
def obool($k): (.[$k] == null) or ((.[$k] | type) == "boolean");
def oint($k; $lo; $hi): (.[$k] == null) or ((.[$k] | type) == "number" and .[$k] == (.[$k] | floor) and .[$k] >= $lo and .[$k] <= $hi);
def title_ok: (.title | type) == "string" and (.title | length) > 0 and (.title | length) <= 512;
def strs($k; $n; $max): (.[$k] == null) or ((.[$k] | type) == "array" and (.[$k] | length) <= $n and all(.[$k][]; type == "string" and length <= $max));
def generate_ok:
  (.generate == null) or (.generate | type == "object" and (
    (.kind == "random" and only(["kind", "length", "numbers", "uppercase", "symbols"])
      and oint("length"; 8; 64) and obool("numbers") and obool("uppercase") and obool("symbols"))
    or (.kind == "passphrase" and only(["kind", "count", "separator", "capitalise", "numbers"])
      and oint("count"; 3; 10) and obool("capitalise") and obool("numbers")
      and (.separator == null or (.separator as $s
        | any(("hyphens", "spaces", "periods", "commas", "underscores", "numbers", "numbers-and-symbols"); . == $s))))));
def has_all($k): . as $o | all($k[]; . as $x | $o | has($x));
def need($k): if type == "object" and has_all($k) then . else error("template") end;
JQ
}

# --- login, note, custom -------------------------------------------------------------------

omapass_create_type_login_check() {
  cat <<'JQ'
only(["title", "username", "email", "password", "generate", "urls", "totp_uri"])
and title_ok and ostr("username"; 512) and ostr("email"; 512) and ostr("password"; 1024)
and ostr("totp_uri"; 2048) and strs("urls"; 32; 2048) and generate_ok
and (.password == null or .generate == null)
JQ
}

omapass_create_type_login_fill() {
  cat <<'JQ'
need(["title", "username", "email", "password", "totp_uri", "urls"])
| .title = $f.title
| .username = $f.username
| .email = $f.email
| .password = (if $pw != null then $pw else $f.password end)
| .totp_uri = $f.totp_uri
| .urls = ($f.urls // [])
JQ
}

omapass_create_type_note_check() {
  cat <<'JQ'
only(["title", "note"]) and title_ok and ostr("note"; 65536)
JQ
}

omapass_create_type_note_fill() {
  cat <<'JQ'
need(["title", "note"])
| .title = $f.title
| .note = $f.note
JQ
}

omapass_create_type_custom_check() {
  cat <<'JQ'
only(["title", "note", "section", "fields"]) and title_ok and ostr("note"; 65536) and ostr("section"; 256)
and ((.fields == null) or ((.fields | type) == "array" and (.fields | length) <= 64
  and all(.fields[]; only(["name", "value", "hidden"]) and (.name | type) == "string" and (.name | length) > 0
    and (.name | length) <= 256 and ostr("value"; 8192) and obool("hidden"))))
JQ
}

omapass_create_type_custom_fill() {
  cat <<'JQ'
need(["title", "note", "sections"])
| .title = $f.title
| .note = ($f.note // "")
| .sections = (($f.fields // []) as $fs
    | if ($fs | length) == 0 then []
      else [{section_name: ($f.section // "Fields"),
             fields: [$fs[] | {field_name: .name,
                               field_type: (if .hidden == true then "hidden" else "text" end),
                               value: (.value // "")}]}]
      end)
JQ
}

# --- engine --------------------------------------------------------------------------------

# omapass_create_has_type <type>: true when <type> has a template (check+fill) or its own run hook.
omapass_create_has_type() {
  local t="${1//-/_}"
  [[ "$1" =~ ^[a-z][a-z-]{0,31}$ ]] || return 1
  declare -F "omapass_create_type_${t}_run" >/dev/null 2>&1 && declare -F "omapass_create_type_${t}_check" >/dev/null 2>&1 && return 0
  declare -F "omapass_create_type_${t}_check" >/dev/null 2>&1 && declare -F "omapass_create_type_${t}_fill" >/dev/null 2>&1
}

# omapass_create_read_form <type>: read stdin into OMAPASS_CREATE_FORM and validate it with the
# type's check, or fail with failed + bad_input before any pass-cli call.
omapass_create_read_form() {
  local t="${1//-/_}" max check ok=""
  max="$(omapass_create_max_form)"
  # head -c reads the bytes from stdin; the value never leaves this process except through pipes.
  OMAPASS_CREATE_FORM="$(head -c "$((max + 1))" 2>/dev/null)" || OMAPASS_CREATE_FORM=""
  if [[ -z "$OMAPASS_CREATE_FORM" ]] || ((${#OMAPASS_CREATE_FORM} > max)); then
    OMAPASS_CREATE_FORM=""
    omapass_fail failed bad_input
  fi
  check="$("omapass_create_type_${t}_check")"
  ok="$(printf '%s' "$OMAPASS_CREATE_FORM" |
    jq -s "$(omapass_create_jq_defs)"$'\n'"length == 1 and (.[0] | type == \"object\" and ($check))" 2>/dev/null)" || ok=""
  if [[ "$ok" != true ]]; then
    OMAPASS_CREATE_FORM=""
    omapass_fail failed bad_input
  fi
}

# omapass_create_generator_args: print the pass-cli argv for the form's .generate, one per line,
# in the fixed contract order with every default spelled out; nothing when there is no .generate.
# Booleans are tested with == null, never //, so an explicit false stays false.
omapass_create_generator_args() {
  printf '%s' "$OMAPASS_CREATE_FORM" | jq -r '
    def b($k; $d): if .[$k] == null then $d else .[$k] end | tostring;
    .generate // empty
    | if .kind == "random" then
        "random", "--length", (b("length"; 16)), "--numbers", b("numbers"; true),
        "--uppercase", b("uppercase"; true), "--symbols", b("symbols"; true), "--output", "json"
      else
        "passphrase", "--separator", b("separator"; "hyphens"), "--capitalise", b("capitalise"; true),
        "--numbers", b("numbers"; true), "--count", b("count"; 5), "--output", "json"
      end' 2>/dev/null
}

# omapass_create_generate: when the form asks for one, generate a password with pass-cli and keep it
# in OMAPASS_CREATE_SECRET as a JSON string (else "null"). The output shape of
# `password generate --output json` is unverified, so the parser accepts a JSON string or an object
# whose password, passphrase or value is a non-empty string, and fails closed (bad_output) otherwise.
omapass_create_generate() {
  local -a args=()
  local line out="" rc=0 cls code reason
  OMAPASS_CREATE_SECRET="null"
  while IFS= read -r line; do
    args+=("$line")
  done < <(omapass_create_generator_args)
  ((${#args[@]} > 0)) || return 0
  case "${args[0]}" in
    random | passphrase) ;;
    *) omapass_fail failed bad_input ;;
  esac
  out="$(omapass_pass "password generate" password generate "${args[@]}")" || rc=$?
  if ((rc != 0)); then
    out=""
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  OMAPASS_CREATE_SECRET="$(printf '%s' "$out" | jq -s -c '
    def ok: type == "string" and length > 0 and length <= 1024;
    if length != 1 then error("shape") else .[0] end
    | if type == "string" then .
      elif type == "object" then ([.password, .passphrase, .value] | map(select(ok)) | first // null)
      else null end
    | if ok then . else error("shape") end' 2>/dev/null)" || OMAPASS_CREATE_SECRET=""
  out=""
  if [[ -z "$OMAPASS_CREATE_SECRET" || "$OMAPASS_CREATE_SECRET" == null ]]; then
    OMAPASS_CREATE_SECRET="null"
    omapass_fail failed bad_output
  fi
}

# omapass_create_template <type> <out file>: write `item create <type> --get-template` to <out file>.
omapass_create_template() {
  local rc=0 cls code reason
  omapass_pass "item template" item create "$1" --get-template >"$2" || rc=$?
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
  jq -e 'type == "object"' "$2" >/dev/null 2>&1 || omapass_fail failed bad_output
}

# omapass_create_fill <type> <template file>: fill the template into OMAPASS_CREATE_FILLED.
# stdin of jq carries the form, then the generated password (both from printf, a builtin);
# the template, which holds no secret, is read from its file.
omapass_create_fill() {
  local t="${1//-/_}" fill
  fill="$("omapass_create_type_${t}_fill")"
  OMAPASS_CREATE_FILLED="$(printf '%s\n%s\n' "$OMAPASS_CREATE_FORM" "$OMAPASS_CREATE_SECRET" |
    jq -c -n --slurpfile tpl "$2" "$(omapass_create_jq_defs)"$'\n'"input as \$f | input as \$pw | \$tpl[0] | $fill" \
      2>/dev/null)" || OMAPASS_CREATE_FILLED=""
  OMAPASS_CREATE_SECRET="null"
  if [[ -z "$OMAPASS_CREATE_FILLED" || "$OMAPASS_CREATE_FILLED" == *$'\n'* ]]; then
    OMAPASS_CREATE_FILLED=""
    omapass_fail failed bad_output
  fi
}

# omapass_create_submit <type> <share_id>: pipe OMAPASS_CREATE_FILLED to
# `item create <type> --share-id <S> --from-template -`. pass-cli stdout is discarded.
omapass_create_submit() {
  local rc=0 cls code reason
  printf '%s\n' "$OMAPASS_CREATE_FILLED" |
    omapass_pass_stdin "item create" item create "$1" --share-id "$2" --from-template - >/dev/null || rc=$?
  OMAPASS_CREATE_FILLED=""
  OMAPASS_CREATE_FORM=""
  if ((rc != 0)); then
    cls="$(omapass_classify "$rc")"
    read -r code reason <<<"$cls"
    omapass_fail "$code" "$reason"
  fi
}

# create <type> --share-id <S>
omapass_cmd_create() {
  local type="${1:-}" share="" tpl t
  if (($# != 3)) || [[ "${2:-}" != --share-id ]]; then omapass_fail failed usage; fi
  share="$3"
  omapass_valid_id "$share" || omapass_fail failed usage
  omapass_create_has_type "$type" || omapass_fail failed usage
  t="${type//-/_}"
  omapass_create_read_form "$type"
  omapass_check_version
  if declare -F "omapass_create_type_${t}_run" >/dev/null 2>&1; then
    "omapass_create_type_${t}_run" "$share"
    omapass_fail failed
  fi
  tpl="$OMAPASS_TMPDIR/template.json"
  omapass_create_template "$type" "$tpl"
  omapass_create_generate
  omapass_create_fill "$type" "$tpl"
  omapass_create_submit "$type" "$share"
  omapass_ok "$(jq -cn --arg t "$type" --arg s "$share" '{type:$t,share_id:$s}')"
}
