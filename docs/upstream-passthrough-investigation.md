# Investigation: native pass-through keybindings in herdr (upstream fix)

Status: **to investigate** — goal is to dig into the herdr source and
propose an upstream feature that makes the `h-nav` shell script (and the
herdr-side install step of this plugin) unnecessary.

Herdr repo: <https://github.com/ogulcancelik/herdr> (Rust, open source,
`CONTRIBUTING.md` present). Source references below were checked against
commit `73d9200` (2026-07-29). A shallow clone lives in
`~/.claude/skills/herdr-docs/vendor/herdr`; make a fresh full clone for
actual development.

## 1. The feature in one sentence

A direct keybinding that herdr forwards to the pane instead of executing
when the focused pane's foreground process matches a pattern — tmux's

```
bind -n C-h if-shell "$is_vim" "send-keys C-h" "select-pane -L"
```

as a first-class, declarative config concept instead of an external
script.

## 2. Why native beats the script

The current workaround (see `implementation-outline.md` §4) binds
`ctrl+h/j/k/l` to a `type = "shell"` custom command that spawns
`/bin/sh -lc` plus 1–2 `herdr` CLI invocations **per keypress**, doing a
full socket round-trip to ask herdr something herdr already knows. Native
support would mean:

- zero per-keypress process spawns; the check is an in-process string
  match,
- no race between "focused pane at keypress time" and "focused pane when
  the detached script runs",
- no script to install and maintain on the herdr side — the nvim plugin's README
  shrinks to one config snippet,
- the same mechanism serves every editor/tool that wants chord
  pass-through (helix, kakoune, emacs `windmove`, fzf, lazygit…), not
  just this plugin.

Key enabler found in the source: **herdr already inspects pane foreground
processes** for agent detection — `src/pane/terminal.rs:998` calls
`crate::detect::foreground_job(shell_pid)` on output events, and the
socket API exposes the same data as `pane.process_info`
(`src/api/schema/panes.rs`). The infrastructure exists; the feature is
"consult it during key dispatch".

## 3. Where the change goes (source map)

### Key dispatch — the interception point

`src/app/input/terminal.rs`, `fn prepare_terminal_key_forward`
(~line 63). Current direct-chord dispatch order for a key headed to a
pane:

1. `super::terminal_direct_non_indexed_navigation_action(&self.state, key)`
   — direct **action** bindings (`focus_pane_left = "ctrl+h"` style);
   logs "intercepted terminal direct keybinding before forwarding to
   pane".
2. `super::navigate::command_for_key(&state, key, BindingDispatch::Direct)`
   (`src/app/input/navigate.rs:1137`) — direct **custom command**
   bindings (`[[keys.command]]`).
3. `terminal_direct_indexed_navigation_action` — indexed (`alt+1..9`).
4. Prefix-key check → `Mode::Prefix`.
5. Otherwise the key is forwarded to the pane.

The pass-through check belongs at the top of steps 1–2: *if this key has
a pass-through rule and the focused pane's foreground matches, skip
interception and fall through to normal pane forwarding (step 5).* Falling
through (rather than synthesizing a `send-keys`) reuses the existing
encode/forward path (`src/input/encode.rs`), so kitty-keyboard-protocol
panes and bracketed modes keep working for free.

### Config model

- `src/config/keybinds.rs` — `ActionKeybinds` (line ~204 has
  `matches_direct_key`), the big keybinds struct (`focus_pane_left` at
  line ~337), `CustomCommandKeybind` (line ~284),
  `append_custom_command_bindings` (line ~721), and an extensive test
  module at the bottom (conflict detection, unsafe-binding rejection —
  new syntax needs tests alongside e.g.
  `direct_custom_binding_conflicting_with_builtin_is_disabled`).
- `src/config/model.rs` — TOML-facing config structs.
- Validation/diagnostics style: keybinds parsing already emits config
  diagnostics (surfaced by `herdr server reload-config`); an invalid
  pass-through regex should produce one, not a hard error.

### Foreground process lookup

- `src/detect/mod.rs` — `foreground_job(shell_pid)`; used today by agent
  detection in `src/pane/terminal.rs` (~998, ~1110).
- `src/platform/{macos,linux,windows,fallback}.rs` —
  `foreground_job`, `foreground_process_group_id`,
  `foreground_group_leader_job`. Fallback platform returns `None` —
  pass-through must degrade gracefully (no match → binding executes
  normally, i.e. behaves like today).
- `src/api/schema/panes.rs` / `src/app/api.rs` — the `pane.process_info`
  response, useful as the reference for what "foreground process name"
  means here.

### Docs to update with the PR

`website/src/content/docs/configuration.mdx` (keybindings + custom
commands sections) and `config-reference.mdx`; possibly `keyboard.mdx`
("going prefix-free" section is where users will look for this).

## 4. Config syntax proposals (pick one after reading maintainer taste)

**Option A — per-binding table (most explicit, most verbose):**

```toml
[keys]
focus_pane_left = [
  "prefix+h",
  { key = "ctrl+h", passthrough_process = '^g?\.?(view|l?n?vim?x?|fzf)(diff)?(-wrapped)?$' },
]
```

Touches the `ActionKeybinds` parser for every action; mixed
string/table arrays in TOML are valid but the parser currently expects
strings.

**Option B — separate rule table keyed by chord (least invasive, recommended starting point):**

```toml
# When the focused pane's foreground process matches, these direct chords
# are forwarded to the pane instead of triggering their herdr binding.
[[keys.passthrough]]
keys = ["ctrl+h", "ctrl+j", "ctrl+k", "ctrl+l"]
process = '^g?\.?(view|l?n?vim?x?|fzf)(diff)?(-wrapped)?$'
```

One new struct + one check at the dispatch point; no changes to existing
binding parsing. Multiple rules compose (different chords for different
programs). This shape also naturally extends later (`agent = "claude"`,
`alt_screen = true`, … predicates) without breaking the schema.

**Option C — generalized conditional custom commands** (`when` clauses on
`[[keys.command]]`, tmux-`if-shell`-general). Most powerful, biggest
surface area; probably over-engineering for the first PR — mention as
future work in the issue instead.

Predicate semantics to specify in the proposal, mirroring what the
prototype validated:

- match against each entry of the pane's foreground process list by
  `name` (basename), case-insensitively; any match wins,
- exclude stopped processes if the platform layer can report state
  (tmux's `[^TXZ]` guard; check what `foreground_job` returns for a
  `ctrl+z`-suspended vim),
- evaluated only for **direct** chords on terminal-mode keys; prefix
  mode, copy mode, navigate mode, popups unaffected.

## 5. Investigation checklist (order of attack)

1. **Read `CONTRIBUTING.md` + open issues/discussions** — search for
   "vim", "navigator", "passthrough", "conditional keybinding". Someone
   may have asked; the maintainer may have a preferred shape. Open a
   design issue *before* writing the PR.
2. **Trace the dispatch path end-to-end**: set
   `HERDR_LOG=debug`, press a bound direct chord, follow the
   "intercepted terminal direct keybinding" log line
   (`src/app/input/terminal.rs:~84`) to confirm the exact interception
   site and what "fall through to forward" requires there (the function
   returns `Option<PreparedPaneInput>` — pass-through means *continuing*
   the function, not returning `None`).
3. **Latency/cost of `foreground_job` per keypress**: it walks the
   process table on some platforms. Agent detection already calls it on
   output events, so cost data may exist. Options if too slow on hot
   path: (a) accept it — key repeat is ~30 Hz worst case; (b) cache the
   last foreground name on the pane (agent detection may already keep
   equivalent state in `src/pane/agent_detection.rs` — check what it
   stores and whether it's fresh enough); (c) memoize per
   foreground-process-group-id.
4. **Suspended-process semantics**: run vim, `ctrl+z`, inspect what
   `foreground_job`/`pane.process_info` report. Decide whether the
   predicate needs a state filter or whether the OS-level foreground
   group already excludes stopped jobs (it should — that's what
   "foreground process group" means — but verify on macOS + Linux).
5. **Windows/fallback**: confirm graceful no-match behavior where
   foreground info is unavailable.
6. **Regex flavor**: herdr is Rust — the `regex` crate (no lookarounds).
   The vim-tmux-navigator pattern ports cleanly; document the flavor in
   config docs.
7. **Write the feature** behind config parsing + dispatch check + tests:
   - keybinds parsing tests next to the existing ones in
     `src/config/keybinds.rs` (valid rule, invalid regex → diagnostic,
     conflict with builtin bindings),
   - dispatch tests next to
     `direct_custom_command_runs_before_forwarding_to_pane`
     (`src/app/input/terminal.rs:~1340`) — they show the harness for
     fake panes + key injection; add "matching foreground forwards to
     pane", "non-matching executes binding".
8. **Update this plugin** once merged: health check detects native
   support (version gate or config probe), README recommends the native
   snippet, `h-nav` stays as the fallback for older herdr.

## 6. The pitch to upstream (issue skeleton)

- Problem: prefix-free pane navigation (`ctrl+h/j/k/l`) conflicts with
  editors; the docs currently steer users to `ctrl+alt` chords
  (`keyboard.mdx` "going prefix-free") precisely because of this.
- Ecosystem precedent: vim-tmux-navigator (tmux `if-shell` +
  `send-keys`) is one of the most-installed tmux plugins; WezTerm/kitty
  achieve the same with user-space callbacks; Zellij punts via a
  "locked" mode toggle. A declarative predicate is herdr's chance to do
  it better than all of them.
- Herdr already has the data (agent detection + `pane.process_info`);
  the feature is ~a config struct + one check in
  `prepare_terminal_key_forward`.
- Working userland prototype exists (this plugin) proving demand and the
  exact semantics; offer the PR.
