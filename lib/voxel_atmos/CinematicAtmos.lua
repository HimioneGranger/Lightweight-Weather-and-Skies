-- Android-safe cinematic atmosphere for Dramatic Shape.
--
-- This pass deliberately avoids sampling the scene depth texture. Instead it
-- draws real translucent geometry while VoxelScene's hardware depth buffer is
-- still bound. Ground mist, clouds and light volumes are therefore occluded by
-- the same depth test as the voxel world on every platform, including Android.
--
-- The light volumes additionally sample Dramatic Shape's ordinary COLOR shadow
-- map (lib/ShadowMap.lua). That texture is portable on Android and tells each
-- fragment whether the sun can actually reach that point in space, so trees,
-- buildings and characters carve darkness through the shafts instead of the
-- shafts being painted screen overlays.

local V = ...

local DayNight = V.require("DayNight")
local function wxCelestial()
  local ok, CB = pcall(V.require, "CelestialBodies")
  if ok then return CB end
  return nil
end
local ForestAtmos = V.require("ForestAtmos")
local ShadowMap = V.require("ShadowMap")
local ModSetting = V.require("WeatherSetting")
local TileShape = V.require("TileShape")
local Sky = V.require("Sky")
local Mat4 = V.require("Mat4")
local SpriteBillboards = V.require("SpriteBillboards")
local TerrainAtlas = V.require("TerrainAtlas")
local WorldPrecip = nil
pcall(function() WorldPrecip = V.require("WorldPrecip") end)
if not WorldPrecip then pcall(function() WorldPrecip = V.require("WorldPrecip") end) end

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max
local sin, cos, abs = math.sin, math.cos, math.abs
local PI2 = math.pi * 2

local CinematicAtmos = {}

-- Companion-mod atmosphere quality.  This intentionally belongs to Kanto
-- Dynamic Weather rather than reusing Dramatic Shape's FOREST FX setting:
-- the two mods can then be updated/configured independently.
CinematicAtmos.atmosphereSetting = ModSetting.new(
  "atmosphere", "ATMOSPHERE", { "full", "low", "off" },
  { "FULL", "LOW", "OFF" }, 1)

-- Volumetric sunlight strength. 5 is deliberately the A5 calibration the
-- user approved; the extra range is presentation, not a different lighting
-- model. Stored as strings because mod option values are serialized as simple
-- scalars across desktop and Android.
local LIGHT_VALUES, LIGHT_LABELS = {}, {}
for i = 1, 10 do
  LIGHT_VALUES[i], LIGHT_LABELS[i] = tostring(i), tostring(i)
end
CinematicAtmos.lightSetting = ModSetting.new(
  "light_intensity", "LIGHT INTENSITY", LIGHT_VALUES, LIGHT_LABELS, 5)

-- Particle tuning is intentionally exposed as two independent ladders so the
-- handset can be calibrated by eye.  A9 is the reference point the player
-- described as DENSITY 1 / SCALE 8. The preferred tuning is now
-- DENSITY 6 / SCALE 8, so new installs start there while both remain editable.
local PARTICLE_VALUES, PARTICLE_LABELS = {}, {}
for i = 1, 10 do
  PARTICLE_VALUES[i], PARTICLE_LABELS[i] = tostring(i), tostring(i)
end
CinematicAtmos.particleDensitySetting = ModSetting.new(
  "particle_density", "PARTICLE DENSITY", PARTICLE_VALUES, PARTICLE_LABELS, 6)
CinematicAtmos.particleScaleSetting = ModSetting.new(
  "particle_scale", "PARTICLE SCALE", PARTICLE_VALUES, PARTICLE_LABELS, 8)

-- Rain calibration is authored per weather preset rather than exposed as
-- separate menu rows. W5 keeps the handset-approved values: steady RAINING
-- uses SIZE 3 / DENSITY 4, while THUNDERSTORM uses SIZE 3 / DENSITY 6.

-- Weather is authored as a continuum internally, with these menu entries acting
-- as calibrated points on it.  PARTLY CLOUDY is the exact M6 cloud field the
-- user approved and is intentionally the default for existing installs.
local WEATHER_VALUES = { "dynamic", "clear", "partly", "mostly", "cloudy", "overcast", "rain", "thunderstorm", "snow", "blizzard", "gale" }
local WEATHER_LABELS = { "DYNAMIC", "CLEAR", "PARTLY CLOUDY", "MOSTLY CLOUDY", "CLOUDY", "OVERCAST", "RAINING", "THUNDERSTORM", "SNOW", "BLIZZARD", "GALE" }
CinematicAtmos.weatherSetting = ModSetting.new(
  "weather", "WEATHER", WEATHER_VALUES, WEATHER_LABELS, 1)

local WEATHER_SPEED_VALUES = { "slow", "normal", "fast", "very_fast" }
local WEATHER_SPEED_LABELS = { "SLOW", "NORMAL", "FAST", "VERY FAST" }
CinematicAtmos.weatherSpeedSetting = ModSetting.new(
  "weather_speed", "WEATHER SPEED", WEATHER_SPEED_VALUES, WEATHER_SPEED_LABELS, 2)

-- The cloud percentages are perceptual targets, not literal occupied lattice
-- cells.  M6 is our measured ~25% reference.  Denser presets tighten the world
-- lattice and use more broad-bank formations, so coverage grows by adding real
-- 3D cloud volume instead of scaling one cloud into a backdrop. RAIN and
-- THUNDERSTORM use the same sealed cloud ceiling plus the world-space rain
-- pass below; W5 adds atmospheric lightning illumination to the storm state.
local WEATHER = {
  clear =        { coverage=0.00, cell=185, gate=1.01, span=0.92, puffs=0.00, bank=0.00, rays=1.10, shadow=0.00, cloudShade=1.02, fog=0.00 },
  partly =       { coverage=0.25, cell=185, gate=0.18, span=1.00, puffs=1.00, bank=0.34, rays=1.00, shadow=1.00, cloudShade=1.00, fog=2.55 },
  mostly =       { coverage=0.75, cell=120, gate=0.08, span=1.08, puffs=0.74, bank=0.46, rays=0.88, shadow=1.18, cloudShade=0.94, fog=2.70 },

  -- W3: the bridge state between Mostly Cloudy and a sealed Overcast deck.
  -- CLOUDY is intentionally still broken cloud volume: broad banks dominate
  -- and blue openings are uncommon, but the deck has not yet fused shut.
  cloudy =       { coverage=0.92, cell=110, gate=0.015, span=1.16, puffs=0.84, bank=0.72, rays=0.55, shadow=1.34, cloudShade=0.86, fog=2.85,
                   skyBlend=0.24, skyColor={0.66,0.71,0.77} },

  -- W2: 100% states are a true CLOSED CEILING, not merely a denser version
  -- of Mostly Cloudy. Every lattice cell is occupied, broad bank bodies overlap
  -- their neighbours, and altitude is compressed into one coherent deck. The
  -- grey underlying sky is only a safety net for microscopic feather gaps; the
  -- visible ceiling is still made from the same world-space 3D cloud geometry.
  overcast =     { coverage=1.00, cell=108, gate=-0.01, span=1.24, puffs=0.94, bank=1.00, rays=0.08, shadow=1.46, cloudShade=0.76, fog=3.00,
                   closedDeck=true, deckWidth=1.82, deckDepth=1.12, deckY0=116, deckYSpan=26,
                   skyBlend=0.92, skyColor={0.52,0.54,0.55} },
  rain =         { coverage=1.00, cell=105, gate=-0.01, span=1.28, puffs=0.98, bank=1.00, rays=0.05, shadow=1.58, cloudShade=0.66, fog=3.22, motes=0.00, storm=0.00,
                   rainIntensity=1.00, rainSpeed=1.00, rainWind=1.00, rainDensityRung=4, rainSizeRung=3,
                   closedDeck=true, deckWidth=1.86, deckDepth=1.16, deckY0=110, deckYSpan=24,
                   skyBlend=0.96, skyColor={0.42,0.44,0.46} },
  thunderstorm = { coverage=1.00, cell=102, gate=-0.01, span=1.34, puffs=1.02, bank=1.00, rays=0.015, shadow=1.72, cloudShade=0.52, fog=3.45, motes=0.00, storm=1.00,
                   rainIntensity=1.38, rainSpeed=1.22, rainWind=1.48, rainDensityRung=6, rainSizeRung=3,
                   closedDeck=true, deckWidth=1.92, deckDepth=1.20, deckY0=104, deckYSpan=23,
                   skyBlend=0.98, skyColor={0.30,0.32,0.34} },
  -- Soft 3D snowfall (flakes, not streaks)
  snow =         { coverage=0.96, cell=108, gate=-0.01, span=1.20, puffs=0.90, bank=0.88, rays=0.12, shadow=1.30, cloudShade=0.82, fog=2.90, motes=0.00, storm=0.00,
                   snowIntensity=3.6, snowSpeed=0.55, snowWind=0.65, snowDensityRung=5, snowSizeRung=4,
                   closedDeck=true, deckWidth=1.78, deckDepth=1.10, deckY0=118, deckYSpan=28,
                   skyBlend=0.90, skyColor={0.58,0.62,0.68} },
  blizzard =     { coverage=1.00, cell=104, gate=-0.01, span=1.30, puffs=1.00, bank=1.00, rays=0.04, shadow=1.50, cloudShade=0.70, fog=3.40, motes=0.00, storm=0.00,
                   snowIntensity=5.5, snowSpeed=0.95, snowWind=1.45, snowDensityRung=7, snowSizeRung=5,
                   closedDeck=true, deckWidth=1.88, deckDepth=1.16, deckY0=108, deckYSpan=26,
                   skyBlend=0.96, skyColor={0.48,0.52,0.58} },
  -- Hard wind: scudding clouds, dense air motes, no rain (2D leaves/debris remain)
  gale =         { coverage=0.94, cell=98, gate=0.02, span=1.32, puffs=1.00, bank=0.92, rays=0.28, shadow=1.35, cloudShade=0.74, fog=2.35, motes=2.20, storm=0.22,
                   rainIntensity=0, rainSpeed=1, rainWind=1.80, rainDensityRung=1, rainSizeRung=1,
                   snowIntensity=0, snowSpeed=1, snowWind=1.5, snowDensityRung=1, snowSizeRung=1,
                   deckWidth=1.70, deckDepth=1.05, deckY0=118, deckYSpan=30, skyBlend=0.55, deckBlend=0.35, softGate=0.12 },
}

local lerp, mixColor

-- Dynamic weather uses one persistent master lattice so cloud cells do not
-- teleport when coverage changes. The manual presets above remain byte-for-byte
-- calibrated; only DYNAMIC normalises their lattice spacing and uses a soft
-- occupancy threshold so new cloud bodies fade into existence as the target
-- coverage rises.
local DYNAMIC_ORDER = { "clear", "partly", "mostly", "cloudy", "overcast", "rain", "thunderstorm" }
local DYNAMIC_INDEX = {}
for i, k in ipairs(DYNAMIC_ORDER) do DYNAMIC_INDEX[k] = i end

local function copyProfile(src)
  local out = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      local c = {}
      for i = 1, #v do c[i] = v[i] end
      out[k] = c
    else
      out[k] = v
    end
  end
  out.deckBlend = src.closedDeck and 1.0 or 0.0
  return out
end

local DYNAMIC_WEATHER = {}
for _, k in ipairs(DYNAMIC_ORDER) do
  DYNAMIC_WEATHER[k] = copyProfile(WEATHER[k])
  DYNAMIC_WEATHER[k].cell = 120
  DYNAMIC_WEATHER[k].softGate = 0.10
end
-- Preserve the handset-calibrated apparent coverage while keeping the same
-- 120-unit lattice under every dynamic state.
DYNAMIC_WEATHER.clear.gate = 1.01
DYNAMIC_WEATHER.partly.gate = 0.655
DYNAMIC_WEATHER.mostly.gate = 0.08
DYNAMIC_WEATHER.cloudy.gate = 0.01
DYNAMIC_WEATHER.overcast.gate = -0.01
DYNAMIC_WEATHER.rain.gate = -0.01
DYNAMIC_WEATHER.thunderstorm.gate = -0.01

local HOLD_RANGES = {
  clear={900,1800}, partly={720,1200}, mostly={600,1080},
  cloudy={480,900}, overcast={480,900}, rain={480,1080},
  thunderstorm={240,600}, gale={360,720},
}
local TRANSITION_RANGES = {
  -- Longer morphs so clouds/rain/snow never hard-cut between states.
  clear={180,360}, partly={180,360}, mostly={170,340},
  cloudy={160,320}, overcast={150,300}, rain={140,280},
  thunderstorm={120,240},
  snow={160,320}, blizzard={140,280}, gale={140,280},
}
local SPEED_MULT = { slow=1.70, normal=1.00, fast=0.50, very_fast=1.00 }
local VERY_FAST_HOLD = 120.0       -- two minutes per recognisable weather state
local VERY_FAST_TRANSITION = 24.0 -- short transition so the test cycle stays useful

local dynamic = {
  active=false, currentKey="clear", targetKey=nil, phase="hold",
  elapsed=0, duration=900, serial=0, speedKey="normal",
}

-- Persistent ground wetness. Rain fills puddles immediately; once the rain
-- stops the puddles remain, then shrink one authored rung after every later
-- dry weather transition. A new shower/storm resets them to full size. This
-- intentionally keys evaporation to weather evolution rather than wall-clock
-- seconds so the effect remains readable at every WEATHER SPEED, including
-- VERY FAST testing.
local PUDDLE_DRY_LEVELS = { 1.00, 0.78, 0.58, 0.42, 0.28, 0.16, 0.08, 0.0 }
local puddleState = { wetness=0.0, drySteps=99, lastManual=nil }

-- Ground snow cover (3D). Builds while snowy weather is active; melts when
-- weather changes. Rates are tuned to feel natural (not instant, not sticky).
local snowState = {
  cover = 0.0,
  target = 0.0,
  meltRate = 0.55,
  wxId = "",
}

local function wxIsSnowy(id)
  if not id then return false end
  id = tostring(id):upper()
  if id:find("SNOW", 1, true) then return true end
  return id == "BLIZZARD" or id == "HAIL" or id == "THUNDERSNOW" or id == "SLEET" or id == "DRAGONSTORM"
end

-- How thick packs get for each WX id (blizzard denser than light snow).
local function snowTargetFor(id)
  id = tostring(id or ""):upper()
  if id == "BLIZZARD" then return 1.00 end
  if id == "THUNDERSNOW" then return 7.38 end  -- dense snow under lightning
  if id == "DRAGONSTORM" then return 1.8 end
  if id == "SNOW_LIGHT" or id == "SNOW" then return 1.86 end
  if id == "HAIL" then return 0.38 end
  if id == "SLEET" then return 0.28 end
  if wxIsSnowy(id) then return 0.55 end
  return 0.0
end

-- Melt speed after leaving snow: rain washes fast, sun medium, overcast slow.
local function meltRateFor(id)
  id = tostring(id or ""):upper()
  if id:find("RAIN", 1, true) or id == "STORM" or id == "GALE" then return 1.35 end
  if id == "SUNNY" or id == "HARSH_SUN" or id == "HEATWAVE" then return 0.72 end
  if id == "CLEAR" then return 0.55 end
  if id == "FOG" or id == "MIST" or id == "SMOG" or id == "HAUNTED_MIST" then return 0.22 end
  if id == "SANDSTORM" or id == "DUSTSTORM" or id == "ASHFALL" then return 0.40 end
  return 0.48
end

--- Called from Weather FX when the overworld weather id changes.
function CinematicAtmos.notifyWxWeather(id)
  id = tostring(id or ""):upper()
  snowState.wxId = id
  if wxIsSnowy(id) then
    snowState.target = snowTargetFor(id)
    snowState.meltRate = 0.55
  else
    snowState.target = 0.0
    snowState.meltRate = meltRateFor(id)
  end
end

function CinematicAtmos.snowCover()
  return snowState.cover or 0
end

local function updateSnowCover(dt)
  dt = tonumber(dt) or 0
  if dt <= 0 then return end
  if dt > 0.25 then dt = 0.25 end
  local c = snowState.cover or 0
  local tgt = snowState.target or 0
  if c < tgt - 0.0005 then
    -- Ease-in accumulation: slower as it approaches the target.
    local gap = tgt - c
    local rate = 0.12 + gap * 0.22  -- ~15–40s to full under light snow
    if (snowState.wxId or "") == "BLIZZARD" then rate = rate * 1.55 end
    if (snowState.wxId or "") == "HAIL" then rate = rate * 0.75 end
    snowState.cover = min(1.0, c + dt * rate)
  elseif c > tgt + 0.0005 then
    -- Ease-out melt: starts noticeable, finishes clean (no long dirty remnants).
    local rate = snowState.meltRate or 0.55
    -- Slightly faster at high cover so thick packs start breaking up.
    rate = rate * (0.75 + 0.45 * c)
    snowState.cover = max(0.0, c - dt * rate)
  else
    snowState.cover = tgt
  end
end

-- Profile keys / wx ids that may show reflective rain puddles.
local function rainyKey(k)
  k = tostring(k or ""):lower()
  if k == "rain" or k == "thunderstorm" or k == "drizzle" then return true end
  if k:find("rain", 1, true) and not k:find("verdant", 1, true) then return true end
  if k:find("sleet", 1, true) then return true end
  if k:find("psy", 1, true) then return true end
  if k:find("dragon", 1, true) then return true end
  if k:find("storm", 1, true) and not k:find("sand", 1, true)
      and not k:find("dust", 1, true) and not k:find("flock", 1, true)
      and not k:find("ash", 1, true) then
    return true
  end
  return false
end

local function puddleWxId(id)
  id = tostring(id or ""):upper()
  return id == "RAIN_LIGHT" or id == "RAIN_HEAVY" or id == "HEAVY_RAIN"
      or id == "STORM" or id == "SLEET" or id == "PSYSTORM" or id == "DRAGONSTORM"
end

local function soakPuddles()
  puddleState.wetness = 1.0
  puddleState.drySteps = 0
  -- Rain washes snow packs away quickly.
  snowState.target = 0.0
  snowState.meltRate = 1.35
end

local function leaveRainPuddles()
  -- Rain-only puddles: clear as soon as rain weather ends.
  puddleState.drySteps = 99
  puddleState.wetness = 0.0
end

local function dryPuddlesOneTransition()
  if puddleState.wetness <= 0.001 then return end
  puddleState.drySteps = min(#PUDDLE_DRY_LEVELS - 1, (puddleState.drySteps or 0) + 1)
  puddleState.wetness = PUDDLE_DRY_LEVELS[puddleState.drySteps + 1] or 0.0
end

local function completedWeatherTransition(fromKey, toKey)
  if rainyKey(toKey) then
    soakPuddles()
  elseif rainyKey(fromKey) then
    -- The first dry state still inherits broad, fresh puddles. Only later
    -- weather transitions progressively evaporate them.
    leaveRainPuddles()
  else
    dryPuddlesOneTransition()
  end
end

local function dynRand(salt)
  local x = sin((dynamic.serial + 1) * 12.9898 + (salt or 0) * 78.233) * 43758.5453
  return x - floor(x)
end

local function speedMult()
  return SPEED_MULT[CinematicAtmos.weatherSpeedSetting:get() or "normal"] or 1.0
end

local function randomRange(pair, salt)
  local a, b = pair[1], pair[2]
  return (a + (b - a) * dynRand(salt)) * speedMult()
end

local function chooseNextWeather(key)
  -- W6: weather is a graph rather than a single severity ladder. Rain is a
  -- precipitation branch from an already-moist CLOUDY / OVERCAST sky, so a
  -- dynamic cycle no longer has to pass through perfect 100% overcast before
  -- every shower, nor must every overcast spell eventually rain.
  local r = dynRand(41)
  if key == "clear" then
    return "partly"
  elseif key == "partly" then
    return r < 0.43 and "clear" or "mostly"
  elseif key == "mostly" then
    return r < 0.36 and "partly" or "cloudy"
  elseif key == "cloudy" then
    if r < 0.31 then return "mostly" end
    if r < 0.73 then return "overcast" end
    return "rain"
  elseif key == "overcast" then
    return r < 0.48 and "cloudy" or "rain"
  elseif key == "rain" then
    -- Rain can clear back to broken cloud, settle under a sealed deck, or
    -- intensify. This is the branch that stops precipitation being a rung
    -- permanently above OVERCAST.
    if r < 0.22 then return "cloudy" end
    if r < 0.76 then return "overcast" end
    return "thunderstorm"
  end
  -- A storm normally decays through rain, but occasionally the convective
  -- rain collapses first and leaves a dark overcast deck behind.
  return r < 0.82 and "rain" or "overcast"
end

local function beginHold(key)
  dynamic.currentKey = key or dynamic.currentKey or "partly"
  dynamic.targetKey = nil
  dynamic.phase = "hold"
  dynamic.elapsed = 0
  dynamic.serial = dynamic.serial + 1
  if (CinematicAtmos.weatherSpeedSetting:get() or "normal") == "very_fast" then
    dynamic.duration = VERY_FAST_HOLD
  else
    dynamic.duration = randomRange(HOLD_RANGES[dynamic.currentKey] or HOLD_RANGES.partly, 17)
  end
end

local function beginTransition()
  dynamic.serial = dynamic.serial + 1
  dynamic.targetKey = chooseNextWeather(dynamic.currentKey)
  dynamic.phase = "transition"
  dynamic.elapsed = 0
  local a = TRANSITION_RANGES[dynamic.currentKey] or TRANSITION_RANGES.partly
  local b = TRANSITION_RANGES[dynamic.targetKey] or a
  local lo = (a[1] + b[1]) * 0.5
  local hi = (a[2] + b[2]) * 0.5
  if (CinematicAtmos.weatherSpeedSetting:get() or "normal") == "very_fast" then
    dynamic.duration = VERY_FAST_TRANSITION
  else
    dynamic.duration = randomRange({lo, hi}, 29)
  end
end

-- Runs on the same unconditional pipeline tick as DayNight/ForestAtmos, so the
-- weather clock keeps advancing in interiors, menus and battles. Returning to
-- the overworld therefore reveals the weather part-way through its natural
-- transition instead of restarting it. Manual presets pause the simulation and
-- seed DYNAMIC from the preset the player was just using.
function CinematicAtmos.update(dt)
  updateSnowCover(dt)
  local selected = CinematicAtmos.weatherSetting:get() or "dynamic"
  if selected ~= "dynamic" then
    if WEATHER[selected] then
      local prev = puddleState.lastManual
      if rainyKey(selected) then
        soakPuddles()
      elseif prev and prev ~= selected then
        if rainyKey(prev) then leaveRainPuddles() else dryPuddlesOneTransition() end
      end
      puddleState.lastManual = selected
      dynamic.active = false
      dynamic.currentKey = selected
      dynamic.targetKey = nil
      dynamic.phase = "hold"
      dynamic.elapsed = 0
    end
    return
  end
  puddleState.lastManual = dynamic.currentKey or "partly"

  if not dynamic.active then
    dynamic.active = true
    dynamic.speedKey = CinematicAtmos.weatherSpeedSetting:get() or "normal"
    beginHold(dynamic.currentKey or "partly")
  end
  if rainyKey(dynamic.currentKey) and dynamic.phase == "hold" then soakPuddles() end

  -- Re-time the current phase immediately when WEATHER SPEED changes while
  -- preserving its progress. This makes VERY FAST useful as an on-device test
  -- switch without snapping the visible weather back to the start of a blend.
  local newSpeed = CinematicAtmos.weatherSpeedSetting:get() or "normal"
  if dynamic.speedKey ~= newSpeed then
    local progress = dynamic.duration > 0 and min(1, max(0, dynamic.elapsed / dynamic.duration)) or 0
    dynamic.speedKey = newSpeed
    if dynamic.phase == "hold" then
      if newSpeed == "very_fast" then
        dynamic.duration = VERY_FAST_HOLD
      else
        dynamic.duration = randomRange(HOLD_RANGES[dynamic.currentKey] or HOLD_RANGES.partly, 17)
      end
    else
      local a = TRANSITION_RANGES[dynamic.currentKey] or TRANSITION_RANGES.partly
      local b = TRANSITION_RANGES[dynamic.targetKey] or a
      local lo = (a[1] + b[1]) * 0.5
      local hi = (a[2] + b[2]) * 0.5
      if newSpeed == "very_fast" then
        dynamic.duration = VERY_FAST_TRANSITION
      else
        dynamic.duration = randomRange({lo, hi}, 29)
      end
    end
    dynamic.elapsed = progress * dynamic.duration
  end

  local left = max(0, dt or 0)
  local guard = 0
  while left > 0 and guard < 12 do
    guard = guard + 1
    local remain = max(0, dynamic.duration - dynamic.elapsed)
    if left < remain then
      dynamic.elapsed = dynamic.elapsed + left
      left = 0
    else
      left = left - remain
      dynamic.elapsed = dynamic.duration
      if dynamic.phase == "hold" then
        beginTransition()
      else
        local fromKey = dynamic.currentKey
        local toKey = dynamic.targetKey or dynamic.currentKey
        completedWeatherTransition(fromKey, toKey)
        beginHold(toKey)
      end
    end
  end
end

local BLEND_NUMERIC = {
  "coverage","cell","gate","span","puffs","bank","rays","shadow",
  "cloudShade","fog","motes","rainIntensity","rainSpeed","rainWind",
  "snowIntensity","snowSpeed","snowWind",
  "sandIntensity","ashIntensity","debrisIntensity","snowCover",
  "rainDensityRung","rainSizeRung","deckWidth","deckDepth","deckY0",
  "deckYSpan","skyBlend","storm","deckBlend","softGate",
}
local BLEND_DEFAULT = {
  coverage=0, cell=120, gate=1.01, span=1, puffs=1, bank=0.34, rays=1,
  shadow=1, cloudShade=1, fog=1, motes=1, rainIntensity=0, rainSpeed=1,
  snowIntensity=0, snowSpeed=1, snowWind=1,
  sandIntensity=0, ashIntensity=0, debrisIntensity=0, snowCover=0,
  rainWind=1, rainDensityRung=4, rainSizeRung=3, deckWidth=1.82,
  deckDepth=1.12, deckY0=116, deckYSpan=26, skyBlend=0, storm=0,
  deckBlend=0, softGate=0.10,
}

local function profileNumber(p, k)
  local v = p and p[k]
  if v == nil then return BLEND_DEFAULT[k] or 0 end
  return v
end

local function blendProfiles(a, b, t)
  local out = {}
  -- Overlap ease so precip/clouds of the outgoing state linger while the
  -- next builds — no dead air between weathers.
  local u = max(0, min(1, t))
  local outW = 1.0 - (u * u)
  local inW = u * (2.0 - u)
  if inW > 1 then inW = 1 end
  for _, k in ipairs(BLEND_NUMERIC) do
    local av = profileNumber(a, k)
    local bv = profileNumber(b, k)
    local mixed = lerp(av, bv, u)
    if k == "rainIntensity" or k == "snowIntensity" or k == "fog"
        or k == "coverage" or k == "puffs" or k == "bank" then
      out[k] = max(mixed, av * outW, bv * inW)
    else
      out[k] = mixed
    end
  end
  local ac, bc = a.skyColor, b.skyColor
  if ac and bc then out.skyColor = mixColor(ac, bc, t)
  elseif bc then out.skyColor = { bc[1], bc[2], bc[3] }
  elseif ac then out.skyColor = { ac[1], ac[2], ac[3] } end
  out.closedDeck = (out.deckBlend or 0) >= 0.985
  return out
end

local function smoother01(t)
  t = max(0, min(1, t))
  return t * t * t * (t * (t * 6 - 15) + 10)
end

-- Gen 2 has no host cloud simulation. Keep its selected Weather FX profile
-- continuous instead of replacing the entire sky deck on one menu tick.
local questWeather = { key = "clear", from = WEATHER.clear, profile = WEATHER.clear, elapsed = 0 }
function CinematicAtmos.setQuestWeather(key, dt)
  CinematicAtmos.questSkyFallback = true
  key = WEATHER[key] and key or "clear"
  if key ~= questWeather.key then
    questWeather.from = questWeather.profile
    questWeather.key = key
    questWeather.elapsed = 0
  end
  questWeather.elapsed = min(24, questWeather.elapsed + max(0, min(0.1, tonumber(dt) or 0)))
  questWeather.profile = blendProfiles(questWeather.from, WEATHER[key],
    smoother01(questWeather.elapsed / 24))
end

local function weatherProfile()
  if V.questLitePrivate and CinematicAtmos.questSkyFallback then
    return questWeather.profile, questWeather.key
  end
  local selected = CinematicAtmos.weatherSetting:get() or "dynamic"
  if selected ~= "dynamic" then
    return WEATHER[selected] or WEATHER.partly, selected
  end

  local a = DYNAMIC_WEATHER[dynamic.currentKey] or DYNAMIC_WEATHER.partly
  if dynamic.phase ~= "transition" or not dynamic.targetKey then
    return a, dynamic.currentKey
  end
  local b = DYNAMIC_WEATHER[dynamic.targetKey] or a
  local t = smoother01(dynamic.duration > 0 and dynamic.elapsed / dynamic.duration or 1)
  return blendProfiles(a, b, t), dynamic.currentKey .. ">" .. dynamic.targetKey
end

local function questFrontProfile(weather)
  if not (CinematicAtmos.questSkyFallback and questWeather.key == "thunderstorm") then
    return weather
  end
  local ok, front = pcall(V.require, "QuestStormFront")
  if ok and front and front.managed then
    local strength = min(1, max(0, (front.coverage or 0) + (front.warning or 0) * 0.16))
    return blendProfiles(questWeather.from, weather, strength)
  end
  return weather
end

-- Effective puddle coverage for the current rendered frame. During a dry ->
-- rain blend, the growing precipitation can refill puddles before the target
-- preset is formally reached; once rain stops, persistent wetness owns them.
local function puddleWetnessFor(weather)
  local wx = tostring((weather and weather.wxId) or snowState.wxId or ""):upper()
  if wx == "GALE" then return 0.0 end  -- 2D cycling small puddles only
  if not puddleWxId(wx) then return 0.0 end
  local rain = max(0.0, min(1.0, tonumber(weather and weather.rainIntensity) or 0.0))
  if wx == "PSYSTORM" or wx == "DRAGONSTORM" or wx == "SLEET" then
    return max(puddleState.wetness, max(0.35, rain))
  end
  if rain <= 0.02 then return 0.0 end
  return max(puddleState.wetness, rain)
end

function CinematicAtmos.puddleWetness()
  local w = weatherProfile()
  return puddleWetnessFor(w)
end

local function eventRand(i, salt)
  local x = sin((i + 17) * 19.197 + (salt or 0) * 71.731) * 9182.117
  return x - floor(x)
end

-- Atmospheric storm illumination rather than a drawn bolt: irregular short
-- bursts brighten the cloud deck, rain, fog and world lighting together. A
-- storm event can contain a second/third pulse, which reads much more like
-- distant lightning behind clouds than a regular screen flash.
local function lightningFlashFor(weather, t)
  if CinematicAtmos.lightningProvider then return CinematicAtmos.lightningProvider() end
  local storm = weather and (weather.storm or 0) or 0
  if storm <= 0.001 then return 0 end
  t = t or ForestAtmos.time
  local cell = 8.5
  local base = floor(t / cell)
  local flash = 0
  for i = base - 1, base do
    local chance = eventRand(i, 3)
    if chance > 0.28 then
      local start = i * cell + 0.8 + eventRand(i, 4) * 5.7
      local d = t - start
      if d >= 0 and d < 0.78 then
        local function pulse(c, w, amp)
          local q = (d - c) / w
          return amp * math.exp(-q * q)
        end
        local f = max(pulse(0.035, 0.045, 1.00), pulse(0.19, 0.060, 0.68))
        if eventRand(i, 5) > 0.48 then f = max(f, pulse(0.43, 0.105, 0.38)) end
        flash = max(flash, f)
      end
    end
  end
  return min(1.0, flash * storm)
end

function CinematicAtmos.lightningFlash()
  local w = weatherProfile()
  return lightningFlashFor(w, ForestAtmos.time)
end

function CinematicAtmos.worldTint(base, outdoor)
  if not outdoor then return base end
  local f = CinematicAtmos.lightningFlash()
  if f <= 0.001 then return base end
  return {
    min(1.42, base[1] + 0.46 * f),
    min(1.48, base[2] + 0.55 * f),
    min(1.60, base[3] + 0.72 * f),
  }
end

-- VoxelScene asks for this before painting the generated sky.  Closed-deck
-- weather shifts the sky beneath the 3D clouds toward the same cool grey family,
-- so a one-pixel feather gap can never read as a patch of saturated blue sky.
-- Clear/Partly/Mostly return nil and preserve Dramatic Shape's normal sky.
function CinematicAtmos.skyWeather()
  local w, key = weatherProfile()
  w = questFrontProfile(w)
  local flash = lightningFlashFor(w, ForestAtmos.time)
  if not (w and ((w.skyColor and w.skyBlend and w.skyBlend > 0) or flash > 0.001)) then return nil end
  return { color=w.skyColor, blend=w.skyBlend or 0, key=key, flash=flash }
end

local LIGHT_SCALE = { 0.38, 0.52, 0.67, 0.83, 1.00, 1.18, 1.38, 1.60, 1.83, 2.08 }

-- Density is a population multiplier, not opacity.  The upper rungs are
-- deliberately nonlinear: early steps are useful for fine tuning, while the
-- last few allow a genuinely busy pollen/dust field for testing.  1 = A9.
local PARTICLE_DENSITY_SCALE = {
  1.00, 1.35, 1.72, 2.12, 2.58, 3.08, 3.64, 4.26, 4.94, 5.70
}

-- Scale changes projected mote diameter only.  8 = A9 exactly; lower rungs
-- get substantially smaller so combinations such as SCALE 3 / DENSITY 7 can
-- create lots of fine atmospheric dust without turning into giant blobs.
local PARTICLE_SIZE_SCALE = {
  0.26, 0.34, 0.43, 0.53, 0.64, 0.76, 0.88, 1.00, 1.13, 1.27
}

-- Rain controls deliberately have a broad useful range. Density changes the
-- number of independent 3D streaks; size changes both streak width and length
-- without altering their fall speed. Level 5 is the authored neutral point.
local RAIN_DENSITY_SCALE = {
  0.30, 0.45, 0.62, 0.80, 1.00, 1.25, 1.55, 1.90, 2.30, 2.75
}
local RAIN_SIZE_SCALE = {
  0.45, 0.56, 0.68, 0.82, 1.00, 1.16, 1.34, 1.54, 1.76, 2.00
}

local function lightScale()
  local n = tonumber(CinematicAtmos.lightSetting:get()) or 5
  n = max(1, min(10, floor(n + 0.5)))
  return LIGHT_SCALE[n] or 1.0
end

local function particleDensityScale()
  local n = tonumber(CinematicAtmos.particleDensitySetting:get()) or 6
  n = max(1, min(10, floor(n + 0.5)))
  return PARTICLE_DENSITY_SCALE[n] or 1.0
end

local function particleSizeScale()
  local n = tonumber(CinematicAtmos.particleScaleSetting:get()) or 8
  n = max(1, min(10, floor(n + 0.5)))
  return PARTICLE_SIZE_SCALE[n] or 1.0
end

local function rainDensityScale(weather)
  local n = tonumber(weather and weather.rainDensityRung) or 4
  n = max(1, min(10, floor(n + 0.5)))
  return RAIN_DENSITY_SCALE[n] or 0.80
end

local function rainSizeScale(weather)
  local n = tonumber(weather and weather.rainSizeRung) or 3
  n = max(1, min(10, floor(n + 0.5)))
  return RAIN_SIZE_SCALE[n] or 0.68
end

-- ---------- shared helpers

local function fract(x) return x - floor(x) end

-- Deterministic 2D hash. It is deliberately arithmetic-only: no bit library,
-- no platform-specific integer behaviour and no texture dependency.
local function hash2(x, z, salt)
  return fract(sin(x * 127.1 + z * 311.7 + (salt or 0) * 74.7) * 43758.5453123)
end

lerp = function(a, b, t) return a + (b - a) * t end

mixColor = function(a, b, t)
  return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t) }
end

local function billboardAxes(Voxel3D)
  local e, fo = Voxel3D.eye, Voxel3D.focus
  if not (e and fo) then return nil end
  local fx, fy, fz = fo[1] - e[1], fo[2] - e[2], fo[3] - e[3]
  local fl = sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return nil end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local up = (Voxel3D.camera and Voxel3D.camera.up) or { 0, 1, 0 }
  local rx = fy * up[3] - fz * up[2]
  local ry = fz * up[1] - fx * up[3]
  local rz = fx * up[2] - fy * up[1]
  local rl = sqrt(rx * rx + ry * ry + rz * rz)
  if rl < 1e-6 then return nil end
  rx, ry, rz = rx / rl, ry / rl, rz / rl
  local ux = ry * fz - rz * fy
  local uy = rz * fx - rx * fz
  local uz = rx * fy - ry * fx
  return { rx, ry, rz }, { ux, uy, uz }
end

local function horizontalRight(Voxel3D)
  local e, f = Voxel3D.eye, Voxel3D.focus
  if not (e and f) then return nil end
  local fx, fz = f[1] - e[1], f[3] - e[3]
  local fl = sqrt(fx * fx + fz * fz)
  if fl < 1e-6 then return nil end
  fx, fz = fx / fl, fz / fl
  return { -fz, 0, fx }
end

-- The vertical FOV stays fixed while a landscape viewport exposes much more
-- world to the left and right. A6 kept a fixed square weather field around
-- the focus, so portrait was mostly inside it while landscape could see clear
-- world beyond its sides. Expand the FIELD, not its alpha: this preserves the
-- same fog density per metre and makes rotation change framing rather than
-- apparent weather strength.
local function viewportAspect(Voxel3D)
  local w, h = 0, 0
  if Voxel3D and Voxel3D.size then
    local ok, rw, rh = pcall(Voxel3D.size)
    if ok then w, h = tonumber(rw) or 0, tonumber(rh) or 0 end
  end
  if h <= 0 and love and love.graphics and love.graphics.getDimensions then
    local ok, rw, rh = pcall(love.graphics.getDimensions)
    if ok then w, h = tonumber(rw) or 0, tonumber(rh) or 0 end
  end
  if h <= 0 then return 1 end
  return max(0.35, min(2.6, w / h))
end

-- Projection-density correction.  Dramatic Shape's orbit keeps vertical FOV
-- fixed and moves the camera with the world-view HEIGHT.  A tall portrait
-- viewport therefore looks through more world-space air than a short
-- landscape viewport.  Coverage alone cannot compensate for that: the
-- landscape rays intersect fewer fog bodies along a typical sightline.
-- Keep portrait as the authored reference and modestly raise per-metre
-- extinction in wide views.  This is intentionally bounded so individual
-- cards never turn into opaque sheets.
local function orientationDensityScale(Voxel3D)
  local a = viewportAspect(Voxel3D)
  if a <= 1.0 then return 1.0 end
  return min(1.55, a ^ 0.42)
end

local function fieldBasis(Voxel3D)
  local r = horizontalRight(Voxel3D)
  if not r then return nil, nil end
  local f = Voxel3D.lookFlat
  if not f then f = { -r[3], 0, r[1] } end
  local fl = sqrt(f[1] * f[1] + f[3] * f[3])
  if fl < 1e-6 then return nil, nil end
  return r, { f[1] / fl, 0, f[3] / fl }
end

-- Iterate only cells inside a camera-oriented rectangle. Landscape widens the
-- rectangle along the camera-right axis in direct proportion to the viewport
-- aspect. The depth span is unchanged, so the extra geometry pays only for
-- world the wider screen can actually reveal.
local function eachWeatherCell(Voxel3D, cell, baseRadius, fn)
  local focus = Voxel3D.focus
  if not focus then return end
  local wide = max(1.0, viewportAspect(Voxel3D))
  local ix0, iz0 = floor(focus[1] / cell), floor(focus[3] / cell)

  -- Portrait/square preserves A6's exact authored neighbourhood. That makes
  -- the portrait look the calibration target instead of thickening it while
  -- trying to repair landscape.
  if wide <= 1.001 then
    for iz = iz0 - baseRadius, iz0 + baseRadius do
      for ix = ix0 - baseRadius, ix0 + baseRadius do fn(ix, iz) end
    end
    return
  end

  local right, forward = fieldBasis(Voxel3D)
  if not (right and forward) then return end
  local half = (baseRadius + 0.5) * cell
  local sideSpan = half * wide
  local depthSpan = half
  -- An oriented rectangle can project onto both world axes; their span sum is
  -- a conservative bounding square. We filter it immediately below, so the
  -- GPU still receives only the cells the widened frustum can reveal.
  local bound = math.ceil((sideSpan + depthSpan) / cell) + 1
  for iz = iz0 - bound, iz0 + bound do
    for ix = ix0 - bound, ix0 + bound do
      local wx, wz = (ix + 0.5) * cell, (iz + 0.5) * cell
      local dx, dz = wx - focus[1], wz - focus[3]
      local side = dx * right[1] + dz * right[3]
      local depth = dx * forward[1] + dz * forward[3]
      if abs(side) <= sideSpan and abs(depth) <= depthSpan then fn(ix, iz) end
    end
  end
end

local function pushQuad(indices, q)
  local b = q * 4
  indices[#indices + 1] = b + 1
  indices[#indices + 1] = b + 2
  indices[#indices + 1] = b + 3
  indices[#indices + 1] = b + 1
  indices[#indices + 1] = b + 3
  indices[#indices + 1] = b + 4
end

local function settingLevel()
  local s = CinematicAtmos.atmosphereSetting:get()
  if s == "off" then return 0 end
  -- LOW preserves the complete weather model with fewer atmospheric volumes;
  -- FULL is the production visual baseline used throughout development.
  return s == "full" and 1.0 or 0.78
end

local function hourColors()
  local forcedNight = false
  pcall(function()
    if package.loaded and package.loaded._WX_NIGHT then forcedNight = true end
    if rawget(_G, "V") and V._WX_NIGHT then forcedNight = true end
  end)
  if forcedNight then
    return { 0.02, 0.025, 0.05 }, { 0, 0, 0 }
  end
  local mix = DayNight.mix(DayNight.time())
  local fog = { 0, 0, 0 }
  local ray = { 0, 0, 0 }
  local weight = 0
  for name, w in pairs(mix) do
    local p = ForestAtmos.RAMP[name] or ForestAtmos.RAMP.day
    fog[1] = fog[1] + p.fog[1] * w
    fog[2] = fog[2] + p.fog[2] * w
    fog[3] = fog[3] + p.fog[3] * w
    ray[1] = ray[1] + p.ray[1] * w
    ray[2] = ray[2] + p.ray[2] * w
    ray[3] = ray[3] + p.ray[3] * w
    weight = weight + w
  end
  if weight <= 0 then
    fog, ray = { 0.78, 0.86, 0.76 }, { 1.0, 0.93, 0.72 }
  end
  return fog, ray
end

-- The scene shader uses this as its far-distance atmospheric extinction.
-- The geometry below supplies the visible body of the mist; this very light
-- haze merely joins the puffs together in depth so they do not read as cards.
function CinematicAtmos.frame(map, outdoor)
  -- Refresh Weather FX night flag from TimeOfDay each atmos frame (not only Sky.paint).
  pcall(function()
    local TOD
    pcall(function()
      if type(V) == "table" and V.require then TOD = V.require("TimeOfDay") end
    end)
    if not TOD then
      local ok, m = pcall(require, "TimeOfDay")
      if ok then TOD = m end
    end
    local night = false
    if TOD then
      if TOD.pin == "NITE" or TOD.pin == "NIGHT" or TOD.tod == "NITE" or TOD.tod == "NIGHT" then night = true end
      if TOD.isNight and TOD.isNight() then night = true end
      if type(TOD.hour) == "number" then
        local h = TOD.hour % 24
        if h >= 20 or h < 5 then night = true end
      end
    end
    if DayNight and DayNight.isNight and DayNight.isNight() then night = true end
    package.loaded._WX_NIGHT = night
    if rawget(_G, "V") then V._WX_NIGHT = night end
  end)

  local level = settingLevel()
  local canopy = DayNight.isCanopy(map)
  if level <= 0 or not (outdoor or canopy) then return nil end
  local fogColor, rayColor = hourColors()
  local weather, weatherKey = weatherProfile()
  if CinematicAtmos.questSkyFallback then
    -- Cloud geometry, sky tint and precipitation see the same moving front.
    weather = questFrontProfile(weather)
    -- Quest weather-frame extensions must never mutate shared preset tables.
    local copy = {}
    for k, v in pairs(weather) do copy[k] = v end
    weather = copy
  end
  local lightning = lightningFlashFor(weather, ForestAtmos.time)
  if lightning > 0.001 then
    fogColor = mixColor(fogColor, { 0.84, 0.91, 1.00 }, min(0.72, lightning * 0.62))
    rayColor = mixColor(rayColor, { 0.90, 0.95, 1.00 }, min(0.80, lightning * 0.72))
  end
  -- Sand / dust: match grain particle colors; wind drifts to screen-right.
  local wxId = tostring(snowState.wxId or ""):upper()
  local mistWind = { 8.8, -5.4 }
  if wxId == "SANDSTORM" then
    fogColor = { 0.85, 0.72, 0.48 }   -- sand grain tan
    mistWind = { 14.0, 0.0 }          -- rightward (same as sand streaks)
  elseif wxId == "DUSTSTORM" then
    fogColor = { 0.78, 0.66, 0.46 }   -- dustier brown (same family as sand grains)
    mistWind = { 14.0, 0.0 }
  elseif wxId == "ASHFALL" then
    fogColor = { 0.42, 0.42, 0.40 }   -- ash haze (gray)
    mistWind = { 3.5, 2.0 }           -- soft scatter, slight fall drift
  end

  -- WorldPrecip grain / ground-snow drivers from Weather FX weather id
  weather.sandIntensity = weather.sandIntensity or 0
  weather.ashIntensity = weather.ashIntensity or 0
  weather.debrisIntensity = weather.debrisIntensity or 0
  weather.snowIntensity = weather.snowIntensity or 0
  weather.snowWind = weather.snowWind or weather.rainWind or 1
  weather.snowCover = weather.snowCover or 0
  weather.wxId = wxId
  -- Drive 3D falling snow the same way sand/ash are driven: from WX id.
  if wxIsSnowy(wxId) then
    local target = snowTargetFor(wxId)
    if target > 0 then
      weather.snowIntensity = max(tonumber(weather.snowIntensity) or 0, target)
    end
    if wxId == "BLIZZARD" or wxId == "THUNDERSNOW" then
      weather.snowWind = max(tonumber(weather.snowWind) or 0, 1.35)
    elseif wxId == "SNOW_LIGHT" or wxId == "SNOW" then
      weather.snowWind = max(tonumber(weather.snowWind) or 0, 0.65)
    end
  end
  if wxId == "SANDSTORM" then
    weather.sandIntensity = max(weather.sandIntensity or 0, 1.45)
  elseif wxId == "DUSTSTORM" then
    weather.sandIntensity = max(weather.sandIntensity or 0, 1.20)
  elseif wxId == "ASHFALL" then
    weather.ashIntensity = max(weather.ashIntensity or 0, 1.10)
  elseif wxId == "GALE" or wxId == "STRONG_WINDS" or wxId == "BRAWL_WIND" or wxId == "FLOCKSTORM" then
    weather.debrisIntensity = max(weather.debrisIntensity or 0, 1.15)
  elseif wxId == "DRAGONSTORM" then
    weather.sandIntensity = max(weather.sandIntensity or 0, 0.55)
    weather.debrisIntensity = max(weather.debrisIntensity or 0, 0.45)
    weather.snowIntensity = max(tonumber(weather.snowIntensity) or 0, 1.8)
  end
  -- Menu dials: SAND / DUST / FOG INTENSITY scale particles + fog dens.
  pcall(function()
    local S = V.require("Settings")
    if wxId == "SANDSTORM" and S.sandIntensity then
      local m = S.sandIntensity() or 1
      if m <= 0 then weather.sandIntensity = 0
      else weather.sandIntensity = (weather.sandIntensity or 0) * m end
    elseif wxId == "DUSTSTORM" and S.dustIntensity then
      local m = S.dustIntensity() or 1
      if m <= 0 then weather.sandIntensity = 0
      else weather.sandIntensity = (weather.sandIntensity or 0) * m end
    end
    if S.fogIntensity then
      local fm = S.fogIntensity() or 1
      if S.fogOff and S.fogOff() then fm = 0 end
      if fm <= 0 then
        weather.fog = 0
      else
        weather.fog = (weather.fog or 1) * fm
      end
    end
  end)
  if (tonumber(weather.snowIntensity) or 0) > 0.05 then
    weather.snowCover = max(weather.snowCover or 0, min(1.0, (weather.snowIntensity or 0) * 0.35))
  end

  local dens, start, heightK
  if canopy then
    -- Keep only a light extinction bed. The visible weather now comes from
    -- the animated world-space mist volumes below, not a static screen haze.
    dens, start, heightK = 0.00855 * level, 32, 0.042
  else
    -- Stronger long-range extinction; FOG INTENSITY / sand-dust haze scale dens.
    dens, start, heightK = 0.011 * level * (weather.fog or 1.0), 22, 0.045
  end
  -- Sand/dust intensity: 500% ≈ 25% remaining visibility (heavy haze, not darken).
  if wxId == "SANDSTORM" or wxId == "DUSTSTORM" then
    local haze = 0.15  -- baseline
    pcall(function()
      local S = V.require("Settings")
      if wxId == "SANDSTORM" and S.sandHaze then haze = S.sandHaze()
      elseif wxId == "DUSTSTORM" and S.dustHaze then haze = S.dustHaze()
      end
    end)
    -- dens scales hard with haze so distant scene washes out to ~25% at max.
    dens = dens * (0.35 + haze * 8.5)
    start = max(6, start - haze * 14)
    heightK = heightK * (1.0 + haze * 1.8)
  end
  return {
    level = level,
    canopy = canopy,
    fogColor = fogColor,
    rayColor = rayColor,
    mistWind = mistWind,
    wxId = wxId,
    weather = weather,
    weatherKey = weatherKey,
    lightning = lightning,
    lightIntensity = (function()
      local li = lightScale() * (weather.rays or 1.0)
      -- Hard stop: Weather FX night flag (set from Sky.paint / TIME pin).
      local night = false
      pcall(function()
        if package.loaded and package.loaded._WX_NIGHT then night = true end
        if rawget(_G, "V") and V._WX_NIGHT then night = true end
      end)
      if night then return 0 end
      -- Host night / mix / TOD pin fallbacks.
      pcall(function()
        if DayNight and DayNight.isNight and DayNight.isNight() then night = true end
      end)
      if not night then
        pcall(function()
          local mix = DayNight and DayNight.mix and DayNight.mix(DayNight.time())
          if type(mix) == "table" and (mix.night or 0) + (mix.nite or 0) > 0.55 then night = true end
        end)
      end
      if not night then
        pcall(function()
          local TOD = package.loaded and package.loaded.TimeOfDay
          if not TOD then
            local ok, m = pcall(function() return require("TimeOfDay") end)
            -- V.require path used by host mods:
            if not ok then return end
            TOD = m
          end
        end)
      end
      if not night then
        pcall(function()
          -- Weather FX TimeOfDay (OPTIONS TIME pin / phase)
          local ok, V = pcall(function() return rawget(_G, "V") end)
          local TOD
          if type(V) == "table" and V.require then
            local o2, m = pcall(V.require, "TimeOfDay")
            if o2 then TOD = m end
          end
          if not TOD then
            local o3, m = pcall(function() return require("TimeOfDay") end)
            if o3 then TOD = m end
          end
          if TOD then
            if TOD.pin == "NITE" or TOD.pin == "NIGHT" then night = true end
            if TOD.tod == "NITE" or TOD.tod == "NIGHT" then night = true end
            if TOD.isNight and TOD.isNight() then night = true end
            if type(TOD.hour) == "number" then
              local h = TOD.hour % 24
              if h >= 20 or h < 5 then night = true end
            end
          end
        end)
      end
      if night then return 0 end
      return li
    end)(),
    -- `startFromFocus` is consumed by Voxel3D.beginScene.  A fixed camera-
    -- distance start made portrait much hazier because the orbit physically
    -- backs away as the viewport gets taller.  Anchoring the extinction bed
    -- to the focus plane makes orientation change framing, not weather.
    fog = { color = fogColor, density = dens, start = start, heightK = heightK,
            startFromFocus = canopy and -12 or -4 },
    -- Lightning is diffuse sky illumination, so it temporarily fills cloud
    -- shadows instead of merely multiplying already-dark surfaces brighter.
    cloudShadow = (canopy and 0.055 or 0.13) * level * (weather.shadow or 1.0)
                  * (1.0 - min(0.72, lightning * 0.72)),
    wind = { 0.021, -0.014 },
    mistWind = { 8.8, -5.4 },
    time = ForestAtmos.time,
  }
end

-- ---------- reflective rain puddles
--
-- W7.5: dedicated mirrored-camera planar reflections.  W7.1/W7.2 proved the
-- puddle geometry itself was fine but the phone did not contribute usable
-- readable-depth SSR, leaving only the grey/sky fallback visible.  The new
-- path copies the fully rendered scene COLOUR (no depth sampling) immediately
-- before the puddles draw, then maps a vertically inverted, perspective-aware
-- window of that real scene onto each horizontal puddle.  Buildings, trees,
-- characters and sky therefore produce recognisable moving reflection detail
-- on every renderer that can sample an ordinary Canvas -- the same capability
-- already used throughout Dramatic Shape.
--
-- Puddles remain map-wide and depth-tested by hardware.  Rain perturbs the
-- reflection window slightly; after rain it settles into a clearer mirror.
-- The old procedural sky is retained only as a fallback outside the captured
-- frame and as a very faint base so reflection failure can never erase the
-- puddle geometry entirely.
local PUDDLE_BASE_SHADER = [[
  varying vec2 vLocal;
  varying vec3 vWorld;
  varying float vAlpha;
  varying float vSeed;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  attribute vec4 PuddleData;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 w = vec4(vertex_position.xyz, 1.0);
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }
    vLocal = PuddleData.xy;
    vAlpha = PuddleData.z;
    vSeed = PuddleData.w;
    vWorld = w.xyz;
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform vec3 eye;
  uniform vec3 skyTop;
  uniform vec3 skyMid;
  uniform vec3 skyHaze;
  uniform vec3 bodyDir;
  uniform vec3 bodyColor;
  uniform float bodyStrength;
  uniform float cloudCover;
  uniform float rainAmount;
  uniform float flashAmount;
  uniform float wetness;
  uniform float time;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float scale = mix(0.06, 1.0, pow(clamp(wetness, 0.0, 1.0), 0.63));
    vec2 local = vLocal / max(scale, 0.03);
    float d = length(local);
    float warp = 0.065 * sin(local.x * 7.2 + local.y * 5.7 + vSeed * 41.0)
               + 0.040 * sin(local.x * 12.0 - local.y * 8.0 + vSeed * 19.0);
    float edge = 1.0 - smoothstep(0.82 + warp, 1.03 + warp, d);
    if (edge <= 0.002) discard;

    vec3 V = normalize(eye - vWorld);
    vec3 R = reflect(-V, vec3(0.0, 1.0, 0.0));
    float elev = clamp(R.y, 0.0, 1.0);
    vec3 sky = mix(skyHaze, skyMid, smoothstep(0.03, 0.46, elev));
    sky = mix(sky, skyTop, smoothstep(0.46, 0.96, elev));
    float spec = pow(max(0.0, dot(normalize(R), normalize(bodyDir))), 54.0) * bodyStrength;
    float ring = sin(d * 30.0 - time * 9.0 + vSeed * 31.0);
    sky *= 0.88 + ring * rainAmount * 0.030 * edge;
    // Stylised shallow-water colour: enough sky/gloss to read as wet, but
    // intentionally restrained so the character reflection remains legible.
    vec3 water = mix(vec3(0.34, 0.57, 0.73), sky, 0.46);
    water += bodyColor * spec * 0.20;
    water = mix(water, vec3(0.82, 0.91, 1.00), flashAmount * 0.36);
    float fresnel = 0.42 + 0.30 * pow(1.0 - max(0.0, V.y), 2.0);
    float wetAlpha = smoothstep(0.015, 0.16, wetness);
    float a = clamp(vAlpha * edge * wetAlpha * fresnel * 0.62, 0.0, 0.48);
    return vec4(water, a) * color;
  }
#endif
]]

local PUDDLE_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "PuddleData", "float", 4 },
}
local puddleBaseShaderState, puddleMesh = nil, nil
local puddleMeshKey = nil

local function puddleBaseShader()
  if puddleBaseShaderState ~= nil then return puddleBaseShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, PUDDLE_BASE_SHADER)
  puddleBaseShaderState = (ok and sh) or false
  if not ok then print("[Weather] puddle base shader refused: " .. tostring(sh)) end
  return puddleBaseShaderState or nil
end

local function flatGroundAt(map, cx, cy)
  if not (map and map.inBounds and map:inBounds(cx, cy)) then return nil end
  local shapes = TileShape.forMap(map)
  local sh = shapes and shapes[map:cellTile(cx, cy)]
  if not sh then return nil end
  if sh.art == "stair" or sh.art == "water" then return nil end
  local h = tonumber(sh.h) or 0
  -- Keep puddles on ordinary ground. Raised blocks are commonly trees,
  -- ledges/building bases; their top surfaces are not walkable wet ground.
  if abs(h) > 0.001 then return nil end
  return 0.12
end

local function mapCellDims(map)
  if not map then return 0, 0 end
  local w = tonumber(map.widthCells)
  local h = tonumber(map.heightCells)
  -- Live Gen1Recomp map objects do not consistently expose widthCells /
  -- heightCells even though the test fixtures do.  map.def is authoritative:
  -- one map block is 32 world pixels = two 16px puddle cells.
  if (not w or w <= 0) and map.def then
    local bw = tonumber(map.def.width)
    if bw and bw > 0 then w = bw * 2 end
  end
  if (not h or h <= 0) and map.def then
    local bh = tonumber(map.def.height)
    if bh and bh > 0 then h = bh * 2 end
  end
  return math.max(0, math.floor(w or 0)), math.max(0, math.floor(h or 0))
end

local function puddleWorldKey(map, neighbors)
  local out = {
    "sparse-v4-sizes",
    tostring(map and (map.id or map) or "nil"),
    tostring(select(1, mapCellDims(map))),
    tostring(select(2, mapCellDims(map))),
  }
  for _, nb in ipairs(neighbors or {}) do
    out[#out + 1] = table.concat({
      tostring(nb.map and (nb.map.id or nb.map) or "nil"),
      tostring(nb.ox or 0), tostring(nb.oy or 0),
      tostring(select(1, mapCellDims(nb.map))),
      tostring(select(2, mapCellDims(nb.map))),
    }, ":")
  end
  return table.concat(out, "|")
end

local function appendMapPuddles(verts, indices, q, map, ox, oz)
  if not map then return q end
  local mw, mh = mapCellDims(map)
  if mw <= 0 or mh <= 0 then return q end
  ox, oz = ox or 0, oz or 0
  local corners = { {-1,-1}, {1,-1}, {1,1}, {-1,1} }
  -- Sparse, non-adjacent puddles across the whole map (min 2 cells apart).
  local occupied = {}
  local function taken(cx, cz)
    return occupied[cx .. ":" .. cz]
  end
  local function mark(cx, cz)
    for dz = -2, 2 do
      for dx = -2, 2 do
        occupied[(cx + dx) .. ":" .. (cz + dz)] = true
      end
    end
  end
  for cz = 0, mh - 1 do
    for cx = 0, mw - 1 do
      local chance = hash2(cx, cz, 901)
      -- Lower density; skip if too close to an existing puddle.
      if chance < 0.055 and not taken(cx, cz) then
        local gy = flatGroundAt(map, cx, cz)
        if gy then
          mark(cx, cz)
          local seed = hash2(cx, cz, 902)
          local wx = ox + cx * 16 + 8 + (hash2(cx, cz, 903) * 2 - 1) * 3.0
          local wz = oz + cz * 16 + 8 + (hash2(cx, cz, 904) * 2 - 1) * 3.0
          local rx = (7.0 + hash2(cx, cz, 905) * 8.0) * 1.5
          local rz = rx * (0.55 + hash2(cx, cz, 906) * 0.28)
          local alpha = 0.64 + hash2(cx, cz, 907) * 0.20
          for i = 1, 4 do
            local c = corners[i]
            verts[#verts + 1] = {
              wx + c[1] * rx, gy, wz + c[2] * rz,
              c[1], c[2], alpha, seed,
            }
          end
          pushQuad(indices, q)
          q = q + 1
        end
      end
    end
  end
  return q
end

local function appendMapSmallPuddles(verts, indices, q, map, ox, oz)
  -- GALE: many tiny reflective flecks (10% of normal puddle radius).
  if not map then return q end
  local mw, mh = mapCellDims(map)
  if mw <= 0 or mh <= 0 then return q end
  ox, oz = ox or 0, oz or 0
  local corners = { {-1,-1}, {1,-1}, {1,1}, {-1,1} }
  local occupied = {}
  local function taken(cx, cz) return occupied[cx .. ":" .. cz] end
  local function mark(cx, cz)
    for dz = -1, 1 do
      for dx = -1, 1 do occupied[(cx + dx) .. ":" .. (cz + dz)] = true end
    end
  end
  for cz = 0, mh - 1 do
    for cx = 0, mw - 1 do
      local chance = hash2(cx, cz, 911)
      if chance < 0.22 and not taken(cx, cz) then
        local gy = flatGroundAt(map, cx, cz)
        if gy then
          mark(cx, cz)
          local seed = hash2(cx, cz, 912)
          local wx = ox + cx * 16 + 8 + (hash2(cx, cz, 913) * 2 - 1) * 5.0
          local wz = oz + cz * 16 + 8 + (hash2(cx, cz, 914) * 2 - 1) * 5.0
          local rx = (7.0 + hash2(cx, cz, 915) * 8.0) * 0.28
          local rz = rx * (0.55 + hash2(cx, cz, 916) * 0.28)
          local alpha = 0.55 + hash2(cx, cz, 917) * 0.30
          for i = 1, 4 do
            local c = corners[i]
            verts[#verts + 1] = {
              wx + c[1] * rx, gy, wz + c[2] * rz,
              c[1], c[2], alpha, seed,
            }
          end
          pushQuad(indices, q)
          q = q + 1
        end
      end
    end
  end
  return q
end

local function ensurePuddleMesh(map, neighbors)
  local key = puddleWorldKey(map, neighbors)
  -- GALE small puddles cycle in 2D Draw only (1s respawn). Skip static 3D mesh.
  local gale = (tostring(snowState.wxId or ""):upper() == "GALE")
  if gale then
    puddleMesh, puddleMeshKey = nil, key .. "|gale-skip"
    return nil
  end
  if puddleMesh and puddleMeshKey == key then return puddleMesh end

  local verts, indices, q = {}, {}, 0
  q = appendMapPuddles(verts, indices, q, map, 0, 0)
  for _, nb in ipairs(neighbors or {}) do
    q = appendMapPuddles(verts, indices, q, nb.map, nb.ox or 0, nb.oy or 0)
  end
  if #verts == 0 then
    puddleMesh, puddleMeshKey = nil, key
    return nil
  end

  local ok, mesh = pcall(love.graphics.newMesh, PUDDLE_FORMAT, verts, "triangles", "static")
  if not (ok and mesh) then return nil end
  pcall(mesh.setVertexMap, mesh, indices)
  puddleMesh, puddleMeshKey = mesh, key
  return puddleMesh
end

local function puddleSkyColors(frame)
  local bands = Sky.bands() or {}
  local top = bands[1] or {0.20,0.42,0.76}
  local mid = bands[max(1, floor((#bands + 1) * 0.55))] or top
  local haze = bands[#bands] or mid
  local w = frame.weather or {}
  if w.skyColor and (w.skyBlend or 0) > 0 then
    local b = min(1, max(0, w.skyBlend or 0))
    top = mixColor(top, w.skyColor, b * 0.90)
    mid = mixColor(mid, w.skyColor, b * 0.82)
    haze = mixColor(haze, w.skyColor, b * 0.72)
  end
  return top, mid, haze
end

local function sendPuddleCommon(sh, Voxel3D, frame, wetness)
  pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
  pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
  pcall(sh.send, sh, "eye", Voxel3D.eye or {0, 1, 0})
  pcall(sh.send, sh, "wetness", wetness)
  pcall(sh.send, sh, "time", ForestAtmos.time)
  local top, mid, haze = puddleSkyColors(frame)
  pcall(sh.send, sh, "skyTop", top)
  pcall(sh.send, sh, "skyMid", mid)
  pcall(sh.send, sh, "skyHaze", haze)
  -- Weather FX celestial clock (world +Y orbit) — not host DayNight.bodyAt (wrong axis).
  local moon = false
  local bdx, bdy, bdz = 0, 1, 0
  do
    local CB = wxCelestial()
    if CB and CB.bodyDir then
      local hour = nil
      pcall(function()
        local TOD = V.require("TimeOfDay")
        hour = TOD and TOD.hour
      end)
      bdx, bdy, bdz = CB.bodyDir(hour)
      if CB.bodies then
        local b = CB.bodies(hour)
        moon = b.moon.alpha > b.sun.alpha and b.moon.alpha > 0.02
      end
    else
      local th, el, isMoon = DayNight.bodyAt(DayNight.time())
      moon = isMoon and true or false
      local tr, er = math.rad(th), math.rad(max(0.5, el))
      bdx, bdy, bdz = cos(tr) * cos(er), sin(er), sin(tr) * cos(er)
    end
  end
  pcall(sh.send, sh, "bodyDir", { bdx, bdy, bdz })
  pcall(sh.send, sh, "bodyColor", moon and {0.76,0.84,1.00} or frame.rayColor)
  pcall(sh.send, sh, "bodyStrength", DayNight.strengthAt(DayNight.time()) * (moon and 0.38 or 0.82))
  pcall(sh.send, sh, "cloudCover", min(1, max(0, frame.weather.coverage or 0)))
  pcall(sh.send, sh, "rainAmount", min(1, max(0, frame.weather.rainIntensity or 0)))
  pcall(sh.send, sh, "flashAmount", min(1, max(0, frame.lightning or 0)))
end

local function drawPuddles(Voxel3D, frame, map, neighbors)
  local wetness = puddleWetnessFor(frame.weather)
  -- Snow packs hide reflective water; avoid double-drawing wet + white.
  local snow = snowState.cover or 0
  if snow > 0.35 then
    wetness = wetness * max(0.0, 1.0 - (snow - 0.35) / 0.65)
  end
  if wetness <= 0.015 then return end
  local mesh = ensurePuddleMesh(map, neighbors)
  if not mesh then return end

  local base = puddleBaseShader()
  if not base then return end
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(base) then
    sendPuddleCommon(base, Voxel3D, frame, wetness)
    pcall(love.graphics.draw, mesh)
    Voxel3D.endEffect()
  end
end

-- Ground snow pack mesh draw disabled: the shared puddle shader path produced
-- a visible pink line artifact on some hosts. Cover state still updates so a
-- dedicated snow pack pass can be restored later without redoing weather logic.
local function drawSnowPacks(Voxel3D, frame, map, neighbors, outdoor)
  return
end

-- W7.6: intentionally stylised reflections.  Android repeatedly proved that
-- scene-wide mirror techniques were either unavailable or visually unstable.
-- Instead, use the Gen-2 visual language: when Red/NPCs stand beside a puddle,
-- draw their CURRENT sprite frame as a flattened, inverted-looking ground
-- reflection extending inward from the puddle edge.  It is still 3D world
-- geometry and depth tested, but the image is simple and instantly readable.
local function puddleDescAt(map, cx, cz, ox, oz)
  if not map then return nil end
  local mw, mh = mapCellDims(map)
  if cx < 0 or cz < 0 or cx >= mw or cz >= mh then return nil end
  local chance = hash2(cx, cz, 901)
  if chance >= 0.175 then return nil end
  local gy = flatGroundAt(map, cx, cz)
  if not gy then return nil end
  ox, oz = ox or 0, oz or 0
  local seed = hash2(cx, cz, 902)
  local wx = ox + cx * 16 + 8 + (hash2(cx, cz, 903) * 2 - 1) * 4.2
  local wz = oz + cz * 16 + 8 + (hash2(cx, cz, 904) * 2 - 1) * 4.2
  local rx = 9.0 + hash2(cx, cz, 905) * 11.0
  local rz = rx * (0.58 + hash2(cx, cz, 906) * 0.30)
  return { wx=wx, wz=wz, rx=rx, rz=rz, y=gy, seed=seed }
end

local function nearestPuddle(map, neighbors, wx, wz)
  local best, bestScore = nil, 1e9
  local function scan(one, ox, oz)
    if not one then return end
    ox, oz = ox or 0, oz or 0
    local lx, lz = wx - ox, wz - oz
    local cx0, cz0 = floor(lx / 16), floor(lz / 16)
    for dz = -2, 2 do
      for dx = -2, 2 do
        local p = puddleDescAt(one, cx0 + dx, cz0 + dz, ox, oz)
        if p then
          local ex, ez = wx - p.wx, wz - p.wz
          local ell = sqrt((ex / p.rx)^2 + (ez / p.rz)^2)
          -- Search generously around the feet so we can find the nearest
          -- candidate cheaply. W7.7 applies the strict inside-water test at
          -- draw time; merely being beside this candidate is not sufficient.
          if ell <= 1.42 and ell < bestScore then
            best, bestScore = p, ell
          end
        end
      end
    end
  end
  scan(map, 0, 0)
  for _, nb in ipairs(neighbors or {}) do scan(nb.map, nb.ox or 0, nb.oy or 0) end
  return best, bestScore
end

local function reflectionFrameFor(def, facing, phase, flip)
  local SR = require("src.render.SpriteRenderer")
  local frame, mirror = 0, false
  if (def.frames or 1) > 1 then
    frame = (def.walker and phase == 1) and SR.WALK[facing] or SR.STAND[facing]
    mirror = facing == "right"
      or ((facing == "down" or facing == "up") and phase == 1 and flip)
  end
  return frame, mirror
end

local function puddlesNearReflection(map, neighbors, wx, wz, radius)
  local out = {}
  radius = radius or 42.0
  local function scan(one, ox, oz)
    if not one then return end
    ox, oz = ox or 0, oz or 0
    local lx, lz = wx - ox, wz - oz
    local cx0, cz0 = floor(lx / 16), floor(lz / 16)
    local cells = max(2, math.ceil((radius + 22) / 16))
    for dz = -cells, cells do
      for dx = -cells, cells do
        local p = puddleDescAt(one, cx0 + dx, cz0 + dz, ox, oz)
        if p then
          local ddx, ddz = p.wx - wx, p.wz - wz
          local reach = radius + max(p.rx, p.rz)
          if ddx*ddx + ddz*ddz <= reach*reach then
            out[#out + 1] = p
          end
        end
      end
    end
  end
  scan(map, 0, 0)
  for _, nb in ipairs(neighbors or {}) do scan(nb.map, nb.ox or 0, nb.oy or 0) end
  return out
end

-- W7.8: continuous under-map reflection + puddle-as-mask.
--
-- The reflected card exists conceptually for EVERY posed character on EVERY
-- frame.  No "touch puddle" test turns it on.  We project the current sprite
-- frame from the character's feet along the camera-ground mirror direction,
-- then draw that same card once through each nearby puddle mask.  The scene
-- shader discards every fragment outside the puddle's authored water shape.
--
-- This is the important visual difference from W7.6/W7.7: approaching a
-- puddle does not cross an activation threshold.  The water progressively
-- reveals whichever part of the already-existing reflection lies beneath it,
-- exactly like cutting holes in the map to a reflection layer underneath.
local function drawSpriteReflections(Voxel3D, frame, map, neighbors, posed)
  if not (posed and Voxel3D.eye) then return end
  local wetness = puddleWetnessFor(frame.weather)
  if wetness <= 0.04 then return end

  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  pcall(love.graphics.setColor, 0.70, 0.86, 0.94, 0.54 * min(1, wetness * 1.18))
  Voxel3D.glass(false)
  Voxel3D.seams(false)

  for _, p in ipairs(posed) do
    if p.sprite and p.sprite.def and (p.lift or 0) < 1.0 then
      local footX, footZ = p.px + 8, p.py + 8
      local dirX, dirZ = (Voxel3D.eye[1] or footX) - footX,
                         (Voxel3D.eye[3] or footZ) - footZ
      local dl = sqrt(dirX*dirX + dirZ*dirZ)
      if dl > 0.001 then
        dirX, dirZ = dirX / dl, dirZ / dl

        local def = p.sprite.def
        local frameIndex, mirror = reflectionFrameFor(def, p.facing or "down", p.phase or 0, p.flip)
        local mesh = SpriteBillboards.mesh(def, frameIndex)
        if mesh then
          local tex = p.sprite:resolveImage()
          if p.colors and not def.trueColor then
            tex = TerrainAtlas.forSprite(def.image, p.colors) or tex
          end

          -- One persistent 16x16 ground reflection, hinged at the feet and
          -- extending toward the camera.  It is deliberately NOT resized to
          -- whichever puddle happens to reveal it; that was the old telltale
          -- attachment behaviour.  Water only masks this fixed projection.
          local yaw = math.atan2(dirX, dirZ)
          local puddles = puddlesNearReflection(map, neighbors, footX, footZ, 23.0)
          for _, puddle in ipairs(puddles) do
            -- Cheap overlap rejection before asking the GPU to apply the
            -- precise irregular ellipse.  The reflected card occupies a
            -- short capsule from the feet toward the camera.
            local midX, midZ = footX + dirX * 8, footZ + dirZ * 8
            local dx, dz = puddle.wx - midX, puddle.wz - midZ
            local reach = max(puddle.rx, puddle.rz) + 12.0
            if dx*dx + dz*dz <= reach*reach then
              local m = Mat4.translate(footX, puddle.y + 0.055, footZ)
              m = Mat4.mul(m, Mat4.rotateY(yaw))
              m = Mat4.mul(m, Mat4.rotateX(math.pi / 2))
              if mirror then m = Mat4.mul(m, Mat4.scale(-1, 1, 1)) end
              m = Mat4.mul(m, Mat4.translate(-8, 0, 0))

              Voxel3D.puddleMask(puddle, wetness)
              Voxel3D.flatten({0.47, 0.68, 0.78}, 0.30)
              Voxel3D.draw(mesh, tex, m, 0)
              Voxel3D.flatten(nil)
              Voxel3D.puddleMask(nil)
            end
          end
        end
      end
    end
  end

  Voxel3D.puddleMask(nil)
  Voxel3D.seams(true)
  Voxel3D.glass(true)
  pcall(love.graphics.setColor, 1, 1, 1, 1)
end

-- ---------- ground mist

local MIST_SHADER = [[
  varying vec2 vLocal;
  varying float vPhase;
  varying float vAlpha;
  varying vec2 vWorld;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  uniform vec3 axisR;
  uniform vec2 mistWind;
  uniform float time;
  attribute vec4 MistData;   // local x, local y, phase, alpha
  attribute vec4 MistShape;  // half width, height, drift, rate
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    float ph = MistData.z;
    float rt = MistShape.w;
    vec3 base = vertex_position.xyz;
    float t = time * rt + ph;
    // Large, slow horizontal excursions make the bodies visibly roll across
    // the world. Two incommensurate motions avoid a repetitive pendulum read.
    float roll1 = sin(t * 0.71) * MistShape.z;
    float roll2 = sin(t * 0.29 + ph * 1.63) * MistShape.z * 0.46;
    base.x += roll1 + roll2 * 0.62;
    base.z += cos(t * 0.53 + ph * 1.91) * MistShape.z * 0.78
            + roll2 * 0.44;
    base.x += mistWind.x * sin(time * 0.055 + ph) * 2.2;
    base.z += mistWind.y * sin(time * 0.047 + ph * 0.77) * 2.2;
    base.y += sin(t * 0.37 + ph) * 2.2;
    vLocal = MistData.xy;
    vPhase = ph;
    vAlpha = MistData.w;
    vec4 w = vec4(base + axisR * (MistData.x * MistShape.x)
                       + vec3(0.0, MistData.y * MistShape.y, 0.0), 1.0);
    vWorld = w.xz;
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform vec3 mistColor;
  uniform vec2 mistWind;
  uniform float alphaScale;
  uniform float time;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float sx = vLocal.x;
    float x = abs(sx);
    float y = clamp(vLocal.y, 0.0, 1.0);
    float floorFade = smoothstep(0.0, 0.06, y);

    // The A5 field moved internally but kept a largely fixed outer silhouette,
    // which the eye reads as haze. A6 makes the silhouette itself travel and
    // billow. The top of every bank is a set of waves moving at different
    // speeds, so shoulders rise, fold and disappear while the player stands
    // still instead of the whole translucent body merely sliding sideways.
    vec2 adv = vWorld + mistWind * time;
    float travel = adv.x * 0.022 + adv.y * 0.014
                   - time * 0.34 + vPhase;
    float crest = 0.53
      + 0.13 * sin(travel)
      + 0.075 * sin(travel * 1.83 + time * 0.16 + vPhase * 0.7)
      + 0.055 * sin(sx * 8.0 - time * 0.29 + vPhase * 1.9);
    float crown = 1.0 - smoothstep(crest - 0.10, crest + 0.11, y);
    float sideEdge = 0.86 + 0.08 * sin(y * 5.0 + time * 0.23 + vPhase);
    float side = 1.0 - smoothstep(sideEdge - 0.30, sideEdge, x);

    // Three advected scales keep the interior turbulent rather than pulsing as
    // one sheet. Their time terms are deliberately much faster than A5: on a
    // stationary tree edge the density should be visibly different within a
    // few seconds, not merely detectable over half a minute.
    float n1 = 0.5 + 0.5 * sin(adv.x * 0.030 + adv.y * 0.019
                               - time * 0.29 + vPhase);
    float n2 = 0.5 + 0.5 * sin(adv.x * 0.061 - adv.y * 0.044
                               + time * 0.21 + vPhase * 2.37);
    float n3 = 0.5 + 0.5 * sin((adv.x + adv.y) * 0.016
                               - time * 0.17 + vPhase * 0.53);
    float n = n1 * 0.42 + n2 * 0.34 + n3 * 0.24;
    float body = 0.24 + 0.76 * smoothstep(0.34, 0.67, n);

    // A travelling corkscrew pattern hollows and refills parts of the bank.
    // Because its phase couples horizontal position to height, bright lobes
    // appear to curl upward and over darker pockets: the visual cue missing
    // from A5's otherwise-volumetric fog.
    float curlPhase = sx * 7.2 + y * 9.0 - time * 0.52 + vPhase * 1.41;
    float curlA = 0.5 + 0.5 * sin(curlPhase + sin(travel * 0.73) * 1.35);
    float curlB = 0.5 + 0.5 * sin(sx * 11.0 - y * 6.5
                                  + time * 0.37 + vPhase * 2.1);
    float curl = 0.50 + 0.50 * smoothstep(0.28, 0.78,
                                          curlA * 0.64 + curlB * 0.36);

    float a = vAlpha * alphaScale * side * floorFade * crown * body * curl;
    return vec4(mistColor, a) * color;
  }
#endif
]]

local MIST_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "MistData", "float", 4 },
  { "MistShape", "float", 4 },
}

local mistShaderState, mistMesh = nil, nil

local function mistShader()
  if mistShaderState ~= nil then return mistShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, MIST_SHADER)
  mistShaderState = (ok and sh) or false
  if not ok then print("[Weather] cinematic mist shader refused: " .. tostring(sh)) end
  return mistShaderState or nil
end

local function buildMistVertices(Voxel3D, frame)
  local f = Voxel3D.focus
  if not f then return nil, nil end
  local level = frame.level
  local cell = 66
  local radius = level > 0.9 and 4 or 3
  local verts, indices, q = {}, {}, 0
  local corners = { { -1, 0 }, { 1, 0 }, { 1, 1 }, { -1, 1 } }
  eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
    local h = hash2(ix, iz, 1)
    -- Density per WORLD CELL is unchanged from A6. Landscape gets more cells
    -- because it sees more world, rather than making every card more opaque.
    local count = (level > 0.9 and h > 0.35) and 2 or 1
    for k = 1, count do
      local a = hash2(ix, iz, 10 + k)
      local b = hash2(ix, iz, 20 + k)
      local c = hash2(ix, iz, 30 + k)
      local d = hash2(ix, iz, 40 + k)
      local cx = (ix + 0.12 + a * 0.76) * cell
      local cz = (iz + 0.12 + b * 0.76) * cell
      local cy = 0.5 + c * 5.0
      local halfW = 46 + d * 62
      local height = 18 + hash2(ix, iz, 50 + k) * 22
      local alpha = (0.081 + hash2(ix, iz, 60 + k) * 0.071) * level
      local phase = hash2(ix, iz, 70 + k) * PI2
      local drift = 13 + hash2(ix, iz, 80 + k) * 18
      local rate = 0.26 + hash2(ix, iz, 90 + k) * 0.22
      for ci = 1, 4 do
        local co = corners[ci]
        verts[#verts + 1] = { cx, cy, cz,
                              co[1], co[2], phase, alpha,
                              halfW, height, drift, rate }
      end
      pushQuad(indices, q)
      q = q + 1
    end
  end)
  return verts, indices
end

local function drawMist(Voxel3D, frame)
  local sh = mistShader()
  local axisR = horizontalRight(Voxel3D)
  if not (sh and axisR) then return end
  local verts, indices = buildMistVertices(Voxel3D, frame)
  if not (verts and indices and #verts > 0) then return end
  if not mistMesh then
    local ok, mesh = pcall(love.graphics.newMesh, MIST_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    mistMesh = mesh
  else
    local ok = pcall(mistMesh.setVertices, mistMesh, verts)
    if not ok then mistMesh = nil return drawMist(Voxel3D, frame) end
  end
  pcall(mistMesh.setVertexMap, mistMesh, indices)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
    pcall(sh.send, sh, "axisR", axisR)
    pcall(sh.send, sh, "mistWind", frame.mistWind or { 8.8, -5.4 })
    -- Geometry coverage now follows the frustum. Keep only a very small
    -- projection correction; cumulative density comes from extra world-space
    -- fog bodies, not stronger alpha in landscape.
    local projectionScale = orientationDensityScale(Voxel3D)
    pcall(sh.send, sh, "alphaScale", projectionScale)
    pcall(sh.send, sh, "time", ForestAtmos.time)
    local c = frame.fogColor or { 0.86, 0.89, 0.93 }
    local wid = tostring(frame.wxId or ""):upper()
    local mr, mg, mb
    if wid == "SANDSTORM" or wid == "DUSTSTORM" then
      mr, mg, mb = c[1], c[2], c[3]  -- exact particle match; opacity from alpha
    else
      mr = min(1, c[1] * 0.76 + 0.24)
      mg = min(1, c[2] * 0.76 + 0.24)
      mb = min(1, c[3] * 0.76 + 0.24)
    end
    pcall(sh.send, sh, "mistColor", { mr, mg, mb })
    pcall(love.graphics.draw, mistMesh)
    Voxel3D.endEffect()
  end
end

-- ---------- rolling crest billows
--
-- The broad mist cards above provide the body of the weather. These smaller
-- puffs are the motion cue: they continually travel through that body, rise,
-- curl over and dissolve downstream. Hardware depth testing keeps every puff
-- in the world, so the rolling edge can disappear behind a tree and reappear
-- on the other side instead of behaving like a screen-space particle layer.

local ROLL_SHADER = [[
  varying vec2 vLocal;
  varying float vAlpha;
  varying float vLife;
  varying float vPhase;
  varying float vCycle;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  uniform vec3 axisR;
  uniform vec3 axisU;
  uniform vec2 windDir;
  uniform float time;
  attribute vec4 RollData;   // local x, local y, phase 0..1, alpha
  attribute vec4 RollShape;  // half width, half height, travel, rate
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    float ph = RollData.z;
    float cyc = fract(time * RollShape.w + ph);
    float theta = cyc * 6.2831853;
    float along = (cyc * 2.0 - 1.0) * RollShape.z;
    float sideways = sin(theta + ph * 9.7) * RollShape.z * 0.17;
    vec2 perp = vec2(-windDir.y, windDir.x);
    vec3 base = vertex_position.xyz;
    base.x += windDir.x * along + perp.x * sideways;
    base.z += windDir.y * along + perp.y * sideways;
    // A cycloidal rise/fall gives the crest an actual turnover trajectory:
    // it grows out of the bank, climbs, folds forward and sinks back into it.
    float lift = 0.5 - 0.5 * cos(theta);
    base.y += 0.8 + lift * RollShape.y * 0.66
              + sin(theta * 2.0 + ph * 13.0) * 1.25;
    float breathe = 0.88 + 0.18 * sin(theta - 0.8 + ph * 5.0);
    vLocal = RollData.xy;
    vPhase = ph * 6.2831853;
    vCycle = cyc;
    vAlpha = RollData.w;
    vLife = smoothstep(0.00, 0.13, cyc) * (1.0 - smoothstep(0.78, 1.0, cyc));

    // Tip the asymmetric billow as it climbs and folds. Because the puff is
    // made of offset lobes rather than a circle, this rotation reads as the
    // fog rolling over itself instead of merely translating through space.
    float turn = sin(theta - 1.05) * 0.48
                 + sin(theta * 0.5 + ph * 11.0) * 0.11;
    float ct = cos(turn), st = sin(turn);
    vec2 lp = vec2(RollData.x * RollShape.x * breathe,
                   RollData.y * RollShape.y * breathe);
    vec2 rp = vec2(lp.x * ct - lp.y * st, lp.x * st + lp.y * ct);
    vec3 p = base + axisR * rp.x + axisU * rp.y;
    vec4 w = vec4(p, 1.0);
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform vec3 mistColor;
  uniform float alphaScale;
  uniform float time;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec2 p = vLocal;
    // The internal lobe field turns with the crest too. It is intentionally
    // less than a full spin: natural fog folds/curls rather than pinwheeling.
    float localTurn = sin(vCycle * 6.2831853 - 1.0) * 0.38
                      + sin(vPhase) * 0.08;
    float lc = cos(localTurn), ls = sin(localTurn);
    p = vec2(p.x * lc - p.y * ls, p.x * ls + p.y * lc);
    // Several soft lobes inside one quad make a billow rather than a circle.
    float d0 = length(vec2(p.x * 0.90, p.y * 1.05));
    float d1 = length(vec2((p.x + 0.34) * 1.32, (p.y - 0.05) * 1.42));
    float d2 = length(vec2((p.x - 0.31) * 1.28, (p.y + 0.08) * 1.36));
    float l0 = 1.0 - smoothstep(0.47, 1.00, d0);
    float l1 = 1.0 - smoothstep(0.42, 0.98, d1);
    float l2 = 1.0 - smoothstep(0.44, 1.00, d2);
    float body = max(l0, max(l1 * 0.88, l2 * 0.84));
    // Internal curling makes the puff deform while its centre follows the
    // rolling trajectory, so it does not look like a sprite simply drifting.
    float curl = 0.70 + 0.30 * sin(p.x * 5.8 - p.y * 7.6
                                  - time * 0.61 + vPhase);
    float a = vAlpha * alphaScale * vLife * body * (0.74 + 0.26 * curl);
    return vec4(mistColor, a) * color;
  }
#endif
]]

local ROLL_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "RollData", "float", 4 },
  { "RollShape", "float", 4 },
}

local rollShaderState, rollMesh = nil, nil

local function rollShader()
  if rollShaderState ~= nil then return rollShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, ROLL_SHADER)
  rollShaderState = (ok and sh) or false
  if not ok then print("[Weather] rolling fog shader refused: " .. tostring(sh)) end
  return rollShaderState or nil
end

local function buildRollVertices(Voxel3D, frame)
  local f = Voxel3D.focus
  if not f then return nil, nil end
  local cell = 72
  local radius = frame.level > 0.9 and 4 or 3
  local verts, indices, q = {}, {}, 0
  local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
  eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
    local gate = hash2(ix, iz, 401)
    if gate > 0.16 then
      local count = frame.level > 0.9 and 3 or 2
      for k = 1, count do
        local cx = (ix + 0.16 + hash2(ix, iz, 410 + k) * 0.68) * cell
        local cz = (iz + 0.16 + hash2(ix, iz, 420 + k) * 0.68) * cell
        local cy = 2.3 + hash2(ix, iz, 430 + k) * 4.4
        local hw = 23 + hash2(ix, iz, 440 + k) * 32
        local hh = 10 + hash2(ix, iz, 450 + k) * 14
        local travel = 30 + hash2(ix, iz, 460 + k) * 34
        local rate = 0.030 + hash2(ix, iz, 470 + k) * 0.024
        local phase = hash2(ix, iz, 480 + k)
        local alpha = (0.046 + hash2(ix, iz, 490 + k) * 0.040) * frame.level
        for ci = 1, 4 do
          local co = corners[ci]
          verts[#verts + 1] = { cx, cy, cz,
                                co[1], co[2], phase, alpha,
                                hw, hh, travel, rate }
        end
        pushQuad(indices, q)
        q = q + 1
      end
    end
  end)
  return verts, indices
end

local function drawRollFog(Voxel3D, frame)
  local sh = rollShader()
  local axisR, axisU = billboardAxes(Voxel3D)
  if not (sh and axisR and axisU) then return end
  local verts, indices = buildRollVertices(Voxel3D, frame)
  if not (verts and indices and #verts > 0) then return end
  if not rollMesh then
    local ok, mesh = pcall(love.graphics.newMesh, ROLL_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    rollMesh = mesh
  else
    local ok = pcall(rollMesh.setVertices, rollMesh, verts)
    if not ok then rollMesh = nil return drawRollFog(Voxel3D, frame) end
  end
  pcall(rollMesh.setVertexMap, rollMesh, indices)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
    pcall(sh.send, sh, "axisR", axisR)
    pcall(sh.send, sh, "axisU", axisU)
    local wx, wz = (frame.mistWind and frame.mistWind[1]) or 8.8,
                   (frame.mistWind and frame.mistWind[2]) or -5.4
    local wl = sqrt(wx * wx + wz * wz)
    if wl < 1e-5 then wx, wz, wl = 1, 0, 1 end
    pcall(sh.send, sh, "windDir", { wx / wl, wz / wl })
    pcall(sh.send, sh, "time", ForestAtmos.time)
    local projectionScale = orientationDensityScale(Voxel3D)
    pcall(sh.send, sh, "alphaScale", projectionScale)
    local c = frame.fogColor or { 0.86, 0.89, 0.93 }
    local wid = tostring(frame.wxId or ""):upper()
    local mr, mg, mb
    if wid == "SANDSTORM" or wid == "DUSTSTORM" then
      mr, mg, mb = c[1], c[2], c[3]
    else
      mr = min(1, c[1] * 0.74 + 0.26)
      mg = min(1, c[2] * 0.74 + 0.26)
      mb = min(1, c[3] * 0.74 + 0.26)
    end
    pcall(sh.send, sh, "mistColor", { mr, mg, mb })
    pcall(love.graphics.draw, rollMesh)
    Voxel3D.endEffect()
  end
end


-- ---------- ambient floating particles
--
-- Small, soft motes provide parallax and make otherwise-clear air feel alive.
-- They are ordinary depth-tested 3D billboards, not a screen overlay. Every
-- mote has its own direction, speed and lifecycle; the fade hides the wrap so
-- it appears, drifts, disappears, and later reforms elsewhere without pops.

local PARTICLE_SHADER = [[
  varying vec2 vLocal;
  varying float vAlpha;
  varying float vLife;
  varying float vWarm;
  varying float vCloud;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  uniform vec3 axisR;
  uniform vec3 axisU;
  uniform float time;
  attribute vec4 ParticleData;   // local x, local y, phase 0..1, alpha
  attribute vec4 ParticleMove;   // mote: size, range, angle, +rate
                                 // cloud: half-width, half-height, drift, -rate
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    float cloud = step(0.000001, -ParticleMove.w);
    float rate = mix(ParticleMove.w, -ParticleMove.w, cloud);
    float cyc = fract(time * rate + ParticleData.z);
    float age = cyc * 2.0 - 1.0;

    vec3 base = vertex_position.xyz;

    // Proven A9/A10 mote motion, unchanged when cloud == 0.
    float ang = ParticleMove.z;
    vec2 dir = vec2(cos(ang), sin(ang));
    vec2 perp = vec2(-dir.y, dir.x);
    float travel = age * ParticleMove.y;
    float wander = sin(time * 0.43 + ParticleData.z * 19.7 + cyc * 8.0)
                   * ParticleMove.y * 0.17;
    base.x += (dir.x * travel + perp.x * wander) * (1.0 - cloud);
    base.z += (dir.y * travel + perp.y * wander) * (1.0 - cloud);
    base.y += (sin(time * 0.31 + ParticleData.z * 23.0 + cyc * 9.0) * 2.0
              + sin(cyc * 3.14159265) * ParticleMove.y * 0.10) * (1.0 - cloud);

    // Cloud lobes ride one coherent wind lane; their own motion is deliberately
    // small and slow. A14 proved the shared particle path, but letting every
    // puff wander too far makes a cloud look like independent bubbles. Here
    // the lobe only swells, settles and shears a little while the descriptor
    // moves the whole cloud across the sky.
    float ct = time * rate + ParticleData.z * 6.2831853;
    base.x += sin(ct * 0.37 + ParticleData.z * 7.1) * ParticleMove.z * 0.42 * cloud;
    base.z += cos(ct * 0.31 + ParticleData.z * 5.3) * ParticleMove.z * 0.24 * cloud;
    base.y += sin(ct * 0.23 + ParticleData.z * 9.7) * 1.15 * cloud;

    vLocal = ParticleData.xy;
    vAlpha = ParticleData.w;
    float moteLife = smoothstep(0.02, 0.18, cyc) * (1.0 - smoothstep(0.76, 0.98, cyc));
    vLife = mix(moteLife, 1.0, cloud);
    vWarm = 0.5 + 0.5 * sin(ParticleData.z * 31.0);
    vCloud = cloud;

    float breathe = 0.86 + 0.14 * sin(time * 0.37 + ParticleData.z * 17.0);
    // Slow growth/decay gives the cloud edge a living cauliflower motion
    // without making the whole mass pulse in unison.
    float cloudBreathe = 0.945 + 0.055 * sin(time * 0.052 + ParticleData.z * 13.0);
    float sx = mix(ParticleMove.x * breathe, ParticleMove.x * cloudBreathe, cloud);
    float sy = mix(ParticleMove.x * breathe, ParticleMove.y * cloudBreathe, cloud);
    vec3 p = base + axisR * (ParticleData.x * sx)
                  + axisU * (ParticleData.y * sy);
    vec4 w = vec4(p, 1.0);

    // Ground motes bend with Dramatic Shape's globe. Sky clouds do not: they
    // are camera-frustum sky geometry, not objects attached to the terrain.
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z * (1.0 - cloud);
    }
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform vec3 particleCool;
  uniform vec3 particleWarm;
  uniform vec3 cloudCool;
  uniform vec3 cloudWarm;
  uniform vec2 cloudSun;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float d = length(vLocal);

    float moteCore = 1.0 - smoothstep(0.10, 0.92, d);
    float moteFeather = 1.0 - smoothstep(0.42, 1.0, d);
    float moteA = vAlpha * vLife * moteCore * moteFeather;
    vec3 moteC = mix(particleCool, particleWarm, vWarm * 0.42);

    // Mostly Cloudy M2: deliberately soft/ambiguous cloud lobes. The previous
    // pass made every puff readable, which produced a scalloped ceiling. Here
    // individual lobes have broad feathering and restrained vertical shading;
    // density comes from overlap, so the eye sees one cloud mass rather than
    // the primitives that construct it.
    vec2 cq = vec2(vLocal.x * 0.96, vLocal.y * 1.03);
    float qd = length(cq);
    float cloudBody = 1.0 - smoothstep(0.36, 1.0, qd);
    float cloudCore = 1.0 - smoothstep(0.10, 0.68, qd);
    float cloudA = clamp(vAlpha * cloudBody * (0.76 + cloudCore * 0.28), 0.0, 0.90);

    float top = smoothstep(-0.86, 0.90, vLocal.y);
    float underside = 0.88 + top * 0.13;
    float selfShade = 0.97 - cloudCore * (1.0 - top) * 0.035;
    vec3 cloudC = mix(cloudCool, cloudWarm, 0.34 + top * 0.31 + cloudCore * 0.035);
    cloudC *= underside * selfShade;

    vec2 sdir = cloudSun / max(length(cloudSun), 0.001);
    vec2 edir = cq / max(qd, 0.001);
    float sunSide = clamp(dot(edir, sdir), 0.0, 1.0);
    float feather = smoothstep(0.68, 0.95, qd) * cloudBody;
    float silver = feather * sunSide * smoothstep(-0.05, 0.92, vLocal.y);
    cloudC += cloudWarm * silver * 0.13;

    float a = mix(moteA, cloudA, vCloud);
    vec3 c = mix(moteC, cloudC, vCloud);
    return vec4(c, a) * color;
  }
#endif
]]

local PARTICLE_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "ParticleData", "float", 4 },
  { "ParticleMove", "float", 4 },
}

local particleShaderState, particleMesh = nil, nil

local function particleShader()
  if particleShaderState ~= nil then return particleShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, PARTICLE_SHADER)
  particleShaderState = (ok and sh) or false
  if not ok then print("[Weather] ambient particle shader refused: " .. tostring(sh)) end
  return particleShaderState or nil
end

local function buildParticleVertices(Voxel3D, frame, clouds, cloudsOnly)
  local f = Voxel3D.focus
  if not f then return nil, nil end
  local cell = 48
  local radius = frame.level > 0.9 and 4 or 3
  local density = particleDensityScale() * ((frame.weather and frame.weather.motes) or 1.0)
  local sizeScale = particleSizeScale()
  local verts, indices, q = {}, {}, 0
  local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
  if not cloudsOnly then
    eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
    -- DENSITY 1 / SCALE 8 is byte-for-byte the A9 population/size recipe.
    -- Higher density adds genuinely independent motes rather than increasing
    -- alpha, so the result remains airy instead of becoming a white veil.
    local gate = hash2(ix, iz, 601)
    if gate > 0.18 then
      local baseCount = 1
      if gate > 0.54 then baseCount = baseCount + 1 end
      if frame.level > 0.9 and gate > 0.91 then baseCount = baseCount + 1 end

      -- Stochastic rounding avoids visible whole-number jumps between cells.
      -- At density 1 this resolves to baseCount exactly, preserving A9.
      local wanted = baseCount * density
      local count = floor(wanted)
      if hash2(ix, iz, 606) < (wanted - count) then count = count + 1 end

      for k = 1, count do
        -- k=1..baseCount retains A9's original deterministic particles. Extra
        -- motes get their own salted hashes and therefore independent motion.
        local cx = (ix + 0.12 + hash2(ix, iz, 610 + k) * 0.76) * cell
        local cz = (iz + 0.12 + hash2(ix, iz, 620 + k) * 0.76) * cell
        -- Bias toward the height band occupied by Red, grass, shrubs and
        -- lower tree crowns. An occasional high mote preserves vertical depth.
        local cy = 3.0 + hash2(ix, iz, 630 + k) * 21.0
        if hash2(ix, iz, 635 + k) > 0.88 then
          cy = cy + 7.0 + hash2(ix, iz, 636 + k) * 9.0
        end
        local size = (1.65 + hash2(ix, iz, 640 + k) * 2.55) * sizeScale
        local range = 10.0 + hash2(ix, iz, 650 + k) * 22.0
        local angle = hash2(ix, iz, 660 + k) * PI2
        local life = 6.5 + hash2(ix, iz, 670 + k) * 10.5
        local rate = 1.0 / life
        local phase = hash2(ix, iz, 680 + k)
        local alpha = (0.115 + hash2(ix, iz, 690 + k) * 0.105) * frame.level
        for ci = 1, 4 do
          local co = corners[ci]
          verts[#verts + 1] = { cx, cy, cz,
                                co[1], co[2], phase, alpha,
                                size, range, angle, rate }
        end
        pushQuad(indices, q)
        q = q + 1
      end
    end
    end)
  end

  -- MOSTLY CLOUDY M2: retain the proven shared particle/cloud render path,
  -- but go back to the visual ambiguity that worked in A14/A15. Each formation
  -- has a few broad low-alpha backbone bodies plus many smaller overlapping
  -- lobes. There is NO explicit row of base puffs, so the player cannot read a
  -- repeated scalloped underside. Macro type still changes width/height, but
  -- the construction itself stays deliberately hard to parse.
  if clouds and #clouds > 0 then
    for ciCloud = 1, #clouds do
      local c = clouds[ciCloud]
      local ix, iz = c.ix, c.iz
      local spanX, spanY, spanZ = c.spanX, c.spanY, c.spanZ
      local kind = c.kind or 1
      local puffs = c.puffs or (frame.level > 0.9 and 34 or 26)

      local deckBlend = c.deckBlend or (c.closedDeck and 1.0 or 0.0)
      local closedDeck = deckBlend >= 0.985
      local backboneCount = max(3, min(6, floor(3 + deckBlend * 3 + 0.5)))
      for k = 1, puffs do
        local hk = 900 + k * 13
        local ox, oy, oz, hw, hh, alpha
        local core = k <= (closedDeck and 14 or 9)

        if k <= backboneCount then
          -- Broad translucent backbones hide the billboard primitives.  Closed
          -- weather gets six overlapping bodies spanning almost the full cell,
          -- which bridges neighbouring formations into a continuous ceiling.
          local anchor
          if backboneCount <= 3 then
            local anchors = { -0.30, 0.0, 0.31 }
            anchor = anchors[k]
          else
            anchor = -0.58 + (k - 1) * (1.17 / max(1, backboneCount - 1))
          end
          ox = spanX * anchor
          oz = (hash2(ix, iz, hk + 1) * 2 - 1) * spanZ * lerp(0.15, 0.20, deckBlend)
          oy = -spanY * lerp(0.03, 0.06, deckBlend)
             + hash2(ix, iz, hk + 2) * spanY * lerp(0.16, 0.12, deckBlend)
          hw = spanX * (lerp(0.39, 0.34, deckBlend)
             + hash2(ix, iz, hk + 3) * lerp(0.09, 0.07, deckBlend))
          hh = spanY * (lerp(0.50, 0.68, deckBlend)
             + hash2(ix, iz, hk + 4) * 0.12)
          alpha = (lerp(0.24, 0.40, deckBlend)
             + hash2(ix, iz, hk + 5) * lerp(0.08, 0.10, deckBlend)) * frame.level
        else
          -- Irregular shell around a soft core. Vertical placement is biased
          -- upward toward the centre but never snaps to a flat floor. Broad
          -- banks stay low; tower types gain a little more central lift.
          local rx = hash2(ix, iz, hk + 1) * 2 - 1
          local rz = hash2(ix, iz, hk + 2) * 2 - 1
          local centre = max(0, 1.0 - abs(rx))
          local radial = sqrt(min(1.0, rx * rx * 0.76 + rz * rz))
          local lift
          if kind == 0 then
            lift = -0.16 + centre * 0.25 + hash2(ix, iz, hk + 3) * 0.26
          elseif kind == 2 then
            lift = -0.12 + (centre ^ 1.55) * 0.72 + hash2(ix, iz, hk + 3) * 0.30
          else
            lift = -0.14 + (centre ^ 1.25) * 0.48 + hash2(ix, iz, hk + 3) * 0.29
          end
          ox = rx * spanX * (kind == 0 and 0.94 or 0.86)
          oz = rz * spanZ * (0.58 + hash2(ix, iz, hk + 4) * 0.34)
          oy = spanY * lift

          -- More, smaller lobes than M1. Near the perimeter they become
          -- broader/softer instead of turning into a crisp string of bubbles.
          local edge = max(0, min(1, (radial - 0.48) / 0.52))
          edge = edge * edge * (3 - 2 * edge)
          hw = spanX * (0.13 + hash2(ix, iz, hk + 5) * 0.16) * (1.0 + edge * 0.12)
          hh = spanY * (0.20 + hash2(ix, iz, hk + 6) * 0.24) * (1.0 + edge * 0.08)
          alpha = (lerp(0.31, 0.39, deckBlend)
                 + hash2(ix, iz, hk + 7) * lerp(0.13, 0.14, deckBlend)) * frame.level
          if core then alpha = min(lerp(0.62, 0.70, deckBlend),
                                   alpha * lerp(1.10, 1.12, deckBlend)) end
        end

        -- Minute-scale edge evolution. Keep displacement tiny; mostly alter
        -- size and height so the cloud appears to develop, not swim apart.
        local evolve = sin(ForestAtmos.time * (0.0085 + c.evolveRate * 0.0035)
                           + c.phase + k * 1.417)
        hw = hw * (0.975 + evolve * 0.035)
        hh = hh * (0.974 + evolve * 0.042)
        oy = oy + evolve * spanY * 0.022

        -- Close formations gain density primarily from extra overlapping lobes,
        -- not from stronger individual cards. That prevents an overhead cloud
        -- from becoming a translucent screen wash as it approaches the camera.
        if c.depthClass == 0 then
          alpha = alpha * lerp(0.82, 1.0, deckBlend)
        elseif c.depthClass == 2 then
          alpha = alpha * lerp(0.93, 0.97, deckBlend)
        end
        alpha = alpha * (c.fadeAlpha or 1.0)

        local phase = hash2(ix, iz, hk + 8)
        local drift = 0.45 + hash2(ix, iz, hk + 9) * 0.95
        local rate = 0.0050 + hash2(ix, iz, hk + 10) * 0.0048

        for corner = 1, 4 do
          local co = corners[corner]
          verts[#verts + 1] = {
            c.cx + ox, c.cy + oy, c.cz + oz,
            co[1], co[2], phase, alpha,
            hw, hh, drift, -rate,
          }
        end
        pushQuad(indices, q)
        q = q + 1
      end
    end
  end
  return verts, indices
end

local function drawParticles(Voxel3D, frame, clouds, cloudsOnly)
  local sh = particleShader()
  local axisR, axisU = billboardAxes(Voxel3D)
  if not (sh and axisR and axisU) then return end
  local verts, indices = buildParticleVertices(Voxel3D, frame, clouds, cloudsOnly)
  if not (verts and indices and #verts > 0) then return end
  if not particleMesh then
    local ok, mesh = pcall(love.graphics.newMesh, PARTICLE_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    particleMesh = mesh
  else
    local ok = pcall(particleMesh.setVertices, particleMesh, verts)
    if not ok then particleMesh = nil return drawParticles(Voxel3D, frame, clouds, cloudsOnly) end
  end
  pcall(particleMesh.setVertexMap, particleMesh, indices)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
    pcall(sh.send, sh, "axisR", axisR)
    pcall(sh.send, sh, "axisU", axisU)
    pcall(sh.send, sh, "time", ForestAtmos.time)
    local fog, ray = frame.fogColor, frame.rayColor
    pcall(sh.send, sh, "particleCool", {
      min(1, fog[1] * 0.74 + 0.22),
      min(1, fog[2] * 0.74 + 0.22),
      min(1, fog[3] * 0.74 + 0.22),
    })
    pcall(sh.send, sh, "particleWarm", {
      min(1, ray[1] * 0.84 + 0.13),
      min(1, ray[2] * 0.84 + 0.13),
      min(1, ray[3] * 0.84 + 0.13),
    })
    local tint = DayNight.tint(true)
    local cloudShade = (frame.weather and frame.weather.cloudShade) or 1.0
    pcall(sh.send, sh, "cloudCool", {
      min(1, (0.58 * tint[1] + 0.17) * cloudShade),
      min(1, (0.59 * tint[2] + 0.18) * cloudShade),
      min(1, (0.61 * tint[3] + 0.19) * cloudShade),
    })
    pcall(sh.send, sh, "cloudWarm", {
      min(1, (0.68 + ray[1] * 0.30) * cloudShade),
      min(1, (0.70 + ray[2] * 0.29) * cloudShade),
      min(1, (0.73 + ray[3] * 0.27) * cloudShade),
    })
    -- Project the sun direction into the billboard plane. The cloud pixel
    -- shader uses this only for restrained silver-lining at the lit feather.
    local kx, kz = ShadowMap.KX or -0.85, ShadowMap.KZ or -0.55
    local sx, sy, sz = -kx, 1.0, -kz
    local sl = sqrt(sx * sx + sy * sy + sz * sz)
    sx, sy, sz = sx / sl, sy / sl, sz / sl
    local sr = sx * axisR[1] + sy * axisR[2] + sz * axisR[3]
    local su = sx * axisU[1] + sy * axisU[2] + sz * axisU[3]
    pcall(sh.send, sh, "cloudSun", { sr, su })
    pcall(love.graphics.draw, particleMesh)
    Voxel3D.endEffect()
  end
end

-- ---------- world-space rain
--
-- Rain is a genuine 3D weather field, not a screen overlay. Each streak has a
-- deterministic world X/Z anchor, falls through a real Y range, leans with the
-- weather wind and is drawn while Dramatic Shape's live scene depth buffer is
-- still bound. Trees, roofs and terrain therefore occlude drops in hardware.

local RAIN_SHADER = [[
  varying vec2 vLocal;
  varying float vAlpha;
  varying float vLife;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  uniform vec3 axisR;
  uniform float time;
  attribute vec4 RainData;    // local x, local y (0..1), phase, alpha
  attribute vec4 RainShape;   // half width, streak length, fall range, cycle rate
  attribute vec4 RainMotion;  // top height, wind x, wind z, sway

  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    float cyc = fract(time * RainShape.w + RainData.z);
    vec3 base = vertex_position.xyz;

    // Fall down through the local atmosphere. Horizontal displacement uses the
    // same cycle, so each streak follows one coherent wind-slanted trajectory.
    base.y += RainMotion.x - cyc * RainShape.z;
    base.x += RainMotion.y * cyc;
    base.z += RainMotion.z * cyc;
    float wobble = sin(time * 2.1 + RainData.z * 37.0 + cyc * 11.0) * RainMotion.w;
    base.x += wobble;

    // Tail points back up the actual world-space fall vector. Perspective is
    // supplied by the ordinary 3D projection, so nearby rain naturally reads
    // larger/faster while distant streaks recede.
    vec3 trail = normalize(vec3(-RainMotion.y, RainShape.z, -RainMotion.z));
    vec3 p = base + axisR * (RainData.x * RainShape.x)
                  + trail * (RainData.y * RainShape.y);
    vec4 w = vec4(p, 1.0);

    // Rain maintains altitude relative to the curved diorama terrain instead
    // of becoming a flat screen sheet at the horizon.
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }

    vLocal = RainData.xy;
    vAlpha = RainData.w;
    vLife = smoothstep(0.015, 0.065, cyc) * (1.0 - smoothstep(0.91, 0.995, cyc));
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform vec3 rainColor;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float side = 1.0 - smoothstep(0.18, 1.0, abs(vLocal.x));
    float tail = smoothstep(0.00, 0.08, vLocal.y)
               * (1.0 - smoothstep(0.82, 1.0, vLocal.y));
    // A faint body plus a brighter lower portion reads as falling water rather
    // than glowing white scratches, especially against the closed cloud deck.
    float body = 0.44 + 0.56 * (1.0 - vLocal.y);
    float a = vAlpha * vLife * side * tail * body;
    return vec4(rainColor, a) * color;
  }
#endif
]]

local RAIN_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "RainData", "float", 4 },
  { "RainShape", "float", 4 },
  { "RainMotion", "float", 4 },
}

local rainShaderState, rainMesh = nil, nil

-- Rain animation must use an INTEGRATED clock, never absoluteTime * speed.
-- W5 multiplied ForestAtmos.time by the live interpolated rainSpeed. During a
-- Thunderstorm -> Rain transition the speed decreases, and at sufficiently
-- large absolute times the changing multiplier can make that product move
-- backwards for a few frames. The authored fall vector was still downward,
-- but the cycle phase reversed and the drops appeared to fly into the sky.
--
-- Integrating positive speed over frame time makes reversal mathematically
-- impossible while preserving smooth acceleration/deceleration between weather
-- states. Source time is sampled here rather than in update(), so headless/menu
-- paths that never draw rain cannot accidentally advance the GPU phase twice.
local rainClock = 0
local rainClockSourceTime = nil
local function integratedRainTime(weather)
  local now = ForestAtmos.time or 0
  if rainClockSourceTime == nil then
    rainClockSourceTime = now
    return rainClock
  end
  local dt = now - rainClockSourceTime
  rainClockSourceTime = now
  if dt > 0 then
    local speed = max(0.05, tonumber(weather and weather.rainSpeed) or 1.0)
    rainClock = rainClock + dt * speed
  end
  -- A reset/frozen screenshot clock may move backwards. Never subtract from the
  -- integrated phase; simply re-anchor the source time on that frame.
  return rainClock
end

local function rainShader()
  if rainShaderState ~= nil then return rainShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, RAIN_SHADER)
  rainShaderState = (ok and sh) or false
  if not ok then print("[Weather] 3D rain shader refused: " .. tostring(sh)) end
  return rainShaderState or nil
end

local function buildRainVertices(Voxel3D, frame)
  local f = Voxel3D.focus
  local weather = frame.weather
  local baseIntensity = weather and weather.rainIntensity or 0
  if not f or baseIntensity <= 0 then return nil, nil end

  local density = rainDensityScale(weather) * baseIntensity
  local size = rainSizeScale(weather)
  local windStrength = weather.rainWind or 1.0
  local cell = 34
  local radius = frame.level > 0.9 and 4 or 3
  local verts, indices, q = {}, {}, 0
  local corners = { { -1, 0 }, { 1, 0 }, { 1, 1 }, { -1, 1 } }

  eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
    local gate = hash2(ix, iz, 1701)
    if gate > 0.05 then
      local baseCount = frame.level > 0.9 and 3 or 2
      if gate > 0.42 then baseCount = baseCount + 1 end
      if gate > 0.76 then baseCount = baseCount + 1 end
      local wanted = baseCount * density
      local count = floor(wanted)
      if hash2(ix, iz, 1702) < (wanted - count) then count = count + 1 end

      for k = 1, count do
        local cx = (ix + 0.08 + hash2(ix, iz, 1710 + k) * 0.84) * cell
        local cz = (iz + 0.08 + hash2(ix, iz, 1720 + k) * 0.84) * cell
        -- Each drop falls through a tall local atmospheric column. The base is
        -- tied to focus elevation so maps with raised terrain still get rain.
        local top = 82 + hash2(ix, iz, 1730 + k) * 42
        local fallRange = 102 + hash2(ix, iz, 1740 + k) * 54
        -- Per-drop cycle rate is fixed. Weather speed is applied by the
        -- monotonic integratedRainTime() clock at draw time, so interpolating
        -- storm speed can never reverse the animation phase.
        local life = 0.72 + hash2(ix, iz, 1750 + k) * 0.48
        local rate = 1.0 / life
        local phase = hash2(ix, iz, 1760 + k)

        local width = (0.72 + hash2(ix, iz, 1770 + k) * 0.58) * size
        local length = (9.0 + hash2(ix, iz, 1780 + k) * 8.5) * size
        -- Wind is coherent at weather scale with small per-drop variance. The
        -- storm preset increases the same vector rather than inventing a new
        -- screen-space angle.
        local jitter = (hash2(ix, iz, 1790 + k) * 2 - 1) * 0.18
        local windX = (10.0 + jitter * 5.0) * windStrength
        local windZ = (-6.2 + jitter * 3.0) * windStrength
        local sway = 0.12 + hash2(ix, iz, 1800 + k) * 0.28
        local alpha = (0.18 + hash2(ix, iz, 1810 + k) * 0.16) * frame.level

        for ci = 1, 4 do
          local co = corners[ci]
          verts[#verts + 1] = {
            cx, f[2] or 0, cz,
            co[1], co[2], phase, alpha,
            width, length, fallRange, rate,
            top, windX, windZ, sway,
          }
        end
        pushQuad(indices, q)
        q = q + 1
      end
    end
  end)

  return verts, indices
end


-- ---------------------------------------------------------------------------
-- 3D snow: soft world-space flakes (billboards), slow fall, horizontal sway.
-- ---------------------------------------------------------------------------
local function snowDensityScale(weather)
  local n = tonumber(weather and weather.snowDensityRung) or 5
  return 0.55 + n * 0.18
end

local function snowSizeScale(weather)
  local n = tonumber(weather and weather.snowSizeRung) or 4
  return 0.70 + n * 0.16
end

local SNOW_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "SnowData", "float", 4 },
}

local snowShaderState, snowMesh = nil, nil

local function snowShader()
  if snowShaderState then return snowShaderState end
  if not (love and love.graphics and love.graphics.newShader) then return nil end
  local ok, sh = pcall(love.graphics.newShader, [[
#ifdef VERTEX
  extern mat4 vp;
  extern float time;
  extern vec3 eye;
  attribute vec4 SnowData; // phase, rate, size, alpha
  varying float vAlpha;
  varying vec2 vLocal;
  vec4 position(mat4 t, vec4 v) {
    // v.xyz = column anchor; SnowData drives fall/sway
    float phase = SnowData.x;
    float rate = max(0.05, SnowData.y);
    float size = SnowData.z;
    float baseA = SnowData.w;
    float cyc = fract(phase + time * rate);
    // Slow drop with soft horizontal flutter (realistic flake motion)
    float fall = cyc * 95.0;
    float sway = sin((phase + time * 0.7) * 6.28318) * 7.5
               + sin((phase * 1.7 + time * 0.45) * 6.28318) * 4.0;
    float drift = cos((phase * 0.9 + time * 0.33) * 6.28318) * 5.5;
    vec3 w = v.xyz;
    w.y -= fall;
    w.x += sway + drift * 0.35;
    w.z += drift * 0.65;
    // Billboard in view plane approx via eye vector
    vec3 toEye = normalize(eye - w);
    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up, toEye));
    up = normalize(cross(toEye, right));
    // v.w encodes corner: 0..3 via RainShape-style packing in position.w unused —
    // corners packed into SnowData via mesh generator using position offset
    vLocal = vec2(0.0);
    vAlpha = baseA * smoothstep(0.0, 0.12, cyc) * (1.0 - smoothstep(0.82, 1.0, cyc));
    return vp * vec4(w, 1.0);
  }
#endif
#ifdef PIXEL
  varying float vAlpha;
  varying vec2 vLocal;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Soft round flake
    vec2 p = tc * 2.0 - 1.0;
    float d = length(p);
    float soft = 1.0 - smoothstep(0.25, 1.0, d);
    float a = vAlpha * soft * soft;
    return vec4(0.95, 0.97, 1.0, a) * color;
  }
#endif
]])
  if ok and sh then snowShaderState = sh end
  return snowShaderState
end

-- Mesh built with expanded positions for 4 corners of each flake billboard
local function buildSnowVertices(Voxel3D, frame)
  local f = Voxel3D.focus
  local weather = frame.weather
  local wxId = snowState.wxId or ""
  local baseIntensity = tonumber(weather and weather.snowIntensity) or 0
  if baseIntensity <= 0 and wxIsSnowy(wxId) then
    baseIntensity = snowTargetFor(wxId)
  end
  if not f or baseIntensity <= 0.02 then return nil end

  local density = snowDensityScale(weather) * baseIntensity
  local sizeMul = snowSizeScale(weather)
  local cell = 40
  local radius = frame.level > 0.9 and 4 or 3
  local verts = {}
  local eye = Voxel3D.eye or f

  eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
    local gate = hash2(ix, iz, 2701)
    if gate > 0.12 then return end
    local baseCount = frame.level > 0.9 and 4 or 3
    if gate < 0.04 then baseCount = baseCount + 2 end
    local wanted = baseCount * density
    local count = floor(wanted)
    if hash2(ix, iz, 2702) < (wanted - count) then count = count + 1 end
    for k = 1, count do
      local cx = (ix + 0.05 + hash2(ix, iz, 2710 + k) * 0.90) * cell
      local cz = (iz + 0.05 + hash2(ix, iz, 2720 + k) * 0.90) * cell
      local top = (f[2] or 0) + 55 + hash2(ix, iz, 2730 + k) * 50
      local phase = hash2(ix, iz, 2740 + k)
      local life = 1.4 + hash2(ix, iz, 2750 + k) * 1.6
      local rate = 1.0 / life
      local size = (1.6 + hash2(ix, iz, 2760 + k) * 2.8) * sizeMul
      local alpha = (0.35 + hash2(ix, iz, 2770 + k) * 0.45) * (0.55 + 0.45 * frame.level)
      -- 4 billboard corners in world, camera-facing approx via fixed axes
      local hs = size * 0.5
      -- Two triangles (6 verts) so we do not need setVertexMap
      local c1 = { cx - hs, top, cz - hs * 0.2 }
      local c2 = { cx + hs, top, cz - hs * 0.2 }
      local c3 = { cx + hs, top, cz + hs * 0.2 }
      local c4 = { cx - hs, top, cz + hs * 0.2 }
      local function push(c)
        verts[#verts + 1] = { c[1], c[2], c[3], phase, rate, size, alpha }
      end
      push(c1); push(c2); push(c3)
      push(c1); push(c3); push(c4)
    end
  end)

  if #verts < 4 then return nil end
  return verts
end

local function drawSnow3D(Voxel3D, frame)
  -- DISABLED. Old path: eachWeatherCell around camera/focus + shader fall.
  -- That made every flake follow the camera. Falling snow is WorldPrecip only.
  return
end
local function drawRain(Voxel3D, frame)
  local weather = frame.weather
  if not (weather and (weather.rainIntensity or 0) > 0) then return end
  local sh = rainShader()
  local axisR = billboardAxes(Voxel3D)
  if not (sh and axisR) then return end
  local verts, indices = buildRainVertices(Voxel3D, frame)
  if not (verts and indices and #verts > 0) then return end

  if not rainMesh then
    local ok, mesh = pcall(love.graphics.newMesh, RAIN_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    rainMesh = mesh
  else
    local ok = pcall(rainMesh.setVertices, rainMesh, verts)
    if not ok then rainMesh = nil return drawRain(Voxel3D, frame) end
  end
  pcall(rainMesh.setVertexMap, rainMesh, indices)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
    pcall(sh.send, sh, "axisR", axisR)
    pcall(sh.send, sh, "time", integratedRainTime(weather))
    local fog = frame.fogColor
    local tint = DayNight.tint(true)
    pcall(sh.send, sh, "rainColor", {
      min(1, fog[1] * 0.54 + tint[1] * 0.34 + 0.16),
      min(1, fog[2] * 0.58 + tint[2] * 0.35 + 0.17),
      min(1, fog[3] * 0.64 + tint[3] * 0.38 + 0.19),
    })
    pcall(love.graphics.draw, rainMesh)
    Voxel3D.endEffect()
  end
end

-- ---------- shadow-map-aware volumetric light shafts

local RAY_SHADER = [[
  varying vec2 vLocal;
  varying float vPhase;
  varying float vAlpha;
  varying LOVE_HIGHP_OR_MEDIUMP vec3 vWorld;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 curve;
  attribute vec4 RayData;    // local x (-1..1), local y (0..1), phase, alpha
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vLocal = RayData.xy;
    vPhase = RayData.z;
    vAlpha = RayData.w;
    vec4 w = vertex_position;
    vWorld = w.xyz;
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }
    return vp * w;
  }
#endif
#ifdef PIXEL
  uniform Image sunMap;
  uniform mat4 sunVP;
  uniform float sunBias;
  uniform float sunActive;
  uniform vec3 rayColor;
  uniform vec2 shear;
  uniform vec2 wind;
  uniform float canopyY;
  uniform float time;

  float packedDepth(vec2 uv) {
    vec4 c = Texel(sunMap, uv);
    return c.r + c.g * (1.0 / 255.0);
  }

  float sunlightAt(vec3 p) {
    if (sunActive < 0.5) return 1.0;
    vec3 su = (sunVP * vec4(p, 1.0)).xyz;
    if (su.x <= 0.0 || su.x >= 1.0 || su.y <= 0.0 || su.y >= 1.0 || su.z >= 1.0)
      return 1.0;
    vec2 e = min(su.xy, 1.0 - su.xy);
    float edge = smoothstep(0.0, 0.055, min(e.x, e.y));
    float z = su.z - sunBias;
    float lit = step(z, packedDepth(su.xy));
    return mix(1.0, lit, edge);
  }

  float canopyPattern(vec3 p) {
    float up = max(0.0, canopyY - p.y);
    vec2 g = p.xz - shear * up;
    vec2 q = g * 0.020 + wind * time;
    float n1 = 0.5 + 0.5 * sin(q.x * 3.1 + q.y * 1.7 + 0.3);
    float n2 = 0.5 + 0.5 * sin(q.x * 1.3 - q.y * 4.2 + 2.1);
    float n3 = 0.5 + 0.5 * sin((q.x + q.y) * 2.2 - 1.4);
    float n = n1 * 0.45 + n2 * 0.35 + n3 * 0.20;
    return 0.46 + 0.54 * smoothstep(0.41, 0.78, n);
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float x = abs(vLocal.x);
    float y = clamp(vLocal.y, 0.0, 1.0);
    float side = 1.0 - smoothstep(0.08, 1.0, x);
    float foot = smoothstep(0.00, 0.09, y);
    float head = 1.0 - smoothstep(0.72, 1.0, y);
    float breathe = 0.82 + 0.18 * sin(time * 0.17 + vPhase + vWorld.y * 0.025);
    float lit = sunlightAt(vWorld);
    float dapple = canopyPattern(vWorld);
    // Cloud transmission is baked into vAlpha on the CPU using the exact
    // cloud descriptors that build the visible clusters. This is much cheaper
    // on Android than re-evaluating a procedural cloud field for every ray
    // fragment, while still making cloud cores physically break the shafts.
    float a = vAlpha * side * foot * head * breathe * lit * dapple;
    return vec4(rayColor * a, a) * color;
  }
#endif
]]

local RAY_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "RayData", "float", 4 },
}

local rayShaderState, rayMesh = nil, nil
local cloudTransmissionAt, cloudTransmissionAlongRay

local function rayShader()
  if rayShaderState ~= nil then return rayShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, RAY_SHADER)
  rayShaderState = (ok and sh) or false
  if not ok then print("[Weather] cinematic ray shader refused: " .. tostring(sh)) end
  return rayShaderState or nil
end

local function buildRayVertices(Voxel3D, frame, clouds)
  local f = Voxel3D.focus
  if not f then return nil, nil end
  local kx, kz = ShadowMap.KX or -0.85, ShadowMap.KZ or -0.55
  local kl = sqrt(kx * kx + kz * kz)
  if kl < 1e-5 then return nil, nil end
  local px, pz = -kz / kl, kx / kl -- horizontal width axis, perpendicular to sun travel
  local cell = 58
  local radius = frame.level > 0.9 and 4 or 3
  local verts, indices, q = {}, {}, 0
  local projectionScale = orientationDensityScale(Voxel3D)
  eachWeatherCell(Voxel3D, cell, radius, function(ix, iz)
      local gate = hash2(ix, iz, 151)
      if gate > (frame.level > 0.9 and 0.20 or 0.30) then
        local hx = hash2(ix, iz, 152)
        local hz = hash2(ix, iz, 153)
        local cx = (ix + 0.18 + hx * 0.64) * cell
        local cz = (iz + 0.18 + hz * 0.64) * cell
        local groundY = 1.5 + hash2(ix, iz, 154) * 6.0
        local height = (frame.canopy and 72 or 116) + hash2(ix, iz, 155) * (frame.canopy and 34 or 70)
        -- Keep the A4 broad footprint, but restore enough radiance that the
        -- field survives mobile display scaling and bright daytime palettes.
        local width = 46 + hash2(ix, iz, 156) * 54
        local alpha = (0.082 + hash2(ix, iz, 157) * 0.068) * frame.level
                      * (frame.lightIntensity or 1.0) * projectionScale
        local phase = hash2(ix, iz, 158) * PI2
        -- Project this shaft toward the mean cloud deck.  The helper below
        -- evaluates the same descriptors used to draw the visible cloud
        -- clusters: dense cores nearly extinguish the shaft, thin lobes only
        -- soften it.  This is true cloud/light interaction without a costly
        -- per-pixel cloud march on Android.
        if clouds and #clouds > 0 then
          -- Sample the physical sun path at each visible cloud's own height.
          -- Three samples across the broad shaft keep cloud edges soft rather
          -- than switching an entire beam on/off at once.
          local off = width * 0.34
          local t0 = cloudTransmissionAlongRay(clouds, cx, groundY, cz, 0, 0)
          local t1 = cloudTransmissionAlongRay(clouds, cx, groundY, cz, px * off, pz * off)
          local t2 = cloudTransmissionAlongRay(clouds, cx, groundY, cz, -px * off, -pz * off)
          alpha = alpha * (t0 * 0.50 + t1 * 0.25 + t2 * 0.25)
        end
        -- Top of the same sun ray: the light travels DOWN by (kx,-1,kz),
        -- therefore rising to the top walks opposite that horizontal shear.
        local tx = cx - kx * height
        local tz = cz - kz * height
        local hw = width * 0.5
        verts[#verts + 1] = { cx - px * hw, groundY, cz - pz * hw, -1, 0, phase, alpha }
        verts[#verts + 1] = { cx + px * hw, groundY, cz + pz * hw,  1, 0, phase, alpha }
        verts[#verts + 1] = { tx + px * hw, groundY + height, tz + pz * hw,  1, 1, phase, alpha }
        verts[#verts + 1] = { tx - px * hw, groundY + height, tz - pz * hw, -1, 1, phase, alpha }
        pushQuad(indices, q)
        q = q + 1

        -- A second, narrower slice through the same shaft prevents a ribbon
        -- vanishing when the camera lines up with the first plane.
        if frame.level > 0.9 or gate > 0.72 then
          local rx = px * 0.52 + (kx / kl) * 0.85
          local rz = pz * 0.52 + (kz / kl) * 0.85
          local rl = sqrt(rx * rx + rz * rz)
          rx, rz = rx / rl, rz / rl
          local hw2 = hw * 0.88
          local a2 = alpha * 0.46
          verts[#verts + 1] = { cx - rx * hw2, groundY, cz - rz * hw2, -1, 0, phase + 1.7, a2 }
          verts[#verts + 1] = { cx + rx * hw2, groundY, cz + rz * hw2,  1, 0, phase + 1.7, a2 }
          verts[#verts + 1] = { tx + rx * hw2, groundY + height, tz + rz * hw2,  1, 1, phase + 1.7, a2 }
          verts[#verts + 1] = { tx - rx * hw2, groundY + height, tz - rz * hw2, -1, 1, phase + 1.7, a2 }
          pushQuad(indices, q)
          q = q + 1
        end
      end
  end)
  return verts, indices
end

local function drawRays(Voxel3D, frame, clouds)
  if not frame or (tonumber(frame.lightIntensity) or 0) <= 0.001 then return end
  local sh = rayShader()
  if not sh then return end
  local verts, indices = buildRayVertices(Voxel3D, frame, clouds)
  if not (verts and indices and #verts > 0) then return end
  if not rayMesh then
    local ok, mesh = pcall(love.graphics.newMesh, RAY_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    rayMesh = mesh
  else
    local ok = pcall(rayMesh.setVertices, rayMesh, verts)
    if not ok then rayMesh = nil return drawRays(Voxel3D, frame, clouds) end
  end
  pcall(rayMesh.setVertexMap, rayMesh, indices)
  pcall(love.graphics.setBlendMode, "add", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "curve", { Voxel3D.curveX or 0, Voxel3D.curveZ or 0, Voxel3D.curveK or 0 })
    local active = ShadowMap.active()
    pcall(sh.send, sh, "sunVP", "row", active and ShadowMap.uvVP or {
      1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 })
    local tex = ShadowMap.texture()
    if tex then pcall(sh.send, sh, "sunMap", tex) end
    pcall(sh.send, sh, "sunBias", ShadowMap.bias or 0)
    pcall(sh.send, sh, "sunActive", active and 1 or 0)
    pcall(sh.send, sh, "rayColor", frame.rayColor)
    pcall(sh.send, sh, "shear", { ShadowMap.KX or -0.85, ShadowMap.KZ or -0.55 })
    pcall(sh.send, sh, "wind", frame.wind)
    pcall(sh.send, sh, "canopyY", frame.canopy and 66 or 188)
    pcall(sh.send, sh, "time", ForestAtmos.time)
    pcall(love.graphics.draw, rayMesh)
    Voxel3D.endEffect()
  end
end

-- ---------- clustered volumetric sky clouds

-- The visible deck and the ray occlusion share one small set of deterministic
-- descriptors every frame.  That gives us exact macro alignment at a fraction
-- of the cost of sampling procedural cloud noise in every ray fragment.
local function smoothstepLua(a, b, x)
  if a == b then return x < a and 0 or 1 end
  local t = max(0, min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end

-- A13 no longer infers a fixed cloud altitude. See buildCloudDescriptors:
-- the deck is constructed from the live camera basis so cloud geometry and
-- the visible sky can no longer disagree on strongly curved/globe views.

local function projectNoCurveNdc(Voxel3D, wx, wy, wz)
  -- Clouds deliberately do not inherit the globe bend. This projection helper
  -- therefore mirrors the VP transform directly instead of Voxel3D.project(),
  -- which applies WorldCurve.drop() for terrain-bound effects.
  local m = Voxel3D.vp
  if not m then return nil end
  local cx = m[1] * wx + m[2] * wy + m[3] * wz + m[4]
  local cy = m[5] * wx + m[6] * wy + m[7] * wz + m[8]
  local cw = m[13] * wx + m[14] * wy + m[15] * wz + m[16]
  if cw <= 1e-5 then return nil end
  return cx / cw, cy / cw, cw
end

local function buildCloudDescriptors(Voxel3D, frame, questBudget)
  if frame.canopy or not (Voxel3D.eye and Voxel3D.focus) then return {} end
  local cloudsOn = true
  pcall(function()
    local S = V.require("Settings")
    if S and S.cloudsOn then cloudsOn = S.cloudsOn() end
  end)
  if not cloudsOn then return {} end
  local weather = frame.weather or WEATHER.partly
  if (weather.coverage or 0) <= 0.001 then return {} end

  -- WEATHER W1: world-anchored atmosphere with persistent frustum coverage.
  --
  -- M1/M2 finally looked like clouds, but the descriptors themselves were
  -- reconstructed from the live camera basis every frame. That made the whole
  -- deck follow the camera like scenery painted on a distant shell. M3 uses an
  -- infinite deterministic X/Z lattice instead. The lattice advects through
  -- world space with one coherent wind vector, so walking/rotating the camera
  -- produces genuine near/mid/far parallax and a cloud can actually pass
  -- overhead rather than remaining pinned to the upper screen.
  local e, f = Voxel3D.eye, Voxel3D.focus
  local fx, fy, fz = f[1] - e[1], f[2] - e[2], f[3] - e[3]
  local camDist = sqrt(fx * fx + fy * fy + fz * fz)
  if camDist < 1e-6 then return {} end
  fx, fy, fz = fx / camDist, fy / camDist, fz / camDist

  local aspect = viewportAspect(Voxel3D)

  -- MOSTLY CLOUDY M6: size parity is a separate problem from deck height.
  -- A15-M5 used 1/aspect, which perfectly cancels the orbit camera distance
  -- only for geometry attached to the focus plane.  These clouds are world-
  -- anchored at independent near/mid/far depths, so that correction shrank
  -- them far too much in a wide landscape view.  Use a gentler projection
  -- compensation instead: portrait remains the authored 1.0 reference, while
  -- a ~2.16:1 handset landscape uses ~0.76 world scale.  The closer landscape
  -- eye then restores the missing projected size without returning to A14's
  -- giant screen-filling cloud sheets.
  local orientationScale = aspect > 1.0 and (aspect ^ -0.35) or 1.0

  -- MOSTLY CLOUDY M5: portrait is the approved vertical-composition reference.
  -- Dramatic Shape's short landscape viewport changes the orbit-camera geometry
  -- enough that the same absolute cloud altitude projects too close to the top
  -- of the screen.  Lower the entire weather deck smoothly as the viewport gets
  -- wider.  This is a descriptor-space correction, so visible cloud geometry
  -- and god-ray occlusion continue to use the exact same physical cloud height.
  -- At the test handset's ~2.16:1 landscape aspect this is ~34 world units;
  -- portrait (aspect <= 1) is untouched.
  local landscapeBlend = max(0.0, min(1.0, (aspect - 1.0) / 1.15))
  local landscapeCloudDrop = 34.0 * landscapeBlend

  local now = ForestAtmos.time

  -- One slow coherent weather flow. Because candidate indices are evaluated
  -- in the inverse-advected lattice, positions are continuous for arbitrarily
  -- long sessions instead of being recycled around the camera.
  local cell = weather.cell or 185.0
  local windX, windZ = 0.43, -0.14
  local advX, advZ = now * windX, now * windZ

  -- Search the world corridor between the player's focus and the camera eye,
  -- not merely around the map centre. This is what allows real foreground
  -- atmospheric masses to exist physically between the viewer and Kanto.
  local midX = (e[1] + f[1]) * 0.5
  local midZ = (e[3] + f[3]) * 0.5
  local bix = floor((midX - advX) / cell)
  local biz = floor((midZ - advZ) / cell)

  local candidates = {}
  local searchSide = max(4, min(7, math.ceil(4.2 * max(1.0, aspect))))
  local searchDepth = 6

  for iz = biz - searchDepth, biz + searchDepth do
    for ix = bix - searchSide, bix + searchSide do
      -- M3 proved that roughly 70% occupied lattice cells only *looked* Partly
      -- Cloudy once perspective/frustum filtering was applied.  Mostly Cloudy
      -- needs a tighter lattice and a higher occupancy target, while still
      -- leaving irregular blue-sky breaks for dramatic shafts.
      local gate = hash2(ix, iz, 230)
      local gateAt = weather.gate or 0.18
      local softGate = weather.softGate or 0.0
      local occupancyAlpha
      if softGate > 0.0001 then
        occupancyAlpha = smoothstepLua(gateAt - softGate, gateAt + softGate, gate)
      else
        occupancyAlpha = gate > gateAt and 1.0 or 0.0
      end
      if occupancyAlpha > 0.01 then
        local seedX, seedZ = ix, iz
        local styleA = hash2(seedX, seedZ, 246)
        local styleB = hash2(seedX, seedZ, 247)
        local styleC = hash2(seedX, seedZ, 248)
        local bankBias = weather.bank or 0.34
        local towerCut = min(0.94, bankBias + 0.48)
        local kind = styleA < bankBias and 0 or (styleA < towerCut and 1 or 2)
        local deckBlend = max(0.0, min(1.0, weather.deckBlend ~= nil
                          and weather.deckBlend or (weather.closedDeck and 1.0 or 0.0)))
        -- As the dynamic continuum approaches overcast, more formations become
        -- broad stratiform banks progressively rather than all changing type on
        -- one frame. Manual overcast still resolves to a fully sealed deck.
        if hash2(seedX, seedZ, 251) < deckBlend then kind = 0 end

        -- Stable world-space centre plus coherent global wind advection.
        local cx = (ix + 0.12 + hash2(ix, iz, 232) * 0.76) * cell + advX
        local cz = (iz + 0.12 + hash2(ix, iz, 233) * 0.76) * cell + advZ

        -- Absolute cloud altitude, deliberately independent of camera pitch.
        -- The range is several building heights above the world: low enough
        -- for near formations to feel overhead, high enough to stay sky-like.
        local brokenCy = 92.0 + hash2(ix, iz, 234) * 84.0
        if kind == 2 then brokenCy = brokenCy + 12.0 + styleC * 20.0 end
        local deckCy = (weather.deckY0 or 116.0)
                     + hash2(ix, iz, 234) * (weather.deckYSpan or 26.0)
        local cy = lerp(brokenCy, deckCy, deckBlend) - landscapeCloudDrop

        local nx, ny, cw = projectNoCurveNdc(Voxel3D, cx, cy, cz)
        if nx then
          -- Keep centres that are in/just beyond the upper view. Allowing a
          -- generous shoulder is intentional: large nearby formations can
          -- enter from above/side with their centre still outside the frame.
          if nx > -2.10 and nx < 2.10 and ny > -2.20 and ny < 0.55 then
            local dx, dy, dz = cx - e[1], cy - e[2], cz - e[3]
            local forwardDepth = dx * fx + dy * fy + dz * fz
            if forwardDepth > max(12.0, camDist * 0.08) then
              local relativeDepth = forwardDepth / camDist
              local depthClass
              if relativeDepth < 0.62 then depthClass = 0      -- near / overhead
              elseif relativeDepth < 1.02 then depthClass = 1  -- mid atmosphere
              else depthClass = 2 end                          -- distant deck

              -- Fixed world dimensions are important here: perspective should
              -- make a near cloud genuinely larger than a far cloud. M6 applies
              -- only a gentle landscape projection correction above; unlike the
              -- old 1/aspect rule it preserves most of the physical cloud size,
              -- so portrait and landscape now keep comparable apparent scale.
              local spanX, spanY, spanZ
              if kind == 0 then
                spanX = (76 + styleB * 52) * orientationScale
                spanY = (16 + styleC * 12) * orientationScale
                spanZ = (38 + styleB * 30) * orientationScale
              elseif kind == 2 then
                spanX = (52 + styleB * 42) * orientationScale
                spanY = (30 + styleC * 20) * orientationScale
                spanZ = (31 + styleB * 29) * orientationScale
              else
                spanX = (58 + styleB * 48) * orientationScale
                spanY = (21 + styleC * 16) * orientationScale
                spanZ = (33 + styleB * 31) * orientationScale
              end
              local weatherSpan = weather.span or 1.0
              spanX, spanY, spanZ = spanX * weatherSpan, spanY * weatherSpan, spanZ * weatherSpan
              if deckBlend > 0.001 then
                -- Geometric closure grows continuously as the continuum moves
                -- through Cloudy toward Overcast. The minimum overlap expands
                -- with deckBlend; at 1.0 it is the exact sealed-ceiling rule.
                local minX = cell * lerp(0.72, weather.deckWidth or 1.82, deckBlend) * orientationScale
                local minZ = cell * lerp(0.52, weather.deckDepth or 1.12, deckBlend) * orientationScale
                spanX = max(spanX, minX)
                spanZ = max(spanZ, minZ)
                spanY = max(spanY, 28.0 * orientationScale * deckBlend)
              end

              -- Nearby formations get a little more internal structure and a
              -- softer per-lobe alpha. The extra overlap creates density while
              -- preserving the undefined volume language the user preferred.
              local puffs
              if kind == 0 then puffs = frame.level > 0.9 and 36 or 28
              elseif kind == 2 then puffs = frame.level > 0.9 and 39 or 30
              else puffs = frame.level > 0.9 and 37 or 29 end
              if depthClass == 0 then puffs = puffs + 7
              elseif depthClass == 2 then puffs = max(22, puffs - 5) end
              puffs = max(16, floor(puffs * (weather.puffs or 1.0) + 0.5))
              if deckBlend > 0.001 then
                local deckMin = floor(lerp(16, frame.level > 0.9 and 34 or 28, deckBlend) + 0.5)
                puffs = max(puffs, deckMin)
              end
              if questBudget then puffs = min(puffs, 18) end

              -- Prefer atmospheric centres in the upper half, but don't force
              -- every cloud into one horizon band. Near clouds may sit partly
              -- above frame; distant clouds are allowed closer to the horizon.
              local screenY = ny * 0.5 + 0.5
              local desirability = abs(nx) * 0.10
                                 + abs(screenY - (depthClass == 0 and 0.06 or 0.18)) * 0.16
                                 + depthClass * 0.015

              -- Spatial shoulder fade.  A cloud starts existing well outside
              -- the visible NDC rectangle, reaches full opacity before its
              -- centre enters the frame, then fades only after it has moved
              -- well beyond the opposite edge.  This removes the landscape
              -- pop caused by hard frustum admission/removal.
              local edgeX = 1.0 - smoothstepLua(1.00, 1.95, abs(nx))
              local edgeTop = smoothstepLua(-2.12, -1.18, ny)
              local edgeBottom = 1.0 - smoothstepLua(0.12, 0.50, ny)
              local fadeAlpha = max(0.0, min(1.0, edgeX * edgeTop * edgeBottom * occupancyAlpha))

              if fadeAlpha > 0.01 then
              candidates[#candidates + 1] = {
                ix = seedX, iz = seedZ,
                cx = cx, cz = cz, cy = cy,
                orientationScale = orientationScale,
                kind = kind, spanX = spanX, spanY = spanY, spanZ = spanZ,
                puffs = puffs, depthClass = depthClass, deckBlend = deckBlend,
                closedDeck = deckBlend >= 0.985,
                relativeDepth = relativeDepth, desirability = desirability,
                forwardDepth = forwardDepth, fadeAlpha = fadeAlpha,
                evolveRate = hash2(seedX, seedZ, 250),
                angle = (hash2(seedX, seedZ, 245) * 2 - 1) * 0.22,
                styleA = styleA, styleB = styleB, styleC = styleC,
                phase = hash2(seedX, seedZ, 249) * PI2,
              }
              end
            end
          end
        end
      end
    end
  end

  -- M3 ranked candidates by camera-relative desirability and then kept only
  -- 8/10.  On a wide landscape frustum tiny camera changes could reorder that
  -- list and instantly replace one fully visible cloud with another.  M4 does
  -- not camera-rank/cull visible formations.  The broad shoulder fade above
  -- is the budget boundary; all surviving candidates are drawn, sorted only
  -- back-to-front for stable alpha blending.
  if questBudget and #candidates > 52 then
    table.sort(candidates, function(a, b)
      return (a.desirability or 0) < (b.desirability or 0)
    end)
    for i = #candidates, 53, -1 do candidates[i] = nil end
  end
  table.sort(candidates, function(a, b)
    return (a.forwardDepth or 0) > (b.forwardDepth or 0)
  end)

  return candidates
end

local function cloudBodyAt(c, x, z)
  local ca, sa = cos(c.angle), sin(c.angle)
  local dx, dz = x - c.cx, z - c.cz
  local rx = dx * ca - dz * sa
  local rz = dx * sa + dz * ca
  local sx = (c.spanX or 80) * 1.22
  local sz = (c.spanZ or 46) * 1.18
  local kind = c.kind or 1

  local function lobe(ox, oz, wx, wz, lo, hi)
    local px = (rx - ox) / max(wx, 1)
    local pz = (rz - oz) / max(wz, 1)
    local d = sqrt(px * px + pz * pz)
    return 1 - smoothstepLua(lo, hi, d)
  end

  -- Macro occlusion mirrors the visible archetype: a bank is wider/flatter,
  -- classic cumulus has three strong bodies, and a tower has a compact dense
  -- centre. This is deliberately coarse; the ray should soften under cloud
  -- mass, not flicker at every individual billboard feather.
  local b0 = lobe(0, 0, sx, sz, 0.52, 1.02)
  local b1 = lobe(-sx * 0.46, sz * 0.05, sx * 0.66, sz * 0.76, 0.47, 1.00)
  local b2 = lobe( sx * 0.44,-sz * 0.06, sx * 0.64, sz * 0.80, 0.47, 1.00)
  local b3
  if kind == 0 then
    b3 = lobe(0, sz * 0.25, sx * 0.80, sz * 0.54, 0.44, 0.98)
  elseif kind == 2 then
    b3 = lobe(0, sz * 0.18, sx * 0.48, sz * 0.56, 0.38, 0.94)
  else
    b3 = lobe(0, sz * 0.31, sx * 0.60, sz * 0.60, 0.43, 0.97)
  end
  return max(max(b0, b1), max(b2, b3)) * (c.fadeAlpha or 1.0)
end

cloudTransmissionAt = function(clouds, x, z)
  local density = 0
  for i = 1, #clouds do
    local c = clouds[i]
    local dx, dz = x - c.cx, z - c.cz
    if dx * dx + dz * dz < 42000 then
      density = max(density, cloudBodyAt(c, x, z))
      if density > 0.90 then break end
    end
  end
  local core = smoothstepLua(0.20, 0.88, density)
  return lerp(1.0, 0.07, core)
end

-- Evaluate a shaft where it actually crosses EACH cloud's visible altitude.
-- A11 projected every shaft to a hard-coded Y=174 even though the visible
-- cloud geometry was elsewhere. With frustum-aware clouds that would make the
-- light/cloud relationship drift apart. This follows the sun shear from the
-- shaft foot to each cloud centre, so the same cloud that is visible is the
-- cloud that blocks the beam.
cloudTransmissionAlongRay = function(clouds, bx, by, bz, ox, oz)
  local kx, kz = ShadowMap.KX or -0.85, ShadowMap.KZ or -0.55
  local density = 0
  for i = 1, #clouds do
    local c = clouds[i]
    local up = max(0, c.cy - by)
    local x = bx - kx * up + (ox or 0)
    local z = bz - kz * up + (oz or 0)
    local dx, dz = x - c.cx, z - c.cz
    if dx * dx + dz * dz < 42000 then
      density = max(density, cloudBodyAt(c, x, z))
      if density > 0.92 then break end
    end
  end
  local core = smoothstepLua(0.18, 0.86, density)
  return lerp(1.0, 0.055, core)
end

local CLOUD_SHADER = [[
  varying vec2 vLocal;
  varying float vPhase;
  varying float vAlpha;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 axisR;
  uniform vec3 axisU;
  uniform float time;
  attribute vec4 CloudData;    // local x, local y, phase, alpha
  attribute vec4 CloudShape;   // half width, half height, drift, rate

  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec3 base = vertex_position.xyz;
    // Same deliberately conservative structure as the proven Android particle
    // shader: a world-space centre plus two camera-facing axes. The puff only
    // breathes/drifts slightly; the macro lane drift is handled by Lua.
    float t = time * CloudShape.w + CloudData.z;
    base.x += sin(t * 0.53 + CloudData.z * 3.7) * CloudShape.z;
    base.z += cos(t * 0.41 + CloudData.z * 2.9) * CloudShape.z * 0.58;
    base.y += sin(t * 0.29 + CloudData.z * 5.1) * 1.8;

    vLocal = CloudData.xy;
    vPhase = CloudData.z;
    vAlpha = CloudData.w;
    vec3 p = base + axisR * (CloudData.x * CloudShape.x)
                  + axisU * (CloudData.y * CloudShape.y);
    return vp * vec4(p, 1.0);
  }
#endif
#ifdef PIXEL
  uniform vec3 cloudColor;
  uniform vec3 rayColor;
  uniform vec2 sunScreen;
  uniform float time;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec2 p = vLocal;
    // One puff is soft and rounded. Cloud complexity comes from many puffs at
    // independent sizes/depths, which is both more natural and much cheaper on
    // Android than one procedural mega-shader.
    float d = length(vec2(p.x * 0.94, p.y * 1.04));
    float body = 1.0 - smoothstep(0.56, 1.0, d);
    float inner = 1.0 - smoothstep(0.20, 0.82, d);
    float detail = 0.94
      + 0.035 * sin(p.x * 10.0 + p.y * 6.0 + vPhase * 7.0 + time * 0.020)
      + 0.025 * sin(p.x * 17.0 - p.y * 11.0 + vPhase * 11.0);
    float a = clamp(vAlpha * body * detail, 0.0, 0.96);

    float underside = mix(0.64, 1.02, smoothstep(-0.82, 0.72, p.y));
    vec2 n = normalize(p + vec2(0.0001));
    vec2 sdir = normalize(sunScreen + vec2(0.0001));
    float facing = max(0.0, dot(n, sdir));
    float rimBand = smoothstep(0.18, 0.70, body) * (1.0 - smoothstep(0.70, 0.97, inner));
    float rim = rimBand * facing;
    vec3 rgb = cloudColor * underside + rayColor * rim * 0.56;
    return vec4(rgb, a) * color;
  }
#endif
]]

local CLOUD_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "CloudData", "float", 4 },
  { "CloudShape", "float", 4 },
}

local cloudShaderState, cloudMesh = nil, nil

local function cloudShader()
  if cloudShaderState ~= nil then return cloudShaderState or nil end
  local ok, sh = pcall(love.graphics.newShader, CLOUD_SHADER)
  cloudShaderState = (ok and sh) or false
  if not ok then print("[Weather] volumetric cloud shader refused: " .. tostring(sh)) end
  return cloudShaderState or nil
end

local function buildCloudVertices(Voxel3D, frame, clouds)
  if not clouds or #clouds == 0 then return nil, nil end
  local verts, indices, q = {}, {}, 0
  local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

  for ciCloud = 1, #clouds do
    local c = clouds[ciCloud]
    local ix, iz = c.ix, c.iz
    local spanX = 54 + c.styleB * 58
    local spanZ = 34 + c.styleC * 48
    local spanY = 12 + c.styleA * 24
    local puffs = frame.level > 0.9 and (14 + floor(c.styleC * 5)) or (11 + floor(c.styleC * 4))

    for k = 1, puffs do
      local hk = 300 + k * 11
      local rx = hash2(ix, iz, hk + 1) * 2 - 1
      local ry = hash2(ix, iz, hk + 2) * 2 - 1
      local rz = hash2(ix, iz, hk + 3) * 2 - 1
      local core = k <= 5
      local ox = rx * spanX * (core and 0.36 or 0.86)
      local oy = ry * spanY * (core and 0.30 or 0.82)
      local oz = rz * spanZ * (core and 0.34 or 0.90)
      if k == 1 then ox, oy, oz = 0, 0, 0 end
      if k == 2 then ox, oy = -spanX * 0.31, spanY * 0.08 end
      if k == 3 then ox, oy =  spanX * 0.30, spanY * 0.02 end
      if k == 4 then ox, oy =  spanX * 0.02, spanY * 0.44 end

      local hw = (42 + hash2(ix, iz, hk + 4) * 40) * (0.88 + c.styleB * 0.28)
      local hh = (20 + hash2(ix, iz, hk + 5) * 24) * (0.84 + c.styleA * 0.42)
      local alpha = (0.34 + hash2(ix, iz, hk + 6) * 0.20) * frame.level
      if core then alpha = alpha * 1.18 end
      local puffPhase = c.phase + hash2(ix, iz, hk + 7) * 1.25
      local drift = 3.5 + hash2(ix, iz, hk + 8) * 6.5
      local rate = 0.035 + hash2(ix, iz, hk + 9) * 0.040

      for corner = 1, 4 do
        local co = corners[corner]
        verts[#verts + 1] = {
          c.cx + ox, c.cy + oy, c.cz + oz,
          co[1], co[2], puffPhase, alpha,
          hw, hh, drift, rate,
        }
      end
      pushQuad(indices, q)
      q = q + 1
    end
  end
  return verts, indices
end

local function drawClouds(Voxel3D, frame, clouds)
  local sh = cloudShader()
  local axisR, axisU = billboardAxes(Voxel3D)
  if not (sh and axisR and axisU) then return end
  local verts, indices = buildCloudVertices(Voxel3D, frame, clouds)
  if not (verts and indices and #verts > 0) then return end
  if not cloudMesh then
    local ok, mesh = pcall(love.graphics.newMesh, CLOUD_FORMAT, verts, "triangles", "stream")
    if not ok then return end
    cloudMesh = mesh
  else
    local ok = pcall(cloudMesh.setVertices, cloudMesh, verts)
    if not ok then cloudMesh = nil return drawClouds(Voxel3D, frame, clouds) end
  end
  pcall(cloudMesh.setVertexMap, cloudMesh, indices)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  if Voxel3D.beginEffect(sh) then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "axisR", axisR)
    pcall(sh.send, sh, "axisU", axisU)
    pcall(sh.send, sh, "time", ForestAtmos.time)
    local tint = DayNight.tint(true)
    local base = mixColor({ 0.67, 0.73, 0.82 }, { 0.97, 0.96, 0.91 },
                          min(1, (frame.rayColor[1] + frame.rayColor[2]) * 0.28))
    pcall(sh.send, sh, "cloudColor", {
      min(1, base[1] * (0.74 + tint[1] * 0.27)),
      min(1, base[2] * (0.74 + tint[2] * 0.27)),
      min(1, base[3] * (0.74 + tint[3] * 0.27)),
    })
    pcall(sh.send, sh, "rayColor", frame.rayColor)

    local kx, kz = ShadowMap.KX or -0.85, ShadowMap.KZ or -0.55
    local sx, sy, sz = -kx, 1.0, -kz
    local sl = sqrt(sx * sx + sy * sy + sz * sz)
    sx, sy, sz = sx / sl, sy / sl, sz / sl
    local sr = sx * axisR[1] + sy * axisR[2] + sz * axisR[3]
    local su = sx * axisU[1] + sy * axisU[2] + sz * axisU[3]
    pcall(sh.send, sh, "sunScreen", { sr, su })

    pcall(love.graphics.draw, cloudMesh)
    Voxel3D.endEffect()
  end
end

-- ---------- public draw

-- Gen2 Battle Art has no VoxelCompanion atmosphere phases or cloud deck.
-- Give the standalone bridge a narrow fallback that reuses the proven cloud
-- descriptor/batch path without also enabling puddles, mist, rays or motes.
function CinematicAtmos.drawQuestClouds(Voxel3D, map, outdoor)
  CinematicAtmos.questSkyFallback = true
  local frame = CinematicAtmos.frame(map, outdoor)
  if not frame then return false end
  local clouds = buildCloudDescriptors(Voxel3D, frame, true)
  if #clouds == 0 then return false end
  drawParticles(Voxel3D, frame, clouds, true)
  return true
end

function CinematicAtmos.draw(map, outdoor, neighbors, posed)
  local Voxel3D = V.require("Voxel3D")
  local frame = CinematicAtmos.frame(map, outdoor)
  if not frame then return end

  -- One descriptor set drives both cloud geometry and cloud occlusion of the
  -- light shafts, so the lighting response tracks the clouds the player sees.
  local clouds = buildCloudDescriptors(Voxel3D, frame)
  -- Reflective ground wetness is underneath the atmospheric volumes, so fog,
  -- shafts and precipitation can naturally pass over the mirror surface.
  drawPuddles(Voxel3D, frame, map, neighbors)
  drawSnowPacks(Voxel3D, frame, map, neighbors, outdoor)
  drawSpriteReflections(Voxel3D, frame, map, neighbors, posed)
  -- A14: clouds ride the exact same proven Android draw call as particles.
  drawMist(Voxel3D, frame)
  drawRollFog(Voxel3D, frame)
  drawParticles(Voxel3D, frame, clouds)
  if not (package.loaded and package.loaded._WX_NIGHT) then
    drawRays(Voxel3D, frame, clouds)
  end
  -- Precipitation is drawn last inside the same depth-tested 3D scene so it
  -- remains visible against shafts/clouds while roofs, trees and terrain still
  -- occlude every streak correctly.
  -- True world-space rain/snow (360° volume, camera orientation independent).
  if not WorldPrecip then
    pcall(function() WorldPrecip = V.require("WorldPrecip") end)
  end
  if WorldPrecip and WorldPrecip.draw then
    pcall(function()
      -- Stream volume anchors on world focus (player/look-at), NEVER camera eye
      -- alone and NEVER camera rotation. Eye is only used at draw time for billboards.
      local foc = Voxel3D.focus
      if not foc and Voxel3D.player then foc = Voxel3D.player end
      if not foc then foc = Voxel3D.eye end
      local dt = 1/60
      if love and love.timer and love.timer.getDelta then dt = love.timer.getDelta() or dt end
      WorldPrecip.update(dt, foc, frame.weather)
      WorldPrecip.draw(Voxel3D, frame)
    end)
  else
    drawRain(Voxel3D, frame)
    -- drawSnow3D disabled (camera-locked lattice)
  end

  -- Restore the scene defaults expected by props drawn after atmosphere.
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", true)
end

function CinematicAtmos.invalidate()
  pcall(function() if WorldPrecip and WorldPrecip.invalidate then WorldPrecip.invalidate() end end)
  mistMesh, rollMesh, particleMesh, rainMesh, rayMesh, cloudMesh, puddleMesh = nil, nil, nil, nil, nil, nil, nil
  puddleMeshKey = nil
  mistShaderState, rollShaderState, particleShaderState, rainShaderState, rayShaderState, cloudShaderState, puddleBaseShaderState = nil, nil, nil, nil, nil, nil, nil
end

return CinematicAtmos
