-- Lightweight weather entry point. Upstream provenance is recorded in SOURCE_PROVENANCE.json.
-- Only the embedded weather bootstrap is allowed to run in this variant.
local mod = ...
local loadChunk = loadstring or load
local unpackArgs = table.unpack or unpack

-- Some host builds format `mod.log:*` messages inside src/core/Logger without
-- protecting string.format.  A diagnostic with a stale %d/%s argument then
-- crashes the Mod Manager before the mod has had a chance to report the real
-- problem.  Normalise every log call at the entry boundary: format locally,
-- reduce it to one safe %s argument for the host, and retain a plain-text
-- fallback for malformed third-party diagnostic calls.  This has to run before
-- any bootstrap module is loaded because content registration logs on boot.
local function installSafeLogger(target)
  local logger = target and target.log
  if type(logger) ~= "table" or logger._theWorldSafeFormat then return end
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    local original = logger[level]
    if type(original) == "function" then
      logger[level] = function(self, format, ...)
        local args = { n = select("#", ...), ... }
        local ok, message = pcall(string.format, tostring(format or ""), unpackArgs(args, 1, args.n))
        if not ok then
          local parts = { tostring(format or "") }
          for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
          message = table.concat(parts, " ")
        end
        -- Logging itself must never take the mod down. %s accepts the single
        -- already-formatted value on every Lua host this mod supports.
        pcall(original, self, "%s", message)
      end
    end
  end
  logger._theWorldSafeFormat = true
end

installSafeLogger(mod)

local function loadModule(path, ...)
  local source = mod:read(path)
  if not source then error("Weather: missing " .. tostring(path), 0) end
  local chunk, err = loadChunk(source, "@weather/" .. path)
  if not chunk then error("Weather: " .. tostring(err), 0) end
  return chunk(...)
end

local Weather = loadModule("bootstrap/Weather.lua", mod, loadModule)
local weatherHandle = Weather.install()

mod.exports.questLitePrivate = true
mod.exports.questLiteWorldSpace = true
mod.exports.directWorldCelestials = true
mod.exports.celestialRenderer = "NightSky.drawWorld+CelestialBodies.drawWorld"
mod.exports.compatibilityCelestialRecreation = false
mod.exports.questLiteScope = {
  "RAIN_LIGHT", "RAIN_HEAVY", "HEAVY_RAIN", "SNOW_LIGHT",
  "STRONG_WINDS", "GALE", "ASHFALL", "CLEAR",
}
mod.exports.weatherHandle = weatherHandle

-- Bundled weather-only adapter selection; not Quest transport.
loadModule('compat/Bootstrap.lua',mod)
