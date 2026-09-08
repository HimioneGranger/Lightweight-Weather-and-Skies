-- WeatherCompanionBridge
--
-- In-memory integration with Kanto Companion Mobile. Weather FX owns the
-- provider and never edits the companion on disk. If the companion exposes a
-- weather-provider registration point, this module registers the stable
-- WeatherEncounterAPI there. Older companion builds can still consume the
-- same data through Weather FX's public exports.

local V = ...
local mod = V.mod
local API = V.require("WeatherEncounterAPI")

local Bridge = { installed = false, accepted = false, companionId = nil }
local IDS = {
  "Kanto-Companion-Mobile", "KANTO_COMPANION_MOBILE",
  "Kanto Companion", "KANTO_COMPANION", "kanto_companion",
}

local function findCompanion()
  if not (mod and mod.find) then return nil, nil end
  for _, id in ipairs(IDS) do
    local ok, h = pcall(mod.find, mod, id)
    if ok and h then return h, id end
  end
  return nil, nil
end

local function tryRegister(target, fnName, provider)
  if type(target) ~= "table" or type(target[fnName]) ~= "function" then return false end
  local ok, result = pcall(target[fnName], target, provider)
  return ok and result ~= false
end

function Bridge.install()
  if Bridge.installed then return Bridge.accepted end
  Bridge.installed = true
  local companion, id = findCompanion()
  if not companion then return false end
  Bridge.companionId = id
  local provider = API.public()
  local accepted = false

  local exports = companion.exports
  local lib = exports and exports.lib
  for _, target in ipairs({ exports, lib }) do
    if not accepted then accepted = tryRegister(target, "registerWeatherProvider", provider) end
    if not accepted then accepted = tryRegister(target, "setWeatherProvider", provider) end
    if not accepted then accepted = tryRegister(target, "registerWeatherEncounterProvider", provider) end
  end

  Bridge.accepted = accepted
  return accepted
end

function Bridge.status()
  return {
    installed = Bridge.installed,
    companion = Bridge.companionId,
    accepted = Bridge.accepted,
  }
end

return Bridge
