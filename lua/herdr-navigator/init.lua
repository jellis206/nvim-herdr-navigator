-- The nvim half of the vim-tmux-navigator pattern for herdr: navigate()
-- moves between vim windows and hands off to herdr when the move hits
-- the edge of vim's layout. The herdr half (herdr-plugin.toml + h-nav at
-- the repo root) passes the ctrl+h/j/k/l chords through to nvim when it
-- is the focused pane's foreground process.
local M = {}

M.config = {
  -- Path to the herdr binary used for the edge handoff.
  herdr_bin = "herdr",
  -- nil | "update" | "wall": write buffers before leaving vim.
  save_on_switch = nil,
}

--- Optional; only needed to override the defaults above. The default
--- mappings and user commands come from plugin/herdr-navigator.lua and
--- do not require calling setup().
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

local wincmds = {
  left = "h",
  down = "j",
  up = "k",
  right = "l",
}

--- Move to the vim window in `direction` ("left"|"down"|"up"|"right"),
--- or to the neighbouring herdr pane when already at vim's layout edge.
function M.navigate(direction)
  local wincmd = wincmds[direction]
  if not wincmd then
    error(("herdr-navigator: invalid direction %q"):format(direction))
  end

  local win = vim.api.nvim_get_current_win()
  vim.cmd.wincmd(wincmd)
  if vim.api.nvim_get_current_win() ~= win then
    return
  end

  -- At the edge: no vim window in that direction, ask herdr to move.
  if M.config.save_on_switch == "update" then
    vim.cmd.update()
  elseif M.config.save_on_switch == "wall" then
    vim.cmd.wall()
  end
  -- Async fire-and-forget: the focus change needs nothing from vim, and
  -- blocking on the CLI round-trip would stall the UI on every crossing.
  vim.system({ M.config.herdr_bin, "pane", "focus", "--direction", direction, "--current" })
end

return M
