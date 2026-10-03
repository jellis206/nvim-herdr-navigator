# nvim-herdr-navigator

Seamless navigation between Neovim splits and [herdr](https://herdr.dev) panes: one set of `ctrl+h/j/k/l` chords moves through Neovim windows and herdr panes as if they were a single layout. A port of the [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) pattern to herdr.

This repository contains both the Neovim plugin (`plugin/`, `lua/`, `doc/`) and the herdr plugin (`herdr-plugin.toml`, `h-nav`).

## How it works

The four actions (`left`, `down`, `up`, `right`) handle both keybindings and Neovim edge navigation:

1. **Herdr owns the chords.** Each keypress runs `h-nav` with `invocation_source: "keybinding"` in `HERDR_PLUGIN_CONTEXT_JSON`. For Neovim or fzf, `h-nav` forwards the chord with `herdr pane send-keys`. For other processes, including Vim, it runs `herdr pane focus --direction`.
2. **Neovim tries its windows first.** At the layout edge, the plugin asynchronously runs `herdr plugin action invoke herdr-navigator.<direction>`. This calls the same action with `invocation_source: "cli"`. `h-nav` skips process detection and key forwarding, then focuses the neighbouring pane. This prevents a loop back into Neovim. fzf handles the forwarded key itself.

```
herdr keybinding ── action ── h-nav (keybinding)
                              ├─ Neovim ── send-keys ── wincmd
                              │                           └─ edge ── same action (cli) ── h-nav ── pane focus
                              ├─ fzf ── send-keys ── fzf handles the key
                              └─ other (including Vim) ── pane focus
```

`h-nav` uses `jq` to read the source from the context JSON. Missing `jq`, absent or malformed JSON, or a missing, empty, or non-string source stops navigation with an error. It does not forward keys or focus a pane after this error. Other nonempty source strings retain the keybinding path.

Herdr must supply `HERDR_BIN_PATH` and `HERDR_PANE_ID` for each action. `h-nav` uses the supplied binary and pane ID for every Herdr command.

## Requirements

- herdr ≥ 0.9.1 (for invocation-source routing, macOS or Linux)
- `jq` on the Herdr plugin runtime's `PATH`, required for all navigation actions, including key forwarding
- Neovim ≥ 0.10 (for `vim.system` and automatic kitty-keyboard-protocol negotiation, see [notes](#notes--trade-offs))
- Both halves of this repository installed. The herdr plugin must be enabled for Neovim edge navigation.

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

Manual CLI calls such as `herdr plugin action invoke herdr-navigator.right` always move pane focus. They skip Neovim windows and fzf key handling.

User commands (for custom mappings): `:HerdrNavigateLeft`, `:HerdrNavigateDown`, `:HerdrNavigateUp`, `:HerdrNavigateRight`. Disable the default mappings with `vim.g.herdr_navigator_no_mappings = 1`.

## Configuration

```lua
require("herdr-navigator").setup({
  herdr_bin = "herdr",   -- path to the herdr binary used for the edge handoff
  save_on_switch = nil,  -- nil | "update" | "wall": write buffers before leaving vim
})
```

## Notes & trade-offs

- **Shadowed shell keys.** Like the tmux original, shells lose direct `ctrl+l` (clear), `ctrl+k` (kill-to-EOL) and `ctrl+h` (backspace) to navigation. `prefix+ctrl+l` restores clear-screen; the others still work while typing in Neovim's insert mode and in any pane whose foreground process matches the passthrough pattern.
- **`ctrl+h` vs Backspace.** `ctrl+h` and Backspace share byte `0x08` in legacy terminal encoding, so pass-through only distinguishes them when the kitty keyboard protocol is active. Neovim ≥ 0.10 negotiates it automatically inside herdr panes, keeping `<C-h>` distinct from `<BS>`.
- **tmux is not supported.** Running tmux inside a herdr pane — with or without vim-tmux-navigator — is unsupported: herdr owns the chords and does not pass them through to tmux, so the chords never reach a nested tmux session. Use herdr panes directly instead.
- **Normal mode only** (for now). Terminal-mode mappings à la vim-tmux-navigator are a planned follow-up.
- **No wrap.** `herdr pane focus --direction` stops at the screen edge instead of wrapping — the behaviour vim-tmux-navigator ships `no_wrap` to get.
- **Latency.** Each keybinding action queries process information, then forwards a key or focuses a pane. A Neovim edge crossing adds a CLI action invocation and a pane-focus command. Each `h-nav` invocation also runs `jq`. The plugin-action path uses no login shell.

## Health check

```vim
:checkhealth herdr-navigator
```

The health check reports whether the plugin is active (`$HERDR_ENV == 1`), the herdr binary is executable, and the server answers process-info requests. It warns when `$TMUX` is set (unsupported, see notes).

A successful process-info request establishes server reachability, not action availability or successful edge navigation. The health check does not check the Herdr version, installed actions, or `jq` in the plugin runtime. Neovim and the plugin runtime can have different `PATH` values.

If edge navigation fails, inspect `herdr plugin action list --plugin herdr-navigator` and `herdr plugin log list --plugin herdr-navigator`. Missing or disabled actions and routing errors require an installation fix. There is no direct-focus fallback.

The Lua notification reports only failure to start the Herdr executable. Action invocation returns before the action completes, so command failures require inspection of the plugin logs.

## Development

```sh
herdr plugin link /path/to/nvim-herdr-navigator
herdr plugin action list --plugin herdr-navigator
herdr plugin action invoke herdr-navigator.left
herdr plugin log list --plugin herdr-navigator
```

The manual action call demonstrates pane-only CLI navigation, not key forwarding. A real keybinding supplies the `keybinding` source.

Script edits apply on the next invocation. After manifest edits, re-link the plugin. Design notes and plans live in [`docs/`](docs/).

## Credits

- [christoomey/vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) — the pattern, the `is_vim` process matching, and the ergonomics this plugin mirrors.
- [paulbkim-dev/vim-herdr-navigation](https://github.com/paulbkim-dev/vim-herdr-navigation) — prior art that validated the herdr-plugin packaging path.
