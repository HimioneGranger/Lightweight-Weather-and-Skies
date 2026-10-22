-- Gen 3 sun and moon (Lab 8 sun-moon lane). Gen 3 only: loaded by
-- Gen3Compat.lua's mods.loaded listener, after Gen3Host.lua. Touches no
-- Gen 1/Gen 2 path and no TWS file outside compat/gen3/.
--
-- FRLG_VOXEL (Lab 8 View.lua) now hands the Voxel3D facade a real per-eye
-- view focus outdoors, which is what TWS's sky layer needs to draw at all.
-- This file does the two Gen 3-specific things that are left:
--
-- 1. Disc size. CelestialBodies.drawWorld puts the sun and moon on a sphere
--    around the eye whose radius comes from the host's far distance,
--      radius = min(far * 0.88, max(280, far * 0.7))   (280 when far is unset),
--    but WorldCelestialDisc keeps each disc's half size in world units (sun
--    22, moon 10.5, a little larger when high). The Quest-tested Gen 1 host
--    sets no far, so there the discs sit at 280 and look about 9-12 degrees
--    (sun) and 4-5 degrees (moon) across. FRLG_VOXEL's facade sets far = 4000
--    (WeatherHostLib), radius 2800: the same discs would look ten times
--    smaller (a moon of a few pixels). TWS's own packet path keeps the
--    angular size fixed while leaving the disc at the sky-layer distance
--    (compat/CelestialPackets.lua: "Keep both bodies' angular sizes stable
--    ... retain sky-layer distance for terrain/cloud occlusion").
--    So, for FRLG_VOXEL's facade only, drawWorld is called with a stand-in
--    whose far is unset (TWS lays the discs out exactly as on Gen 1, radius
--    280) and whose view-projection is the eye's own, scaled about the eye by
--    k = (the radius TWS would have used) / 280. Every disc vertex p lands at
--    eye + k * (p - eye): same direction, same angular size as Gen 1, at the
--    far sky radius, so terrain, buildings and trees still hide it (depth
--    test lequal, no depth write, unchanged). The disc orientation stays
--    WorldCelestialDisc's own world-fixed one (no swim, no roll with the
--    head). Per eye: the stand-in is refilled from the facade on every call.
--
-- 2. Stars use the accepted Gen3NightStars helper: every star and every
-- eye retain their original geometry/fades, with cheaper allocations.
-- No stars are held back.
--
-- Any other caller, and the facade without a real view focus (focus == eye:
-- indoors, or an FRLG_VOXEL without the Lab 8 View.lua change), go to the
-- originals unchanged -- including the weather-perf lane's quiet-decline
-- wrapper, whichever of the two was installed first.
--
-- 3. Weather. TWS hides the sun and moon behind its cloud deck, drawn right
--    after them; compat/CloudsSource.lua decides the deck's coverage from the
--    weather. On Gen 3 that deck draws nothing yet (WeatherHost calls
--    afterCelestial() with no map/outdoor, and Gen2VoxelClouds:draw returns
--    early without outdoor; Lab 8 sun-moon NOTES.md). Until it does, the
--    discs are dimmed by the same decision: CloudsSource.updateWeather's
--    weather intensity (rain/dim/snow/ash channels and the weather id, eased
--    5 s in / 9 s out; snow -> coverage 0.90, storm -> 0.94) gives the deck's
--    coverage, and the discs' visibility runs from 1 at the clear-sky
--    coverage (0.30) to 0 at full weather coverage (0.86). Heavy rain, storm
--    and snow hide them; mostly cloudy leaves about half. One deviation: a
--    regional storm front (which TWS draws with its own storm shader, not
--    drawn on Gen 3 either) counts as STORM here, not as clear. Set
--    Gen3SunMoon.WEATHER_DIM = false once the Gen 3 deck draws clouds.
--
-- 4. When every body is below the horizon or faded out by the weather, the
--    facade's call is answered "handled" without drawing, so DramalessAtmos
--    does not turn it into its per-hour decline message.
--
-- 5. Also bakes the two disc textures once at install (WorldCelestialDisc
--    .image): the moon texture costs about 0.2 s of CPU on the desktop (more
--    on the Quest), which would otherwise land on the first outdoor frame.

local mod, loadModule, hostLib, shared = ...

local Gen3SunMoon = {}

local GEN1_RADIUS = 280 -- lib/CelestialBodies.lua SKY_RADIUS (the Gen 1 Quest radius)

-- ------- 3. weather visibility (CloudsSource.updateWeather's decision) ----
Gen3SunMoon.WEATHER_DIM = not (shared and shared.rse) -- Emerald already draws its weather cloud deck
local COVER_CLEAR, COVER_WEATHER = 0.30, 0.86 -- Clouds.COVERAGE, Clouds.WEATHER_COVERAGE
local RAIN_TARGETS = { RAIN_LIGHT = 0.75, RAIN_HEAVY = 1.0, HEAVY_RAIN = 1.0 } -- Clouds.RAIN_TARGETS
local FADE_IN, FADE_OUT, MIX_S = 5.0, 9.0, 9.0 -- Clouds.WEATHER_FADE_IN/OUT, the snow/storm response
local wx = { intensity = 0, snowMix = 0, stormMix = 0, t = nil, vis = 1 }
Gen3SunMoon._wx = wx -- test seam
local function clamp01(v)
  v = tonumber(v) or 0
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end
local function mix(a, b, t) return a + (b - a) * t end
local getTime = nil
local function nowS()
  if getTime == nil then
    local ok, f = pcall(function() return love.timer.getTime end)
    getTime = (ok and type(f) == "function") and f or false
  end
  if not getTime then return 0 end
  local ok, t = pcall(getTime)
  return ok and tonumber(t) or 0
end
local function weatherVisibility()
  local okS, State = pcall(hostLib.require, "WeatherState")
  if not (okS and type(State) == "table" and type(State.channel) == "function") then return 1 end
  local now = nowS()
  local dt = wx.t and math.max(0, math.min(0.25, now - wx.t)) or math.huge -- first call: settle at once
  wx.t = now
  local id = State.id
  local target = math.max(clamp01(State.channel("rain") / 1.30), clamp01(State.channel("dim") / 0.34),
    clamp01(State.channel("snow") / 1.08) * 0.55, clamp01(State.channel("ash") / 0.95) * 0.45)
  if id == "PARTLY_CLOUDY" or id == "PARTLY_SNOW" then target = 0.30 end
  if id == "MOSTLY_CLOUDY" then target = 0.45 end
  local rainTarget = RAIN_TARGETS[id]
  if rainTarget then target = math.max(target, rainTarget) end
  local cur = wx.intensity
  cur = mix(cur, target, 1 - math.exp(-dt / (target > cur and FADE_IN or FADE_OUT)))
  if math.abs(cur - target) < 0.0001 then cur = target end
  wx.intensity = cur
  local snowT = (type(id) == "string" and id ~= "PARTLY_SNOW" and id:find("SNOW", 1, true)) and 1 or 0
  local stormT = id == "STORM" and 1 or 0
  local okA, After = pcall(hostLib.require, "QuestAfterStorm")
  local recovery = okA and type(After) == "table" and tonumber(After.cloud) or nil
  if recovery then
    stormT = math.max(stormT, clamp01(recovery) * ((id == "CLEAR" or id == "SUNNY") and 0.15 or 1))
  end
  local r = 1 - math.exp(-dt / MIX_S)
  wx.snowMix = mix(wx.snowMix, snowT, r)
  wx.stormMix = mix(wx.stormMix, stormT, r)
  local cov = mix(COVER_CLEAR, COVER_WEATHER, cur)
  cov = mix(cov, 0.90, wx.snowMix)
  cov = mix(cov, 0.94, wx.stormMix)
  wx.vis = clamp01((COVER_WEATHER - cov) / (COVER_WEATHER - COVER_CLEAR))
  return wx.vis
end
Gen3SunMoon.weatherVisibility = weatherVisibility

local function findFacade()
  local handle = mod.find("FRLG_VOXEL")
  if not (handle and handle.exports) then return nil end
  local lib = handle.exports.lib
  if not (lib and type(lib.require) == "function") then return nil end
  local ok, Voxel3D = pcall(lib.require, "Voxel3D")
  if not (ok and type(Voxel3D) == "table") then return nil end
  return Voxel3D
end

-- The radius CelestialBodies.drawWorld derives from a far (its own formula).
local function skyRadius(far)
  if type(far) == "number" and far > 80 then
    return math.min(far * 0.88, math.max(GEN1_RADIUS, far * 0.7))
  end
  return GEN1_RADIUS
end
Gen3SunMoon.skyRadius = skyRadius

-- out = vp * T(e) * S(k) * T(-e): row-major 16, column vectors (the facade's
-- convention, sent with shader:send(name, "row", vp)). No allocation.
local function scaleAboutEye(vp, e, k, out)
  local tx, ty, tz = (1 - k) * e[1], (1 - k) * e[2], (1 - k) * e[3]
  for r = 0, 12, 4 do
    local a1, a2, a3, a4 = vp[r + 1], vp[r + 2], vp[r + 3], vp[r + 4]
    out[r + 1], out[r + 2], out[r + 3] = a1 * k, a2 * k, a3 * k
    out[r + 4] = a1 * tx + a2 * ty + a3 * tz + a4
  end
  return out
end
Gen3SunMoon.scaleAboutEye = scaleAboutEye

local standIn = { eye = nil, focus = nil, vp = nil, far = nil, camera = {} }
local standInVp = {}

local function prewarm()
  local ok, Disc = pcall(hostLib.require, "WorldCelestialDisc")
  if not (ok and type(Disc) == "table" and type(Disc.image) == "function") then return end
  local okS, errS = pcall(Disc.image, false, true)
  local okM, errM = pcall(Disc.image, true)
  if not (okS and okM) then
    mod.log:warn("gen3: sun/moon texture prewarm failed: %s", tostring(okS and errM or errS))
  end
end

local function installDiscs(Voxel3D)
  local okCB, CB = pcall(hostLib.require, "CelestialBodies")
  if not (okCB and type(CB) == "table" and type(CB.drawWorld) == "function"
    and type(CB.bodies) == "function") then return false end
  if CB._gen3SunMoonSize then return true end
  CB._gen3SunMoonSize = true
  local inner, baseBodies = CB.drawWorld, CB.bodies
  -- CB.drawWorld reads CB.bodies(hour) (fresh tables from CelestialSim);
  -- for the facade's call only, this scales their alpha by the weather and
  -- notes whether any body is left to draw.
  local dimVis, dimSeen = 1, false
  local function dimmedBodies(hour)
    local b = baseBodies(hour)
    local s, m = b and b.sun, b and b.moon
    if dimVis < 1 then
      if s then s.alpha = (s.alpha or 0) * dimVis end
      if m then m.alpha = (m.alpha or 0) * dimVis end
    end
    dimSeen = (s and (s.alpha or 0) > 0.02) or (m and (m.alpha or 0) > 0.02) or false
    return b
  end
  CB.drawWorld = function(voxel, hour)
    if voxel ~= Voxel3D then return inner(voxel, hour) end
    local e, fo, vp = voxel.eye, voxel.focus, voxel.vp
    if not (e and fo and vp) or fo == e then return inner(voxel, hour) end
    local vis = Gen3SunMoon.WEATHER_DIM and weatherVisibility() or 1
    if vis < 0.02 then return true end -- hidden by the weather: handled, nothing drawn
    local target = voxel
    local k = skyRadius(voxel.far or (voxel.camera and voxel.camera.far)) / GEN1_RADIUS
    if k > 1.0001 then
      standIn.eye, standIn.focus = e, fo
      standIn.vp = scaleAboutEye(vp, e, k, standInVp)
      target = standIn
    end
    dimVis, dimSeen = vis, false
    CB.bodies = dimmedBodies
    -- Scoped opt-in: never change the shared disc's Gen 1/2 default or moon.
    local priorCleanSun=target._gen3CleanSun
    target._gen3CleanSun=true
    local ok, result = pcall(inner, target, hour)
    target._gen3CleanSun=priorCleanSun
    CB.bodies = baseBodies
    if not ok then error(result, 0) end
    if not result and not dimSeen then return true end -- nothing above the horizon, or all faded
    return result
  end
  prewarm()
  return true
end

local installed = false
local function install()
  if installed then return true end
  local Voxel3D = findFacade()
  if not Voxel3D then return false end
  local okD = installDiscs(Voxel3D)
  if okD then
    installed = true
    mod.log:info("gen3: clean 2-degree sun core with modest 4.5-degree halo; existing moon on far sky sphere unchanged; full cheaper per-eye star field enabled")
  end
  return installed
end
Gen3SunMoon.install = install
Gen3SunMoon._standIn = standIn -- test seam

install()
mod.events:on("mods.loaded", install, 10)

return Gen3SunMoon

