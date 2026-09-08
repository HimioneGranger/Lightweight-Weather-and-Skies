-- CelestialSim — game celestial sphere (simulation only, no drawing)
--
-- Architecture (from research / Gen1Recomp target):
--
--   GAME TIME → CELESTIAL ANGLES → WORLD DIRECTIONS → RENDERER
--
--   Camera / player rotation NEVER enters this module.
--   Player position is NOT stored here; the renderer may center the sphere
--   on the eye for precision (parallax-free), using only these directions.
--
-- World basis (permanent):
--   EAST  = (1, 0, 0)
--   UP    = (0, 1, 0)
--   SOUTH = (0, 0, 1)
--
-- Day arc (what the player should experience):
--   Sunrise  → east horizon
--   Noon     → straight overhead (UP)
--   Sunset   → west horizon
--   Night    → below horizon; Moon above on the opposite side
--
-- Moon = daily opposite of Sun + slow orbital offset (simplified lunar motion).
-- Stars are fixed on the sphere and rotated only by daily angle (NightSky).

local V = ...
local Sim = {}

-- Layered celestial sphere radii (Blender-style depth layering).
-- Stars farthest, then sun, then moon nearest — occlusion order.
Sim.LAYER = { stars = 1.00, sun = 0.96, moon = 0.94 }

--- Soft horizon fade: 1 above ~8°, 0 below horizon.
function Sim.horizonFade(dy)
  if type(dy) ~= "number" then return 0 end
  -- dy is sin(altitude); map -0.05..0.15 → 0..1
  local t = (dy + 0.05) / 0.20
  if t < 0 then return 0 end
  if t > 1 then return 1 end
  return t * t * (3 - 2 * t)  -- smoothstep
end

local TOD = V.require("TimeOfDay")

local TWO_PI = math.pi * 2
local DEG = 180 / math.pi

local function clamp01(x)
  if x < 0 then return 0 elseif x > 1 then return 1 end
  return x
end

local function norm2pi(a)
  a = a % TWO_PI
  if a < 0 then a = a + TWO_PI end
  return a
end

--- Hour of day 0..24 from authoritative TOD (or override).
function Sim.hour(override)
  if type(override) == "number" and override == override then
    return override % 24
  end
  local h = TOD and TOD.hour
  if type(h) == "number" and h == h then return h % 24 end
  return 12
end

--- Day-of-year proxy for slow lunar drift (0..365-ish). Optional.
function Sim.dayIndex()
  local d = 0
  pcall(function()
    if TOD and type(TOD.day) == "number" then d = TOD.day
    elseif TOD and type(TOD.dayOfYear) == "number" then d = TOD.dayOfYear
    end
  end)
  return d
end

-- Solar alpha: 0 at 06:00 (east), π/2 at 12:00 (zenith), π at 18:00 (west).
-- Full 2π over 24h so the body continues below the horizon at night.
function Sim.solarAlpha(hour)
  hour = Sim.hour(hour)
  return norm2pi(((hour - 6.0) / 24.0) * TWO_PI)
end

-- Lunar: opposite sun + ~13°/day style drift (scaled down for game feel).
function Sim.lunarAlpha(hour)
  local sun = Sim.solarAlpha(hour)
  local drift = (Sim.dayIndex() % 30) * (TWO_PI / 30) * 0.35
  return norm2pi(sun + math.pi + drift)
end

-- Direction in world space from alpha in the East–Up plane:
--   α=0 → +EAST, α=π/2 → +UP, α=π → −EAST, α=3π/2 → −UP
-- This is the path: rise → overhead → set → under world.
local function dirFromAlpha(alpha)
  local dx = math.cos(alpha)  -- east/west
  local dy = math.sin(alpha)  -- up/down
  local dz = 0
  local L = math.sqrt(dx * dx + dy * dy + dz * dz)
  if L > 1e-8 then dx, dy, dz = dx / L, dy / L, dz / L end
  return dx, dy, dz
end

--- Full snapshot for renderers / lighting.
function Sim.sample(hour)
  hour = Sim.hour(hour)
  local sa = Sim.solarAlpha(hour)
  local la = Sim.lunarAlpha(hour)
  local sdx, sdy, sdz = dirFromAlpha(sa)
  local mdx, mdy, mdz = dirFromAlpha(la)

  local sunFade = Sim.horizonFade(sdy)
  local moonFade = Sim.horizonFade(mdy)
  local sunAbove = sdy > 0.02
  local moonAbove = mdy > 0.02
  local sunA = sunFade * math.max(0.45, clamp01(sdy / 0.4 + 0.2))
  local moonA = moonFade * math.max(0.45, clamp01(mdy / 0.4 + 0.2))

  pcall(function()
    if TOD and (TOD.pin == "NITE" or TOD.pin == "NIGHT" or TOD.tod == "NITE" or TOD.tod == "NIGHT") then
      sunA = 0
      if moonA < 0.45 then moonA = 0.85 end
    end
  end)

  return {
    hour = hour,
    solarAlpha = sa,
    lunarAlpha = la,
    sun = {
      dx = sdx, dy = sdy, dz = sdz,
      alpha = sunA, above = sunAbove, kind = "sun",
      el = math.asin(math.max(-1, math.min(1, sdy))),
      theta = sa,
    },
    moon = {
      dx = mdx, dy = mdy, dz = mdz,
      alpha = moonA, above = moonAbove, kind = "moon",
      el = math.asin(math.max(-1, math.min(1, mdy))),
      theta = la,
    },
  }
end

-- Back-compat aliases used by CelestialBodies / NightSky
function Sim.bodies(hour)
  return Sim.sample(hour)
end

function Sim.sunDir(hour)
  local s = Sim.sample(hour).sun
  return s.dx, s.dy, s.dz
end

function Sim.moonDir(hour)
  local m = Sim.sample(hour).moon
  return m.dx, m.dy, m.dz
end

function Sim.debug(hour)
  local s = Sim.sample(hour)
  return string.format(
    "[CelestialSim] h=%.2f SUN dir=(%.2f,%.2f,%.2f) above=%s | MOON dir=(%.2f,%.2f,%.2f) above=%s",
    s.hour, s.sun.dx, s.sun.dy, s.sun.dz, tostring(s.sun.above),
    s.moon.dx, s.moon.dy, s.moon.dz, tostring(s.moon.above))
end

return Sim
