-- Seamless vim <-> herdr pane navigation: default mappings and user
-- commands for the nvim half. See lua/herdr-navigator/init.lua for the
-- navigation logic and :h herdr-navigator for the full story.
if vim.g.loaded_herdr_navigator then
  return
end
vim.g.loaded_herdr_navigator = 1

-- No-op outside herdr. Inside tmux (even nested in a herdr pane) defer
-- to vim-tmux-navigator, whose tmux side handles the inner boundary.
if vim.env.HERDR_ENV ~= "1" or vim.env.TMUX then
  return
end

-- Ask vim-tmux-navigator not to claim the chords too. Only effective
-- when this file loads before it — see the coexistence recipe in the
-- README for the load-order-proof version.
if vim.g.tmux_navigator_no_mappings == nil then
  vim.g.tmux_navigator_no_mappings = 1
end

for name, direction in pairs({
  Left = "left",
  Down = "down",
  Up = "up",
  Right = "right",
}) do
  vim.api.nvim_create_user_command("HerdrNavigate" .. name, function()
    require("herdr-navigator").navigate(direction)
  end, { desc = "Go to window / herdr pane " .. direction })
end

if vim.g.herdr_navigator_no_mappings then
  return
end

for key, direction in pairs({
  ["<C-h>"] = "left",
  ["<C-j>"] = "down",
  ["<C-k>"] = "up",
  ["<C-l>"] = "right",
}) do
  vim.keymap.set("n", key, function()
    require("herdr-navigator").navigate(direction)
  end, { silent = true, desc = "Go to window / herdr pane " .. direction })
end
