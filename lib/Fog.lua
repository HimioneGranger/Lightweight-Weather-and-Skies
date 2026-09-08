-- FOG AND MIST: banks of drifting cloud, generated at runtime.
--
-- WHY THERE IS NO FOG TEXTURE IN assets/.  Two reasons, and the second is
-- the real one.  A tiling noise sheet would be a few kilobytes, which is
-- nothing -- but it would also be a hand-authored asset that has to look
-- right at every zoom on both renderers, and value noise is four lines of
-- arithmetic that always does.  Generating it means the mod ships no
-- pixels at all: nothing derived from the ROM, nothing to license, nothing
-- to keep in step with a palette mode.
--
-- HOW IT READS AS DEPTH WITHOUT ANY DEPTH.  Three things, none of which
-- need the scene:
--
--   * LAYERS AT DIFFERENT SCALES AND SPEEDS.  The near bank is large and
--     fast, the far bank small and slow.  Parallax between them is the
--     whole illusion, and it costs one extra quad per layer.
--   * A VERTICAL GRADIENT.  Fog pools low.  The mesh carries per-vertex
--     alpha, so the bottom of the screen is dense and the top is nearly
--     clear in a single draw rather than a stack of scissored bands.
--   * DRIFT TIED TO THE CAMERA, not just to the clock.  Walking east
--     slides the banks west at a fraction of the world's speed, so they
--     sit at a distance instead of being stuck to the glass.  The fraction
--     is small (fog is close), which is what separates it from Dramatic
--     Shape's horizon backdrop, which is pinned to the player precisely
--     because it is far away.
--
-- COST.  One 128x128 texture built once, one four-vertex mesh reused per
-- layer, and one draw per layer -- so the LOW tier's single layer is a
-- single quad.  Nothing here scales with particle count.

local V = ...

local Fog = {}

local NOISE = 128          -- texture edge, power of two so wrapping is exact
local LATTICE = 16         -- value-noise grid; NOISE/LATTICE = cell size

local texture, mesh = nil, nil

-- ------- the noise
--
-- Value noise: a lattice of random values, smoothly interpolated, summed
-- over three octaves.  Seeded deterministically so the sheet is the same
-- every launch -- a fog bank that differed between sessions would be an
-- invisible difference bought with an unreproducible bug report.

local function smoothstep(t)
  return t * t * (3 - 2 * t)
end

local function buildLattice(size, seed)
  local grid = {}
  local s = seed
  for y = 0, size - 1 do
    grid[y] = {}
    for x = 0, size - 1 do
      -- a cheap deterministic hash; quality here only has to beat "looks
      -- like a grid", which it does
      s = (s * 1103515245 + 12345) % 2147483648
      grid[y][x] = (s % 65536) / 65535
    end
  end
  return grid
end

local function sampleLattice(grid, size, x, y)
  local x0, y0 = math.floor(x), math.floor(y)
  local fx, fy = smoothstep(x - x0), smoothstep(y - y0)
  local xa, xb = x0 % size, (x0 + 1) % size
  local ya, yb = y0 % size, (y0 + 1) % size
  local v00, v10 = grid[ya][xa], grid[ya][xb]
  local v01, v11 = grid[yb][xa], grid[yb][xb]
  local top = v00 + (v10 - v00) * fx
  local bot = v01 + (v11 - v01) * fx
  return top + (bot - top) * fy
end

local function buildTexture()
  if texture then return texture end
  if not (love and love.graphics and love.image) then return nil end
  local ok, image = pcall(function()
    local data = love.image.newImageData(NOISE, NOISE)
    local octaves = {
      { grid = buildLattice(LATTICE, 20260805), cells = LATTICE, gain = 0.55 },
      { grid = buildLattice(LATTICE * 2, 991), cells = LATTICE * 2, gain = 0.30 },
      { grid = buildLattice(LATTICE * 4, 7717), cells = LATTICE * 4, gain = 0.15 },
    }
    data:mapPixel(function(px, py)
      local v = 0
      for _, oct in ipairs(octaves) do
        local sx = px / NOISE * oct.cells
        local sy = py / NOISE * oct.cells
        v = v + sampleLattice(oct.grid, oct.cells, sx, sy) * oct.gain
      end
      -- Bias toward transparency: raw noise averages 0.5, which would be a
      -- flat grey sheet.  The curve keeps the bright wisps and clears the
      -- middle, which is what makes it read as separate banks.
      v = math.max(0, (v - 0.42) / 0.58)
      v = v * v * (3 - 2 * math.min(1, v))
      return 1, 1, 1, math.min(1, v)
    end)
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    img:setWrap("repeat", "repeat")
    return img
  end)
  if not ok then return nil end
  texture = image
  return texture
end

local function buildMesh()
  if mesh then return mesh end
  if not buildTexture() then return nil end
  local ok, made = pcall(function()
    local m = love.graphics.newMesh({
      { 0, 0, 0, 0, 1, 1, 1, 1 },
      { 1, 0, 1, 0, 1, 1, 1, 1 },
      { 1, 1, 1, 1, 1, 1, 1, 1 },
      { 0, 1, 0, 1, 1, 1, 1, 1 },
    }, "fan", "stream")
    m:setTexture(texture)
    return m
  end)
  if not ok then return nil end
  mesh = made
  return mesh
end

function Fog.invalidate()
  texture, mesh = nil, nil
end

function Fog.ready()
  return buildTexture() ~= nil
end

-- ------- layers
--
-- scale  how many texture tiles fit across the screen (small = far)
-- speed  drift in tiles per second
-- para   how much of the camera's motion the layer takes, 0..1
-- top    alpha at the top edge, bot at the bottom -- the gradient
-- weight share of the fog channel this layer carries

Fog.LAYERS = {
  -- Long-distance visibility loss: stronger far (top) + heavy weights.
  { scale = 1.00, speed = 0.012, para = 0.16, top = 0.62, bot = 1.00, weight = 2.80 },
  { scale = 2.00, speed = 0.028, para = 0.09, top = 0.50, bot = 1.00, weight = 2.20 },
  { scale = 3.50, speed = 0.048, para = 0.05, top = 0.38, bot = 0.98, weight = 1.70 },
  -- Extra banks for top-down / lower quality (still capped by layers arg)
  { scale = 1.40, speed = 0.018, para = 0.12, top = 0.45, bot = 1.00, weight = 2.40 },
  { scale = 2.80, speed = 0.036, para = 0.07, top = 0.32, bot = 0.96, weight = 1.90 },
}

-- Ground fog: pools in the lower screen (top-down / diorama). top alpha
-- near 0 so sky stays readable; bot heavy so the map floor is hazed.
Fog.GROUND_LAYERS = {
  { scale = 0.85, speed = 0.010, para = 0.20, top = 0.05, bot = 1.00, weight = 3.20, y0 = 0.35 },
  { scale = 1.60, speed = 0.022, para = 0.12, top = 0.08, bot = 1.00, weight = 2.60, y0 = 0.48 },
  { scale = 2.40, speed = 0.038, para = 0.06, top = 0.04, bot = 0.95, weight = 2.00, y0 = 0.55 },
}

local FOG_R, FOG_G, FOG_B = 0.86, 0.89, 0.93   -- a cool white, never pure
local FOG_DIR = 1   -- +1 = drift to the right of the screen

function Fog.setTint(r, g, b, dir)
  if r then FOG_R, FOG_G, FOG_B = r, g, b end
  if dir ~= nil then FOG_DIR = dir end
end

function Fog.resetTint()
  FOG_R, FOG_G, FOG_B = 0.86, 0.89, 0.93
  FOG_DIR = 1
end

-- `amount` is the eased fog channel, `layers` the quality cap, `t` the
-- weather clock, `camX/camY` the world camera in world pixels, `scale` the
-- frame's pixels-per-GB-pixel, and `w/h` the rect.
function Fog.draw(amount, alpha, layers, t, camX, camY, scale, w, h, speedCh)
  if amount <= 0 or alpha <= 0 then return end
  local m = buildMesh()
  if not m then return end
  local drift = 0.6 + 0.9 * (speedCh or 0.5)

  love.graphics.setBlendMode("alpha")
  for i = 1, math.min(layers or 1, #Fog.LAYERS) do
    local L = Fog.LAYERS[i]
    -- tiles across the screen: keeping this proportional to the rect's
    -- aspect means a wide window shows more fog, not stretched fog
    local tilesX = L.scale * (w / (160 * scale))
    local tilesY = L.scale * (h / (144 * scale))
    -- Wrapped into 0..1 before it reaches the mesh.  The texture repeats,
    -- so subtracting whole tiles is invisible -- and it keeps the uv a
    -- small number after an hour of play instead of one large enough to
    -- start losing precision against the tile size.
    -- FOG_DIR > 0 → banks travel right (matches sand/dust grain motion).
    local ox = ((-FOG_DIR * t * L.speed * drift) + (camX / (160 * 16)) * L.para) % 1
    local oy = ((t * L.speed * drift * 0.35) + (camY / (144 * 16)) * L.para) % 1
    -- Extreme amounts (FOG INTENSITY 200%+) stack dense; soft-cap per layer at 1.
    local a = alpha * amount * L.weight
    if a > 1.35 then a = 1.35 end
    -- per-vertex uv (the scroll) and alpha (the gradient) in one update
    m:setVertices({
      { 0, 0, ox,           oy,           FOG_R, FOG_G, FOG_B, a * L.top },
      { w, 0, ox + tilesX,  oy,           FOG_R, FOG_G, FOG_B, a * L.top },
      { w, h, ox + tilesX,  oy + tilesY,  FOG_R, FOG_G, FOG_B, a * L.bot },
      { 0, h, ox,           oy + tilesY,  FOG_R, FOG_G, FOG_B, a * L.bot },
    })
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(m)
  end
end

-- Top-down / diorama ground fog: dense banks in the lower portion of the
-- frame so fog remains readable when the camera is not in first person.
-- `strength` is scaled by FOG INTENSITY × weather intensity × quality.
function Fog.drawGround(amount, alpha, layers, t, camX, camY, scale, w, h, speedCh, strength)
  if amount <= 0 or alpha <= 0 then return end
  strength = strength or 1
  if strength <= 0.01 then return end
  if not Fog.GROUND_LAYERS then return end
  local m = buildMesh()
  if not m then return end
  local drift = 0.55 + 0.85 * (speedCh or 0.5)
  local n = math.max(1, math.min(layers or 2, #Fog.GROUND_LAYERS))
  love.graphics.setBlendMode("alpha")
  for i = 1, n do
    local L = Fog.GROUND_LAYERS[i]
    local y0 = (L.y0 or 0.4) * h
    local gh = h - y0
    if gh < 4 then gh = h * 0.4; y0 = h - gh end
    local tilesX = L.scale * (w / (160 * scale))
    local tilesY = L.scale * (gh / (144 * scale))
    local ox = ((-FOG_DIR * t * L.speed * drift) + (camX / (160 * 16)) * L.para) % 1
    local oy = ((t * L.speed * drift * 0.4) + (camY / (144 * 16)) * L.para) % 1
    local a = alpha * amount * L.weight * strength
    if a > 1.45 then a = 1.45 end
    local topA = a * (L.top or 0.05)
    local botA = a * (L.bot or 1)
    m:setVertices({
      { 0, y0, ox,           oy,           FOG_R, FOG_G, FOG_B, topA },
      { w, y0, ox + tilesX,  oy,           FOG_R, FOG_G, FOG_B, topA },
      { w, h,  ox + tilesX,  oy + tilesY,  FOG_R, FOG_G, FOG_B, botA },
      { 0, h,  ox,           oy + tilesY,  FOG_R, FOG_G, FOG_B, botA },
    })
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(m)
  end
end

return Fog

