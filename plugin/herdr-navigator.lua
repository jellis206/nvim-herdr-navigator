-- Seamless vim <-> herdr pane navigation: default mappings and user
-- commands for the nvim half. See lua/herdr-navigator/init.lua for the
-- navigation logic and :h herdr-navigator for the full story.
if vim.g.loaded_herdr_navigator then
  return
end
vim.g.loaded_herdr_navigator = 1

-- No-op outside herdr. tmux inside a herdr pane is not supported: herdr
-- owns the chords and does not pass them through to tmux.
if vim.env.HERDR_ENV ~= "1" then
  return
end

-- Plugin arbitration, not tmux support: vim-tmux-navigator maps the same
-- chords even outside tmux (degrading to plain wincmd, which would break
-- the edge handoff). If it loads after us, this flag stops it mapping;
-- if it loaded first, our mappings below overwrite its. Either order,
-- the right plugin owns the chords per environment.
if vim.g.tmux_navigator_no_mappings == nil then
  vim.g.tmux_navigator_no_mappings = 1
end

for name, key in pairs({
  Left = "<C-h>",
  Down = "<C-j>",
  Up = "<C-k>",
  Right = "<C-l>",
}) do
  local direction = name:lower()
  local desc = "Go to window / herdr pane " .. direction
  local function navigate()
    require("herdr-navigator").navigate(direction)
  end

  vim.api.nvim_create_user_command("HerdrNavigate" .. name, navigate, {
    desc = desc,
  })

  if not vim.g.herdr_navigator_no_mappings then
    vim.keymap.set("n", key, navigate, {
      silent = true,
      desc = desc,
    })
  end
end
