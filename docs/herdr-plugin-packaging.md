# Packaging the herdr half as a herdr plugin

How this repo ships its herdr side as a proper herdr plugin (manifest +
action script) instead of a loose script bound via
`[[keys.command]] type = "shell"`. This is the distribution decision from
`implementation-outline.md` §5 / `steal-from-vim-herdr-navigation.md` §1,
worked out to the concrete files. The same conversion applied to the
original prototype in-place is documented from the config repo's
perspective in `~/Dev/herdr-config/docs/h-nav-as-plugin.md`.

Prior art proving plugin actions work on a per-keypress hot path:
<https://github.com/paulbkim-dev/vim-herdr-navigation> and the fzf-url
plugin in `~/Dev/herdr-config/plugins/fzf-url`.

## Why a plugin beats a script binding

- **No shell per keypress.** `type = "shell"` custom commands run through
  `/bin/sh -lc` — a login shell (profile sourcing and all) on every
  press. Plugin action `command`s are argv arrays that herdr execs
  directly.
- **No absolute path in the user's config.** Actions are referenced by
  id; herdr resolves the plugin root. The README install step stops
  depending on where the plugin manager checked the repo out.
- **Lifecycle.** `version`, `min_herdr_version` gating, enable/disable,
  `herdr plugin action list` discoverability, `herdr plugin log list`
  debugging.
- **One-command install**: `herdr plugin install <owner>/nvim-herdr-navigator`
  (GitHub shorthand), or `herdr plugin link <checkout>` for development.

## Repo layout (herdr half)

The manifest must sit at the directory users install/link, so it lives at
the repo root, next to the nvim plugin structure:

```
nvim-herdr-navigator/
├── herdr-plugin.toml         -- herdr plugin manifest (repo root)
├── h-nav                     -- action script (sh, no dependencies)
├── plugin/ lua/ doc/         -- the nvim half
└── docs/
```

## The manifest

`herdr-plugin.toml`:

```toml
# herdr-plugin.toml - herdr side of nvim-herdr-navigator.
#
# Install:
#   herdr plugin install <owner>/nvim-herdr-navigator
# Local development (link does not run build steps):
#   herdr plugin link /path/to/nvim-herdr-navigator
#
# Vim-aware directional pane focus (vim-tmux-navigator pattern): bound to
# direct ctrl+h/j/k/l chords, passes the chord through when the focused
# pane runs vim/fzf, otherwise moves herdr pane focus. The nvim half
# (plugin/, lua/) hands navigation back at vim's layout edge.

id = "herdr-navigator"
name = "Herdr Navigator"
version = "0.1.0"
min_herdr_version = "0.7.4"
description = "Seamless ctrl+h/j/k/l across herdr panes and Neovim splits."
platforms = ["linux", "macos"]

[[actions]]
id = "left"
title = "Navigate left (nvim/herdr)"
contexts = ["global"]
command = ["sh", "h-nav", "left"]

[[actions]]
id = "down"
title = "Navigate down (nvim/herdr)"
contexts = ["global"]
command = ["sh", "h-nav", "down"]

[[actions]]
id = "up"
title = "Navigate up (nvim/herdr)"
contexts = ["global"]
command = ["sh", "h-nav", "up"]

[[actions]]
id = "right"
title = "Navigate right (nvim/herdr)"
contexts = ["global"]
command = ["sh", "h-nav", "right"]
```

Details that matter:

- `command` is an **argv array, not a shell line** — no word splitting,
  globbing, or `$VAR` expansion; anything needing shell syntax goes
  inside the script. `["sh", "h-nav", …]` sidesteps executable-bit
  concerns, and the relative path works because herdr runs plugin
  commands **with the plugin directory as cwd**.
- `contexts = ["global"]` — navigation isn't tied to a workspace row.
- Plugin actions run **without a TTY**; fine here, `h-nav` only calls
  the CLI.

## The script: one env-var difference

The pane id env var differs between binding styles:

| Binding style | Focused-pane env var |
| --- | --- |
| `[[keys.command]] type = "shell"` | `HERDR_ACTIVE_PANE_ID` |
| plugin action | `HERDR_PANE_ID` (invocation context) |

Plugin actions additionally receive `HERDR_BIN_PATH`,
`HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_STATE_DIR`, `HERDR_PLUGIN_ACTION_ID`,
and `HERDR_PLUGIN_CONTEXT_JSON`. So `h-nav` resolves the pane as:

```sh
pane=${HERDR_PANE_ID:-${HERDR_ACTIVE_PANE_ID:?h-nav must run from a herdr keybinding}}
```

Keeping both fallbacks means the identical script also works as a bare
`type = "shell"` binding — ship that recipe in the README as the
no-install fallback for older herdr or non-plugin setups. The rest of
the script (vim/fzf pattern → `pane send-keys`, otherwise
`pane focus --direction`) is unchanged; see
`implementation-outline.md` §4 for the current source.

## User-facing keybindings (README snippet)

Qualified action ids (`<plugin id>.<action id>`), since bare ids like
`left` are generic:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "herdr-navigator.left"
description = "navigate left (nvim/herdr)"

# … ctrl+j -> herdr-navigator.down, ctrl+k -> herdr-navigator.up,
#   ctrl+l -> herdr-navigator.right …

# clear-screen parity: the direct ctrl+l chord is taken by navigation,
# so prefix+ctrl+l sends a literal ctrl+l to the pane. Stays a plain
# shell command — no vim logic, no reason to be a plugin action.
[[keys.command]]
key = "prefix+ctrl+l"
type = "shell"
command = "\"$HERDR_BIN_PATH\" pane send-keys \"$HERDR_ACTIVE_PANE_ID\" ctrl+l"
description = "send ctrl+l (clear screen) to pane"
```

Plus the prefix fallbacks users likely already have
(`focus_pane_left = "prefix+h"`, …) — and the direct `ctrl+*` chords
must NOT also be bound to `focus_pane_*`, or the action binding races
the plugin action.

After editing: `herdr server reload-config`, confirm `"diagnostics":[]`.

## Development and debugging workflow

1. `herdr plugin link /path/to/nvim-herdr-navigator` — registers the
   working copy; script edits are live on the next invocation (manifest
   edits — new/renamed actions — may need a re-link; verify with
   `herdr plugin action list --plugin herdr-navigator`).
2. Invoke an action directly, without the keybinding:
   `herdr plugin action invoke --plugin herdr-navigator --action left`.
3. Inspect failures: `herdr plugin log list --plugin herdr-navigator`.
4. Test matrix: shell pane (chords move focus), nvim splits (chords move
   windows, cross out at edges), fzf (`ctrl+j/k` move the list),
   insert-mode `ctrl+h` still backspaces, `prefix+ctrl+l` clears.

## Caveats

- **Latency**: still two CLI round-trips per keypress in the worst case,
  just without the login-shell startup — strictly faster than the
  `type = "shell"` version. The endgame that removes the subprocess
  entirely is the upstream native pass-through feature
  (`upstream-passthrough-investigation.md`).
- **Does the manifest-at-root conflict with nvim plugin managers?** No —
  lazy.nvim/vim.pack ignore unknown root files; conversely
  `herdr plugin link` on the repo root ignores `lua/`/`plugin/`. One
  repo, both halves, like vim-tmux-navigator shipping its `.tmux` file.
- **Windows**: manifest declares `platforms = ["linux", "macos"]`; the
  sh script and key semantics are untested elsewhere.
