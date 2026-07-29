# Investigation: porting vim-tmux-navigator to Herdr

Goal: seamless `ctrl+h/j/k/l` navigation across nvim splits and multiplexer panes, the way [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) does it for tmux, but for [Herdr](https://herdr.dev).

Sources: vendored vim-tmux-navigator in `~/Dev/tmux-config/plugins/vim-tmux-navigator/`, offline Herdr docs (herdr-docs skill clone), and live verification against a running Herdr 0.7.5 server.

## How vim-tmux-navigator works in tmux

It is a two-sided handshake. Neither side alone is enough because both tmux and vim want to own `ctrl+h/j/k/l`.

### tmux side (`vim-tmux-navigator.tmux`)

Binds `C-h/j/k/l` in the root table (no prefix) with a conditional:

```
bind-key -n C-h if-shell "$is_vim" "send-keys C-h" "select-pane -L"
```

`$is_vim` runs `ps -o state= -o comm= -t '#{pane_tty}'` and greps the foreground process of the focused pane against a regex:

```
(\S+/)?g?\.?(view|l?n?vim?x?|fzf)(diff)?(-wrapped)?
```

So: if the focused pane runs vim (or nvim, fzf, ...), tmux forwards the raw key into the pane; otherwise tmux navigates with `select-pane`.

Details worth noting:

- The pattern and check command are configurable via tmux options (`@vim_navigator_pattern`, `@vim_navigator_check`).
- Copy-mode gets unconditional bindings (`bind-key -T copy-mode-vi C-h select-pane -L`).
- `prefix C-l` is rebound to `send-keys C-l` to restore clear-screen, since root-table `C-l` is consumed.
- Optional zoom handling: `@tmux_navigator_disable_when_zoomed` wraps the command in `if-shell -F '#{window_zoomed_flag}'`.

### vim side (`plugin/tmux_navigator.vim`)

Maps `<C-h/j/k/l>` (and `<C-\>` for previous) in normal mode to `TmuxNavigate*` commands which:

1. Try `wincmd h/j/k/l` to move between vim splits.
2. Compare `winnr()` before and after. If unchanged, vim is at the edge of its splits.
3. At the edge, shell out to tmux: `tmux -S <socket> select-pane -t $TMUX_PANE -L/-D/-U/-R`. The socket path comes from the first comma-separated field of `$TMUX`; the pane from `$TMUX_PANE`.

Other behaviors:

- When `$TMUX` is empty, the commands degrade to plain `wincmd` and the tmux forwarding code is never defined.
- Terminal-mode mappings (`tnoremap`) exist too, with an fzf exception (fzf buffers keep raw keys).
- Options: `g:tmux_navigator_save_on_switch` (write buffers before switching), `g:tmux_navigator_disable_when_zoomed`, `g:tmux_navigator_preserve_zoom` (`select-pane -Z`), `g:tmux_navigator_no_wrap` (guards with `#{pane_at_left}` etc.).
- `TmuxNavigatePrevious` (`<C-\>`) toggles to the last pane, tracked with a `s:tmux_is_last_pane` flag reset on `WinEnter`.

### Keypress flow

```
terminal -> tmux root binding
             is foreground process vim?
               yes -> send-keys into pane -> vim wincmd
                        at split edge? -> `tmux select-pane` (shell out from vim)
               no  -> select-pane directly
```

## Herdr findings

Herdr 0.7.5 has no built-in vim-aware navigation (checked docs and source). But every primitive the tmux mechanism needs exists. Verified live against a running server:

| tmux concept | Herdr equivalent | Status |
|---|---|---|
| `bind -n C-h if-shell ...` | `[[keys.command]]` with `type = "shell"` bound to `ctrl+h`; runs detached via `/bin/sh -lc`, receives `HERDR_ACTIVE_PANE_ID`, `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH` | documented |
| `ps -t '#{pane_tty}'` is_vim check | `herdr pane process-info --pane ID` returns JSON: `foreground_processes[]` with `pid`, `name`, `argv0`, `cmdline`, `cwd`, plus `shell_pid` | verified live |
| `send-keys C-h` (forward to vim) | `herdr pane send-keys <pane_id> ctrl+h` (same key-combo syntax: `ctrl+h`, legacy `C-h` accepted) | documented |
| `select-pane -L/-D/-U/-R` | `herdr pane focus --direction left\|down\|up\|right` | verified live |
| `$TMUX` / `$TMUX_PANE` inside vim | `$HERDR_PANE_ID` (exported into every pane process), `$HERDR_ENV` | documented |
| `select-pane -l` (previous) | `last_pane` keybinding action exists, but no "focus last pane" CLI/socket verb found | gap |
| Wrapping at screen edge | tmux wraps by default; `pane focus --direction` does not wrap (matches vim-tmux-navigator's `no_wrap` option) | behavior difference |

Latency measured: ~10ms per CLI round trip (`pane process-info` and `pane focus` both ~8-10ms). Two hops per keypress inside vim (~20ms) is comparable to tmux's per-keypress `ps` fork.

Relevant Herdr docs pages: `configuration.mdx` (custom command keybindings), `cli-reference.mdx` (pane commands, key syntax, env vars), `socket-api.mdx` (`pane.process_info`, `pane.focus_direction`, `pane.send_keys`), `keyboard.mdx` (prefix-free chords).

### Current pain point in herdr-config

`~/Dev/herdr-config/config.toml` binds:

```toml
focus_pane_left = ["prefix+h", "ctrl+h"]
focus_pane_down = ["prefix+j", "ctrl+j"]
focus_pane_up = ["prefix+k", "ctrl+k"]
focus_pane_right = ["prefix+l", "ctrl+l"]
```

Herdr consumes the direct `ctrl+h/j/k/l` chords before the pane app sees them, so nvim never receives the keys. A config comment already flags this. This is exactly the conflict vim-tmux-navigator's conditional binding solves in tmux.

## Proposed design

### Herdr side

Remove the direct `ctrl+h/j/k/l` entries from `focus_pane_*` (keep the `prefix+h/j/k/l` fallbacks). Add four `[[keys.command]]` shell bindings that run a dispatch script:

```toml
[[keys.command]]
key = "ctrl+h"
type = "shell"
command = "$HOME/.config/herdr/scripts/h-navigate left"
description = "navigate left (vim-aware)"
# ... repeat for down/up/right
```

`h-navigate <direction>` (pseudocode):

```sh
info=$("$HERDR_BIN_PATH" pane process-info --pane "$HERDR_ACTIVE_PANE_ID")
fg=$(jq -r '.result.process_info.foreground_processes[].name' <<<"$info")
if [[ $fg =~ vim_pattern ]]; then
  "$HERDR_BIN_PATH" pane send-keys "$HERDR_ACTIVE_PANE_ID" "ctrl+$key_letter"
else
  "$HERDR_BIN_PATH" pane focus --direction "$direction"
fi
```

Use the same foreground-process regex as vim-tmux-navigator. Use `$HERDR_BIN_PATH` and an absolute `jq` path (or a grep fallback) so login-shell PATH cost is irrelevant.

### nvim side

Drop vim-tmux-navigator. Add `plugin/herdr-navigator.lua` (~30 lines, fits the nvim-config no-`lua/`-dir convention):

- Map `<C-h/j/k/l>` in normal mode (and terminal mode) to a function that runs `wincmd`, compares `winnr()` before/after, and on no movement with `$HERDR_PANE_ID` set runs `herdr pane focus --direction <dir>` via `vim.system` (async, fire-and-forget).
- Outside Herdr (`$HERDR_PANE_ID` unset) it degrades to plain `wincmd`, same as the original plugin outside tmux.

### Keypress flow (ported)

```
terminal -> Herdr custom command binding (ctrl+h)
             h-navigate: foreground process vim?
               yes -> pane send-keys ctrl+h -> nvim wincmd
                        at split edge? -> `herdr pane focus --direction` (vim.system from nvim)
               no  -> pane focus --direction directly
```

## Trade-offs and open questions

- **Latency**: two socket round trips per keypress inside vim (~20ms total). tmux pays a comparable `ps` fork per keypress. Needs a feel test.
- **Key theft from other TUIs**: like the tmux original, non-vim TUIs (lazygit, pi, claude) lose direct `ctrl+h/j/k/l`, and shells lose `ctrl+l` (clear) / `ctrl+k` (kill-to-EOL) / `ctrl+h` (backspace). The foreground-process pattern can be widened to pass keys through to any chosen app; tmux's `prefix C-l -> send-keys C-l` clear-screen workaround has a direct analog as another `[[keys.command]]` popup/send-keys binding or just `prefix` fallback.
- **No wrap**: `pane focus --direction` stops at the screen edge instead of wrapping. Arguably nicer; vim-tmux-navigator ships `no_wrap` for exactly this.
- **Previous-pane toggle (`<C-\>`)**: no Herdr CLI verb for "focus last pane", only the `last_pane` keybinding action. Not portable 1:1; skip or wait for a `pane.focus_last` API.
- **Zoom behavior**: unverified how `pane focus --direction` interacts with a zoomed pane. tmux options `disable_when_zoomed` / `preserve_zoom` have no confirmed Herdr equivalent yet.
- **Copy mode**: Herdr copy mode is modal inside Herdr itself, so pane-switching bindings there are Herdr's concern, not the script's. (Herdr recently added pane switching in copy mode upstream.)
- **Detached shell command semantics**: `type = "shell"` runs via `/bin/sh -lc`; confirm the binding fully consumes the chord in all pane states and that detached spawn overhead stays low in practice.

## Prior art (GitHub survey, 2026-07-29)

Searched GitHub (API + web) and the Herdr marketplace topic (`topic:herdr-plugin`). This problem is already solved, twice, plus several smaller takes.

### paulbkim-dev/vim-herdr-navigation (58★)

An exact port of vim-tmux-navigator, and effectively identical to the design proposed above, with one improvement: the Herdr side is a proper Herdr plugin (`herdr-plugin.toml` with four `[[actions]]`) invoked via `type = "plugin_action"` keybindings instead of raw `type = "shell"` commands.

- **Herdr side** (`navigate.sh`): `herdr pane process-info --current` piped through `jq`, matching foreground process names against the vim-tmux-navigator regex (`^g?(view|l?n?vim?x?)(diff)?$`). Match: `pane send-keys $HERDR_PANE_ID ctrl+<key>`. No match: `pane focus --direction <dir> --current`. Degrades gracefully without `jq` (plain pane focus, no vim awareness). Opt-in passthrough for other TUIs via `HERDR_NAV_PASSTHROUGH_RE` (e.g. lazygit).
- **Editor side** (`editor/nvim.lua`, ~45 lines, plus `editor/vim.vim`): `wincmd`, compare `nvim_get_current_win()` before/after, at edge call `herdr pane focus --direction <dir> --current` via `vim.fn.system`. Falls back to tmux (`TmuxNavigate*` if `$TMUX` set) or plain `wincmd` outside Herdr, so tmux setups keep working.
- **Caveats**: normal-mode maps only (no terminal/insert mode); the repo is not a standard nvim plugin layout (`editor/nvim.lua`, no root `plugin/` dir), so `vim.pack` would clone it but load nothing. The README's own recommendation is to copy `editor/nvim.lua` into the config's plugin dir, which happens to fit the nvim-config convention (`nvim/plugin/herdr_nav.lua`) exactly.
- README documents the same trade-offs identified above: ctrl+l/ctrl+k shadowing in shells, ctrl+h vs backspace (fine on nvim ≥ 0.10 with kitty keyboard protocol), non-vim TUIs not crossing out at edges.

### lmilojevicc/herdr-splits.nvim (33★)

A port of smart-splits.nvim rather than vim-tmux-navigator. Richer feature set:

- Navigation plus **resizing** (`<M-h/j/k/l>`, delegating to `pane resize` at edges).
- `at_edge` behaviors: `wrap` (default), `stop`, `split`, or custom function; Herdr-pane wrap-around at layout edges.
- **Auto-unzoom** when navigating away from a zoomed pane (covers the zoom question left open above).
- Sidebar/float awareness (ignores neo-tree, snacks, quickfix, embedded floats), count prefixes (`3<C-h>`), health checks, test suite.
- Proper two-part install: `herdr plugin install lmilojevicc/herdr-splits.nvim` (Herdr side) + standard nvim plugin layout (`lua/` + `plugin/`), so it works with `vim.pack` directly. Requires a `setup()` call and generates a shared `herdr-splits.conf` so both sides agree on keys.
- Requires nvim ≥ 0.10, Herdr ≥ 0.7.0. Herdr keybindings are the same `[[keys.command]]` / `plugin_action` pattern.

### Smaller alternatives

- `willfish/herdr-navigator` (2★) + `willfish/herdr-navigator.nvim` (1★): same split as vim-herdr-navigation, as a two-repo pair.
- `bojackduy/nvim-herdr-navigation` (1★), `joo-was-already-taken/herdr-navigator.nvim` (0★), `AVGVSTVS96/vim-herdr-navigator` (0★): smaller/younger takes on the same idea.
- `shoaibkhanz/herdr-nav-plus` (1★): vim-aware ctrl+h/j/k/l that continues past panes into workspaces, wraps at both ends.
- `ycros/herdr-compass` (0★): unified directional navigation across panes, tabs, and workspaces (not vim-specific).

### Assessment

Building from scratch is unnecessary. Two credible options for this setup:

1. **vim-herdr-navigation**: minimal, faithful vim-tmux-navigator port; matches the proposed design one-for-one. Install = `herdr plugin install paulbkim-dev/vim-herdr-navigation`, four `[[keys.command]]` plugin_action bindings, copy `editor/nvim.lua` into `nvim/plugin/`. Least moving parts.
2. **herdr-splits.nvim**: more features (resize, wrap control, auto-unzoom, sidebar handling), proper vim.pack-compatible plugin, but a `setup()`-configured dependency with generated shared config. More capable, more machinery.

Either way, remove the direct `ctrl+h/j/k/l` chords from `focus_pane_*` in `config.toml` first.

## Implementation checklist (when building from scratch; superseded by prior art above)

1. `herdr-config/scripts/h-navigate` dispatch script with vim pattern check.
2. `herdr-config/config.toml`: four `[[keys.command]]` bindings; trim `focus_pane_*` to prefix-only chords; update the explanatory comment.
3. `nvim-config/nvim/plugin/herdr-navigator.lua`: wincmd-or-herdr mappings; remove `christoomey/vim-tmux-navigator` from `vim.pack.add` in `init.lua` (or keep it for tmux sessions since both plugins no-op outside their multiplexer).
4. Test: nvim splits at edges in all four directions, shell panes, fzf inside nvim terminal, zoomed panes, latency feel.
