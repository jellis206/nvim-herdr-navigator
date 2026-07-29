# nvim-herdr-navigator

Seamless navigation between Neovim splits and [herdr](https://herdr.dev) panes: one set of `ctrl+h/j/k/l` chords moves through vim windows and herdr panes as if they were a single layout. A port of the [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) pattern to herdr.

This repository contains both the nvim plugin (`plugin/`, `lua/`, `doc/`) and the herdr plugin (`herdr-plugin.toml`, `h-nav`)

## How it works

Both herdr and vim want to own `ctrl+h/j/k/l`, so the two sides cooperate:

1. **Herdr owns the chords.** Each keypress runs the `h-nav` plugin action, which checks the focused pane's foreground process. If it is vim-like (vi/vim/nvim/gvim/view/lvim/… or fzf), the chord is passed through to the pane with `herdr pane send-keys`; otherwise herdr moves focus directly with `herdr pane focus --direction`.
2. **Vim owns the chords while focused.** The mappings move between vim windows; when a move hits the edge of vim's layout, the plugin hands off asynchronously to `herdr pane focus`, crossing into the neighbouring pane.

```
terminal ── herdr binding (ctrl+h)
             ├─ foreground is vim? ── send-keys ──▶ nvim wincmd
             │                                       └─ at split edge? ──▶ herdr pane focus
             └─ otherwise ──▶ herdr pane focus
```

## Requirements

- herdr ≥ 0.7.4 (macOS or Linux)
- Neovim ≥ 0.10 (for `vim.system` and automatic kitty-keyboard-protocol negotiation, see [notes](#notes--trade-offs))

## Installation

### 1. Herdr

```sh
herdr plugin install kaar/nvim-herdr-navigator
```

Then bind the actions in `~/.config/herdr/config.toml`, using the qualified action ids:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "herdr-navigator.left"
description = "navigate left (nvim/herdr)"

[[keys.command]]
key = "ctrl+j"
type = "plugin_action"
command = "herdr-navigator.down"
description = "navigate down (nvim/herdr)"

[[keys.command]]
key = "ctrl+k"
type = "plugin_action"
command = "herdr-navigator.up"
description = "navigate up (nvim/herdr)"

[[keys.command]]
key = "ctrl+l"
type = "plugin_action"
command = "herdr-navigator.right"
description = "navigate right (nvim/herdr)"

# clear-screen parity: the direct ctrl+l chord is taken by navigation,
# so prefix+ctrl+l sends a literal ctrl+l to the pane (the analogue of
# vim-tmux-navigator's `bind C-l send-keys C-l`).
[[keys.command]]
key = "prefix+ctrl+l"
type = "shell"
command = "\"$HERDR_BIN_PATH\" pane send-keys \"$HERDR_ACTIVE_PANE_ID\" ctrl+l"
description = "send ctrl+l (clear screen) to pane"
```

**Important:** the direct `ctrl+h/j/k/l` chords must *not* also be bound to the `focus_pane_*` actions, or the action binding races the plugin action. Keep only prefix fallbacks there (`focus_pane_left = "prefix+h"`, …).

Reload and check for a clean diagnostics list:

```sh
herdr server reload-config
```

<details>
<summary>No-install fallback: bare shell keybindings (no herdr plugin)</summary>

`h-nav` also works as a plain `type = "shell"` custom command — copy it somewhere stable and bind:

```toml
[[keys.command]]
key = "ctrl+h"
type = "shell"
command = "$HOME/.config/herdr/scripts/h-nav left"
description = "navigate left (nvim/herdr)"
# ... same for ctrl+j/k/l with down/up/right
```

This pays a `/bin/sh -lc` login shell per keypress; the plugin action path is faster.

</details>

### 2. Neovim

With `vim.pack` (Neovim ≥ 0.12):

```lua
vim.pack.add({ "https://github.com/kaar/nvim-herdr-navigator" })
```

No `setup()` call is required. The plugin is a no-op unless nvim runs inside a herdr pane (`$HERDR_ENV == 1`).

[vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) can stay installed alongside: inside herdr this plugin owns the chords (it sets `g:tmux_navigator_no_mappings`, and its mappings win regardless of plugin load order); inside tmux it stays inactive and vim-tmux-navigator works as usual.

## Usage

| Focused pane  | `ctrl+h/j/k/l` does                                  |
| ------------- | ---------------------------------------------------- |
| shell / other | moves herdr pane focus left/down/up/right            |
| vim / nvim    | moves vim windows; crosses out to herdr at the edge  |
| fzf           | `ctrl+j/k` move the selection (chord passed through) |

User commands (for custom mappings): `:HerdrNavigateLeft`, `:HerdrNavigateDown`, `:HerdrNavigateUp`, `:HerdrNavigateRight`. Disable the default mappings with `vim.g.herdr_navigator_no_mappings = 1`.

## Configuration

```lua
require("herdr-navigator").setup({
  herdr_bin = "herdr",   -- path to the herdr binary used for the edge handoff
  save_on_switch = nil,  -- nil | "update" | "wall": write buffers before leaving vim
})
```

On the herdr side, `HERDR_NAVIGATOR_PASSTHROUGH_RE` (a POSIX extended regex over foreground process names, set in the herdr server's environment) extends — never replaces — the vim/fzf pattern, so other TUIs can receive the chords too:

```sh
HERDR_NAVIGATOR_PASSTHROUGH_RE='lazygit|k9s'
```

## Notes & trade-offs

- **Shadowed shell keys.** Like the tmux original, shells lose direct `ctrl+l` (clear), `ctrl+k` (kill-to-EOL) and `ctrl+h` (backspace) to navigation. `prefix+ctrl+l` restores clear-screen; the others still work while typing in vim's insert mode and in any pane whose foreground process matches the passthrough pattern.
- **`ctrl+h` vs Backspace.** `ctrl+h` and Backspace share byte `0x08` in legacy terminal encoding, so pass-through only distinguishes them when the kitty keyboard protocol is active. Neovim ≥ 0.10 negotiates it automatically inside herdr panes, keeping `<C-h>` distinct from `<BS>`.
- **tmux is not supported.** Running tmux inside a herdr pane — with or without vim-tmux-navigator — is unsupported: herdr owns the chords and does not pass them through to tmux, so the chords never reach a nested tmux session. Use herdr panes directly instead.
- **Normal mode only** (for now). Terminal-mode mappings à la vim-tmux-navigator are a planned follow-up.
- **No wrap.** `herdr pane focus --direction` stops at the screen edge instead of wrapping — the behaviour vim-tmux-navigator ships `no_wrap` to get.
- **Latency.** Worst case two CLI round-trips per keypress (~10 ms each), no login shell on the plugin-action path. The endgame is a native pass-through predicate upstream in herdr (see `docs/upstream-passthrough-investigation.md`).

## Health check

```vim
:checkhealth herdr-navigator
```

Verifies the plugin is active (`$HERDR_ENV` set), the herdr binary is executable, and `herdr pane process-info --current` answers. Warns when `$TMUX` is set (unsupported, see notes).

## Development

```sh
herdr plugin link /path/to/nvim-herdr-navigator
herdr plugin action list --plugin herdr-navigator
herdr plugin action invoke herdr-navigator.left
herdr plugin log list --plugin herdr-navigator
```

Script edits are live on the next invocation; manifest edits (new/renamed actions) may need a re-link. Design notes and the extraction plan live in [`docs/`](docs/).

## Credits

- [christoomey/vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) — the pattern, the `is_vim` process matching, and the ergonomics this plugin mirrors.
- [paulbkim-dev/vim-herdr-navigation](https://github.com/paulbkim-dev/vim-herdr-navigation) — prior art that validated the herdr-plugin packaging path.
