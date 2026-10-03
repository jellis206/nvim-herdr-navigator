local M = {}

function M.check()
  vim.health.start("herdr-navigator")

  local active = vim.env.HERDR_ENV == "1"

  if active then
    vim.health.ok("HERDR_ENV=1 — running inside a herdr pane")
  else
    vim.health.warn(
      "HERDR_ENV is not '1' — not inside herdr, plugin is inactive",
      { "Start nvim inside a herdr pane to activate the mappings and commands." }
    )
  end

  if vim.env.TMUX then
    vim.health.warn(
      "$TMUX is set — tmux inside a herdr pane is not supported",
      { "herdr owns the ctrl+h/j/k/l chords and does not pass them through to tmux; navigation will not work as expected." }
    )
  end

  local bin = require("herdr-navigator").config.herdr_bin
  if vim.fn.executable(bin) == 1 then
    vim.health.ok(("herdr binary found: `%s`"):format(bin))
  else
    vim.health.error(
      ("herdr binary not executable: `%s`"):format(bin),
      { "Install herdr or point herdr_bin at it: require('herdr-navigator').setup({ herdr_bin = '/path/to/herdr' })" }
    )
    return
  end

  if not active then
    return
  end

  -- This probe checks server reachability, not actions or runtime dependencies.
  local ok, res = pcall(function()
    return vim.system({ bin, "pane", "process-info", "--current" }, { text = true }):wait(2000)
  end)
  if ok and res and res.code == 0 then
    vim.health.ok("`herdr pane process-info --current` succeeded. The herdr server is reachable.")
  else
    local detail = ok and res and (res.stderr or res.stdout or "") or tostring(res)
    vim.health.error(
      "`herdr pane process-info --current` failed",
      { vim.trim(detail) ~= "" and vim.trim(detail) or "No output; is the herdr server reachable from this pane?" }
    )
  end
end

return M
