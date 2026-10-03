# nvim-herdr-navigator

Seamless navigation between Neovim splits and [herdr](https://herdr.dev) panes: one set of `ctrl+h/j/k/l` chords moves through Neovim windows and herdr panes as if they were a single layout. A port of the [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) pattern to herdr.

This repository contains the Neovim plugin (`plugin/`, `lua/`, `doc/`) and the Herdr plugin (`herdr-plugin.toml`, `h-nav`, `lib/select-mru.jq`). Both installed halves must come from the same release or development checkout.

## How it works

The four actions (`left`, `down`, `up`, `right`) handle both keybindings and Neovim edge navigation:

1. **Herdr owns the chords.** Each keypress runs `h-nav` with `invocation_source: "keybinding"` in `HERDR_PLUGIN_CONTEXT_JSON`. For Neovim or fzf, `h-nav` forwards the chord with `herdr pane send-keys`. Other processes, including Vim, use pane navigation.
2. **Neovim tries its windows first.** At the layout edge, the plugin asynchronously runs `herdr plugin action invoke herdr-navigator.<direction>`. This calls the same action with `invocation_source: "cli"`. `h-nav` skips process detection and key forwarding. This prevents a loop back into Neovim. fzf handles the forwarded key itself.
3. **Pane navigation prefers a remembered neighbor.** `h-nav` records the source pane, then selects the most recently used (MRU) eligible neighbor. Without a remembered neighbor, or after an MRU failure, it runs native `herdr pane focus --direction`.

```text
Herdr keybinding -> action -> h-nav (keybinding)
  |-- Neovim -> send-keys -> window navigation
  |     `-- window edge -> same action (cli) -> h-nav -> pane navigation
  |-- fzf -> send-keys -> fzf handles the key
  `-- other (including Vim) -> pane navigation

pane navigation -> record source -> select MRU neighbor -> socket pane.focus
                                  `-- no target or failure -> native focus
```

`h-nav` uses `jq` to read the invocation source from the context JSON. Only `keybinding` permits key forwarding. All other nonempty string sources use pane navigation without process detection. Missing `jq`, absent or malformed JSON, or a missing, empty, or non-string source stops navigation with an error. These errors cause no key forwarding, history update, or focus fallback.

Herdr must supply `HERDR_BIN_PATH` and `HERDR_PANE_ID` for each action. Native fallback always specifies the original source pane. MRU selection also needs `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_STATE_DIR`, and `HERDR_SOCKET_PATH`, which Herdr supplies to plugin actions.

## Requirements

- herdr ≥ 0.9.1 (for invocation-source routing, macOS or Linux)
- `jq` on the Herdr plugin runtime's `PATH`, required for all navigation actions, including key forwarding
- Neovim ≥ 0.10 (for `vim.system` and automatic kitty-keyboard-protocol negotiation, see [notes](#notes--trade-offs))
- Both halves installed from the same release or checkout. The Herdr plugin must be enabled for Neovim edge navigation.
- Standard macOS/Linux shell utilities, including `tail`, for history reads.
- Optional `nc` (netcat) on the plugin runtime's `PATH`, with support for `-U -w 1`, for MRU focus by ID. Without it, pane navigation uses native geometry. History updates and reset still work.

The transport targets macOS netcat and Linux OpenBSD netcat. The macOS silent-socket timeout has a local verification result. Linux timeout behavior still needs integration verification. Executable presence alone does not establish compatible flags or timeout behavior.

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

Manual CLI calls such as `herdr plugin action invoke herdr-navigator.right` use the same MRU pane navigation. They skip Neovim windows and fzf key handling. An edge request can leave focus unchanged.

User commands (for custom mappings): `:HerdrNavigateLeft`, `:HerdrNavigateDown`, `:HerdrNavigateUp`, `:HerdrNavigateRight`. Disable the default mappings with `vim.g.herdr_navigator_no_mappings = 1`.

## MRU pane navigation

### Selection and examples

MRU means the most recent **source of a plugin pane-navigation request**, not the most recently focused pane from every source.

With a tall Pane 1 on the left and Panes 2 and 3 stacked on the right:

1. Focus Pane 3.
2. Navigate left through the plugin to Pane 1.
3. Navigate right through the plugin. Pane 3 receives focus instead of Pane 2.

The left request records `[3]`. The right request appends Pane 1 to produce `[3, 1]` and selects Pane 3. The source cannot select itself. The same sequence works through Neovim window edges.

Older useful entries also survive other moves. Add a short Pane 4 below Pane 1, with Pane 1 still overlapping both right panes. After plugin moves `3 → 1 → 4 → 1`, a right request selects Pane 3.

The selector uses the source pane's live tab layout:

- Candidates must touch the source pane's edge in the requested direction and have positive perpendicular overlap. Corner contact and gaps do not count.
- Among these candidates, the newest remembered pane wins. Recency takes priority over overlap size and center distance.
- The selector excludes the source, closed panes, and panes outside the live tab layout. Zoomed tabs use native fallback.

Without an eligible remembered candidate, native Herdr focus determines the destination. Selection does not wrap or cross tabs or workspaces.

The MRU move succeeds when `jq -e .result` accepts the server reply. A missing, null, or false result causes native fallback. An empty or malformed reply, or a transport failure without a result, also causes native fallback.

### History and limitations

History lives in `$HERDR_PLUGIN_STATE_DIR/pane-mru`. Each request appends one source pane ID, with the newest entry last. Selection reads the last 256 lines in reverse order. Duplicate entries remain in the file but do not change the first eligible match. Lines that do not match eligible pane IDs cannot win. The file grows until reset.

Every request that reaches pane navigation appends its source before focus. Failed focus requests and no-op edge requests also append their sources. Destinations enter history on their next plugin departure. Key forwarding and movement between Neovim windows do not read or update history.

Mouse clicks, native prefix navigation, and direct Herdr focus calls alone do not update this history. A later plugin request records its source, however that pane received focus. Clicking Pane 3, then Pane 1, does not by itself establish a preference for Pane 3.

Native prefix bindings remain geometric. A prefix binding configured as a plugin action uses MRU pane selection, subject to the same Neovim/fzf key-forwarding rule.

Recording uses a shell append, without temporary files, traps, or renames. Selection reads shared history after the append. Read or write failures preserve native navigation. The plugin trusts its state directory and does not reject symbolic links.

There is no writer lock. Concurrent requests can appear in each other's history reads, and their order is not guaranteed. Reset can overlap appends and reads. Use one active Herdr server per plugin state directory. Shared state does not isolate independent servers.

Existing newest-first files use the opposite order. Reset history once before navigation with this version.

### Reset history

The manifest runs `sh h-nav --reset` through a startup hook after server restore and during live handoff. This clears stale history because Herdr can reuse pane IDs. Startup hooks run asynchronously, so early navigation can overlap the reset.

Linking or enabling the plugin does not run this hook. Reset existing history manually before reuse after linking or enabling the plugin.

First, stop navigation requests that can overlap the reset. From the plugin checkout, run this command with the actual plugin state directory:

```sh
HERDR_PLUGIN_STATE_DIR="<actual absolute plugin state directory>" sh h-nav --reset
```

Do not guess the state directory or substitute the plugin source directory. Herdr supplies the state variable to plugin commands. Ordinary pane shells do not necessarily contain that variable.

Reset truncates the history file, or creates it if absent. It requires `HERDR_PLUGIN_STATE_DIR` to name an existing writable directory. It needs no pane ID, invocation context, `jq`, `nc`, or socket connection. The shell reports a failure if it cannot open the file. There is no public reset action in the manifest.

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
- **Latency.** Every navigation action parses its invocation source with `jq`. Keybindings also query process information. Pane navigation appends one source ID and reads at most 256 history lines for MRU selection. With another remembered ID and the MRU prerequisites, it adds one layout query and selection. A selected target adds one socket request. Otherwise, it uses native focus. Neovim adds an asynchronous action call at its window edge. The plugin-action path uses no login shell.
- **Socket timeout.** MRU focus uses `nc -U -w 1`. On compatible netcat variants, the one-second timeout bounds the raw-socket wait, not the total action duration. There is no socket retry. A lost response does not prove that focus stayed unchanged. Native fallback still uses the original source pane.

## Health check

```vim
:checkhealth herdr-navigator
```

The health check reports whether the plugin is active (`$HERDR_ENV == 1`), the herdr binary is executable, and the server answers process-info requests. It warns when `$TMUX` is set (unsupported, see notes).

A successful process-info request establishes server reachability, not action availability or successful edge navigation. The current health check does not inspect the Herdr version, installed actions, `jq`, `nc`, state access, or socket compatibility. Neovim and the plugin runtime can have different `PATH` values.

If edge navigation fails, inspect `herdr plugin action list --plugin herdr-navigator` and `herdr plugin log list --plugin herdr-navigator`. Missing or disabled actions and routing errors require an installation fix. Neovim does not bypass a failed action with a direct-focus call. After routing succeeds, `h-nav` provides native fallback for MRU failures.

If pane navigation works but MRU preference does not, inspect the action runtime's dependencies and state context. Missing netcat, unavailable state, missing MRU environment variables, layout errors, or socket errors cause native fallback. A failed history update also prints `h-nav: could not update history`.

The Lua notification reports only failure to start the Herdr executable. Action invocation returns before the action completes, so command failures require inspection of the plugin logs.

## Development

```sh
herdr plugin link /path/to/nvim-herdr-navigator
herdr plugin action list --plugin herdr-navigator
herdr plugin action invoke herdr-navigator.left
herdr plugin log list --plugin herdr-navigator
```

The manual action call demonstrates pane-only CLI navigation, not key forwarding. A real keybinding supplies the `keybinding` source.

Script and selector edits apply on the next invocation. After manifest edits, re-link the plugin. Linking does not reset existing history.

Run the isolated shell tests from the checkout:

```sh
sh -n h-nav
bash -n tests/h-nav-test
shellcheck -s sh h-nav
shellcheck -s bash tests/h-nav-test
bash tests/h-nav-test
```

The harness uses fake Herdr and netcat commands. It covers history, geometry, routing, socket responses, fallback, and reset under `sh` and, when available, `dash`. It does not move live panes. Real layout, focus, Linux timeout, and restart behavior still need controlled integration verification.

Design notes and plans live in [`docs/`](docs/). They include alternative designs, not only the current implementation. Focus-event recording, writer locks, separate focus/history scripts, and additional health probes remain unimplemented proposals.

## Credits

- [christoomey/vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) — the pattern, the `is_vim` process matching, and the ergonomics this plugin mirrors.
- [paulbkim-dev/vim-herdr-navigation](https://github.com/paulbkim-dev/vim-herdr-navigation) — prior art that validated the herdr-plugin packaging path.
