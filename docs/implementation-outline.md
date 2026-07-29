# nvim-herdr-navigator — implementation outline

Seamless `ctrl+h/j/k/l` navigation between Neovim windows and [herdr](https://herdr.dev)
panes, mirroring [christoomey/vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator).

This document is the extraction plan for turning the working prototype
(currently living in `~/Dev/nvim-config` and `~/Dev/herdr-config`, July 2026)
into a standalone plugin. It records the reference architecture, every
herdr primitive the prototype validated, the proposed repo layout, and the
open questions.

---

## 1. The problem

Both the multiplexer and vim want to own `ctrl+h/j/k/l`:

- If herdr binds the chords directly (`focus_pane_left = "ctrl+h"`), vim
  never receives them — no in-vim window navigation.
- If herdr doesn't bind them, vim navigates its own windows but can never
  cross into a neighbouring herdr pane.

The solution (identical to vim-tmux-navigator) is a **two-sided handshake**:

1. The multiplexer owns the chords, but **passes them through** when the
   focused pane's foreground process is vim-like.
2. Vim owns the chords while focused, and **hands navigation back** to the
   multiplexer when a window move hits the edge of vim's layout.

## 2. Reference: how vim-tmux-navigator does it

Source: `plugin/tmux_navigator.vim` + `vim-tmux-navigator.tmux` (bash, run
by tpm).

### tmux side

- Binds `C-h/j/k/l` in the root table (`bind -n`) with a conditional:

  ```
  bind-key -n C-h if-shell "$is_vim" "send-keys C-h" "select-pane -L"
  ```

- `is_vim` greps the pane tty's foreground processes:

  ```
  ps -o state= -o comm= -t '#{pane_tty}' \
    | grep -iqE '^[^TXZ ]+ +(\S+/)?g?\.?(view|l?n?vim?x?|fzf)(diff)?(-wrapped)?$'
  ```

  The pattern matches `vi`, `vim`, `nvim`, `gvim`, `view`, `lvim`, … and
  `fzf` (so `C-j`/`C-k` keep moving fzf's selection). `[^TXZ ]` excludes
  stopped/zombie processes (a backgrounded, suspended vim must not
  capture the keys).

- Restores clear-screen as `prefix C-l` (`bind C-l send-keys 'C-l'`).
- Options: custom pattern (`@vim_navigator_pattern`), custom check
  command, `@tmux_navigator_disable_when_zoomed` (skips select-pane when
  `#{window_zoomed_flag}` is set).

### vim side

- Maps `<C-h/j/k/l>` (normal mode) to `:TmuxNavigate{Left,Down,Up,Right}`,
  plus `<C-\>` → `TmuxNavigatePrevious`.
- Outside tmux (`$TMUX` empty) the commands degrade to plain `wincmd`.
- Inside tmux, `s:TmuxAwareNavigate(direction)`:
  1. `let nr = winnr()`
  2. `wincmd h/j/k/l`
  3. `at_tab_page_edge = (nr == winnr())` — the move was a no-op, so vim
     was at its layout edge.
  4. If at edge: `tmux -S <socket> select-pane -t $TMUX_PANE -L/D/U/R`.
     Socket path is parsed from `$TMUX`.
- Also: `tnoremap` variants for terminal buffers (skipping `&ft == 'fzf'`),
  a netrw `<C-l>` workaround, `save_on_switch`, `preserve_zoom`, `no_wrap`
  (uses tmux `#{pane_at_left}` etc.), and "previous pane" bookkeeping
  (`s:tmux_is_last_pane` + a `WinEnter` autocmd).

## 3. Herdr primitives (validated July 2026, herdr ≥ 0.7.x)

Everything needed exists; each item below was tested live.

### Keybinding layer

- `[[keys.command]]` in `config.toml` binds a chord to an external
  command. `type = "shell"` runs it **detached** through `/bin/sh -lc`
  (Unix). Direct chords like `key = "ctrl+h"` are allowed (same syntax as
  action bindings).
- Custom commands receive env: `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`,
  `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`,
  `HERDR_ACTIVE_PANE_ID` (the UI-focused pane), `HERDR_ACTIVE_PANE_CWD`.
- Config reloads live via `herdr server reload-config` (returns
  `{"status":"applied","diagnostics":[]}`) or `prefix+shift+r`.

### Pane-process env (what nvim sees)

Processes inside herdr panes get: `HERDR_ENV=1`, `HERDR_PANE_ID`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_SOCKET_PATH`. Note: **no**
`HERDR_BIN_PATH` inside panes — resolve `herdr` from `$PATH` there.

### CLI (thin wrapper over the socket API)

| Need | Command |
| --- | --- |
| Foreground process detection | `herdr pane process-info [--pane ID\|--current]` |
| Move focus directionally | `herdr pane focus --direction left\|right\|up\|down [--pane ID\|--current]` |
| Pass a chord through | `herdr pane send-keys <pane_id> ctrl+h` (accepts herdr key-combo strings; validated) |
| Edge/zoom awareness | `herdr pane edges`, `herdr pane neighbor --direction X`, `herdr pane layout` (layout snapshot includes `zoomed`, pane rects) |

`pane process-info` output shape (observed):

```json
{"id":"cli:pane:process_info","result":{"process_info":{
  "foreground_process_group_id":61410,
  "foreground_processes":[{"argv":["nvim","."],"argv0":"nvim",
    "cmdline":"nvim .","cwd":"...","name":"nvim","pid":61410}],
  "pane_id":"wB:p35","shell_pid":61387},"type":"pane_process_info"}}
```

`--current` semantics (observed): from a shell whose `HERDR_PANE_ID` was
pane A while the UI focused pane B, `--current` resolved to **B** (the
UI-focused pane). For this plugin that distinction never matters: a
keypress in vim implies vim's pane is focused. Prefer passing an explicit
`--pane "$HERDR_ACTIVE_PANE_ID"` on the herdr side; `--current` is fine on
the vim side.

### Socket API (latency upgrade path)

Newline-delimited JSON-RPC over `$HERDR_SOCKET_PATH`:
`pane.process_info`, `pane.focus_direction`, `pane.send_keys`,
`pane.edges`, `pane.layout`. One connection could do check + act in a
single round-trip, skipping CLI process startup.

## 4. Prototype (working, to be extracted)

### Herdr half — `h-nav` script

Bound via four `[[keys.command]]` entries (`ctrl+h/j/k/l` →
`h-nav left/down/up/right`):

```sh
#!/bin/sh
set -eu

dir=$1
case $dir in
left) key=ctrl+h ;;
down) key=ctrl+j ;;
up) key=ctrl+k ;;
right) key=ctrl+l ;;
*) echo "usage: h-nav left|down|up|right" >&2; exit 2 ;;
esac

herdr=${HERDR_BIN_PATH:-herdr}
pane=${HERDR_ACTIVE_PANE_ID:?h-nav must run as a herdr custom command}

vim_pattern='"name":"g?\.?(view|l?n?vim?x?|fzf)(diff)?(-wrapped)?"'

if "$herdr" pane process-info --pane "$pane" | grep -qE "$vim_pattern"; then
	exec "$herdr" pane send-keys "$pane" "$key"
fi
exec "$herdr" pane focus --direction "$dir" --pane "$pane"
```

Notes:
- The grep runs over raw JSON and keys off `"name":"…"` only — simple and
  dependency-free (no jq). It matches **any** foreground process in the
  list, which mirrors tmux checking every process on the pane tty.
- Unlike tmux's `ps` check there is no process-state filter; a suspended
  (`ctrl+z`) vim may still capture the keys. See open questions.

Config additions (herdr `config.toml`):

```toml
[[keys.command]]
key = "ctrl+h"
type = "shell"
command = "$HOME/.config/herdr/scripts/h-nav left"
description = "focus pane left (vim-aware)"
# … same for ctrl+j/k/l with down/up/right …

# clear-screen parity, like vim-tmux-navigator's `bind C-l send-keys C-l`
[[keys.command]]
key = "prefix+ctrl+l"
type = "shell"
command = "\"$HERDR_BIN_PATH\" pane send-keys \"$HERDR_ACTIVE_PANE_ID\" ctrl+l"
description = "send ctrl+l (clear screen) to pane"
```

And the plain-action bindings keep only the prefix fallbacks
(`focus_pane_left = "prefix+h"`, etc.) — the `ctrl+*` chords must NOT
also appear there or the action binding would race the custom command.

### Vim half — `plugin/herdr_navigator.lua`

```lua
if vim.env.HERDR_ENV ~= "1" or vim.env.TMUX then
  return
end

local function navigate(wincmd, direction)
  local win = vim.api.nvim_get_current_win()
  vim.cmd.wincmd(wincmd)
  if vim.api.nvim_get_current_win() == win then
    vim.system({ "herdr", "pane", "focus", "--direction", direction, "--current" })
  end
end

for key, m in pairs({
  ["<C-h>"] = { "h", "left" },
  ["<C-j>"] = { "j", "down" },
  ["<C-k>"] = { "k", "up" },
  ["<C-l>"] = { "l", "right" },
}) do
  vim.keymap.set("n", key, function() navigate(m[1], m[2]) end,
    { silent = true, desc = "Go to window / herdr pane " .. m[2] })
end
```

Plus, in the user's `init.lua` *before* plugins load (coexistence with
vim-tmux-navigator):

```lua
if vim.env.HERDR_ENV == "1" and not vim.env.TMUX then
  vim.g.tmux_navigator_no_mappings = 1
end
```

## 5. Standalone plugin design

### Repo layout

```
nvim-herdr-navigator/
├── plugin/
│   └── herdr-navigator.lua       -- guard + default mappings + commands
├── lua/
│   └── herdr-navigator/
│       ├── init.lua              -- setup(opts), navigate(direction)
│       └── health.lua            -- :checkhealth herdr-navigator
├── herdr/
│   ├── h-nav                     -- the shell script (executable)
│   └── config-snippet.toml       -- copy-paste [[keys.command]] block
├── doc/
│   └── herdr-navigator.txt       -- vimdoc
├── docs/
│   └── implementation-outline.md -- this file
└── README.md
```

The `herdr/` directory is the analogue of `vim-tmux-navigator.tmux`
shipping in the vim plugin repo: one repo, both halves.

### Lua API

```lua
require("herdr-navigator").setup({
  mappings = true,            -- set default <C-h/j/k/l> (+ <C-\> later)
  herdr_bin = "herdr",        -- override binary path
  save_on_switch = nil,       -- nil | "update" | "wall"
  disable_when_zoomed = false,-- don't leave a zoomed herdr pane
  no_wrap = false,            -- if herdr wraps at edges (verify; see §7)
})
```

Design decisions:

- **Activation guard**: `plugin/herdr-navigator.lua` is a no-op unless
  `HERDR_ENV == "1"` and `TMUX` is unset (tmux-inside-herdr defers to
  vim-tmux-navigator, whose tmux side handles the inner boundary).
- **Set the no-clobber flag itself**: the plugin file can set
  `vim.g.tmux_navigator_no_mappings = 1` under its guard, but load order
  vs. vim-tmux-navigator's `plugin/` script is not guaranteed across
  plugin managers. Safer: define our mappings unconditionally *and*
  document setting the flag; last-writer-wins makes the outcome correct
  either way, the flag just removes the redundant work. Decide during
  extraction; test with lazy.nvim, vim.pack, and pckr load orders.
- **User commands** for parity and custom mappings:
  `:HerdrNavigateLeft/Down/Up/Right` (and later `Previous`).
- **Modes**: normal-mode mappings first. Terminal-mode (`tnoremap`)
  variants like vim-tmux-navigator's tmux branch, skipping `ft == "fzf"`
  buffers, as a fast follow.
- **Edge handoff** uses `vim.system` (async, non-blocking) — the CLI call
  fires and vim carries on; no UI stall.
- **health.lua** checks: `herdr` executable found; `HERDR_ENV` present;
  `herdr pane process-info --current` succeeds; warn if `$TMUX` is also
  set; optionally parse the user's herdr config for the `[[keys.command]]`
  bindings and warn if the direct chords are still bound to
  `focus_pane_*` actions.

### Herdr-half distribution

Users need the script + keybindings on the herdr side. Options:

1. **Manual (v1, matches tmux plugin ergonomics)**: README instructs
   copying `herdr/h-nav` somewhere stable (or referencing the plugin
   checkout path directly) and pasting `herdr/config-snippet.toml` into
   `config.toml`, then `herdr server reload-config`. Checkout paths from
   plugin managers are predictable (`~/.local/share/nvim/lazy/…`,
   `~/.local/share/nvim/site/pack/core/opt/…`) but manager-specific —
   document both, prefer "copy the script".
2. **Herdr plugin (now the plan)**: ship a `herdr-plugin.toml` so
   `herdr plugin link/install` registers navigation actions, and the
   keybindings become `type = "plugin_action"`. Validated in the wild by
   paulbkim-dev/vim-herdr-navigation — plugin actions do receive the
   focused pane as `HERDR_PANE_ID` and skip the `/bin/sh -lc` login
   shell. Details and what else to adopt from that project:
   `steal-from-vim-herdr-navigation.md`. Scope decision recorded there:
   this plugin is Neovim-only. The worked-out manifest, script changes,
   and dev workflow: `herdr-plugin-packaging.md`.

## 6. Feature parity checklist

| vim-tmux-navigator feature | herdr equivalent | status |
| --- | --- | --- |
| `C-h/j/k/l` both directions | `h-nav` + edge handoff | done (prototype) |
| vim-side pass-through detection (`is_vim`) | `pane process-info` name grep | done |
| fzf pass-through | included in pattern | done |
| `prefix C-l` clear-screen restore | `prefix+ctrl+l` custom command | done |
| `C-\` previous pane | herdr has a `last_pane` *keybinding action*; no CLI/socket verb found yet | open — see §7 |
| terminal-mode (`tnoremap`) mappings | same technique | todo |
| `save_on_switch` | trivial (`update`/`wall` before handoff) | todo |
| `disable_when_zoomed` / `preserve_zoom` | `pane layout` snapshot has `zoomed`; `pane zoom --on/--off/toggle` | todo |
| `no_wrap` | `pane edges` reports layout edges | todo (see §7) |
| custom `is_vim` pattern | option piped into `h-nav` (env var or arg) | todo |
| netrw `<C-l>` workaround | same problem exists; copy approach | todo |

## 7. Open questions / things to verify during extraction

1. **Does `pane focus --direction` wrap at screen edges?** If it stops
   (tmux-like default), `no_wrap` is free. If it wraps, implement
   `no_wrap` via `pane edges` before focusing.
2. **Previous-pane (`C-\`)**: is `last_pane` reachable via CLI/socket?
   If not, request upstream or emulate with a `WinEnter`-style history in
   the vim half (only covers vim-internal history, not cross-pane).
3. **Suspended vim**: `process-info` has no process-state field in the
   observed output. If a `ctrl+z`-suspended vim still appears in
   `foreground_processes`, keys would be wrongly passed through. Check
   whether herdr reports the *current* foreground group (suspended vim
   should drop out of it — likely fine, verify).
4. **Latency budget**: `type = "shell"` runs `/bin/sh -lc` (login shell)
   plus 1–2 CLI invocations per keypress (~tens of ms, felt fine in the
   prototype). If it ever matters: talk to `$HERDR_SOCKET_PATH` directly
   (one connection, two requests), or propose a native conditional
   binding upstream (herdr-side `if-foreground-matches` would eliminate
   the script entirely — the cleanest possible end state; see
   `upstream-passthrough-investigation.md` for the full plan).
5. **Load-order vs vim-tmux-navigator** across plugin managers (see §5).
6. **`HERDR_ACTIVE_PANE_ID` freshness**: custom commands receive the
   focused pane at keypress time — confirm there's no race when focus
   changes rapidly (e.g. held-down key auto-repeat crossing panes).
7. **Herdr plugin packaging** (§5 option 2): action invocation context +
   per-keypress latency.
8. **Remote sessions** (`herdr --remote`): confirm the socket/CLI is
   available where nvim runs (if nvim runs on the remote host, the herdr
   server may not be local). Possibly gate on `HERDR_SOCKET_PATH`
   existing.

## 8. Testing plan

- **Unit-ish (headless nvim)**: assert mappings exist iff
  `HERDR_ENV=1 && !TMUX`; assert `vim.g.tmux_navigator_no_mappings`
  interplay; assert edge detection calls `vim.system` with the right args
  (inject a fake `herdr_bin` capturing argv).
- **Script tests**: run `h-nav` against a scratch herdr workspace
  (`herdr workspace create --label test --no-focus`), with
  `HERDR_ACTIVE_PANE_ID` pointed at the scratch pane: shell pane → focus
  branch; `nvim` running in the pane → send-keys branch; bad args → exit 2.
  Clean up with `herdr workspace close`.
- **Manual matrix**: vim splits inside a pane grid — all four directions,
  both boundary crossings; fzf popup inside a shell pane (`ctrl+j/k` move
  the fzf list); fzf inside nvim; insert-mode `ctrl+h` still backspaces;
  zoomed pane; single-pane tab (keys should reach the shell? no — they
  run h-nav and no-op; acceptable, same as tmux); tmux session nested in
  a herdr pane (vim-tmux-navigator must win).

## 9. Prototype source locations (for extraction)

- `~/Dev/nvim-config/nvim/plugin/herdr_navigator.lua` — vim half
- `~/Dev/nvim-config/nvim/init.lua` — `tmux_navigator_no_mappings` guard
  (top of file)
- `~/Dev/herdr-config/scripts/h-nav` — herdr half
- `~/Dev/herdr-config/config.toml` — `[[keys.command]]` bindings +
  reduced `focus_pane_*` entries (search "vim-tmux-navigator")
