-- Lab Gen 3 compat for the_world_weather_quest_lite_private (TWS-L).
-- See daynight-weather-hook/DESIGN.md §4.1-4.3. This is the ONLY entry
-- point Gen 1/Gen 2 never load: main.lua's one guarded line calls this file
-- through pcall, and only when mod.generation == 3. Everything below is
-- additive to TWS; no Gen 1/Gen 2 code path is touched by this file or by
-- anything it loads. If any step here throws, TWS keeps running un-adapted
-- (CRITIQUE H) -- the visible failure signal is a Mod Manager entry for
-- whichever registration Gen3Tick did not get to swallow, plus this file's
-- own warn lines.
--
-- Called as: loadModule("compat/gen3/Gen3Compat.lua", mod, loadModule)
-- i.e. with the SAME two values main.lua's own loadModule closure captured
-- (mod, and the loadModule function itself), so this file can load its own
-- sibling files the identical way TWS loads everything else.

local mod, loadModule = ...
if require("src.core.game3.profile").family() == "rse" then return loadModule("compat/gen3/RseCompat.lua", mod, loadModule) end

-- ------- provenance line -----------------------------------------------
-- A lab build vs. a hypothetical released Gen 3 build must be tellable
-- apart at a glance in the log. TWS_LAB_PATCHES.md carries the real sha of
-- this patch set; that value is written into the log line by the lab build
-- script (F:\...\w9\ build receipt), so a stale copy of this file cannot
-- silently claim a patch log it does not match. Until a build script stamps
-- it, "unstamped" is a truthful placeholder, not a guess.
local PATCH_LOG_SHA = (mod.exports and mod.exports._gen3LabPatchSha) or "unstamped"
mod.log:info("gen3Candidate %s LWS 1.2.0 (compatibility qualification pending)", PATCH_LOG_SHA)

-- Small bag of state shared between the compat/gen3/*.lua files, passed as
-- an explicit argument to each -- not stashed on `mod`, which is TWS's and
-- the engine's shared namespace, not ours to add fields to.
local shared = {
  patchLogSha = PATCH_LOG_SHA,
}

local function loadGen3(name, ...)
  return loadModule("compat/gen3/" .. name, mod, loadModule, ...)
end

-- ------- 1. Must run BEFORE weather_main.lua and compat/Bootstrap.lua --
--
-- This file executes while main.lua is still between `loadModule`'s
-- definition and `local Weather = loadModule("bootstrap/Weather.lua", ...)`
-- (DESIGN.md §4.1 item 1) -- i.e. before weather_main.lua registers its
-- render_pipelines/sfx content and before compat/Bootstrap.lua defines its
-- MOD OPTIONS schema. Gen3Tick and Gen3Options both need to wrap engine-
-- level fields (mod.content.*, mod.options.define) that exist from mod
-- construction, so both load synchronously right here, not from an event.

local function loadEarly(name)
  local ok, result = pcall(loadGen3, name, nil, shared)
  if not ok then
    mod.log:warn("gen3: %s not loaded: %s", name, tostring(result))
    return nil
  end
  return result
end

shared.tick = loadEarly("Gen3Tick.lua")
shared.options = loadEarly("Gen3Options.lua")

-- ------- 2. Everything that needs TWS's own cached modules or another --
--            mod's exports waits for mods.loaded.
--
-- `mod.exports.lib` (TWS's V, the cached-module namespace: Interop, Scene,
-- TimeOfDay, QuestStormFront, QuestNature, OutdoorWeatherAreas, ...) is set
-- at weather_main.lua:1065, which runs as part of Weather.install() --
-- itself called from main.lua AFTER this file returns. So none of that is
-- reachable yet from Gen3Compat's own top level. `mods.loaded` fires once
-- every mod's entry chunk (main.lua) has finished running, by which point
-- TWS's own main.lua has completed and mod.exports.lib exists, and RTC and
-- FRLG_VOXEL (if present) have set their own exports too.
--
-- Priority 50 runs before compat/Bootstrap.lua's OWN mods.loaded listener
-- (registered at default priority 0, Bootstrap.lua:118): the engine's
-- Events:on sorts listeners by priority DESCENDING (ENG mods\Events.lua),
-- so 50 fires first. That is what lets Gen3Host replace
-- mod.exports.rendererReady/activeWeatherHost/compatibilityStatus before
-- Bootstrap's first refresh() reads them (CRITIQUE D).
local installedLate = false
mod.events:on("mods.loaded", function()
  if installedLate then return end -- mods.loaded can refire; only do this once
  installedLate = true

  local hostLib = mod.exports and mod.exports.lib
  if not (hostLib and type(hostLib.require) == "function") then
    mod.log:warn("gen3: TWS exports.lib not ready at mods.loaded; "
      .. "RTC clock / host routing / Gen 3 maps not installed this session")
    return
  end

  local function loadLate(name)
    local ok, result = pcall(loadGen3, name, hostLib, shared)
    if not ok then
      mod.log:warn("gen3: %s not loaded: %s", name, tostring(result))
      return nil
    end
    return result
  end

  -- Order matters only in that each of these publishes into `shared` for
  -- the ones after it to read; none of them call each other directly.
  shared.maps = loadLate("Gen3Maps.lua")
  shared.world = loadLate("Gen3World.lua")
  shared.clock = loadLate("RealTimeClockCompat.lua")
  shared.host = loadLate("Gen3Host.lua")
end, 50)

return shared
