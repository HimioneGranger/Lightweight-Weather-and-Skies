-- Pokémon outline constellations (celestial sphere)
-- Dense outline stars, spread around the sky so only one fits in view at a time.
-- Very vivid so they are easy to find at night.

local V = ...
local C = {}

local function hash(n)
  local x = math.sin(n * 127.1) * 43758.5453
  return x - math.floor(x)
end

local function densify(poly, spacing)
  -- poly: { {x,y}, ... } closed or open. spacing in shape units (~0.04)
  local out = {}
  if not poly or #poly < 2 then return out end
  for i = 1, #poly do
    local a = poly[i]
    local b = poly[(i % #poly) + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
      out[#out + 1] = { a[1], a[2] }
    else
      local steps = math.max(1, math.floor(len / spacing + 0.5))
      for s = 0, steps - 1 do
        local t = s / steps
        out[#out + 1] = { a[1] + dx * t, a[2] + dy * t }
      end
    end
  end
  return out
end

-- Local outline shapes in [-1,1]×[-1,1] (y up). Recognizable silhouettes.
local SHAPES = {
  -- Pikachu: tall ears, round head/body, lightning tail
  Pikachu = {
    color = { 1.00, 0.92, 0.20 },
    -- outer silhouette (clockwise-ish)
    poly = {
      { -0.15, 0.95 }, { -0.28, 0.55 }, { -0.22, 0.35 }, -- left ear
      { -0.45, 0.25 }, { -0.55, 0.05 }, { -0.50, -0.25 }, { -0.35, -0.45 },
      { -0.25, -0.70 }, { -0.10, -0.85 }, { 0.10, -0.85 }, { 0.25, -0.70 },
      { 0.35, -0.45 }, { 0.50, -0.25 }, { 0.55, 0.05 }, { 0.45, 0.25 },
      { 0.22, 0.35 }, { 0.28, 0.55 }, { 0.15, 0.95 }, -- right ear tip
      { 0.08, 0.55 }, { 0.00, 0.40 }, { -0.08, 0.55 }, -- between ears
    },
    -- cheek marks + eye dots as bright secondary points
    accents = {
      { -0.35, 0.00 }, { 0.35, 0.00 },
      { -0.12, 0.12 }, { 0.12, 0.12 },
    },
    -- lightning tail
    tail = {
      { 0.35, -0.40 }, { 0.55, -0.25 }, { 0.70, -0.45 }, { 0.85, -0.20 },
      { 0.95, -0.35 }, { 0.75, -0.55 }, { 0.60, -0.40 },
    },
  },
  -- Charmander: body, snout, flame tail tip
  Charmander = {
    color = { 1.00, 0.55, 0.18 },
    poly = {
      { -0.10, 0.70 }, { -0.30, 0.55 }, { -0.45, 0.30 }, { -0.50, 0.00 },
      { -0.45, -0.30 }, { -0.30, -0.55 }, { -0.15, -0.75 }, { 0.05, -0.85 },
      { 0.25, -0.75 }, { 0.40, -0.50 }, { 0.45, -0.20 }, { 0.40, 0.10 },
      { 0.50, 0.25 }, { 0.55, 0.45 }, { 0.35, 0.55 }, -- snout
      { 0.20, 0.65 }, { 0.05, 0.75 }, { -0.10, 0.70 },
    },
    accents = {
      { -0.15, 0.35 }, { 0.20, 0.35 }, -- eyes
      { 0.35, 0.40 }, -- nose
    },
    tail = {
      { 0.25, -0.55 }, { 0.45, -0.65 }, { 0.65, -0.55 }, { 0.80, -0.35 },
      { 0.70, -0.15 }, { 0.85, 0.05 }, { 0.95, 0.20 }, -- flame
      { 0.75, 0.10 }, { 0.60, -0.10 },
    },
  },
  -- Squirtle: shell oval + head + tiny tail
  Squirtle = {
    color = { 0.35, 0.75, 1.00 },
    poly = {
      { 0.00, 0.75 }, { -0.25, 0.65 }, { -0.40, 0.45 }, { -0.50, 0.20 },
      { -0.55, -0.05 }, { -0.50, -0.30 }, { -0.35, -0.50 }, { -0.15, -0.65 },
      { 0.10, -0.70 }, { 0.30, -0.60 }, { 0.45, -0.40 }, { 0.55, -0.15 },
      { 0.55, 0.10 }, { 0.45, 0.35 }, { 0.30, 0.55 }, { 0.10, 0.70 },
      { 0.00, 0.75 },
    },
    accents = {
      { -0.15, 0.40 }, { 0.15, 0.40 }, -- eyes
      { 0.00, 0.25 }, -- nose
      { -0.20, -0.10 }, { 0.20, -0.10 }, { 0.00, -0.25 }, -- shell pattern
    },
    tail = {
      { 0.40, -0.45 }, { 0.55, -0.55 }, { 0.65, -0.45 },
    },
  },
  -- Bulbasaur: bulb + body + legs silhouette
  Bulbasaur = {
    color = { 0.45, 1.00, 0.40 },
    poly = {
      { -0.20, 0.55 }, { -0.40, 0.40 }, { -0.55, 0.15 }, { -0.55, -0.15 },
      { -0.40, -0.40 }, { -0.25, -0.60 }, { -0.05, -0.70 }, { 0.20, -0.65 },
      { 0.40, -0.45 }, { 0.50, -0.20 }, { 0.50, 0.10 }, { 0.35, 0.30 },
      { 0.15, 0.40 }, { 0.00, 0.35 }, { -0.10, 0.45 }, { -0.20, 0.55 },
    },
    -- bulb on back
    accents = {
      { -0.05, 0.65 }, { 0.10, 0.80 }, { 0.25, 0.70 }, { 0.15, 0.55 },
      { -0.15, 0.25 }, { 0.15, 0.25 }, -- eyes
    },
    tail = {
      { 0.35, -0.35 }, { 0.50, -0.50 }, { 0.60, -0.40 },
    },
  },
}

-- Sky anchors: ~90° apart so you cannot frame all four at once.
local ANCHORS = {
  Pikachu    = { az = math.rad(25),  el = math.rad(38), scale = math.rad(20) },
  Charmander = { az = math.rad(115), el = math.rad(42), scale = math.rad(19) },
  Squirtle   = { az = math.rad(205), el = math.rad(36), scale = math.rad(20) },
  Bulbasaur  = { az = math.rad(295), el = math.rad(40), scale = math.rad(19) },
}

local function localToDir(u, v, anchor)
  local az = anchor.az + u * anchor.scale
  local el = anchor.el + v * anchor.scale * 0.85
  if el < math.rad(4) then el = math.rad(4) end
  if el > math.rad(78) then el = math.rad(78) end
  local ce, se = math.cos(el), math.sin(el)
  local dx = math.sin(az) * ce
  local dy = se
  local dz = math.cos(az) * ce
  local L = math.sqrt(dx * dx + dy * dy + dz * dz)
  if L > 1e-8 then dx, dy, dz = dx / L, dy / L, dz / L end
  return dx, dy, dz, az, el
end

local STARS = {}
local BY_NAME = {}

local function addStar(name, u, v, col, size, a, primary)
  local anchor = ANCHORS[name]
  if not anchor then return end
  local dx, dy, dz, az, el = localToDir(u, v, anchor)
  local s = {
    constellation = name,
    primary = primary and true or false,
    dx = dx, dy = dy, dz = dz,
    az = az, el = el,
    size = size or 2.8,
    a = a or 1.0,
    r = col[1], g = col[2], b = col[3],
    tw = 0.8, tw2 = 0.4, phase = hash(#STARS * 3.1) * math.pi * 2,
    phase2 = hash(#STARS * 7.7) * math.pi * 2,
    twDepth = 0.08,
    hideNearBuilding = false,
  }
  STARS[#STARS + 1] = s
  local bag = BY_NAME[name]
  if not bag then bag = {}; BY_NAME[name] = bag end
  bag[#bag + 1] = s
end

do
  for name, shape in pairs(SHAPES) do
    local col = shape.color
    local outline = densify(shape.poly, 0.045)
    for i, p in ipairs(outline) do
      local primary = (i % 5 == 1)
      addStar(name, p[1], p[2], col, primary and 3.6 or 2.6, primary and 1.0 or 0.95, primary)
    end
    if shape.tail then
      local tail = densify(shape.tail, 0.04)
      for _, p in ipairs(tail) do
        addStar(name, p[1], p[2], col, 2.9, 1.0, true)
      end
    end
    if shape.accents then
      for _, p in ipairs(shape.accents) do
        addStar(name, p[1], p[2], { 1, 1, 1 }, 3.2, 1.0, true)
      end
    end
  end
end

C.STARS = STARS
C.BY_NAME = BY_NAME
C.NAMES = { "Pikachu", "Charmander", "Squirtle", "Bulbasaur" }
C.ANCHORS = ANCHORS

function C.count()
  return #STARS
end

--- Append constellation stars into world mesh (always vivid; no LOD skip).
function C.appendWorld(verts, n, pushQuad, axisR, axisU, eye, radius, rotateY, vaultAng, nightVis, starFade, twinkleAlpha, t)
  if (nightVis or 0) < 0.05 then return n end
  for i = 1, #STARS do
    local s = STARS[i]
    local fade = 1
    if starFade then fade = starFade(s, nightVis) or nightVis end
    if fade >= 0.02 then
      local dx, dy, dz = s.dx, s.dy, s.dz
      if rotateY and vaultAng then
        dx, dy, dz = rotateY(dx, dy, dz, vaultAng)
      end
      local cx = eye[1] + dx * radius
      local cy = eye[2] + dy * radius
      local cz = eye[3] + dz * radius
      local tw = 1
      if twinkleAlpha then tw = twinkleAlpha(s, t or 0) end
      local a = math.min(1.0, (s.a or 1) * fade * (0.85 + 0.15 * tw) * 1.15)
      local half = math.max(1.2, (s.size or 2.8) * 0.7)
      n = pushQuad(verts, n, cx, cy, cz, half * 1.35, axisR, axisU, s.r, s.g, s.b, a * 0.45)
      n = pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, s.r, s.g, s.b, a)
      if s.primary then
        n = pushQuad(verts, n, cx, cy, cz, half * 0.4, axisR, axisU, 1, 1, 1, a)
      end
    end
  end
  return n
end

return C
