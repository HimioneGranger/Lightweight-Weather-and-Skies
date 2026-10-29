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
local GEN3LAB_ENTRY = ({[1] = "compat/gen1/HostAlias.lua", [3] = "compat/gen3/Gen3Compat.lua"})[mod.generation]; if GEN3LAB_ENTRY then local ok, err = pcall(loadModule, GEN3LAB_ENTRY, mod, loadModule); if not ok then mod.log:warn("gen%s compat not loaded: %s", tostring(mod.generation), tostring(err)) end end

-- Lab 52: per-frame batching of the weather updates (exports.setFrameOnce; default OFF). Loaded before the weather
-- bootstrap so every input.step link can register its stage; Gen 3 has already loaded it from Gen3Tick.
local okFrameOnce, FrameOnce = pcall(loadModule, "compat/FrameOnce.lua", mod)
if not okFrameOnce then FrameOnce = nil end

local Weather = loadModule("bootstrap/Weather.lua", mod, loadModule)
local weatherHandle = Weather.install()

mod.exports.questLitePrivate = true
mod.exports.questLiteWorldSpace = true
mod.exports.directWorldCelestials = true
mod.exports.celestialRenderer = "NightSky.drawWorld+CelestialBodies.drawWorld"
pcall(function() mod.exports.lib.require('Settings').lwsSkyEnabled() end)
mod.exports.compatibilityCelestialRecreation = false
mod.exports.questLiteScope = {
  "RAIN_LIGHT", "RAIN_HEAVY", "HEAVY_RAIN", "SNOW_LIGHT",
  "STRONG_WINDS", "GALE", "ASHFALL", "CLEAR",
}
mod.exports.weatherHandle = weatherHandle

-- Runtime-only performance switches (never saved, never touch the user's
-- weather settings). Game-neutral: any host may call them. The state table is
-- shared with the render files through mod.exports.questPerf.
--   setFrameHoist(on): true = allocation-free per-eye sky/cloud passes
--     (default), anything else = the original per-eye code.
--   setQuestWeatherTier(tier): "off" | "lite" | "full" (default "full").
--     off  = no sky-deck clouds or atmosphere extras; precipitation and the
--            day/night grade are kept.
--     lite = cheaper per-eye weather passes.
--     full = the complete look.
do
  local perf = mod.exports.questPerf
  if type(perf) ~= "table" then perf = { hoist = true, tier = "full" }; mod.exports.questPerf = perf end
  if perf.hoist == nil then perf.hoist = true end
  if perf.tier == nil then perf.tier = "full" end
  mod.exports.setFrameHoist = function(on) perf.hoist = on == true; return perf.hoist end
  mod.exports.frameHoist = function() return perf.hoist end
  -- setFrameOnce(on): true = per-frame weather/sky setup and per-frame (not per-tick) weather, cloud-deck, lightning and
  --   atmosphere updates; the host must call frameBegin() once per rendered frame before the frame reads weather state
  --   (without it the updates fall back to per tick after 3 ticks). Default false = the original per-tick, per-eye code.
  -- frameBegin(): the per-frame host signal (runs the pending updates, then opens a new frame). No-op while the switch is off.
  -- flushPending(): run any pending batched updates now (map change, invalidate; the switch-off path does this itself).
  if perf.frameOnce == nil then perf.frameOnce = false end
  mod.exports.setFrameOnce = function(on)
    if FrameOnce then return FrameOnce.setOn(on == true) end
    perf.frameOnce = on == true; return perf.frameOnce
  end
  mod.exports.frameOnce = function() return perf.frameOnce == true end
  mod.exports.frameBegin = function() if FrameOnce then return FrameOnce.frameBegin() end return false end
  mod.exports.flushPending = function() if FrameOnce then return FrameOnce.flush() end return 0 end
  mod.exports.frameOnceStatus = function() if FrameOnce then return FrameOnce.status() end return { on = perf.frameOnce == true } end
  mod.exports.setQuestWeatherTier = function(tier)
    if type(tier) == "string" then
      tier = tier:lower()
      if tier == "off" or tier == "lite" or tier == "full" then perf.tier = tier end
    end
    return perf.tier
  end
  mod.exports.questWeatherTier = function() return perf.tier end
  -- setFixedSunAzimuth(azDeg [, sweepDeg]): pin the drawn sun (and moon) heading
  -- for baked/fixed sun shadows. azDeg = heading TOWARD the sun in the world x/z
  -- plane, degrees from +X (east) toward +Z (south). Elevation and arc timing
  -- still follow the clock. sweepDeg (default 15, clamped 0..45) is the slow
  -- +-wander of the heading over the day. nil / non-number = original arc.
  mod.exports.setFixedSunAzimuth = function(az, sweep)
    if type(az) == "number" and az == az and az ~= math.huge and az ~= -math.huge then
      perf.fixedSunAzimuth = az % 360
      sweep = tonumber(sweep)
      if not sweep or sweep ~= sweep then sweep = 15 end
      perf.fixedSunSweep = math.max(0, math.min(45, sweep))
    else
      perf.fixedSunAzimuth, perf.fixedSunSweep = nil, nil
    end
    return perf.fixedSunAzimuth, perf.fixedSunSweep
  end
  mod.exports.fixedSunAzimuth = function() return perf.fixedSunAzimuth, perf.fixedSunSweep end
end

-- Bundled weather-only adapter selection; not Quest transport.
loadModule('compat/Bootstrap.lua',mod)
