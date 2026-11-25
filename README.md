# Omapass for Omarchy

A Proton Pass picker for the [Omarchy](https://omarchy.org/) bar: search, copy
and manage entries from the keyboard.

**Status:** early development, not usable yet.

## Install

On an Omarchy system:

```bash
omarchy plugin add https://github.com/elvisgastelum/omarchy-omapass.git --enable
```

Or from a clone of this repo:

```bash
make install
```

## Settings

Settings live on the plugin's bar widget entry. Set them from the command line,
with `--json` for numbers, booleans and arrays:

| Key                     | Default | Meaning                                                              |
|-------------------------|---------|----------------------------------------------------------------------|
| `clipboardClearSeconds` | `45`    | Seconds before a copied secret is cleared from the clipboard (0 keeps it) |
| `pasteOnce`             | `false` | Clear the clipboard after the first paste                            |
| `hiddenVaults`          | `[]`    | JSON array of vault share_ids to hide                                |
| `showRecents`           | `true`  | List recently used entries at the top of the picker                  |
| `webAccountIndex`       | `0`     | Proton web session number used in `/u/<n>/` links                    |
| `refreshMaxAgeSeconds`  | `120`   | Reuse cached entries younger than this many seconds                  |

```bash
omarchy bar set elvisgastelum.omapass clipboardClearSeconds 30 --json
```

## Development

Make targets:

```text
make help       List the targets
make install    Install from GitHub and put it on the bar
make update     Pull the latest version of the installed plugin
make uninstall  Remove the plugin
make enable     Put the widget on the bar
make disable    Take the widget off the bar
make test       Run the tests and check the JSON files parse
make validate   Validate the manifest against Omarchy's plugin schema
make check      Run test and validate
make dev        Copy this working tree over the installed plugin
```

`make dev` runs `make check`, copies the working tree over the installed plugin
and restarts the shell. It stops when the installed checkout is dirty or is not
a git checkout, unless you pass `FORCE=1`. Its own copy leaves that checkout
dirty, so later runs need `FORCE=1` too.

## Credits

Inspired by [josh2c/omarchy-protonpass](https://github.com/josh2c/omarchy-protonpass) (MIT). Omapass is a rewrite, not a fork.

## License

MIT
