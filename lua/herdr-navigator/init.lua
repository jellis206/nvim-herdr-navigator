-- The nvim half of the vim-tmux-navigator pattern for herdr: navigate()
-- moves between Neovim windows, then calls the same navigation action
-- via the CLI at the layout edge. The herdr half (herdr-plugin.toml +
-- h-nav at the repo root) forwards keybinding chords to Neovim or fzf.
-- CLI invocations skip key forwarding and focus a herdr pane.
local M = {}

M.config = {
  -- Path to the herdr binary used to call the action at the layout edge.
  herdr_bin = "herdr",
  -- nil | "update" | "wall": write buffers before leaving vim.
  save_on_switch = nil,
}

--- Optional; only needed to override the defaults above. The default
--- mappings and user commands come from plugin/herdr-navigator.lua and
--- do not require calling setup().
function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
end

-- Notify about a broken herdr_bin once per session, not on every crossing.
local spawn_failure_notified = false

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

  -- At the edge: call the same action via the CLI after the optional save.
  -- Herdr supplies invocation_source="cli", so h-nav cannot forward the key.
  if M.config.save_on_switch == "update" then
    vim.cmd.update()
  elseif M.config.save_on_switch == "wall" then
    vim.cmd.wall()
  end
  -- Async: do not wait for the CLI round-trip or stall Neovim's UI.
  -- Action invocation acknowledges startup, not the completed focus change.
  -- pcall reports spawn failures only. Action errors appear in plugin logs.
  local ok, err = pcall(vim.system, { M.config.herdr_bin, "plugin", "action", "invoke", "herdr-navigator." .. direction })
  if not ok and not spawn_failure_notified then
    spawn_failure_notified = true
    vim.notify(
      ("herdr-navigator: could not run %q (%s) — see :checkhealth herdr-navigator"):format(M.config.herdr_bin, err),
      vim.log.levels.ERROR
    )
  end
end

return M
