# Helper output contract

`bin/omapass-helper` is the only process in Omapass that talks to `pass-cli`
and the clipboard. QML and JS run it, read one JSON object from its stdout and
never see a secret. This document is the contract between the helper and its
callers. The JSON block under [Machine-readable contract](#machine-readable-contract)
is the single source of truth: `tests/contract.test.mjs` and
`tests/helper-core.test.sh` both read it, and the fixtures in `tests/fixtures`
are checked against it.

Markers used below:

- **verified**: seen in real `pass-cli` 2.7.1 output or `--help` text.
- **unverified**: taken from public docs, `proton-pass-common`, the reference
  plugin or reasoning; not yet seen in real output. Fixtures follow the best
  guess; correct them and this file together when real output disagrees.

## Rules every subcommand follows

1. Usage: `omapass-helper <subcommand> [args...]`. Subcommand names match
   `^[a-z][a-z0-9-]*$`.
2. Stdout carries exactly one JSON object on one line, on success and on
   failure. Nothing else is ever written to stdout.
3. Stderr stays empty. `pass-cli` stderr is captured to a private temp file,
   read only by the error classifier and deleted on exit; it is never echoed.
4. No secret is ever on argv (of the helper or of any process it starts), on
   stdout, on stderr or in the debug log.
   Secrets reach the helper only on stdin (`create`) or from `pass-cli` stdout,
   and leave it only through a pipe into `wl-copy` or `pass-cli`.
5. The helper runs with `set -euo pipefail` and `umask 077`; every file it
   creates is `0600` and every directory `0700`.
6. Items are keyed by `share_id` plus `id`. Item titles are never used to
   address an item (`--item-title` is never passed).
7. Item lists only ever request active items (`--filter-state active`).
8. Identifiers taken as arguments (`share_id`, `item_id`) must match
   `^[A-Za-z0-9_=-]{1,128}$`; anything else is a usage error.
9. Every `pass-cli` call runs under `timeout` (`OMAPASS_TIMEOUT` seconds,
   default 20, integer 1-300).

## Envelope

Success:

```json
{"ok":true, "...": "subcommand fields"}
```

Failure:

```json
{"ok":false,"error":"locked"}
{"ok":false,"error":"failed","reason":"unknown_subcommand"}
```

`error` is always one of the error codes below. `reason` is optional, only
ever one of the fixed reason tokens below, and is a hint for logs and tests;
callers branch on `error`. Callers map any `error` they do not know to `failed`.

## Error codes and exit codes

| error | exit | meaning | UI state |
|-------|------|---------|----------|
| (none) | 0 | success | `ready` or `empty` |
| `failed` | 1 | anything not covered below | generic error |
| `failed` + `reason: usage` or `unknown_subcommand` | 2 | bad invocation | generic error |
| `signed_out` | 10 | no session or session invalidated | offer sign-in |
| `locked` | 11 | session has a lock and is locked | offer unlock |
| `too_old` | 12 | `pass-cli` older than 2.7.1 | ask to update |
| `plan_required` | 13 | account or plan may not use the CLI or a feature | explain |
| `agent_session` | 14 | running on an agent (PAT) session; secrets refused | title-only list |
| `network` | 15 | cannot reach Proton | offline, keep cache |
| `timeout` | 16 | a `pass-cli` call exceeded `OMAPASS_TIMEOUT` | retry |
| `not_found` | 17 | item, vault or field does not exist | refresh list |

Reason tokens: `usage`, `unknown_subcommand`, `missing_pass_cli`,
`bad_version`, `bad_output`, `bad_input`, `bad_lib` (a `bin/lib` file was
refused). Planned: `no_lock` (OPA-16, see [Session lock](#session-lock)).

## Classifying `pass-cli` failures

The helper maps a failing `pass-cli` call to an error code from its exit
status and its stderr (lowercased, first 64 KiB), first match wins. pass-cli
returns errors from `main` (anyhow), so Rust prints `Error: <message>` on
stderr and exits 1; a few paths print with `eprintln!` and call `exit(1)`.
Strings marked "source" were read in the public pass-cli source
(github.com/protonpass/pass-cli, `main` at 2.7.1); none has been seen in real
output yet, because the probe never triggered an error state.

| order | condition | code | source |
|-------|-----------|------|--------|
| 1 | exit status 124 or 137 (our `timeout`) | `timeout` | coreutils `timeout` |
| 2 | exit status 126 or 127, or `pass-cli` not on `PATH` | `failed` + `missing_pass_cli` | shell |
| 3 | `agent session`, `proton_pass_agent_reason` | `agent_session` | source (2.7.1 `main`): `--show-secrets is not allowed with an agent session`, `Agent sessions must set the PROTON_PASS_AGENT_REASON environment variable ...`; not seen in real output |
| 4 | `session is locked`, `sessionlocked` | `locked` | source: `Session is locked. Please unlock your session and try again.` then `Could not perform operation. Reason: SessionLocked`; not seen in real output |
| 5 | `requires an authenticated client`, `no active session`, `session has been invalidated`, `please log in again`, `non-existent session` | `signed_out` | source: `This operation requires an authenticated client`, `No active session`, `Your session has been invalidated and you have been logged out automatically.` + `Please log in again with: pass login`; `non-existent session` from the reference plugin; not seen in real output |
| 6 | `not yet allowed to use`, `requires a paid plan`, `upgrade your plan` | `plan_required` | source: `Your account is not yet allowed to use our CLI` (login); the other two are unverified guesses for feature gates |
| 7 | `error sending request`, `network is unreachable`, `failed to connect`, `error trying to connect`, `error while connecting`, `name or service not known`, `temporary failure in name resolution`, `dns error`, `connection refused`, `connection reset`, `connection timed out` | `network` | source: `Error sending request` context; the underlying HTTP-client texts are unverified (reference plugin, common reqwest/hyper wording) |
| 8 | `could not find`, `error finding vault`, `no item found`, `does not exist`, `not found`, `no totp fields found` | `not_found` | source: `Could not find vault {}`, `Error finding vault [..]`, `No item found with title: {}`, `Field does not exist: {}`; `no totp fields found` from the reference plugin |
| 9 | anything else | `failed` | |

A successful exit whose stdout is not the expected JSON is `failed` +
`bad_output`.

`status` probes with `vault list`, which is not an audited agent command, so on
a real agent session `status` most likely returns `ready`; `agent_session`
shows up from `list` (the `--show-secrets` refusal). The `status` mapping for
`agent_session` is tested with a mocked refusal only.

## pass-cli invocations

Fixtures are keyed by the exact argument list (see `tests/mocks/pass-cli`), so
callers must pass arguments in exactly this order.

Every row was checked against `pass-cli <subcommand...> --help` from
`Proton Pass CLI 2.7.1 (cae479b)`. **verified** covers the subcommand and the
flags only; what `--help` cannot show (JSON output shapes, error texts) stays
**unverified** and is marked so.

| use | command | owner | status |
|-----|---------|-------|--------|
| version | `pass-cli --version` | OPA-10 | verified, output too |
| session probe, vaults | `pass-cli vault list --output json` | OPA-10, OPA-13 | verified |
| list a vault | `pass-cli item list --share-id <S> --filter-state active --output json --show-secrets` | OPA-13 | verified; `--filter-state` takes `active` or `trashed`; `--show-secrets` needs `--output json` and is not allowed with agent sessions |
| agent-session fallback | `pass-cli item list --share-id <S> --filter-state active --output json` | OPA-13 | verified |
| copy a field | `pass-cli item view --share-id <S> --item-id <I> --output json` (piped to `jq`, then `wl-copy --sensitive`) | OPA-14 | verified flags; JSON shape unverified. Never `--field`, `--item-title`, `--vault-name` or a `pass://` URI |
| copy TOTP | `pass-cli item totp --share-id <S> --item-id <I> --output json` | OPA-14 | verified flags; JSON shape unverified. `--field` (one TOTP field of several) exists and is not used |
| trash | `pass-cli item trash --share-id <S> --item-id <I>` | OPA-16 | verified. Never `--item-title` or `--vault-name` |
| untrash | `pass-cli item untrash --share-id <S> --item-id <I>` | OPA-16 | corrected: was `item untrash ...`; same flags as `trash` |
| lock | `pass-cli session lock` | OPA-16 | verified; no options; requires an existing lock, see [Session lock](#session-lock) |
| logout | `pass-cli logout` | OPA-16 | verified; `--force` (log out even if remote logout fails) exists and is not passed |
| login | `pass-cli login` (in a terminal) | OPA-16 | added, verified; `--pat <PAT>` exists and is never passed (a token on argv) |
| unlock | `pass-cli session unlock` (in a terminal) | OPA-16 | added, verified; no options; how it reads the lock code is unverified |
| create | `pass-cli item create <type> --get-template`, then `pass-cli item create <type> --share-id <S> --from-template -` | OPA-18, OPA-23 | verified for `login`, `note`, `credit-card`, `wifi`, `identity`, `custom`. Corrected: `ssh-key` has no `--get-template` and `item create alias` does not exist; both have their own rows |
| create SSH key | `pass-cli item create ssh-key generate --share-id <S> --title <T> --key-type <K> [--comment <C>]` | OPA-23 | added, verified |
| import SSH key | `pass-cli item create ssh-key import --share-id <S> --title <T> --from-private-key <FILE>` | OPA-23 | added, verified; how the key reaches `<FILE>` is decided in OPA-23 (for example a private temp file written under `umask 077` and deleted on exit; the key itself never goes on argv) |
| create alias | `pass-cli item alias create --share-id <S> --prefix <P> --output json` | OPA-23 | verified; `--output` defaults to `human`, so `json` must be passed; JSON shape unverified |
| generate | `pass-cli password generate random <options> --output json` / `pass-cli password generate passphrase <options> --output json` (inside `create` only) | OPA-18 | verified flags; JSON shape unverified |

`pass-cli --version` prints `Proton Pass CLI 2.7.1 (cae479b)` (verified). The
helper takes the first `MAJOR.MINOR.PATCH` and compares it numerically with
2.7.1.

### Options from `--help`

All verified against 2.7.1 `--help`. Flag names are exact; placeholders in
the tables above are shortened (`<S>`, `<FILE>`), and the list below uses
the help text's own placeholders.

- `password generate random`: `--length <LENGTH>` (default 16); `--numbers`,
  `--uppercase`, `--symbols`, each `true` or `false` (default `true`);
  `--output human|json` (default `human`).
- `password generate passphrase`: `--separator` one of `hyphens`, `spaces`,
  `periods`, `commas`, `underscores`, `numbers`, `numbers-and-symbols`
  (default `hyphens`); `--capitalise true|false` (alias `--capitalize`,
  default `true`); `--numbers true|false` (default `true`); `--count <COUNT>`
  (default 5); `--output human|json` (default `human`).
- `item create ssh-key generate`: `--title <TITLE>` (required); `--key-type`
  one of `ed25519`, `rsa2048`, `rsa4096` (default `ed25519`);
  `--comment <COMMENT>`; `--password` (a flag that enables a key passphrase; how it reads the
  passphrase is unverified, so the helper does not pass it); `--share-id`,
  `--vault-name`, `--folder-id`.
- `item create ssh-key import`: `--from-private-key <PRIVATE_KEY_FILE>` and
  `--title <TITLE>` (both required); `--password` (as above); `--share-id`,
  `--vault-name`, `--folder-id`.
- `item alias create`: `--prefix <PREFIX>` (required; the address is
  `[prefix].[suffix]`); `--share-id`, `--vault-name`; `--output human|json`.
- `item create login|note|credit-card|wifi|identity|custom`: `--get-template`,
  `--from-template <FROM_TEMPLATE>` (a path or `-` for stdin), `--share-id`, `--vault-name`, `--folder-id`.
  `login`, `note`, `credit-card` and `wifi` also take per-field flags
  (`--password`, `--cvv`, `--pin`, `--number`, `--generate-password[=...]` and
  others). They would put secrets on argv, so the helper never uses them
  (rule 4); it always goes through `--from-template -`.
- `item list`: also `--vault-name`, a positional `[VAULT_NAME]`,
  `--filter-type` and `--sort-by`; the helper addresses vaults by share ID
  only.
- `session create-lock`: `--idle-timeout <IDLE_TIMEOUT>` in seconds (30 to
  900, default 300); how it reads the lock code is unverified. `session
  remove-lock` takes no options. The helper runs neither.

### Session lock

`pass-cli session lock` "requires an existing lock" (verified, `--help`): a
lock code must first be set with `pass-cli session create-lock`. What
`session lock` prints and exits with when no lock exists is unverified.

Decision for `lock` (OPA-16): the helper clears its clipboard state first,
then runs `pass-cli session lock`. When that fails because the session has no
lock, `lock` returns `{"ok":false,"error":"failed","reason":"no_lock"}` (exit
1), and the UI says that no lock code is set and offers to open a terminal
running `pass-cli session create-lock`. Every other failure goes through the
error classifier as usual. The helper never logs out instead: that would
force a full sign-in for a user who only asked to lock.

`no_lock` is a planned reason token. It is not yet in the JSON block below,
because `tests/model.test.mjs` requires `Model.REASONS` to equal its
`reasons` list. OPA-16 adds `no_lock` to the JSON block, to the reason
allowlist in `omapass_fail` (`bin/lib/core.sh`) and to `Model.REASONS` in the
same change, and confirms the real no-lock error text before matching it.

## Subcommands

| subcommand | args | stdin | owner | status |
|------------|------|-------|-------|--------|
| `status` | none | none | OPA-10 | implemented |
| `version` | none | none | OPA-10 | implemented |
| `vaults` | none | none | OPA-13 | planned |
| `list` | `[--share-id <S>]...` | none | OPA-13 | planned |
| `copy` | `<share_id> <item_id> <field> [--paste-once] [--clear-after <0-300>]` | none | OPA-14 | planned |
| `clipboard-clear` | internal: run detached by `copy` | none | OPA-14 | planned |
| `trash`, `untrash` | `<share_id> <item_id>` | none | OPA-16 | planned |
| `lock` | none | none | OPA-16 | planned |
| `logout` | none | none | OPA-16 | planned |
| `login`, `unlock` | none: open a terminal running `pass-cli login` / `pass-cli session unlock` | none | OPA-16 | planned |
| `create` | `<type> --share-id <S>` | form JSON | OPA-18, OPA-23 | planned |
| `recents` | `add <share_id> <item_id>`, `list`, `clear` | none | OPA-20 | implemented |

### `version`

Checks `pass-cli` only; needs no session.

```json
{"ok":true,"pass_cli":"2.7.1","min_pass_cli":"2.7.1"}
```

Errors: `too_old`, `failed` (`missing_pass_cli`, `bad_version`), `timeout`.

### `status`

Runs `version`, then probes the session with `vault list --output json`
(no secrets). The vault names are not printed.

```json
{"ok":true,"state":"ready","pass_cli":"2.7.1","min_pass_cli":"2.7.1","vaults":2}
```

Errors: everything `version` returns, plus `signed_out`, `locked`,
`plan_required`, `agent_session`, `network`, `timeout`, `not_found`, `failed`
(the probe's stderr goes through the same classifier as every other call).

### `vaults`

```json
{"ok":true,"vaults":[{"share_id":"...","vault_id":"...","name":"..."}]}
```

### `list`

Lists every vault (or the given `--share-id`s), one `item list` call per vault
(at most 4 at a time), each piped straight into `jq`, which keeps only the
allowlisted fields below. `jq` stderr is dropped. As a second guard the `jq`
filter also drops any item whose `state`, lowercased, is `trashed`. A failing vault does not abort
the others: it is reported in `vaults[]` with its own `error`, its items are
absent, and the envelope stays `ok:true`. Only when every vault fails does the
envelope fail with the first vault's error.

```json
{
  "ok": true,
  "notice": null,
  "vaults": [
    {"share_id": "S1", "vault_id": "V1", "name": "Personal", "ok": true, "count": 3},
    {"share_id": "S2", "vault_id": "V2", "name": "Work", "ok": false, "error": "network"}
  ],
  "items": [ListItem]
}
```

`notice` is `null` or `"agent_session"`. On an agent session `--show-secrets`
is refused, so the helper falls back to the title-only call and every item is
title-only: `username`, `email` `null`, `urls` `[]`, `has_totp` `false`,
`secret_fields` and `fields` `[]`. The title-only output has a top-level
`item_type` and `title` (verified keys); the `item_type` values are
unverified (fixtures use the variant names, such as `Login`).

`ListItem`:

| key | type | from (`--show-secrets` output) |
|-----|------|--------------------------------|
| `share_id` | string | `.share_id` |
| `id` | string | `.id` |
| `vault_id` | string | `.vault_id` |
| `vault` | string | vault `name` from `vault list` |
| `type` | string | the single key of `.content.content`, mapped by the type table |
| `title` | string | `.content.title` |
| `username` | string or null | display field, per type |
| `email` | string or null | display field, per type |
| `urls` | string[] | display field, per type (`[]` when none) |
| `create_time` | string | `.create_time` (ISO-8601) |
| `modify_time` | string | `.modify_time` (ISO-8601) |
| `last_use_time` | string or null | `.last_use_time` |
| `has_totp` | bool | a non-empty TOTP anywhere in the item |
| `secret_fields` | string[] | copy-field names that are non-empty on this item; names only, never values |
| `fields` | object[] | dynamic fields: `{"field":"extra:0","name":"<label>","kind":"text"}` |

Empty strings in display fields become `null`. Nothing else from the item
reaches stdout: no `note`, no `password`, no `totp_uri`, no passkeys, no
`autofill_urls`, no `platform_specific`, no field values.

### Type table

The `type` values match `pass-cli --filter-type` and `item create`. Copy-field
names are what `copy` takes and what `secret_fields` lists (decision 30).

| `type` | variant key | display fields | copy fields → source |
|--------|-------------|----------------|----------------------|
| `login` | `Login` | `username`, `email`, `urls` | `username` → `Login.username`, `email` → `Login.email`, `password` → `Login.password`, `totp` → `Login.totp_uri` (copied as a code via `item totp`) |
| `alias` | `Alias` (`null`) | `email` ← top-level `.alias_email` | `alias` → `.alias_email` |
| `note` | `Note` (unverified: `null`) | none | `note` → `.content.note` |
| `credit-card` | `CreditCard` (unverified) | none | `holder` → `cardholder_name`, `number` → `number`, `cvv` → `verification_number`, `expiry` → `expiration_date` |
| `identity` | `Identity` | none | `name` → `full_name`, `email` → `email`, `phone` → `phone_number`, `address` → `street_address` |
| `ssh-key` | `SshKey` | none | `private_key` → `private_key`, `public_key` → `public_key` |
| `wifi` | `Wifi` | none | `ssid` → `ssid`, `password` → `password` |
| `custom` | `Custom` | none | dynamic only |

Dynamic fields, for every type:

- `extra:<i>` is `.content.extra_fields[i]`; `name` is its `.name`, `kind` is
  `text`, `hidden`, `timestamp` or `totp` from its single content key
  (`Text`, `Hidden`, `Timestamp` verified; `Totp` unverified).
- `section:<s>:<f>` is field `f` of `.content.content.<Variant>.sections[s]`
  (`Custom`, `SshKey`, `Wifi`). Section element shape is unverified; fixtures
  use `{"section_name": "...", "section_fields": [<extra field>]}`, following
  `proton-pass-common`.

A dynamic field is listed in `fields` and in `secret_fields` only when its value
is non-empty. `has_totp` is true when `Login.totp_uri` or any dynamic field of
kind `totp` is non-empty.

Credit-card and note content, the `Totp` extra-field variant, section
elements and the `state` values (`Active`, `Trashed`) were not present in the
probed vault; they are unverified and the fixtures follow `--get-template` and
`proton-pass-common`. The `--get-template` output for `credit-card` names the
CVV `cvv`, while `proton-pass-common` names it `verification_number`; the list
fixture uses `verification_number` (unverified).

### `copy`, `clipboard-clear`

`copy <share_id> <item_id> <field>` copies one copy field (type table) or one
dynamic field to the clipboard: `pass-cli` stdout goes through `jq` straight
into `wl-copy --sensitive` (`-o` with `--paste-once`). A detached
`clipboard-clear` clears it after `--clear-after` seconds (default 45, 0 means
never) only if the clipboard still matches an HMAC with a random per-session
key kept `0600` in `$XDG_RUNTIME_DIR`. Unknown fields: `not_found`.

```json
{"ok":true,"field":"password","clear_after":45}
```

### `trash`, `untrash`, `lock`, `logout`, `login`, `unlock`

```json
{"ok":true}
{"ok":true,"state":"locked"}
{"ok":true,"state":"signed_out"}
```

`lock` also clears the clipboard; with no session lock it will fail with
`failed` + `no_lock` (a planned reason, added by OPA-16; see
[Session lock](#session-lock)). `login` and `unlock`
open a terminal; the password or lock code is entered there (or in the browser
`pass-cli login` opens; unverified) and never reaches the helper.

### `create`

`create <type> --share-id <S>` reads the form JSON on stdin, fills the
`--get-template` output with `jq` and pipes it to
`pass-cli item create <type> --share-id <S> --from-template -`. This template
path covers `login`, `note`, `credit-card`, `wifi`, `identity` and `custom`
only: `ssh-key` has no `--get-template` and uses `item create ssh-key
generate` or `import`, and an alias uses `item alias create` (see
[pass-cli invocations](#pass-cli-invocations)); OPA-23 maps their form fields
to those flags. Invalid form JSON is `failed` + `bad_input` and `pass-cli` is
not called.

```json
{"ok":true,"type":"login","share_id":"..."}
```

### `recents`

Stores `share_id`, `id` and timestamps only, at most 8, in
`$XDG_STATE_HOME/omapass/recents.json` (`0600`, directory `0700`).

```json
{"ok":true,"recents":[{"share_id":"...","id":"...","time":"2026-01-01T00:00:00Z"}]}
```

Newest first; `add` of an entry already stored moves it to the front with a
new `time`, and past 8 the oldest is dropped. `add` and `clear` take an
exclusive `flock` on `recents.lock` in the same directory and replace the file
atomically (temp file, `0600`, `mv`). `list` keeps only well-formed entries
(valid ids, UTC `time`); a missing or invalid file reads as empty. Every
action prints the resulting `recents` (`[]` after `clear`).

The `showRecents` setting reaches the helper as `OMAPASS_SHOW_RECENTS`: `0`
or `false` turns it off, anything else (or unset) is on. Off, `add` writes
nothing (not even the directory) and `list` returns `[]`; `clear` still
removes the file. Never calls `pass-cli`.

Errors: `failed` + `usage` (unknown action, wrong argument count), `failed` +
`bad_input` (an id that fails `omapass_valid_id`), `failed` (the directory is
a symlink or not ours, `recents.lock` is a symlink or not a regular file, the
lock times out after 5 s, or the write fails).

## Debug log

Off unless `OMAPASS_DEBUG=1`. Written to `OMAPASS_DEBUG_LOG`, default
`$XDG_RUNTIME_DIR/omapass/debug.log` (else
`${XDG_STATE_HOME:-$HOME/.local/state}/omapass/debug.log`), file `0600`,
directory `0700`, appended. One line per event, nothing else:

```text
2026-01-01T00:00:00.000Z pid=1234 sub=status event=start
2026-01-01T00:00:00.120Z pid=1234 sub=status event=pass-cli cmd="vault list" rc=0 ms=118
2026-01-01T00:00:00.121Z pid=1234 sub=status event=end rc=0 ms=121
```

`cmd` is a fixed label chosen by the caller, never the argument list, so no
id, title, vault name or value is logged. An unknown subcommand is logged as
`sub=unknown`.

## Adding a subcommand

Put a file in `bin/lib/` that defines `omapass_cmd_<name>` (dashes become
underscores) and nothing else at top level. The dispatcher sources every
`bin/lib/*.sh` and calls the matching function; it never needs editing. A lib
that is a symlink, not a regular file, not owned by the user, or writable by
group or others is refused (`bad_lib`), and so is a group- or other-writable
`bin/` or `bin/lib/`, a lib that fails `bash -n`, and a lib whose top level
returns non-zero or calls `exit`.

Core API (`bin/lib/core.sh`), for later libs:

- `omapass_ok '<json object>'` prints the success envelope and exits 0;
  `omapass_ok_file <path>` does the same for a large object in a file. The
  object reaches `jq` on stdin, never on argv, and `ok` is forced to `true`.
  An empty-string argument (a failed `"$(jq ...)"` payload builder) or a
  non-object fails with `failed` + `bad_output`.
- `omapass_fail <code> [reason]` prints the failure envelope and exits with
  the contract exit code; unknown codes become `failed`, unknown reasons are
  dropped.
- Both end the process: call them from the main shell only, never inside
  `$(...)` or a pipeline. A subcommand that returns without calling either, or
  that `set -e` stops, gets `{"ok":false,"error":"failed"}` and exit 1 from the
  dispatcher's EXIT trap. Libs never set their own EXIT trap.
- `OMAPASS_TMPDIR` is a private `0700` directory created before the subcommand
  runs and removed on exit; keep every temp file there.
- `omapass_pass <label> <args...>` runs `pass-cli` under `timeout` with stdin
  closed, stdout inherited (pipe or redirect it) and stderr written to
  `$OMAPASS_PASS_STDERR` (default `$OMAPASS_TMPDIR/pass.stderr`);
  `omapass_pass_stdin` keeps stdin (for `--from-template -`). `<label>` is a
  fixed literal such as `"item list"`, the only part that is logged. Parallel
  calls must each set `OMAPASS_PASS_STDERR` to their own file in
  `OMAPASS_TMPDIR` and pass it to `omapass_classify`.
- `omapass_classify <rc> [stderr file]` prints `code` or `code reason`.
- `omapass_check_version` fails with `too_old`/`bad_version` or sets
  `OMAPASS_PASS_CLI_VERSION`.
- `omapass_valid_id`, `omapass_version_ge`, `omapass_debug`, `omapass_now_ms`.
- The helper's stderr is `/dev/null` from the first line, so nothing can leak
  there; diagnostics go to the debug log only.

## Machine-readable contract

<!-- contract:begin -->
```json
{
  "min_pass_cli": "2.7.1",
  "default_timeout": 20,
  "exit_codes": {
    "ok": 0,
    "failed": 1,
    "usage": 2,
    "signed_out": 10,
    "locked": 11,
    "too_old": 12,
    "plan_required": 13,
    "agent_session": 14,
    "network": 15,
    "timeout": 16,
    "not_found": 17
  },
  "errors": ["signed_out", "locked", "too_old", "plan_required", "agent_session", "network", "timeout", "not_found", "failed"],
  "reasons": ["usage", "unknown_subcommand", "missing_pass_cli", "bad_version", "bad_output", "bad_input", "bad_lib"],
  "subcommands": {
    "status": "OPA-10",
    "version": "OPA-10",
    "vaults": "OPA-13",
    "list": "OPA-13",
    "copy": "OPA-14",
    "clipboard-clear": "OPA-14",
    "trash": "OPA-16",
    "untrash": "OPA-16",
    "lock": "OPA-16",
    "logout": "OPA-16",
    "login": "OPA-16",
    "unlock": "OPA-16",
    "create": "OPA-18",
    "recents": "OPA-20"
  },
  "vault_keys": ["name", "share_id", "vault_id"],
  "item_keys": ["id", "share_id", "vault_id", "state", "flags", "create_time", "modify_time", "last_use_time", "content"],
  "title_only_item_keys": ["id", "share_id", "vault_id", "state", "flags", "create_time", "modify_time", "last_use_time", "item_type", "title"],
  "list_item_keys": ["share_id", "id", "vault_id", "vault", "type", "title", "username", "email", "urls", "create_time", "modify_time", "last_use_time", "has_totp", "secret_fields", "fields"],
  "extra_field_kinds": {"Text": "text", "Hidden": "hidden", "Timestamp": "timestamp", "Totp": "totp"},
  "secret_extra_kinds": ["hidden", "totp"],
  "types": {
    "login": {
      "variant": "Login",
      "template": "login",
      "display": {"username": "username", "email": "email", "urls": "urls"},
      "copy": {
        "username": {"path": ["content", "content", "Login", "username"], "template": "username"},
        "email": {"path": ["content", "content", "Login", "email"], "template": "email"},
        "password": {"path": ["content", "content", "Login", "password"], "template": "password", "secret": true},
        "totp": {"path": ["content", "content", "Login", "totp_uri"], "template": "totp_uri", "secret": true, "totp": true}
      }
    },
    "alias": {
      "variant": "Alias",
      "template": null,
      "display": {"email": "alias_email"},
      "copy": {
        "alias": {"path": ["alias_email"], "template": null}
      }
    },
    "note": {
      "variant": "Note",
      "template": "note",
      "display": {},
      "copy": {
        "note": {"path": ["content", "note"], "template": "note", "secret": true}
      }
    },
    "credit-card": {
      "variant": "CreditCard",
      "template": "credit-card",
      "display": {},
      "copy": {
        "holder": {"path": ["content", "content", "CreditCard", "cardholder_name"], "template": "cardholder_name"},
        "number": {"path": ["content", "content", "CreditCard", "number"], "template": "number", "secret": true},
        "cvv": {"path": ["content", "content", "CreditCard", "verification_number"], "template": "cvv", "secret": true},
        "expiry": {"path": ["content", "content", "CreditCard", "expiration_date"], "template": "expiration_date"}
      }
    },
    "identity": {
      "variant": "Identity",
      "template": "identity",
      "display": {},
      "copy": {
        "name": {"path": ["content", "content", "Identity", "full_name"], "template": "full_name"},
        "email": {"path": ["content", "content", "Identity", "email"], "template": "email"},
        "phone": {"path": ["content", "content", "Identity", "phone_number"], "template": "phone_number"},
        "address": {"path": ["content", "content", "Identity", "street_address"], "template": "street_address"}
      }
    },
    "ssh-key": {
      "variant": "SshKey",
      "template": null,
      "display": {},
      "copy": {
        "private_key": {"path": ["content", "content", "SshKey", "private_key"], "template": null, "secret": true},
        "public_key": {"path": ["content", "content", "SshKey", "public_key"], "template": null}
      }
    },
    "wifi": {
      "variant": "Wifi",
      "template": "wifi",
      "display": {},
      "copy": {
        "ssid": {"path": ["content", "content", "Wifi", "ssid"], "template": "ssid"},
        "password": {"path": ["content", "content", "Wifi", "password"], "template": "password", "secret": true}
      }
    },
    "custom": {
      "variant": "Custom",
      "template": "custom",
      "display": {},
      "copy": {}
    }
  },
  "sections_variants": ["Custom", "SshKey", "Wifi"],
  "canary": "CANARY",
  "fixture_id_prefix": "FIXTURE-"
}
```
<!-- contract:end -->
