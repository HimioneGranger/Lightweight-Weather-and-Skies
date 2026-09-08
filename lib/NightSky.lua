-- NightSky — celestial sphere for Weather FX (Dramaless / Potato / Gen2).
--
-- Architecture (do not break this model):
--   • Each star has a FIXED unit direction D in world space (permanent home).
--   • D is generated once; never regenerated from player position or camera.
--   • Render position = camera_eye + D * SKY_RADIUS (translation only).
--   • Orientation comes solely from Voxel3D.vp (view-projection).
--   • Camera rotation changes which part of the sphere is visible.
--   • Camera translation does not create parallax (sphere is re-centered).
--
-- Stars are drawn BEFORE volumetric clouds so weather occludes them.

local V = ...
local Constellations
pcall(function() Constellations = V.require("Constellations") end)
local NightSky = {}
local DesktopWeatherProfile = V.require('DesktopWeatherProfile')

NightSky._DayNight = nil
NightSky._FirstPerson = nil
NightSky._Voxel = nil
NightSky._TOD = nil
NightSky.DEBUG = false  -- set true for marker star + basis dump

function NightSky.constellationsEnabled()
  if not V.questLitePrivate then return true end
  local ok, enabled = pcall(function()
    local compat = V.mod.find("BATTLE_ART_QUEST_COMPAT")
    local prefs=V.mod.exports.weatherPreferences or (compat and compat.exports and compat.exports.quest)
    return prefs and prefs.constellations()
  end)
  return ok and enabled == true
end

-- ---------------------------------------------------------------------------
-- Night detection
-- ---------------------------------------------------------------------------
function NightSky.isNight(body)
  if body and body.moon then return true end
  local TOD = NightSky._TOD
  if not TOD then
    pcall(function()
      if V and V.require then TOD = V.require("TimeOfDay") end
    end)
    NightSky._TOD = TOD
  end
  if TOD then
    if TOD.pin == "NITE" or TOD.pin == "NIGHT" then return true end
    if TOD.tod == "NITE" or TOD.tod == "NIGHT" then return true end
    if TOD.isNight and TOD.isNight() then return true end
    if type(TOD.hour) == "number" then
      local h = TOD.hour % 24
      if h >= 20 or h < 4 then return true end
    end
    -- Explicit day pins only block when host is also not night.
    if TOD.pin == "DAY" or TOD.pin == "MORN" then
      -- still allow Dramaless DayNight night below
    elseif TOD.tod == "MORN" or TOD.tod == "DAY" or TOD.tod == "EVE" then
      -- fall through to host DayNight check
    end
    if type(TOD.daylight) == "function" then
      local ok, d = pcall(TOD.daylight)
      if ok and type(d) == "number" and d < 0.12 then return true end
    end
  end
  -- Dramaless / host voxel DayNight (primary for 3D outdoor night)
  local DN = NightSky._DayNight
  if DN then
    if DN.isNight and type(DN.isNight) == "function" then
      local ok, n = pcall(DN.isNight)
      if ok and n then return true end
    end
    if type(DN.time) == "function" and DN.bodyAt then
      local ok, tt = pcall(DN.time)
      if ok and type(tt) == "number" then
        local ok2, th, el, moon = pcall(DN.bodyAt, tt)
        if ok2 and moon then return true end
      end
    end
    if type(DN.mix) == "function" and type(DN.time) == "function" then
      local ok, tt = pcall(DN.time)
      if ok then
        local ok2, mix = pcall(DN.mix, tt)
        if ok2 and type(mix) == "table" then
          local n = (mix.night or 0) + (mix.nite or 0)
          if n > 0.45 then return true end
        end
      end
    end
  end
  if package.loaded and package.loaded._WX_NIGHT then return true end
  return false
end

-- Stars always attempt at night (top-down may still depth-occlude).
function NightSky.skyVisible(_Voxel3D)
  return true
end

-- ---------------------------------------------------------------------------
-- Day/night star visibility (alpha only — celestial D never changes)
--
-- Tied EXACTLY to Weather FX TimeOfDay phases (TOD.phaseAt):
--   DAY  (10–17)  → 0%
--   EVE  (17–20)  → fade IN  0% → 100%
--   NITE (20–4)   → 100%
--   MORN (4–10)   → fade OUT 100% → 0%
-- ---------------------------------------------------------------------------
NightSky._nightVis = 0
NightSky._nightVisRaw = 0

local function smoothstep(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

-- Phase hour windows — must match lib/TimeOfDay.lua TOD.phaseAt
local MORN_START, MORN_END = 4.0, 10.0
local DAY_START, DAY_END = 10.0, 17.0
local EVE_START, EVE_END = 17.0, 20.0
-- NITE is 20 → 24 and 0 → 4

--- Global star visibility 0..1 from DAY / EVE / NITE / MORN only.
function NightSky.computeNightVisibility()
  local TOD = NightSky._TOD
  if not TOD then
    pcall(function()
      if V and V.require then TOD = V.require("TimeOfDay") end
    end)
    NightSky._TOD = TOD
  end

  -- Host Dramaless night always lights stars unless player pinned DAY.
  local pin = TOD and TOD.pin
  if pin == "DAY" then return 0 end
  if pin == "NITE" or pin == "NIGHT" then return 1 end
  if NightSky.isNight(nil) then return 1 end
  if not TOD then
    return 0
  end

  -- OPTIONS TIME pin wins (player set NITE / DAY / etc.)
  if pin == "EVE" then
    local h = 19.0
    return smoothstep((h - EVE_START) / (EVE_END - EVE_START))
  end
  if pin == "MORN" then
    local h = 7.0
    return 1 - smoothstep((h - MORN_START) / (MORN_END - MORN_START))
  end

  local h = tonumber(TOD.hour)
  local phase = TOD.tod
  if type(h) == "number" then
    h = h % 24
    if type(TOD.phaseAt) == "function" then
      local ok, p = pcall(TOD.phaseAt, h)
      if ok and type(p) == "string" then phase = p end
    end
  else
    if phase == "NITE" or phase == "NIGHT" then return 1 end
    if phase == "DAY" then return 0 end
    if phase == "EVE" then return 0.5 end
    if phase == "MORN" then return 0.5 end
    return 0
  end

  if phase == "DAY" then return 0 end
  if phase == "NITE" or phase == "NIGHT" then return 1 end
  if phase == "EVE" then
    local u = (h - EVE_START) / (EVE_END - EVE_START)
    return smoothstep(clamp01(u))
  end
  if phase == "MORN" then
    local u = (h - MORN_START) / (MORN_END - MORN_START)
    return 1 - smoothstep(clamp01(u))
  end

  -- Hour fallback matching TOD.phaseAt bands
  if h >= DAY_START and h < DAY_END then return 0 end
  if h >= EVE_START and h < EVE_END then
    return smoothstep(clamp01((h - EVE_START) / (EVE_END - EVE_START)))
  end
  if h >= MORN_START and h < MORN_END then
    return 1 - smoothstep(clamp01((h - MORN_START) / (MORN_END - MORN_START)))
  end
  return 1
end

function NightSky.starFade(s, globalVis)
  globalVis = tonumber(globalVis) or 0
  if globalVis <= 0.001 then return 0 end
  if globalVis >= 0.999 then return 1 end
  return clamp01(globalVis)
end

--- Twinkle multiplier for alpha only (never changes celestial direction D).
--- Combines a primary and secondary sine so the field does not pulse in unison.
function NightSky.twinkleAlpha(s, time)
  time = tonumber(time) or 0
  if not s then return 1 end
  local d = tonumber(s.twDepth) or 0.2
  local tw = tonumber(s.tw) or 1
  local tw2 = tonumber(s.tw2) or 0.4
  local ph = tonumber(s.phase) or 0
  local ph2 = tonumber(s.phase2) or 1
  local w1 = 0.65 * math.sin(time * tw + ph)
  local w2 = 0.35 * math.sin(time * tw2 + ph2)
  local m = 1 + d * (0.55 * w1 + 0.45 * w2)
  if m < 0.35 then m = 0.35 end
  if m > 1.25 then m = 1.25 end
  return m
end

--- Building-proximity density: ~50% of stars (spatially balanced) fade out
--- near buildings. BuildingLight.factor is 0 near / 1 far — multiplies alpha
--- only for hideNearBuilding stars. Group assignment is permanent.
function NightSky.buildingDensityMul(s)
  if not s or not s.hideNearBuilding then return 1 end
  local f = 1
  pcall(function()
    local BL = V.require("BuildingLight")
    if BL and type(BL.factor) == "number" then
      f = BL.factor
    end
  end)
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return f
end


-- ---------------------------------------------------------------------------
-- Deterministic celestial catalog (generated once)
-- ---------------------------------------------------------------------------
local STARS = {}
local PLANETS = {}

do
  local function hash(n)
    local x = math.sin(n * 127.1) * 43758.5453
    return x - math.floor(x)
  end

  -- Natural distribution: clustered bands + sparse voids, full 360° azimuth.
  -- Population ~2× prior (640 → 1280). Base alpha slightly reduced so 2×
  -- count does not over-brighten the sky.
  local N = 1280
  for i = 1, N do
    local az = hash(i * 3.17) * math.pi * 2
    local band = hash(i * 0.41)
    local el
    if band < 0.55 then
      el = (0.02 + hash(i * 7.91) * 0.55) * (math.pi * 0.5)
    elseif band < 0.82 then
      el = (0.45 + hash(i * 9.3) * 0.50) * (math.pi * 0.5)
    else
      el = (hash(i * 5.1) * 0.12 - 0.04) * (math.pi * 0.5)
    end
    local ce, se = math.cos(el), math.sin(el)
    local dx = math.sin(az) * ce
    local dy = se
    local dz = math.cos(az) * ce
    local L = math.sqrt(dx * dx + dy * dy + dz * dz)
    if L > 1e-8 then dx, dy, dz = dx / L, dy / L, dz / L end

    local mag = hash(i * 11.3)
    -- Slightly lower peak alpha than 640-star field (richer, not washed out)
    local bright = 0.42 + (1 - mag) * 0.40
    STARS[i] = {
      id = i,
      dx = dx, dy = dy, dz = dz,
      az = az, el = el,
      size = 0.40 + (1 - mag) * 1.55 + hash(i * 2.7) * 0.35,
      a = bright,
      r = 0.86 + hash(i * 2.1) * 0.14,
      g = 0.88 + hash(i * 4.3) * 0.12,
      b = 0.94 + hash(i * 6.7) * 0.06,
      tw = 0.35 + hash(i * 13.7) * 2.2,
      tw2 = 0.15 + hash(i * 23.3) * 0.9,
      phase = hash(i * 19.1) * math.pi * 2,
      phase2 = hash(i * 29.7) * math.pi * 2,
      twDepth = 0.12 + hash(i * 31.1) * 0.28,
      hideNearBuilding = false,  -- set below (spatially balanced)
    }
  end

  -- Spatially balanced ~50% building-hidden group (deterministic, once).
  -- Bin by azimuth × elevation so no sky region is stripped bare.
  do
    local AZ_BINS, EL_BINS = 12, 6
    local bins = {}
    for i = 1, #STARS do
      local s = STARS[i]
      local az = s.az or 0
      if az < 0 then az = az + math.pi * 2 end
      local el = s.el or 0
      local elN = (el + 0.05) / (math.pi * 0.5 + 0.1)
      if elN < 0 then elN = 0 elseif elN > 1 then elN = 1 end
      local bi = math.floor(az / (math.pi * 2) * AZ_BINS) % AZ_BINS
      local bj = math.floor(elN * EL_BINS)
      if bj >= EL_BINS then bj = EL_BINS - 1 end
      local key = bi * EL_BINS + bj
      local bucket = bins[key]
      if not bucket then
        bucket = {}
        bins[key] = bucket
      end
      bucket[#bucket + 1] = i
    end
    for _, bucket in pairs(bins) do
      table.sort(bucket, function(a, b)
        return hash(a * 17.9) < hash(b * 17.9)
      end)
      local nHide = math.floor(#bucket * 0.5 + 0.5)
      for j = 1, #bucket do
        STARS[bucket[j]].hideNearBuilding = (j <= nHide)
      end
    end
  end

  -- Marker star for acceptance tests (DEBUG): bright gold; never hide near buildings
  STARS[1].r, STARS[1].g, STARS[1].b = 1.0, 0.82, 0.35
  STARS[1].a = 0.95
  STARS[1].size = 3.0
  STARS[1].hideNearBuilding = false

local pdata = {
    -- sizes 2× for readability against the star field
    { az = 0.9,  el = 0.55, size = 5.6, r = 0.92, g = 0.78, b = 0.58, a = 1.0 },
    { az = 3.6,  el = 0.42, size = 4.8, r = 0.72, g = 0.82, b = 0.98, a = 0.90 },
    { az = 5.1,  el = 0.68, size = 4.2, r = 0.98, g = 0.84, b = 0.72, a = 0.85 },
    { az = 1.8,  el = 0.35, size = 4.6, r = 0.78, g = 0.90, b = 0.72, a = 0.82 },
    { az = 4.4,  el = 0.72, size = 3.8, r = 0.95, g = 0.70, b = 0.65, a = 0.80 },
  }
  for i, p in ipairs(pdata) do
    local ce, se = math.cos(p.el), math.sin(p.el)
    local dx = math.sin(p.az) * ce
    local dy = se
    local dz = math.cos(p.az) * ce
    local L = math.sqrt(dx * dx + dy * dy + dz * dz)
    PLANETS[i] = {
      id = i,
      dx = dx / L, dy = dy / L, dz = dz / L,
      size = p.size, r = p.r, g = p.g, b = p.b, a = p.a,
    }
  end
end

-- ---------------------------------------------------------------------------
-- GPU path: fixed directions → world pos via eye + D*R → Voxel3D.vp
-- ---------------------------------------------------------------------------
local STAR_SHADER = [[
  varying vec4 vColor;
#ifdef VERTEX
  uniform mat4 vp;
  uniform float celestialDepth;
  // VertexColor is supplied by LÖVE.
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vColor = VertexColor;
    vec4 clip=vp*vertex_position;
    // Celestial distance is beyond terrain/clouds, irrespective of the small
    // helper dome used to construct its quads. Preserve projected x/y rays.
    if(celestialDepth>0.5 && clip.w>0.0) clip.z=clip.w*0.999999;
    return clip;
  }
#endif
#ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec2 point = tc * 2.0 - 1.0;
    float distanceSquared = dot(point, point);
    if (distanceSquared >= 1.0) discard;
    float edgeAlpha = 1.0 - smoothstep(0.45, 1.0, distanceSquared);
    return vColor * color * vec4(1.0, 1.0, 1.0, edgeAlpha);
  }
#endif
]]

local FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexColor", "float", 4 },
  { "VertexTexCoord", "float", 2 },
}

local shader, mesh = nil, nil

local function ensureShader()
  if shader then return shader end
  if not (love and love.graphics and love.graphics.newShader) then return nil end
  local ok, sh = pcall(love.graphics.newShader, STAR_SHADER)
  if ok then shader = sh else error("World NightSky shader: " .. tostring(sh)) end
  return shader
end

local SKY_RADIUS = 420  -- large vs playable map; re-centered on eye each frame

local function rotateY(dx, dy, dz, ang)
  -- Daily celestial vault rotation about world UP (parallax-free with observer).
  local c, s = math.cos(ang), math.sin(ang)
  return dx * c + dz * s, dy, -dx * s + dz * c
end

local function skyRadius(Voxel3D)
  local r = SKY_RADIUS
  -- Optional PC policy decouples apparent celestial size from terrain range.
  local desktopProfile = DesktopWeatherProfile.current()
  if desktopProfile then
    return math.max(180, DesktopWeatherProfile.value(desktopProfile, 'skyRadius', r, 10000))
  end
  local far = Voxel3D and (Voxel3D.far or (Voxel3D.camera and Voxel3D.camera.far))
  if type(far) == "number" and far > 80 then
    r = math.min(far * 0.88, math.max(r, far * 0.7))
  end
  return r
end

-- Billboard axes from camera (orientation only — does not move star homes).
local function billboardAxes(Voxel3D)
  local e, fo = Voxel3D.eye, Voxel3D.focus
  if not e then return nil, nil end
  if not fo then fo = { e[1], e[2], e[3] - 1 } end
  local fx, fy, fz = fo[1] - e[1], fo[2] - e[2], fo[3] - e[3]
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return nil, nil end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  -- right ≈ forward × world-up alternate: (-fz, 0, fx)
  local rx, ry, rz = -fz, 0, fx
  local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rl < 1e-6 then rx, ry, rz = 1, 0, 0 else rx, ry, rz = rx / rl, ry / rl, rz / rl end
  local ux = ry * fz - rz * fy
  local uy = rz * fx - rx * fz
  local uz = rx * fy - ry * fx
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  if ul < 1e-6 then return { rx, ry, rz }, { 0, 1, 0 } end
  return { rx, ry, rz }, { ux / ul, uy / ul, uz / ul }
end

local VERT_POOL = {}
local function vertAt(i)
  local v = VERT_POOL[i]
  if not v then
    v = { 0, 0, 0, 0, 0, 0, 0 }
    VERT_POOL[i] = v
  end
  return v
end

local function pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, r, g, b, a)
  local hx, hy, hz = axisR[1] * half, axisR[2] * half, axisR[3] * half
  local vx, vy, vz = axisU[1] * half, axisU[2] * half, axisU[3] * half
  -- two triangles
  local function corner(ox, oy, oz, u, vCoord)
    n = n + 1
    local v = vertAt(n)
    v[1], v[2], v[3] = cx + ox, cy + oy, cz + oz
    v[4], v[5], v[6], v[7] = r, g, b, a
    v[8], v[9] = u, vCoord
    verts[n] = v
  end
  -- tri 1
  corner(-hx - vx, -hy - vy, -hz - vz, 0, 0)
  corner( hx - vx,  hy - vy,  hz - vz, 1, 0)
  corner( hx + vx,  hy + vy,  hz + vz, 1, 1)
  -- tri 2
  corner(-hx - vx, -hy - vy, -hz - vz, 0, 0)
  corner( hx + vx,  hy + vy,  hz + vz, 1, 1)
  corner(-hx + vx, -hy + vy, -hz + vz, 0, 1)
  return n
end

local function celestialLod()
  local lod = { starStep = 1, maxPlanets = 5, twinkle = true, meteors = true }
  pcall(function()
    local Q = V.require("Quality")
    if Q and Q.celestial then
      local c = Q.celestial()
      if c then
        lod.starStep = math.max(1, tonumber(c.starStep) or 1)
        lod.maxPlanets = math.max(0, tonumber(c.maxPlanets) or 5)
        lod.twinkle = c.twinkle ~= false
        lod.meteors = c.meteors ~= false
      end
    end
  end)
  return lod
end

local function starScaleNow()
  local starScale = 1
  pcall(function()
    local BL = V.require("BuildingLight")
    if BL and BL.starScale then starScale = BL.starScale() or 1 end
  end)
  if type(starScale) ~= "number" or starScale ~= starScale then starScale = 1 end
  if starScale < 0.4 then starScale = 0.4 end
  if starScale > 1 then starScale = 1 end
  return starScale
end


-- ---------------------------------------------------------------------------
-- Sun / Moon as world-space entities on the celestial sphere (same path as stars).
-- Drawn day AND night (does not use nightVis). Noon = overhead (+Y).
-- Player must look up in FPV/3rd to see noon sun; horizon view hides it.
-- ---------------------------------------------------------------------------

-- Stand down if another system already draws a sun/moon (voxel host DayNight bodies).
local function hostCelestialFlags()
  local hasSun, hasMoon = false, false
  pcall(function()
    local DN = NightSky._DayNight
    if not DN then return end
    -- Common host patterns: sunDir/moonDir, sunVisible, getSun, bodies
    if DN.sunDir or DN.sunPosition or DN.getSun or DN.sun then hasSun = true end
    if DN.moonDir or DN.moonPosition or DN.getMoon or DN.moon then hasMoon = true end
    if type(DN.hasSun) == "boolean" then hasSun = DN.hasSun end
    if type(DN.hasMoon) == "boolean" then hasMoon = DN.hasMoon end
    -- Explicit draw already done this frame by host
    if DN._wxHostDrewSun then hasSun = true end
    if DN._wxHostDrewMoon then hasMoon = true end
  end)
  pcall(function()
    local Voxel = NightSky._Voxel
    if Voxel and Voxel.sunDrawn then hasSun = true end
    if Voxel and Voxel.moonDrawn then hasMoon = true end
  end)
  return hasSun, hasMoon
end

function NightSky.drawSunMoonWorld(Voxel3D)

  local hostSun, hostMoon = hostCelestialFlags()
  if not (Voxel3D and Voxel3D.vp and Voxel3D.eye) then return false end
  local CB
  pcall(function() CB = V.require("CelestialBodies") end)
  if not (CB and CB.bodies) then return false end
  local hour
  pcall(function()
    local TOD = V.require("TimeOfDay")
    hour = TOD and TOD.hour
  end)
  local b = CB.bodies(hour)
  local body = nil
  -- Prefer sun then moon, but stand down per-body if host already draws it.
  if (not hostSun) and b.sun and b.sun.alpha and b.sun.alpha > 0.02 then body = b.sun
  elseif (not hostMoon) and b.moon and b.moon.alpha and b.moon.alpha > 0.02 then body = b.moon
  end
  if not body then return false end

  local sh = ensureShader()
  if not sh then return false end
  local axisR, axisU = billboardAxes(Voxel3D)
  if not (axisR and axisU) then return false end
  local e = Voxel3D.eye
  local radius = skyRadius(Voxel3D)
  if radius > 400 then radius = 400 end
  if radius < 180 then radius = 180 end
  -- Layer: moon nearer than sun (depth occlusion like scientific simulators)
  local layer = 0.96
  if body.kind == "moon" then layer = 0.94 end
  pcall(function()
    local Sim = V.require("CelestialSim")
    if Sim and Sim.LAYER then
      layer = (body.kind == "moon") and (Sim.LAYER.moon or 0.94) or (Sim.LAYER.sun or 0.96)
    end
  end)
  radius = radius * layer

  local cx = e[1] + body.dx * radius
  local cy = e[2] + body.dy * radius
  local cz = e[3] + body.dz * radius

  local verts = NightSky._sunVerts
  if not verts then verts = {}; NightSky._sunVerts = verts end
  local n = 0
  local isMoon = body.kind == "moon"
  -- Large billboard stack so it reads as a distant sun/moon disk
  local core = isMoon and 20 or 28
  local a = body.alpha or 1
  if isMoon then
    n = pushQuad(verts, n, cx, cy, cz, core * 1.5, axisR, axisU, 0.55, 0.62, 0.85, a * 0.35)
    n = pushQuad(verts, n, cx, cy, cz, core,       axisR, axisU, 0.85, 0.88, 0.95, a * 0.85)
    n = pushQuad(verts, n, cx, cy, cz, core * 0.45, axisR, axisU, 1.0, 1.0, 1.0, a)
  else
    n = pushQuad(verts, n, cx, cy, cz, core * 2.2, axisR, axisU, 1.0, 0.65, 0.25, a * 0.25)
    n = pushQuad(verts, n, cx, cy, cz, core * 1.5, axisR, axisU, 1.0, 0.85, 0.40, a * 0.45)
    n = pushQuad(verts, n, cx, cy, cz, core,       axisR, axisU, 1.0, 0.95, 0.65, a * 0.9)
    n = pushQuad(verts, n, cx, cy, cz, core * 0.4, axisR, axisU, 1.0, 1.0, 0.95, a)
  end
  for i = n + 1, #verts do verts[i] = nil end
  if n < 3 then return false end

  if not NightSky._sunMesh then
    local ok, m = pcall(love.graphics.newMesh, FORMAT, verts, "triangles", "stream")
    if not ok or not m then return false end
    NightSky._sunMesh = m
  else
    if not pcall(NightSky._sunMesh.setVertices, NightSky._sunMesh, verts) then
      NightSky._sunMesh = nil
      return NightSky.drawSunMoonWorld(Voxel3D)
    end
  end

  local prev
  pcall(function() prev = { love.graphics.getBlendMode() } end)
  pcall(love.graphics.setBlendMode, "add", "alphamultiply")
  pcall(love.graphics.setDepthMode, "always", false)
  local began = false
  if Voxel3D.beginEffect then began = Voxel3D.beginEffect(sh) end
  if not began then pcall(love.graphics.setShader, sh) end
  if not pcall(sh.send, sh, "vp", "row", Voxel3D.vp) then
    pcall(sh.send, sh, "vp", Voxel3D.vp)
  end
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, NightSky._sunMesh)
  if Voxel3D.endEffect then pcall(Voxel3D.endEffect)
  else pcall(love.graphics.setShader) end
  pcall(love.graphics.setDepthMode, "lequal", true)
  if prev then pcall(love.graphics.setBlendMode, prev[1], prev[2]) end
  return true
end

--- Primary renderer: celestial sphere through the host view-projection matrix.
function NightSky.drawWorld(Voxel3D, time)
  -- Always sample current TOD/pin so OPTIONS → NITE is never stuck at 0.
  local target = NightSky.computeNightVisibility()
  NightSky._nightVisRaw = target
  local nightVis = NightSky._nightVis or target
  if math.abs(target - nightVis) > 0.25 then
    nightVis = target  -- pin / sleep / load snap
  end
  NightSky._nightVis = nightVis
  if nightVis < 0.02 then return false end
  if not (Voxel3D and Voxel3D.vp) then return false end
  local e = Voxel3D.eye
  if not e then return false end

  local sh = ensureShader()
  if not sh then return false end
  sh:send('celestialDepth',V.questLitePrivate and 1 or 0)
  local axisR, axisU = billboardAxes(Voxel3D)
  if not (axisR and axisU) then return false end

  local radius = skyRadius(Voxel3D)
  local t = tonumber(time) or 0
  local scale = starScaleNow()
  local verts = NightSky._worldVerts
  if not verts then
    verts = {}
    NightSky._worldVerts = verts
  end
  local n = 0

  -- LOD: step through catalog (full positions still fixed on the sphere).
  local lod = celestialLod()
  local step = lod.starStep or 1
  -- Daily vault angle (same clock as sun) — stars share the celestial sphere.
  local vaultAng = 0
  pcall(function()
    local Sim = V.require("CelestialSim")
    if Sim and Sim.solarAlpha then vaultAng = Sim.solarAlpha() or 0 end
  end)

  local desktopProfile = DesktopWeatherProfile.current()
  local desktopSize = DesktopWeatherProfile.value(desktopProfile, 'starSize', 1, 3)
  local desktopBrightness = DesktopWeatherProfile.value(desktopProfile, 'starBrightness', 1, 3)
  for i = 1, #STARS, step do
    local s = STARS[i]
    local fade = NightSky.starFade(s, nightVis)
    local dens = NightSky.buildingDensityMul(s)
    if fade > 0.01 and dens > 0.02 then
      local sdx, sdy, sdz = rotateY(s.dx, s.dy, s.dz, vaultAng)
      -- Horizon fade for stars near/below horizon
      local hf = 1
      pcall(function()
        local Sim = V.require("CelestialSim")
        if Sim and Sim.horizonFade then hf = Sim.horizonFade(sdy) end
      end)
      if hf >= 0.02 then
        local cx = e[1] + sdx * radius
        local cy = e[2] + sdy * radius
        local cz = e[3] + sdz * radius
        local tw = 1
        if lod.twinkle then tw = NightSky.twinkleAlpha(s, t) end
        local a = s.a * scale * fade * dens * tw * hf * desktopBrightness
        if NightSky.DEBUG and i == 1 then
          a = math.max(a, 0.85 * fade)
        end
        local half = math.max(0.5, s.size * 0.55) * desktopSize
        if desktopProfile then
          -- Tangent to the celestial sphere: independent of the captured
          -- camera's yaw/pitch, which can precede the rendered camera frame.
          local len=math.sqrt(sdx*sdx+sdz*sdz)
          local rx,rz=1,0
          if len>1e-6 then rx,rz=-sdz/len,sdx/len end
          local right={rx,0,rz}
          local up={-sdy*rz,sdz*rx-sdx*rz,sdy*rx}
          n=pushQuad(verts,n,cx,cy,cz,half,right,up,s.r,s.g,s.b,a)
        else
          n = pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, s.r, s.g, s.b, a)
        end
      end
    end
  end

  local nPlan = math.min(#PLANETS, lod.maxPlanets or #PLANETS)
  for i = 1, nPlan do
    local p = PLANETS[i]
    local fade = NightSky.starFade(p, nightVis)
    if fade > 0.01 then
      local pdx, pdy, pdz = rotateY(p.dx, p.dy, p.dz, vaultAng)
      local cx = e[1] + pdx * radius
      local cy = e[2] + pdy * radius
      local cz = e[3] + pdz * radius
      local pa = p.a * scale * fade
      n = pushQuad(verts, n, cx, cy, cz, p.size * 0.55, axisR, axisU, p.r, p.g, p.b, pa)
      if (lod.starStep or 1) <= 2 then
        n = pushQuad(verts, n, cx, cy, cz, p.size * 0.22, axisR, axisU, 1, 1, 1, pa * 0.5)
      end
    end
  end


  -- Pokémon outline constellations (vivid, spread around the sky)
  if NightSky.constellationsEnabled() and Constellations and Constellations.appendWorld then
    n = Constellations.appendWorld(
      verts, n, pushQuad, axisR, axisU, e, radius,
      rotateY, vaultAng, nightVis, NightSky.starFade, NightSky.twinkleAlpha, t
    ) or n
  end

  if lod.meteors and NightSky._appendMeteorsWorld then
    n = NightSky._appendMeteorsWorld(verts, n, axisR, axisU, e, radius) or n
  end

  for i = n + 1, #verts do verts[i] = nil end
  if n < 3 then return false end

  if not mesh then
    local ok, m = pcall(love.graphics.newMesh, FORMAT, verts, "triangles", "stream")
    if not ok or not m then return false end
    mesh = m
  else
    if not pcall(mesh.setVertices, mesh, verts) then
      mesh = nil
      return NightSky.drawWorld(Voxel3D, time)
    end
  end

  mesh:setDrawRange(1, n)
  local began = false
  if Voxel3D.beginEffect then
    began = Voxel3D.beginEffect(sh)
  end
  if not began then
    pcall(love.graphics.setShader, sh)
    pcall(love.graphics.setDepthMode, "lequal", false)
    began = true
  end

  -- Host matrices are row-major in Love shaders (Dramaless / Gen2 convention).
  if not pcall(sh.send, sh, "vp", "row", Voxel3D.vp) then
    pcall(sh.send, sh, "vp", Voxel3D.vp)
  end
  pcall(love.graphics.setBlendMode, "add", "alphamultiply")
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.setDepthMode, "lequal", false)
  love.graphics.draw(mesh)

  if Voxel3D.endEffect then
    pcall(Voxel3D.endEffect)
  else
    pcall(love.graphics.setShader)
    pcall(love.graphics.setDepthMode, "lequal", true)
  end
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  return true
end

-- ---------------------------------------------------------------------------
-- Math fallback when VP path is unavailable: project D through camera basis
-- (inverse orientation × direction). Not a screen-space position hack —
-- same celestial D, same orientation transform as a view matrix would apply.
-- ---------------------------------------------------------------------------
NightSky._basisR = nil
NightSky._basisU = nil
NightSky._basisF = nil

local function captureBasis(Voxel3D)
  local e = Voxel3D and Voxel3D.eye
  local fo = Voxel3D and Voxel3D.focus
  local fx, fy, fz
  if e and fo then
    fx, fy, fz = fo[1] - e[1], fo[2] - e[2], fo[3] - e[3]
  else
    local FP = NightSky._FirstPerson
    if FP and type(FP.yaw) == "number" then
      local yaw = FP.yaw
      local pitch = type(FP.pitch) == "number" and FP.pitch or 0
      local cp = math.cos(pitch)
      fx = math.sin(yaw) * cp
      fy = -math.sin(pitch)
      fz = math.cos(yaw) * cp
    else
      return false
    end
  end
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return false end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local rx, ry, rz = -fz, 0, fx
  local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rl < 1e-6 then rx, ry, rz = 1, 0, 0 else rx, ry, rz = rx / rl, ry / rl, rz / rl end
  local ux = ry * fz - rz * fy
  local uy = rz * fx - rx * fz
  local uz = rx * fy - ry * fx
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  if ul < 1e-6 then ux, uy, uz = 0, 1, 0 else ux, uy, uz = ux / ul, uy / ul, uz / ul end
  NightSky._basisF = { fx, fy, fz }
  NightSky._basisR = { rx, ry, rz }
  NightSky._basisU = { ux, uy, uz }
  return true
end

local function projectCelestial(dx, dy, dz)
  local R, U, F = NightSky._basisR, NightSky._basisU, NightSky._basisF
  if not (R and U and F) then return nil, nil, 0 end
  -- View-space direction = basis^T * D  (camera orientation only)
  local sx = dx * R[1] + dy * R[2] + dz * R[3]
  local sy = dx * U[1] + dy * U[2] + dz * U[3]
  local sz = dx * F[1] + dy * F[2] + dz * F[3]
  if sz < 0.02 then return nil, nil, 0 end  -- behind camera
  local k = 0.55  -- focal scale (FOV-like)
  local u = 0.5 + (sx / sz) * k
  local v = 0.5 - (sy / sz) * k
  local fade = 1
  if sz < 0.2 then fade = sz / 0.2 end
  if u < -0.2 or u > 1.2 or v < -0.2 or v > 1.2 then return nil, nil, 0 end
  if u < 0 then fade = fade * math.max(0, 1 + u * 2) end
  if u > 1 then fade = fade * math.max(0, 1 - (u - 1) * 2) end
  if v < 0 then fade = fade * math.max(0, 1 + v * 2) end
  if v > 1 then fade = fade * math.max(0, 1 - (v - 1) * 2) end
  if fade < 0.03 then return nil, nil, 0 end
  return u, v, fade
end

function NightSky.draw(w, h, edge, body, time)
  local target = NightSky.computeNightVisibility()
  NightSky._nightVisRaw = target
  local nightVis = NightSky._nightVis or target
  if math.abs(target - nightVis) > 0.25 then nightVis = target end
  NightSky._nightVis = nightVis
  if nightVis < 0.02 then return false end
  if not (love and love.graphics) then return false end
  w = tonumber(w) or 160
  h = tonumber(h) or 144
  edge = tonumber(edge) or (h * 0.65)
  time = tonumber(time) or 0
  captureBasis(nil)

  local scale = starScaleNow()
  local prev
  pcall(function() prev = { love.graphics.getBlendMode() } end)
  pcall(love.graphics.setBlendMode, "add", "alphamultiply")

  local drawn = 0
    local lod2 = celestialLod()
  local step2 = lod2.starStep or 1
  local desktopProfile = DesktopWeatherProfile.current()
  local desktopSize = DesktopWeatherProfile.value(desktopProfile, 'starSize', 1, 3)
  local desktopBrightness = DesktopWeatherProfile.value(desktopProfile, 'starBrightness', 1, 3)
  for i = 1, #STARS, step2 do
    local s = STARS[i]
    local dayFade = NightSky.starFade(s, nightVis)
    if dayFade > 0.01 then
      local u, v, fade = projectCelestial(s.dx, s.dy, s.dz)
      if u and v and fade then
        local a = s.a * scale * fade * dayFade * NightSky.twinkleAlpha(s, time) * NightSky.buildingDensityMul(s) * desktopBrightness
        local sz = math.max(1.1, s.size * 0.7) * desktopSize
        pcall(love.graphics.setColor, s.r, s.g, s.b, a)
        pcall(love.graphics.rectangle, "fill", u * w, v * edge, sz, sz)
        drawn = drawn + 1
      end
    end
  end
  for i = 1, #PLANETS do
    local p = PLANETS[i]
    local dayFade = NightSky.starFade(p, nightVis)
    if dayFade > 0.01 then
      local u, v, fade = projectCelestial(p.dx, p.dy, p.dz)
      if u and v and fade then
        local a = p.a * scale * fade * dayFade
        pcall(love.graphics.setColor, p.r, p.g, p.b, a)
        pcall(love.graphics.rectangle, "fill", u * w - 4, v * edge - 4, 10, 10)
        drawn = drawn + 1
      end
    end
  end

  if NightSky._drawMeteorsScreen then
    NightSky._drawMeteorsScreen(w, h, edge)
  end
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  if prev then pcall(love.graphics.setBlendMode, prev[1], prev[2]) end
  return drawn > 0
end

function NightSky.applyWeatherBands(bands, skyInfo)
  if not (bands and skyInfo and skyInfo.color and (skyInfo.blend or 0) > 0) then
    return bands
  end
  local b = math.min(1, math.max(0, skyInfo.blend))
  local c = skyInfo.color
  local flash = skyInfo.flash or 0
  local out = {}
  for i = 1, #bands do
    local band = bands[i]
    local r = band[1] or 0
    local g = band[2] or 0
    local bl = band[3] or 0
    local nr = r * (1 - b) + c[1] * b
    local ng = g * (1 - b) + c[2] * b
    local nb = bl * (1 - b) + c[3] * b
    if flash > 0 then
      nr = math.min(1, nr + flash * 0.35)
      ng = math.min(1, ng + flash * 0.38)
      nb = math.min(1, nb + flash * 0.42)
    end
    out[i] = { nr, ng, nb, band[4] or 1 }
  end
  return out
end

-- Expose catalog for tests / debug
NightSky._STARS = STARS
NightSky._PLANETS = PLANETS


-- ---------- Shooting stars (in-game clock, night only)
--
-- Cadence is IN-GAME minutes from Weather FX TimeOfDay.hour (0..24 → minutes).
--   • One meteor every 1 game-minute at night, random direction.
--   • Every 90 game-minutes at night: a short shower (several meteors, same
--     heading, staggered starts) instead of the single.
--   • If a timer fires while it is day, the event is deferred until 1
--     game-minute after the next nightfall.

local METEOR = {
  lastGameMin = nil,
  singleAcc = 0,       -- game-minutes toward next single
  showerAcc = 0,       -- game-minutes toward next shower
  pendingSingle = false,
  pendingShower = false,
  deferAt = nil,       -- game-minute stamp: fire deferred 1 min after night
  wasNight = false,
  nightStartMin = nil,
  active = {},         -- { birth, life, ox,oy,oz, dx,dy,dz, speed, bright, shower }
  realTime = 0,
}

local questSchedule
local function restoreQuestSchedule()
  local Planner = V.require("QuestMeteorSchedule")
  local saved
  if V.mod and V.mod.save then saved=V.mod.save:get(Planner.KEY) end
  questSchedule=Planner.new(saved)
  METEOR.active={}
end

local function persistQuestSchedule()
  if questSchedule and V.mod and V.mod.save then
    V.mod.save:set("questMeteorSchedule",questSchedule:snapshot())
  end
end

local function questClockMode()
  local TOD=V.require("TimeOfDay")
  if TOD.pin then return "pinned" end
  if TOD.source=="cycle" or TOD.source=="system" then return TOD.source end
  local Interop=V.require("Interop")
  local host=Interop and Interop.dayNight and Interop.dayNight()
  if host and host.setting and host.setting.get then return host.setting:get() end
  return "pinned"
end

function NightSky.meteorStatus()
  local result=questSchedule and questSchedule:snapshot() or {}
  result.active=#METEOR.active
  result.shower=questSchedule and questSchedule.wasShower or false
  return result
end

if V.questLitePrivate and V.mod and V.mod.events then
  V.mod.events:on("save.loaded",restoreQuestSchedule)
  V.mod.events:on("save.created",restoreQuestSchedule)
  V.mod.events:on("save.writing",persistQuestSchedule)
end

local SINGLE_EVERY = 1       -- upstream non-Quest cadence; Quest uses its scheduler
local SHOWER_EVERY = 90      -- game minutes
local DEFER_AFTER_NIGHT = 1  -- game minutes after nightfall
local SHOWER_COUNT = 7
local SHOWER_SPREAD = 0.55   -- real-seconds between staggered heads

local function gameMinutesNow()
  local TOD
  pcall(function()
    if V and V.require then TOD = V.require("TimeOfDay") end
  end)
  if TOD and type(TOD.hour) == "number" then
    return (TOD.hour % 24) * 60
  end
  -- Host DayNight: map cycle position to 24h game minutes
  local DN = NightSky._DayNight
  if DN and type(DN.time) == "function" then
    local ok, t = pcall(DN.time)
    local cycle = tonumber(DN.CYCLE) or 1200
    if ok and type(t) == "number" and cycle > 0 then
      return ((t % cycle) / cycle) * (24 * 60)
    end
  end
  return nil
end

local function wrapDelta(now, prev)
  -- Game clock wraps at 24h = 1440 minutes
  local d = now - prev
  if d < -720 then d = d + 1440 end  -- crossed midnight forward
  if d > 720 then d = d - 1440 end   -- went backward (pin change) — ignore large jumps
  if d < 0 then d = 0 end
  if d > 5 then d = 5 end            -- clamp hitch / source switch
  return d
end

local function randomDir()
  -- Mostly horizontal, slight downward so trails read as falling.
  local az = math.random() * math.pi * 2
  local el = -0.15 - math.random() * 0.35  -- slight dive
  local ce, se = math.cos(el), math.sin(el)
  local dx = math.sin(az) * ce
  local dy = se
  local dz = math.cos(az) * ce
  local L = math.sqrt(dx * dx + dy * dy + dz * dz)
  return dx / L, dy / L, dz / L
end

local function meteorBusy()
  -- Any live or scheduled streak means an event is already on screen.
  for i = 1, #METEOR.active do
    local m = METEOR.active[i]
    if METEOR.realTime <= (m.birth + m.life + 0.05) then
      return true
    end
  end
  return false
end

local function spawnOne(dx, dy, dz, delay, shower, spicy)
  delay = delay or 0
  -- Origin on upper hemisphere, offset opposite travel so it crosses the view.
  local az = math.random() * math.pi * 2
  local el = 0.35 + math.random() * 0.45
  local ce, se = math.cos(el), math.sin(el)
  local ox = math.cos(az) * ce
  local oy = se
  local oz = math.sin(az) * ce
  -- Nudge origin against direction so the path crosses overhead.
  ox = ox - dx * 0.35
  oy = oy - dy * 0.15
  oz = oz - dz * 0.35
  local L = math.sqrt(ox * ox + oy * oy + oz * oz)
  if L > 1e-6 then ox, oy, oz = ox / L, oy / L, oz / L end
  METEOR.active[#METEOR.active + 1] = {
    birth = METEOR.realTime + delay,
    life = 0.85 + math.random() * 0.55,
    ox = ox, oy = oy, oz = oz,
    dx = dx, dy = dy, dz = dz,
    speed = 0.55 + math.random() * 0.35,
    bright = shower and (0.85 + math.random() * 0.15) or (0.95 + math.random() * 0.05),
    shower = shower and true or false,
    green = V.questLitePrivate and math.random()<(spicy and .40 or .20) or false,
    longTrail = V.questLitePrivate and math.random()<(spicy and .40 or .15) or false,
  }
end

local function spawnSingle()
  -- Hard rule: never stack. One single OR one shower in flight — never both,
  -- and never two singles at once.
  if meteorBusy() then return false end
  METEOR.active = {}  -- belt-and-braces clear
  local dx, dy, dz = randomDir()
  spawnOne(dx, dy, dz, 0, false)
  return true
end

local function spawnShower()
  if meteorBusy() then return false end
  METEOR.active = {}
  local dx, dy, dz = randomDir()
  for i = 1, SHOWER_COUNT do
    local jx = (math.random() - 0.5) * 0.12
    local jz = (math.random() - 0.5) * 0.12
    local jy = (math.random() - 0.5) * 0.04
    local sx, sy, sz = dx + jx, dy + jy, dz + jz
    local L = math.sqrt(sx * sx + sy * sy + sz * sz)
    sx, sy, sz = sx / L, sy / L, sz / L
    spawnOne(sx, sy, sz, (i - 1) * SHOWER_SPREAD, true)
  end
  return true
end

function NightSky.update(dt)
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end
  if dt > 0.25 then dt = 0.25 end
  -- Smooth within phase; snap on large jumps (sleep, pin, load, debug).
  local target = NightSky.computeNightVisibility()
  NightSky._nightVisRaw = target
  local cur = NightSky._nightVis or target
  if math.abs(target - cur) > 0.4 then
    NightSky._nightVis = target
  else
    local k = 1 - math.exp(-3.2 * dt)
    NightSky._nightVis = cur + (target - cur) * k
  end
  METEOR.realTime = METEOR.realTime + dt

  -- Retire finished meteors
  local live = {}
  for i = 1, #METEOR.active do
    local m = METEOR.active[i]
    if METEOR.realTime <= m.birth + m.life + 0.05 then
      live[#live + 1] = m
    end
  end
  METEOR.active = live

  if V.questLitePrivate then
    if not questSchedule then restoreQuestSchedule() end
    local TOD=V.require("TimeOfDay")
    local night=NightSky.isNight(nil)
    local event=questSchedule:update(dt,TOD.hour,questClockMode(),night,meteorBusy())
    local preview=V.require('QuestSkyEvents').update(dt,questSchedule.day,questClockMode(),meteorBusy())
    if preview then event='shower' end
    if event then
      -- Source random trajectory/artwork, but one head at a time even during
      -- a shower. No seven-head burst and no daytime deferred backlog.
      local dx,dy,dz=randomDir()
      spawnOne(dx,dy,dz,0,event=="shower",preview=='spicy')
    end
    return
  end

  local night = NightSky.isNight(nil)
  local gmin = gameMinutesNow()
  if gmin == nil then return end

  if METEOR.lastGameMin == nil then
    METEOR.lastGameMin = gmin
    METEOR.wasNight = night
    if night then METEOR.nightStartMin = gmin end
    return
  end

  local dmin = wrapDelta(gmin, METEOR.lastGameMin)
  METEOR.lastGameMin = gmin

  -- Night edge: schedule deferred events for 1 game-minute after nightfall.
  if night and not METEOR.wasNight then
    METEOR.nightStartMin = gmin
    if METEOR.pendingSingle or METEOR.pendingShower then
      METEOR.deferAt = gmin + DEFER_AFTER_NIGHT
    end
  end
  if not night then
    METEOR.nightStartMin = nil
    METEOR.deferAt = nil
  end
  METEOR.wasNight = night

  METEOR.singleAcc = METEOR.singleAcc + dmin
  METEOR.showerAcc = METEOR.showerAcc + dmin

  -- Only one cadence fire per update tick; shower wins over single.
  local wantShower = false
  local wantSingle = false
  if METEOR.showerAcc >= SHOWER_EVERY then
    METEOR.showerAcc = METEOR.showerAcc % SHOWER_EVERY
    wantShower = true
  end
  if METEOR.singleAcc >= SINGLE_EVERY then
    METEOR.singleAcc = METEOR.singleAcc % SINGLE_EVERY
    wantSingle = true
  end
  -- Shower replaces the single for this tick (never both).
  if wantShower then
    wantSingle = false
    if night and not meteorBusy() then
      if spawnShower() then
        METEOR.pendingShower = false
        METEOR.pendingSingle = false
      else
        METEOR.pendingShower = true
      end
    else
      METEOR.pendingShower = true
      METEOR.pendingSingle = false  -- absorbed into shower pending
    end
  elseif wantSingle then
    if night and not meteorBusy() then
      if spawnSingle() then
        METEOR.pendingSingle = false
      else
        METEOR.pendingSingle = true
      end
    else
      METEOR.pendingSingle = true
    end
  end

  -- Deferred fire: 1 game-minute after night began. Still no stacking.
  if night and METEOR.deferAt and gmin + 1e-6 >= METEOR.deferAt then
    if not meteorBusy() then
      if METEOR.pendingShower then
        if spawnShower() then
          METEOR.pendingShower = false
          METEOR.pendingSingle = false
          METEOR.deferAt = nil
        end
      elseif METEOR.pendingSingle then
        if spawnSingle() then
          METEOR.pendingSingle = false
          METEOR.deferAt = nil
        end
      else
        METEOR.deferAt = nil
      end
    end
    -- If still busy, leave deferAt set and retry next frames once clear.
  end

  -- If something is pending at night and sky is free, try once (covers
  -- "busy when timer fired" without stacking).
  if night and not meteorBusy() then
    if METEOR.pendingShower then
      if spawnShower() then
        METEOR.pendingShower = false
        METEOR.pendingSingle = false
      end
    elseif METEOR.pendingSingle then
      if spawnSingle() then
        METEOR.pendingSingle = false
      end
    end
  end
end

local function meteorProgress(m)
  if METEOR.realTime < m.birth then return nil end
  local u = (METEOR.realTime - m.birth) / m.life
  if u < 0 or u > 1 then return nil end
  return u
end

-- Append meteor quads into a vertex list (world dome space).
local function appendMeteorsWorld(verts, n, axisR, axisU, e, radius)
  n = n or 0
  for i = 1, #METEOR.active do
    local m = METEOR.active[i]
    local u = meteorProgress(m)
    if u then
      local fade = 1.0
      if u < 0.12 then fade = u / 0.12 end
      if u > 0.72 then fade = (1.0 - u) / 0.28 end
      local travel = (u - 0.05) * m.speed * 1.8
      local cx = e[1] + (m.ox + m.dx * travel) * radius
      local cy = e[2] + (m.oy + m.dy * travel) * radius
      local cz = e[3] + (m.oz + m.dz * travel) * radius
      local sm = 1
      pcall(function()
        local BL = V.require("BuildingLight")
        if BL and BL.starScale then sm = BL.starScale() or 1 end
      end)
      local a = m.bright * fade * (type(sm) == "number" and sm or 1)
      local tiny=V.questLitePrivate
      local glow=tiny and math.min(0.9,radius*0.00115) or 3.2
      local core=tiny and math.min(0.55,radius*0.00065) or 1.4
      local r,g,b=.90,.96,1.0
      if tiny and m.green then r,g,b=.30,1.0,.55 end
      n = pushQuad(verts, n, cx, cy, cz, glow, axisR, axisU, r,g,b, tiny and a*.40 or a)
      n = pushQuad(verts, n, cx, cy, cz, core, axisR, axisU, 1, 1, 1, a)
      if tiny then
        -- One short continuous tapered streak, not five separated glowing beads.
        local length=radius*(m.longTrail and .012 or .003)
        local px,py,pz=cx-e[1],cy-e[2],cz-e[3]
        local ux,uy,uz=m.dy*pz-m.dz*py,m.dz*px-m.dx*pz,m.dx*py-m.dy*px
        local norm=math.sqrt(ux*ux+uy*uy+uz*uz)
        if norm>0.0001 then
          local along={m.dx*length,m.dy*length,m.dz*length}
          local across={ux/norm*core*.55,uy/norm*core*.55,uz/norm*core*.55}
          n=pushQuad(verts,n,cx-m.dx*length,cy-m.dy*length,cz-m.dz*length,
            1,along,across,r,g,b,a*.65)
        end
      else for k = 1, 5 do
        local back = k * (tiny and 0.0012 or 0.035)
        local tx = e[1] + (m.ox + m.dx * (travel - back)) * radius
        local ty = e[2] + (m.oy + m.dy * (travel - back)) * radius
        local tz = e[3] + (m.oz + m.dz * (travel - back)) * radius
        local ta = a * (1.0 - k * 0.16)
        local half = tiny and core*(1-k*.12) or (2.4-k*.28)
        n = pushQuad(verts, n, tx, ty, tz, half, axisR, axisU, 0.90, 0.96, 1.0, ta * 0.7)
      end end
    end
  end
  return n
end

function drawMeteorsScreen(w, h, edge)
  if not (love and love.graphics) then return end
  for i = 1, #METEOR.active do
    local m = METEOR.active[i]
    local u = meteorProgress(m)
    if u then
      local fade = 1.0
      if u < 0.12 then fade = u / 0.12 end
      if u > 0.72 then fade = (1.0 - u) / 0.28 end
      local travel = (u - 0.05) * m.speed * 1.8
      local px = m.ox + m.dx * travel
      local py = m.oy + m.dy * travel
      local pz = m.oz + m.dz * travel
      local su = (px * 0.5 + 0.5)
      local sv = 1.0 - (py * 0.85 + 0.05)
      local x = su * w
      local y = sv * edge
      if y < edge - 1 and y > 0 then
        local a = m.bright * fade
        pcall(love.graphics.setColor, 1, 0.95, 0.85, a)
        pcall(love.graphics.rectangle, "fill", x - 1, y - 1, 3, 2)
        -- short trail
        for k = 1, 4 do
          local tpx = m.ox + m.dx * (travel - k * 0.04)
          local tpy = m.oy + m.dy * (travel - k * 0.04)
          local tx = (tpx * 0.5 + 0.5) * w
          local ty = (1.0 - (tpy * 0.85 + 0.05)) * edge
          pcall(love.graphics.setColor, 0.8, 0.88, 1.0, a * (1 - k * 0.2) * 0.7)
          pcall(love.graphics.rectangle, "fill", tx, ty, 2, 1)
        end
      end
    end
  end
end


NightSky._appendMeteorsWorld = appendMeteorsWorld
NightSky._drawMeteorsScreen = drawMeteorsScreen

return NightSky
