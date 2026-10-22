-- Gen 3 host routing: makes TWS treat FRLG_VOXEL as its Battle-Art-legacy
-- 3D host, and everything else DESIGN.md §4.3's Gen3Host row lists.
-- Loaded from Gen3Compat's mods.loaded@50 listener -- BEFORE Bootstrap's
-- own (default-priority) mods.loaded refresh listener, which is what lets
-- this file's export replacements land before Bootstrap's first refresh()
-- call reads mod.exports.rendererReady/activeWeatherHost (CRITIQUE D).

local mod, loadModule, hostLib, shared = ...

local Gen3Host = {}

local function findFrlgVoxel()
  local handle = mod.find("FRLG_VOXEL")
  if not handle or not handle.exports then return nil end
  local lib = handle.exports.lib
  if not (lib and type(lib.require) == "function") then return nil end
  local ok, Voxel3D = pcall(lib.require, "Voxel3D")
  if not (ok and type(Voxel3D) == "table" and type(Voxel3D.endScene) == "function") then
    return nil
  end
  return handle, Voxel3D
end

local lastLoggedKey = nil
local function currentSelection()
  local handle, Voxel3D = findFrlgVoxel()
  if not handle then return nil, "no-frlg-voxel-host" end
  if not (handle.exports.active == true) then return nil, "frlg-voxel-inactive" end
  return handle, Voxel3D
end

-- ------- A. the three exports DramalessAtmos/Controls read (§4.3) -------
mod.exports.ownedWeatherAdapter = false

mod.exports.rendererReady = function()
  local handle = currentSelection()
  if not handle then return false, "gen3-host-not-ready" end
  return true, "gen3-host-ready"
end

mod.exports.activeWeatherHost = function()
  local handle = currentSelection()
  if not handle then return nil, nil end
  return handle, "FRLG_VOXEL"
end

mod.exports.compatibilityStatus = function()
  local handle, reasonOrVoxel = currentSelection()
  local ready = handle ~= nil
  return {
    adapter = "frlg_voxel", host = "FRLG_VOXEL", ready = ready,
    reason = ready and "legacy-world-hook-selected" or tostring(reasonOrVoxel),
    bundled = true,
  }
end

-- Bootstrap's own `refresh` (compat/Bootstrap.lua:76-104) still runs from
-- its own mods.loaded/game.ready listeners and logs its own (non-FRLG)
-- adapter line every time router.key changes; that line is harmless and
-- ignored (DESIGN.md §4.9). This is Gen3Host's OWN line, logged once per
-- change, matching the format DESIGN.md §7.1 P0 (5) checks for.
local function logSelection()
  local handle = currentSelection()
  local standalone = false
  pcall(function()
    standalone = love.system.getOS() == "Android" and handle ~= nil
      and handle.exports.xrSessionStarted == true
  end)
  local key = handle and "frlg_voxel" or "none"
  if key ~= lastLoggedKey then
    lastLoggedKey = key
    mod.log:info("gen3: Weather adapter: %s; standalone=%s", key, tostring(standalone))
  end
end
logSelection()
mod.events:on("mods.loaded", logSelection, 10) -- after export swap (50), before/near Bootstrap's own refresh

-- ------- afterCelestial: the Gen 3 cloud deck (§4.3, §4.5 step 6) -------
--
-- TWS has only questCelestialBeforeClouds (set by DramalessAtmos itself,
-- DramalessAtmos.lua:864-880 in the V.questLitePrivate branch); afterCelestial
-- is a NEW function this file defines on the same Voxel3D table FV's
-- WeatherHostLib exposes, for View.lua's WeatherHost:sky(eye) to call after
-- questCelestialBeforeClouds() (CRITIQUE E). This only WRITES a field on
-- FRLG_VOXEL's own hostLib table (owned by "atmos"/W8); it does not touch
-- any FRLG_VOXEL file.
local function installAfterCelestial()
  local handle, Voxel3D = findFrlgVoxel()
  if not (handle and Voxel3D) then return false end
  -- Both families use the persistent, tick-driven transport. Keep rseSky
  -- as the existing shared status handle for compatibility.
  shared.rseSky = shared.rseSky or loadModule("compat/gen3/Gen3SkyRse.lua", mod, loadModule, hostLib, shared)
  return shared.rseSky.install(handle, Voxel3D)
end
installAfterCelestial()
mod.events:on("mods.loaded", installAfterCelestial, 10)

-- ------- sun/moon decline: one log line, not one per frame (Lab 8) --------
--
-- FRLG_VOXEL's WeatherHost gives the Voxel3D facade no view focus (focus is
-- the eye itself), so CelestialBodies.drawWorld finds no billboard axes and
-- declines before drawing anything. DramalessAtmos turns that decline into
-- an error whose text carries the hour, and its celestialPass prints and
-- warns whenever that text changes: with the RTC clock that is every frame
-- (about 2 lines and 0.6 KB a frame, enough to roll the Quest's logcat
-- buffer over in seconds; weather-perf/NOTES.md). For THIS case only (our
-- facade, focus == eye) the wrapper returns "handled" without drawing, which
-- is what happened before, and logs the reason once. Any other call, or a
-- facade that does carry a focus, goes to the original unchanged.
local function installQuietSunMoon()
  local okCB, CB = pcall(hostLib.require, "CelestialBodies")
  if not (okCB and type(CB) == "table" and type(CB.drawWorld) == "function") then return false end
  if CB._gen3QuietDecline then return true end
  local handle, Voxel3D = findFrlgVoxel()
  if not (handle and Voxel3D) then return false end
  CB._gen3QuietDecline = true
  local original = CB.drawWorld
  local logged = false
  CB.drawWorld = function(voxel, hour)
    if voxel == Voxel3D then
      local e, fo = voxel.eye, voxel.focus
      if e and fo and (fo == e or (fo[1] == e[1] and fo[2] == e[2] and fo[3] == e[3])) then
        if not logged then
          logged = true
          mod.log:info("gen3: sun/moon not drawn: the host gives no view focus (focus == eye); logged once")
        end
        return true
      end
    end
    return original(voxel, hour)
  end
  return true
end
installQuietSunMoon()
mod.events:on("mods.loaded", installQuietSunMoon, 10)

-- ------- Voxel3D.weatherHazeLevel (§3.3 step 5) --------------------------
--
-- Normalised 0..1 haze level, read by FV's own fog-curve mapping. Source:
-- QuestStormFront.haze, which tops out at 1 (lib/QuestStormFront.lua:
-- `F.haze=0`, updated 0..1 by the front simulation; QuestStorm.lua:469
-- reads it as a per-pixel density that tops at 1e-4, but the RAW 0..1
-- value on QuestStormFront.haze is what this exports, matching DESIGN.md
-- §3.3's "reads QuestStormFront.haze").
local function installHazeLevel()
  local handle, Voxel3D = findFrlgVoxel()
  if not (handle and Voxel3D) then return false end
  Voxel3D.weatherHazeLevel = function()
    local ok, front = pcall(hostLib.require, "QuestStormFront")
    if not ok or not front then return 0, nil end
    local h = tonumber(front.haze) or 0
    if h < 0 then h = 0 elseif h > 1 then h = 1 end
    return h, nil -- colour left nil: FV falls back to its own fog colour
  end
  return true
end
installHazeLevel()
mod.events:on("mods.loaded", installHazeLevel, 10)

-- ------- rain-splash sampler (§4.3) --------------------------------------
--
-- QuestRainSurface.sampler(map, shapesAPI) normally samples FV's TileShape
-- stub, which always answers nil (§4.4 A: "Minimal stub (forMap, at → nil)"),
-- so splashes would never place on Gen 3 without this. vrHost.world.heightAt
-- is part of vrHost 1.2 (not present in the FRLG_VOXEL HostApi checked this
-- pass, which reports VERSION "1.1"); this degrades to the original
-- (TileShape-stub-backed, i.e. no-splash) sampler until that lands -- see
-- W9_NOTES.md.
local function installRainSampler()
  local Surface = hostLib.require("QuestRainSurface")
  if not (Surface and type(Surface.sampler) == "function") then return false end
  if Surface._gen3Wrapped then return true end
  Surface._gen3Wrapped = true
  local origSampler = Surface.sampler
  Surface.sampler = function(map, shapesAPI)
    local handle = currentSelection()
    local vrHost = handle and handle.exports and handle.exports.vrHost
    if vrHost and vrHost.world and type(vrHost.world.heightAt) == "function" then
      return function(x, z)
        -- WeatherHostLib exposes particle coordinates in pixels (16/cell),
        -- while vrHost.world.heightAt accepts native root-map cells.
        local ok, h = pcall(vrHost.world.heightAt, x / 16, z / 16)
        if ok and type(h) == "number" then return h * 16 end
        return nil
      end
    end
    return origSampler(map, shapesAPI)
  end
  return true
end
installRainSampler()
mod.events:on("mods.loaded", installRainSampler, 10)

-- ------- Quality tier pin (rev 2, §4.3 "Quality pin") --------------------
--
-- TWS's own governor only steps down above 23.8 ms/frame (lib/Quality.lua),
-- which never protects a 13.9 ms (72 Hz) or 11.1 ms (90 Hz) VR frame. Fixed
-- tier until P2 measures a real number; "medium" is DESIGN.md's own
-- placeholder (the mobile AUTO cap), not a measured result.
local function pinQuality()
  local Quality = hostLib.require("Quality")
  if not Quality then return false end
  if Quality._gen3Pinned then return true end
  Quality._gen3Pinned = true
  Quality.tier = function() return "medium" end
  return true
end
pinQuality()

-- ------- gen3Status() (§5.3) ---------------------------------------------
function Gen3Host.gen3Status()
  local clock = shared.clockStatus and shared.clockStatus() or { hour = 12, minute = 0, period = "day", source = "unknown" }
  local weather = shared.weatherStatus and shared.weatherStatus() or { level = 1, captured = false }
  local weatherId, weatherLabel, strength = nil, nil, nil
  pcall(function()
    local State = hostLib.require("WeatherState")
    if State then weatherId, strength = State.id, State.level end
  end)
  local Scene = hostLib.require("Scene")
  local outdoor = Scene and Scene.now and Scene.now.outdoor or false
  return {
    clock = clock,
    weather = { id = weatherId, label = weatherId, strength = strength or weather.level },
    outdoor = outdoor,
  }
end
mod.exports.gen3 = mod.exports.gen3 or {}
mod.exports.gen3.status = Gen3Host.gen3Status
do local ok, lightning = pcall(loadModule, "compat/gen3/Gen3Lightning.lua", mod, loadModule, hostLib, shared); if ok then shared.lightning = lightning else mod.log:warn("gen3: Gen3Lightning not loaded: %s", tostring(lightning)) end end -- LWS 1.1.0 lightning adapters (camera, thunder valve, native gate)

do local ok, discs = pcall(loadModule, "compat/gen3/Gen3SunMoon.lua", mod, loadModule, hostLib, shared); if ok then shared.sunMoon = discs else mod.log:warn("gen3: sun/moon adapter failed: %s", tostring(discs)) end end -- Packet H: paired with cheaper full per-eye stars

return Gen3Host
