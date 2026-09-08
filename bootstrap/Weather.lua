local mod, loadModule = ...
local M = {}

function M.install()
  loadModule("weather_main.lua", mod)
  return { exports = mod.exports }
end

return M
