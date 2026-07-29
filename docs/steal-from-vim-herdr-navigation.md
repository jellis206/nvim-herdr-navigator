# Things to adopt from paulbkim-dev/vim-herdr-navigation

Source: <https://github.com/paulbkim-dev/vim-herdr-navigation>
(reviewed at the 2026-06-28 merge commit; MIT licensed — attribute if any
code is lifted verbatim). It solves the same problem with the same
vim-tmux-navigator handshake; this doc lists what it does better and
should be folded into this plugin. Scope decision: **this plugin is
Neovim-only** — their `editor/vim.vim` support is explicitly out.

Their weaknesses are listed at the end so we don't accidentally copy
them.

## 1. Package the herdr half as a herdr plugin (replaces outline §5 "option 2 — to evaluate")

Their repo **validates** the herdr-plugin distribution path end to end,
so it stops being an open question and becomes the plan:

- Ship a `herdr-plugin.toml` at the repo root with one action per
  direction:

  ```toml
  id = "herdr-navigator"
  name = "Herdr Navigator"
  version = "0.1.0"
  min_herdr_version = "0.7.0"
  description = "Seamless ctrl+h/j/k/l across herdr panes and Neovim splits"
  platforms = ["linux", "macos"]

  [[actions]]
  id = "left"
  title = "Navigate left (nvim/herdr)"
  contexts = ["global"]
  command = ["sh", "h-nav", "left"]
  # … down / up / right …
  ```

- Users install with `herdr plugin link <checkout>` (or
  `herdr plugin install <repo>` once published) and bind:

  ```toml
  [[keys.command]]
  key = "ctrl+h"
  type = "plugin_action"
  command = "herdr-navigator.left"
  description = "navigate left (nvim/herdr)"
  ```

Why this beats our current `type = "shell"` custom command:

- **No login shell per keypress.** Plugin actions exec the argv directly
  (`["sh", "h-nav", "left"]`); our `type = "shell"` binding goes through
  `/bin/sh -lc`, paying profile sourcing on every press.
- **No absolute script path** baked into the user's `config.toml`; the
  plugin root is resolved by herdr.
- Versioning + `min_herdr_version` gating + `herdr plugin action list`
  discoverability.

Verified facts to rely on (docs `plugins.mdx`): action commands receive
`HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`,
`HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_ACTION_ID`,
`HERDR_PLUGIN_CONTEXT_JSON`, and *any available* `HERDR_WORKSPACE_ID`,
`HERDR_TAB_ID`, `HERDR_PANE_ID` (the invocation-context/focused pane).
Note the var name differs from custom commands: plugin actions get
`HERDR_PANE_ID`, custom shell commands get `HERDR_ACTIVE_PANE_ID` —
`h-nav` should accept either:

```sh
pane=${HERDR_PANE_ID:-${HERDR_ACTIVE_PANE_ID:?}}
```

Keep the raw `[[keys.command]] type = "shell"` recipe in the README as
the no-install fallback; it's what the prototype proved.

## 2. User-configurable pass-through pattern

Their `HERDR_NAV_PASSTHROUGH_RE` env var (regex over lower-cased
foreground process names) lets users forward the chords to *other* TUIs
that own `ctrl+h/j/k/l` — lazygit, k9s, vi-sql. Adopt the capability,
improve the plumbing:

- default pattern stays the full vim-tmux-navigator one **including
  fzf** (their default drops fzf — do not copy that),
- an *additional* user pattern is OR-ed in, not a replacement, so users
  extending it can't accidentally break vim detection,
- expose it both as an env var read by `h-nav` (works with any binding
  style, their approach) and as a documented option; matching is
  case-insensitive on the process basename, anchored `^…$`.

## 3. Case-insensitive, anchored process matching

Their jq matcher lowercases the name and anchors the regex. Our grep is
case-sensitive. Cheap fix: `grep -iqE`. Keep the quote-delimited
`"name":"…"` pattern trick so we stay dependency-free — do **not** adopt
their hard jq dependency (their script silently loses vim-awareness when
jq is missing). Optional middle ground: use jq when present, fall back
to grep.

## 4. Document the `Ctrl+H` / Backspace 0x08 nuance

From their README, worth stealing verbatim into ours: `ctrl+h` and
Backspace share byte `0x08` in legacy terminal encoding, so pass-through
only distinguishes them when the kitty keyboard protocol is active.
Neovim ≥ 0.10 negotiates it automatically inside herdr panes, keeping
`<C-h>` distinct from `<BS>`. Add to README "requirements/notes"
(Neovim ≥ 0.10 recommended) and to the health check if the protocol
state is queryable.

## 5. Runtime tmux chaining in the nvim mapping (adapt, nvim-only)

Their single mapping handles all three environments at runtime: wincmd
first; at the edge, herdr if `HERDR_PANE_ID` is set, else
`:TmuxNavigate<Dir>` if `$TMUX` is set, else no-op. Ours instead guards
at load time and defers to vim-tmux-navigator inside tmux.

Steal the *idea* as an option, not the default:

```lua
require("herdr-navigator").setup({
  tmux_fallback = true,  -- at a window edge outside herdr, call
                         -- :TmuxNavigate* when $TMUX is set (needs
                         -- vim-tmux-navigator); default false
})
```

Default stays "only active inside herdr" — simplest, no cross-plugin
coupling. With `tmux_fallback`, users who want one plugin owning the
keys everywhere can have it. Wrap the tmux call in `pcall` like they do
(command may not exist).

Also steal their **lazy.nvim coexistence recipe** for the README — the
`init = function() vim.g.tmux_navigator_no_mappings = 1 end` spec
pattern is clearer than prose, and load-order via `after/plugin` or
manager config is exactly the §5 open question answered in practice.

## 6. README structure

Theirs is a good skeleton to mirror: what it is in two sentences → "How
it works" (two cooperating sides, ~6 lines) → requirements →
install (herdr side, then editor side) → "Notes & tradeoffs" that
honestly lists the shadowed readline keys, the 0x08 caveat, and
normal-mode-only scope. Add our extras: the `prefix+ctrl+l`
clear-screen restore and the health check.

## Explicitly NOT stealing

- **`editor/vim.vim`** — Neovim-only by decision.
- **Blocking `vim.fn.system()`** in the mapping — keep async
  `vim.system()`; theirs freezes the editor for the CLI round-trip at
  every edge crossing.
- **fzf-less default pattern** — keep fzf in the default matcher so
  `ctrl+j/k` keep working in bare-fzf panes without user config.
- **Mixed pane targeting** — theirs resolves the pane via `--current`
  for `process-info` but `$HERDR_PANE_ID` for `send-keys`; keep our
  single explicit `--pane "$pane"` for both check and act.
- **Hard jq dependency** (see §3).
- **No clear-screen restore** — keep our `prefix+ctrl+l` binding in the
  shipped config snippet.

## Follow-up worth considering

Their plugin predates ours publicly. Before publishing, decide: publish
this as a separate (nvim-only, more robust) plugin, or PR the fixes
(async handoff, fzf pattern, consistent targeting, jq-optional parsing)
into theirs. Either way, the upstream herdr native-passthrough work
(`upstream-passthrough-investigation.md`) is unaffected and benefits
both.
