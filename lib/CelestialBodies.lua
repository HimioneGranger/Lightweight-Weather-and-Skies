-- CelestialBodies — player-centered origin, world-oriented day arc
--
-- MODEL:
--   Origin  = player / eye POSITION (sphere center follows the player)
--   Orient  = WORLD axes only (never player/camera rotation)
--   Angle   = game time only
--
-- DAY ARC (what you see looking at the sky):
--   Sunrise  → EAST,  on the horizon
--   Noon     → nearly OVERHEAD (top of sky)
--   Sunset   → WEST,  on the horizon
--
-- World basis: +X east, +Y up, +Z south.
-- The day arc lives in the East–Up plane (X/Y):
--   dir = (cos(α), sin(α), 0)  with α = 0 at east, π/2 overhead, π at west
-- That is a pure rotation about world +Z (north–south), so the sun climbs
-- the sky and sets opposite — not a flat spin around vertical, and not a
-- south-biased path that looked like the "wrong axis" in play.
--
-- Moon is always opposite: α_moon = α_sun + π (below when sun is above).

local V = ...
local Celestial = {}
local TOD = V.require("TimeOfDay")

local SUN_HALF, MOON_HALF = 22.0, 10.5
local SKY_RADIUS = 280  -- closer so FPV look-up clearly sees overhead disc

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function normAngle(a)
  local two = math.pi * 2
  a = a % two
  if a < 0 then a = a + two end
  return a
end

-- α: 0 = east horizon, π/2 = overhead, π = west horizon, 3π/2 = below.
local function worldDirFromAlpha(alpha)
  local dx = math.cos(alpha)   -- east (+) / west (−)
  local dy = math.sin(alpha)   -- up (+) / below (−)
  local dz = 0                 -- arc in East–Up plane (no south bias)
  local L = math.sqrt(dx * dx + dy * dy + dz * dz)
  if L > 1e-8 then dx, dy, dz = dx / L, dy / L, dz / L end
  return dx, dy, dz
end

function Celestial.bodies(hour)
  local Sim
  pcall(function() Sim = V.require("CelestialSim") end)
  if Sim and Sim.sample then
    return Sim.sample(hour)
  end
  -- Fallback if Sim missing (should not happen)
  hour = tonumber(hour) or ((TOD and TOD.hour) or 12)
  hour = hour % 24
  local alpha = ((hour - 6.0) / 24.0) * math.pi * 2
  local dx, dy, dz = math.cos(alpha), math.sin(alpha), 0
  local moonA = alpha + math.pi
  local mx, my, mz = math.cos(moonA), math.sin(moonA), 0
  local sunAbove = dy > 0.02
  local moonAbove = my > 0.02
  return {
    hour = hour,
    sun = { dx=dx, dy=dy, dz=dz, theta=alpha, el=math.asin(math.max(-1,math.min(1,dy))),
            alpha = sunAbove and 0.9 or 0, kind="sun", above=sunAbove },
    moon = { dx=mx, dy=my, dz=mz, theta=moonA, el=math.asin(math.max(-1,math.min(1,my))),
             alpha = moonAbove and 0.9 or 0, kind="moon", above=moonAbove },
  }
end

function Celestial.direction(hour)
  local b = Celestial.bodies(hour)
  if b.sun.alpha > 0.02 then
    local s = b.sun
    return s.dx, s.dy, s.dz, "sun", s.alpha, s.theta, s.el
  end
  if b.moon.alpha > 0.02 then
    local m = b.moon
    return m.dx, m.dy, m.dz, "moon", m.alpha, m.theta, m.el
  end
  return nil
end

function Celestial.bodyDir(hour)
  local b = Celestial.bodies(hour)
  if b.sun.alpha >= b.moon.alpha and b.sun.alpha > 0.02 then
    return b.sun.dx, b.sun.dy, b.sun.dz
  end
  if b.moon.alpha > 0.02 then
    return b.moon.dx, b.moon.dy, b.moon.dz
  end
  return b.sun.dx, b.sun.dy, b.sun.dz
end

function Celestial.bodyAt(hour)
  local b = Celestial.bodies(hour)
  if b.sun.alpha > 0.02 then
    return math.deg(b.sun.theta), math.deg(b.sun.el), false
  end
  if b.moon.alpha > 0.02 then
    return math.deg(b.moon.theta), math.deg(b.moon.el), true
  end
  return math.deg(b.sun.theta), math.deg(b.sun.el), false
end

function Celestial.shearAt(hour)
  local b = Celestial.bodies(hour)
  local s = b.sun
  local dy = s.dy
  if dy < 0.08 then dy = 0.08 end
  local kx, kz = -s.dx / dy, -s.dz / dy
  if kx > 3 then kx = 3 elseif kx < -3 then kx = -3 end
  if kz > 3 then kz = 3 elseif kz < -3 then kz = -3 end
  return kx, kz
end

function Celestial.pose(hour)
  local b = Celestial.bodies(hour)
  return {
    hour = b.hour,
    sunAz = math.deg(b.sun.theta), sunAlt = math.deg(b.sun.el),
    moonAz = math.deg(b.moon.theta), moonAlt = math.deg(b.moon.el),
    sepDeg = math.deg(normAngle(b.moon.theta - b.sun.theta)),
  }
end

function Celestial.debugSnapshot(hour)
  local b = Celestial.bodies(hour)
  local s, m = b.sun, b.moon
  return string.format(
    "[WX] t=%.2f arc=East-Zenith-West | SUN (%.2f,%.2f,%.2f) a=%.2f | MOON (%.2f,%.2f,%.2f) a=%.2f",
    b.hour, s.dx, s.dy, s.dz, s.alpha, m.dx, m.dy, m.dz, m.alpha)
end

local function billboardAxes(Voxel3D)
  local e, fo = Voxel3D.eye, Voxel3D.focus
  if not e then return nil, nil end
  if not fo then fo = { e[1], e[2], e[3] - 1 } end
  local fx, fy, fz = fo[1] - e[1], fo[2] - e[2], fo[3] - e[3]
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return nil, nil end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
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

local function pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, r, g, b, a)
  local hx, hy, hz = axisR[1] * half, axisR[2] * half, axisR[3] * half
  local vx, vy, vz = axisU[1] * half, axisU[2] * half, axisU[3] * half
  local function v(ox, oy, oz)
    n = n + 1
    local t = verts[n]
    if not t then t = { 0, 0, 0, 0, 0, 0, 0 }; verts[n] = t end
    t[1], t[2], t[3] = cx + ox, cy + oy, cz + oz
    t[4], t[5], t[6], t[7] = r, g, b, a
    return n
  end
  n = v(-hx - vx, -hy - vy, -hz - vz)
  n = v( hx - vx,  hy - vy,  hz - vz)
  n = v( hx + vx,  hy + vy,  hz + vz)
  n = v(-hx - vx, -hy - vy, -hz - vz)
  n = v( hx + vx,  hy + vy,  hz + vz)
  n = v(-hx + vx, -hy + vy, -hz + vz)
  return n
end

local FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexColor", "float", 4 },
}

local function ensureShader()
  if Celestial._sh then return Celestial._sh end
  if not (love and love.graphics and love.graphics.newShader) then return nil end
  local ok, sh = pcall(love.graphics.newShader, [[
    varying vec4 vColor;
#ifdef VERTEX
    uniform mat4 vp;
    // VertexColor is supplied by LÖVE.
    vec4 position(mat4 transform_projection, vec4 vertex_position) {
      vColor = VertexColor;
      return vp * vertex_position;
    }
#endif
#ifdef PIXEL
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      return vColor * color;
    }
#endif
  ]])
  if ok then Celestial._sh = sh end
  return Celestial._sh
end

local function appendBody(verts, n, body, half, axisR, axisU, origin, radius)
  if not body or (body.alpha or 0) < 0.02 then return n end
  local cx = origin[1] + body.dx * radius
  local cy = origin[2] + body.dy * radius
  local cz = origin[3] + body.dz * radius
  local a = body.alpha
  -- Higher in the sky → slightly larger disc (reads as closer to overhead in FPV)
  local elevBoost = 1 + 0.35 * clamp01(body.dy or 0)
  half = half * elevBoost
  local layers = 4
  pcall(function()
    local Q = V.require("Quality")
    if Q and Q.celestial then
      local c = Q.celestial()
      if c and c.sunLayers then layers = tonumber(c.sunLayers) or 4 end
    end
  end)
  if body.kind == "sun" then
    if layers >= 4 then
      n = pushQuad(verts, n, cx, cy, cz, half * 1.9, axisR, axisU, 1.0, 0.72, 0.30, a * 0.22)
    end
    if layers >= 3 then
      n = pushQuad(verts, n, cx, cy, cz, half * 1.3, axisR, axisU, 1.0, 0.88, 0.48, a * 0.42)
    end
    if layers >= 2 then
      n = pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, 1.0, 0.96, 0.70, a * 0.85)
    end
    n = pushQuad(verts, n, cx, cy, cz, half * 0.42, axisR, axisU, 1.0, 1.0, 0.95, a)
  else
    if layers >= 3 then
      n = pushQuad(verts, n, cx, cy, cz, half * 1.4, axisR, axisU, 0.50, 0.58, 0.82, a * 0.32)
    end
    if layers >= 2 then
      n = pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, 0.78, 0.84, 0.96, a * 0.78)
    end
    n = pushQuad(verts, n, cx, cy, cz, half * 0.48, axisR, axisU, 0.92, 0.94, 1.00, a)
  end
  return n
end

function Celestial.drawWorld(Voxel3D, hour)
  if not (Voxel3D and Voxel3D.vp and Voxel3D.eye) then return false end
  local b = Celestial.bodies(hour or (TOD and TOD.hour))
  local axisR, axisU = billboardAxes(Voxel3D)
  if not axisR then return false end
  local origin = Voxel3D.eye
  local radius = SKY_RADIUS
  local far = Voxel3D.far or (Voxel3D.camera and Voxel3D.camera.far)
  if type(far) == "number" and far > 80 then
    radius = math.min(far * 0.88, math.max(radius, far * 0.7))
  end
  if V.questLitePrivate then
    return V.require("WorldCelestialDisc").draw(Voxel3D, b, axisR, axisU, radius)
  end
  local verts, n = {}, 0
  n = appendBody(verts, n, b.sun, SUN_HALF, axisR, axisU, origin, radius)
  n = appendBody(verts, n, b.moon, MOON_HALF, axisR, axisU, origin, radius)
  for i = n + 1, #verts do verts[i] = nil end
  if n < 3 then return false end
  local sh = ensureShader()
  if not sh then return false end
  local okMesh, mesh = pcall(love.graphics.newMesh, FORMAT, verts, "triangles", "stream")
  if not okMesh or not mesh then return false end
  local prev
  pcall(function() prev = { love.graphics.getBlendMode() } end)
  pcall(love.graphics.setBlendMode, "add", "alphamultiply")
  local began = Voxel3D.beginEffect and Voxel3D.beginEffect(sh)
  -- Always on top of world geometry for sky layer; still world-positioned.
  pcall(love.graphics.setDepthMode, "always", false)
  if not began then
    pcall(love.graphics.setShader, sh)
  end
  if not pcall(sh.send, sh, "vp", "row", Voxel3D.vp) then
    pcall(sh.send, sh, "vp", Voxel3D.vp)
  end
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, mesh)
  if Voxel3D.endEffect then pcall(Voxel3D.endEffect)
  else
    pcall(love.graphics.setShader)
    pcall(love.graphics.setDepthMode, "lequal", true)
  end
  if prev then pcall(love.graphics.setBlendMode, prev[1], prev[2]) end
  pcall(mesh.release)
  Celestial._lastDraw = {
    hour = b.hour,
    sun = b.sun.above and true or false,
    moon = b.moon.above and true or false,
    sunDy = b.sun.dy,
    moonDy = b.moon.dy,
  }
  return true
end

function Celestial.projectBody(w, h, edge, cell, hour, Voxel3D)
  w = tonumber(w) or 160
  h = tonumber(h) or 144
  edge = tonumber(edge) or (h * 0.42)
  local b = Celestial.bodies(hour)
  local body = nil
  if b.sun.alpha > 0.02 then body = b.sun
  elseif b.moon.alpha > 0.02 then body = b.moon
  else return nil end

  -- Sky plate: X = east/west, Y = altitude (horizon → overhead at top of sky)
  local u = 0.5 + 0.40 * body.dx
  local elevN = clamp01(body.dy)  -- 0 horizon → 1 overhead
  -- Noon (elevN=1) must sit near the TOP of the sky plate (small v).
  local v = 0.72 - 0.68 * elevN
  if u < 0.05 then u = 0.05 elseif u > 0.95 then u = 0.95 end
  if v < 0.04 then v = 0.04 elseif v > 0.78 then v = 0.78 end

  return {
    x = u * w,
    y = v * edge,
    moon = (body.kind == "moon"),
    glowAmt = 0,
    _wxKind = body.kind,
    _wxAlpha = body.alpha,
  }
end

function Celestial.projectBoth(w, h, edge, hour, Voxel3D)
  return Celestial.projectBody(w, h, edge, 4, hour, Voxel3D), nil
end

return Celestial
