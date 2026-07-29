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
