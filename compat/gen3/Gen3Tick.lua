-- Gen 3 tick: keeps TWS's weather state machine running on Gen 3, where
-- render_pipelines do not exist and are never ticked by the engine.
-- DESIGN.md §4.3 Gen3Tick. Loaded EARLY, synchronously, from Gen3Compat's
-- own top level -- before weather_main.lua registers the "weather"
-- render_pipelines record or its seven WX_* sfx entries, and before
-- compat/Bootstrap.lua runs. `hostLib` is not available yet at this point
-- (nil); everything here only touches mod.content.*, which is an engine-
-- level field present from mod construction.

local mod, loadModule, hostLib, shared = ...

local Gen3Tick = {}

-- ------- 1. Swallow render_pipelines/sfx registration on Gen 3 ---------
--
-- ENG mods\Schemas.lua marks both `render_pipelines` (:674) and `sfx`
-- (:676) as having no Gen 3 target. Left alone, the engine's own
-- _contentApi.register would log one "registry has no Gen %d target"
-- warning per registry into loader.errors -- which the Mod Manager shows as
-- a TWS error on every Gen 3 boot, even though nothing is actually broken
-- (CRITIQUE F). Wrapping the mod's OWN mod.content.render_pipelines.register
-- / mod.content.sfx.register, rather than letting the call reach the
-- engine's registry, means the write never happens and the warning is never
-- logged -- so the manager stays clean AND the "weather" record's table
-- (the thing TWS built with .update/.invalidate/etc on it) is still
-- captured for Gen3Tick to drive manually.

local capturedRecord = nil

local origPipelinesRegister = mod.content and mod.content.render_pipelines
  and mod.content.render_pipelines.register
if mod.content and mod.content.render_pipelines then
  mod.content.render_pipelines.register = function(self, id, value)
    if id == "weather" then
      capturedRecord = value
      mod.log:info("gen3: pipeline captured")
    end
    -- Never forward on Gen 3: there is no render_pipelines target, and
    -- forwarding is exactly what would produce the Mod Manager error this
    -- wrap exists to avoid. Gen 1/Gen 2 never run this file, so their own
    -- registration reaches the real engine registry unchanged.
    return value
  end
end

if mod.content and mod.content.sfx then
  mod.content.sfx.register = function(self, id, value)
    -- No target on Gen 3 (Schemas.lua sfx=false); TWS plays WX_* beds
    -- through love.audio directly (lib/Audio.lua), so dropping the registry
    -- entry costs nothing except the engine's own volume-table lookup,
    -- which TWS never uses on Gen 3 either.
    return value
  end
end

-- ------- 2. Drive it from input.step, TWS's own fixed lifecycle hook ---
--
-- weather_main.lua already wraps input.step at priority -900 for the
-- Quest Lite bridge (V.questLitePrivate branch, weather_main.lua:522-535).
-- -950 runs INSIDE that -900 link (ENG mods\Hooks.lua sorts descending, so
-- higher priority is outer; -950's callback is what -900's own `next()`
-- reaches), so State/Draw/Audio are already ticked once before the pipeline
-- record's own .update runs, matching what a real render_pipelines driver
-- would have done ahead of the pipeline callback.

local LEVEL_IDS = { OFF = 0, AUTO = 1, CYCLE = 2 } -- WeatherState.lua:90-91 order

local function currentLevel()
  if shared.weatherLevel then return shared.weatherLevel() end
  local ok, raw = pcall(function()
    return mod.options and mod.options.get and mod.options:get("gen3_weather")
  end)
  if not ok or type(raw) ~= "string" then return 1 end -- default AUTO
  return LEVEL_IDS[raw] or 1
end

-- Lab 52 (exports.setFrameOnce, default OFF): with the switch on, the record update is summed over the ticks of a
-- rendered frame and run once when the host calls exports.frameBegin(); compat/FrameOnce.lua owns the rules. With the
-- switch off this link is the original one tick, one update.
local okFO, FO = pcall(loadModule, "compat/FrameOnce.lua", mod)
if not okFO then FO = nil end
local perf = FO and FO.perf or {}
local take = FO and FO.take
local function runRecord(dt)
  if capturedRecord and type(capturedRecord.update) == "function" then
    local ok, err = pcall(capturedRecord.update, dt, currentLevel())
    if not ok then
      mod.log:warn("gen3: weather record update failed: %s", tostring(err))
    end
  end
end
local stage = FO and FO.stage("weather", 20, runRecord) or { n = 0 }

mod.hooks:wrap("input.step", function(next, game, dt)
  local result = next(game, dt)
  local go, d = true, dt
  if perf.frameOnce or stage.n ~= 0 then go, d = take(stage, dt) end
  if go then runRecord(d) end
  return result
end, -950)

-- Pending batched dt must not straddle a map change.
if FO and mod.events and type(mod.events.on) == "function" then
  local function flushPending() FO.flush() end
  pcall(mod.events.on, mod.events, "map.entered", flushPending, 9999)
  pcall(mod.events.on, mod.events, "map.exited", flushPending, 9999)
end

-- ------- 3. invalidate() surface for FRLG_VOXEL --------------------
--
-- DESIGN.md §4.3: "Call record.invalidate() on FV's invalidate event."
-- FV does not yet publish that event (checked this session: no
-- `invalidate` hook/event anywhere under FRLG_VOXEL as of this pass), so
-- this is exposed as a plain function on this mod's own exports for W8's
-- code to call directly once it exists -- see W9_NOTES.md for the exact
-- ask. Never called from inside this file on a guess.
function Gen3Tick.invalidate()
  if capturedRecord and type(capturedRecord.invalidate) == "function" then
    local ok, err = pcall(capturedRecord.invalidate)
    if not ok then mod.log:warn("gen3: weather record invalidate failed: %s", tostring(err)) end
    return ok
  end
  return false
end

mod.exports.gen3 = mod.exports.gen3 or {}
mod.exports.gen3.invalidate = Gen3Tick.invalidate

function Gen3Tick.status()
  return { level = currentLevel(), captured = capturedRecord ~= nil }
end

shared.weatherStatus = Gen3Tick.status

return Gen3Tick
