-- PRECIPITATION AND DEBRIS: everything that moves through the air.
--
-- FOUR DECISIONS WORTH THE COMMENT:
--
-- 1. ONE DRAW CALL, ALWAYS.  Every drop, flake, grain, leaf and splash
--    tick goes into a single SpriteBatch built on a 1x1 white texture, so
--    a full-tier downpour is one draw call and one texture bind rather
--    than 900.  The 1x1 texture is also the reason there is no `assets/`
--    folder: a white pixel stretched to (length, thickness) and rotated IS
--    a rain streak, and scaled square IS a flake.  Nothing is shipped,
--    nothing is derived from the ROM, and the batch's per-sprite colour
--    does the rest.
--
-- 2. NOTHING IS ALLOCATED AFTER WARMUP.  The pools are flat parallel
--    arrays sized once to the quality cap.  A drop that falls off the
--    bottom is not freed and a new one is not created -- the same slot is
--    rewound to the top with fresh randomness.  Density changes by moving
--    an `active` count, so a drizzle is the same memory as a storm and the
--    garbage collector never sees weather.
--
-- 3. THREE POOLS, NOT SIX.  Rain and snow each get their own because they
--    coexist (hail is snow with grains through it) and behave completely
--    differently.  Hail, sand and debris share the GRAIN pool: they are
--    all "a hard little thing thrown across the screen", they differ only
--    in colour, speed, angle and whether they tumble, and two of the three
--    are mutually exclusive weathers anyway.  Each grain carries its kind,
--    assigned at spawn by rolling against the live channel mix -- so a
--    transition from sandstorm to hail is grains changing kind one at a
--    time as they recycle, which reads as the storm turning over rather
--    than as one effect being swapped for another.
--
-- 4. PARTICLES ARE SIZED IN GAME-BOY PIXELS, NOT SCREEN PIXELS.  Every
--    length and speed here is in GB pixels and multiplied by the frame's
--    scale at draw time, so weather looks the same at 1x in a small
--    window, at 6x fullscreen, through the survey zoom, and over a voxel
--    diorama, whose scale is the same number measured the same way.
--
-- SPLASHES AND BOUNCES CARRY THEIR OWN CAMERA.  A splash is on the GROUND,
-- but this system draws in screen space, so one spawned while the player
-- is walking would slide with the screen for its whole life.  Each records
-- the camera position it was born at and is drawn offset by how far the
-- camera has moved since, which pins it to the ground for the third of a
-- second it exists, at the cost of two numbers per splash.

local V = ...

local P = {}

-- LÖVE 11 is LuaJIT, where math.atan2 exists; a 5.3+ host (a headless test
-- runner, a future LÖVE) folds it into math.atan.  One line here beats a
-- version check at the call site.
local atan2 = math.atan2 or math.atan

-- ------- the white pixel

local pixel, batch, batchCap = nil, nil, 0

local function ensureTexture()
  if pixel then return pixel end
  if not (love and love.graphics and love.image) then return nil end
  local ok, image = pcall(function()
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, 1, 1, 1, 1)
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    return img
  end)
  if not ok then return nil end
  pixel = image
  return pixel
end

local function ensureBatch(capacity)
  if not ensureTexture() then return nil end
  if batch and batchCap >= capacity then return batch end
  local ok, made = pcall(love.graphics.newSpriteBatch, pixel, capacity, "stream")
  if not ok then return nil end
  batch, batchCap = made, capacity
  return batch
end

function P.ready()
  return ensureTexture() ~= nil
end

function P.invalidate()
  pixel, batch, batchCap = nil, nil, 0
end

-- ------- pools

local function newPool(fields)
  local pool = { n = 0, active = 0 }
  for _, name in ipairs(fields) do pool[name] = {} end
  return pool
end

-- `ld` is the y this drop lands at.  THE WHOLE SCREEN IS GROUND in a
-- top-down game: rain that only bursts along the bottom edge is what a
-- side-on game would do, and it reads as the rain falling behind the world
-- instead of onto it.  Each drop picks its own landing depth at spawn, so
-- splashes appear at every distance at once, the way they do out a window.
local rain  = newPool({ "x", "y", "vs", "ls", "a", "ld", "dp" })
local snow  = newPool({ "x", "y", "vs", "ph", "sw", "sz", "a", "dp", "y0", "pathH" })
-- grain: kind 1 = hail, 2 = sand, 3 = debris, 4 = ash, 5 = black ash
local grain = newPool({ "x", "y", "vx", "vy", "kind", "sz", "a", "rot", "spin", "ld", "dp", "pathH" })
-- splash: kind 1 = water burst, 2 = hail bounce, 3 = dust puff
local splash = newPool({ "x", "y", "cx", "cy", "t", "sz", "kind" })
-- Ground wet residual after a drop hits (2s dry-up).
local wetGround = newPool({ "x", "y", "cx", "cy", "t", "sz" })
local wetCursor = 0

local function rnd(a, b)
  if love and love.math and love.math.random then return love.math.random() * (b - a) + a end
  return math.random() * (b - a) + a
end

local rect = { w = 0, h = 0, scale = 1 }

local function rescale(w, h)
  if rect.w <= 0 or rect.h <= 0 then return end
  local fx, fy = w / rect.w, h / rect.h
  for i = 1, rain.n do
    rain.x[i] = rain.x[i] * fx
    rain.y[i] = rain.y[i] * fy
    rain.ld[i] = rain.ld[i] * fy
  end
  for i = 1, snow.n do snow.x[i] = snow.x[i] * fx; snow.y[i] = snow.y[i] * fy end
  for i = 1, grain.n do
    grain.x[i] = grain.x[i] * fx
    grain.y[i] = grain.y[i] * fy
    grain.ld[i] = grain.ld[i] * fy
  end
  -- splashes are transient; letting them die where they are is cheaper
  -- and invisible
end

function P.setRect(w, h, scale)
  w, h = math.max(1, w or 1), math.max(1, h or 1)
  if w ~= rect.w or h ~= rect.h then
    rescale(w, h)
    rect.w, rect.h = w, h
  end
  rect.scale = math.max(0.25, scale or 1)
end

-- ------- spawners
--
-- `fresh` scatters through the whole field (first fill, so the sky is not
-- empty for a second); otherwise the particle is rewound to just outside
-- the edge it entered from, which is where a recycled one belongs.

-- How far up the screen a drop may land, 0..1 (config `splashSpread`).
-- 1 = anywhere on screen, 0 = the bottom edge only.
P.spread = 1.0

local function landingY(fresh, startY)
  local top = rect.h * (1 - math.max(0, math.min(1, P.spread)))
  local y = rnd(top, rect.h)
  -- A drop rewound to the top must not be given a landing depth it has
  -- already passed, or it recycles instantly and the pool thrashes.
  if startY and y < startY then y = rect.h end
  return y
end

local function spawnRain(i, fresh)
  -- 20 spread depth layers (near → far).
  local layer = math.min(19, math.floor(rnd(0, 1) * 20))
  local depth = 1.0 - (layer / 19)  -- 1 near … 0 far
  rain.dp[i] = depth
  rain.x[i] = rnd(-0.25 * rect.w, 1.25 * rect.w)
  rain.y[i] = fresh and rnd(0, rect.h) or rnd(-0.2 * rect.h, -2)
  rain.vs[i] = (0.72 + depth * 0.55) * rnd(0.88, 1.12)
  rain.ls[i] = rnd(0.55, 1.15) * (0.40 + depth * 1.15)
  rain.a[i] = rnd(0.32, 0.50) + depth * 0.50
  rain.ld[i] = landingY(fresh, rain.y[i])
end

local function spawnSnow(i, fresh)
  -- 20 depth layers. pathH is the SCREEN Y where the flake stops/recycles:
  -- layer 1 (near, depth=1) → past bottom of screen (exits)
  -- layer 20 (far, depth=0) → 50% down the screen
  -- layers between are linear steps.
  local layer = math.min(19, math.floor(rnd(0, 1) * 20))
  local depth = 1.0 - (layer / 19)  -- 1 nearest … 0 farthest
  snow.dp[i] = depth
  -- endY: near = 1.05*h (clear bottom exit), far = 0.50*h
  snow.pathH[i] = rect.h * (0.50 + 0.55 * depth)
  snow.x[i] = rnd(-0.22 * rect.w, 1.22 * rect.w)
  -- Always start near the top so near flakes travel the full height
  if fresh then
    snow.y[i] = rnd(-0.18 * rect.h, 0.02 * rect.h)
  else
    snow.y[i] = rnd(-0.22 * rect.h, -0.02 * rect.h)
  end
  snow.y0[i] = snow.y[i]
  snow.vs[i] = (0.16 + depth * 1.05) * rnd(0.72, 1.28)
  snow.ph[i] = rnd(0, math.pi * 2)
  snow.sw[i] = rnd(0.6, 2.8) * (0.35 + depth * 1.15)
  snow.sz[i] = rnd(0.45, 0.81) * (0.55 + depth * 0.55)
  snow.a[i] = rnd(0.28, 0.42) + depth * 0.28
end

-- The kind mix, refreshed each tick from the channels.  Rolling per spawn
-- rather than per pool is what makes a weather change look like the air
-- turning over instead of a swap.
local kindMix = { 0, 0, 0, 0, 0 }
local kindTotal = 0

local function rollKind()
  if kindTotal <= 0 then return 1 end
  local roll = rnd(0, kindTotal)
  for k = 1, 5 do
    roll = roll - kindMix[k]
    if roll <= 0 then return k end
  end
  return 1
end

-- Per-kind motion.  Hail falls hard and nearly straight; sand is thrown
-- almost horizontally and barely falls at all; debris tumbles across on
-- the wind at every height.
local function spawnGrain(i, fresh)
  local kind = rollKind()
  grain.kind[i] = kind
  local depth
  if kind == 4 or kind == 5 then
    -- Ash / black ash: 20 spread depth layers (FPV volume)
    local layer = math.min(19, math.floor(rnd(0, 1) * 20))
    depth = 1.0 - (layer / 19)
  elseif kind == 2 then
    -- Sand / dust: 20 spread depth layers
    local layer = math.min(19, math.floor(rnd(0, 1) * 20))
    depth = 1.0 - (layer / 19)
  elseif kind == 3 then
    -- Gale / debris leaves: 20 spread depth layers
    local layer = math.min(19, math.floor(rnd(0, 1) * 20))
    depth = 1.0 - (layer / 19)
  elseif kind == 1 then
    -- Hail: 10 spread depth layers
    local layer = math.min(9, math.floor(rnd(0, 1) * 10))
    depth = 1.0 - (layer / 9)
  else
    depth = rnd(0.08, 1.0)
  end
  grain.dp[i] = depth
  if kind == 2 then                                   -- sand / dust (20 depth layers)
    grain.x[i] = fresh and rnd(-0.15 * rect.w, 1.05 * rect.w) or rnd(-0.45 * rect.w, -4)
    -- Near lower in frame; far higher / more sparse vertical band
    grain.y[i] = rnd(-0.12 * rect.h + (1.0 - depth) * 0.15 * rect.h,
                     0.35 * rect.h + depth * 0.70 * rect.h)
    grain.vx[i] = rnd(1.4, 3.3) * (0.45 + depth * 1.05)
    grain.vy[i] = rnd(0.02, 0.35) * (0.45 + depth * 0.75)
    grain.sz[i] = rnd(0.7, 1.5) * (0.50 + depth * 0.65)
    grain.a[i] = rnd(0.26, 0.46) + depth * 0.35
  elseif kind == 4 or kind == 5 then                  -- ash / black ash (20 depth layers)
    -- pathH = end screen-Y: near exits bottom, layer 20 stops at 50% height
    grain.pathH[i] = rect.h * (0.50 + 0.55 * depth)
    grain.x[i] = rnd(-0.25 * rect.w, 1.25 * rect.w)
    -- Start near top so near layers travel full height and exit bottom
    if fresh then
      grain.y[i] = rnd(-0.18 * rect.h, 0.02 * rect.h)
    else
      grain.y[i] = rnd(-0.22 * rect.h, -0.02 * rect.h)
    end
    grain.vx[i] = rnd(-1.05, 1.1) * (0.35 + depth * 1.05)
    grain.vy[i] = rnd(0.06, 0.48) * (0.32 + depth * 1.15)
    grain.sz[i] = rnd(1.19, 2.17) * (0.52 + depth * 0.58)
    grain.a[i] = rnd(0.26, 0.40) + depth * 0.30
    grain.spin[i] = 0
  elseif kind == 3 then                               -- gale / debris leaves (20 depth layers)
    grain.x[i] = fresh and rnd(-0.1 * rect.w, 1.1 * rect.w) or rnd(-0.35 * rect.w, -8)
    grain.y[i] = rnd(-0.20 * rect.h + (1.0 - depth) * 0.12 * rect.h,
                     0.40 * rect.h + depth * 0.65 * rect.h)
    grain.vx[i] = rnd(0.7, 1.4) * (0.42 + depth * 1.15)
    grain.vy[i] = rnd(-0.45, 0.55) * (0.45 + depth * 0.85)
    grain.sz[i] = rnd(0.6, 1.4) * (0.48 + depth * 0.90)
    grain.a[i] = rnd(0.24, 0.48) + depth * 0.38
  else                                                -- hail (10 depth layers)
    -- pathH = end screen-Y: layer 1 exits bottom, layer 10 stops at 50%
    grain.pathH[i] = rect.h * (0.50 + 0.55 * depth)
    grain.x[i] = rnd(-0.15 * rect.w, 1.15 * rect.w)
    -- Start near top so near layers travel full height and exit bottom
    if fresh then
      grain.y[i] = rnd(-0.18 * rect.h, 0.02 * rect.h)
    else
      grain.y[i] = rnd(-0.22 * rect.h, -0.02 * rect.h)
    end
    grain.vx[i] = rnd(-0.12, 0.30) * (0.55 + depth * 0.55)
    grain.vy[i] = rnd(1.4, 2.3) * (0.50 + depth * 0.80)
    grain.sz[i] = rnd(0.88, 1.76) * (0.50 + depth * 0.70)
    grain.a[i] = rnd(0.36, 0.50) + depth * 0.35
  end
  -- hail bounces where it lands, and lands all over the screen for the
  -- same reason rain does
  grain.ld[i] = (kind == 1) and landingY(fresh, grain.y[i]) or (rect.h * 2)
  grain.rot[i] = rnd(0, math.pi * 2)
  grain.spin[i] = (kind == 3) and rnd(-6, 6) or ((kind == 4) and rnd(-1.2, 1.2) or 0)
end

local function spawnSplash(i)
  splash.x[i], splash.y[i] = 0, 0
  splash.cx[i], splash.cy[i] = 0, 0
  splash.t[i] = -1                      -- negative = dead slot
  splash.sz[i], splash.kind[i] = 1, 1
end

local function grow(pool, capacity, spawn)
  while pool.n < capacity do
    pool.n = pool.n + 1
    spawn(pool.n, true)
  end
end

-- Splashes use a rolling cursor rather than a free list: the pool is
-- small, every entry has the same short life, and overwriting the oldest
-- is both correct and one increment.
local splashCursor = 0

local function addSplash(x, y, camX, camY, size, kind)
  if splash.n <= 0 then return end
  splashCursor = splashCursor % splash.n + 1
  local i = splashCursor
  splash.x[i], splash.y[i] = x, y
  splash.cx[i], splash.cy[i] = camX, camY
  splash.t[i] = 0
  splash.sz[i], splash.kind[i] = size, kind or 1
  -- Wet mark that remains after the splash animation (2s).
  if wetGround.n > 0 and (kind or 1) == 1 then
    wetCursor = wetCursor % wetGround.n + 1
    local w = wetCursor
    wetGround.x[w], wetGround.y[w] = x, y
    wetGround.cx[w], wetGround.cy[w] = camX, camY
    wetGround.t[w] = 0
    wetGround.sz[w] = (size or 1) * (0.35 + rnd(0, 0.45))
  end
end

-- ------- the tick

local SPLASH_LIFE = 0.35
local WET_LIFE = 1.0

-- `ch` is the eased channel table; `budget` the quality caps; `wind` the
-- frame's gust in GB pixels per second; `camX/camY` the world camera, for
-- splash anchoring; `splashesOn` the player's setting.
function P.update(dt, ch, budget, wind, camX, camY, splashesOn)
  if dt <= 0 then return end
  local px = rect.scale

  if rain.n < budget.rain then grow(rain, budget.rain, spawnRain) end
  if snow.n < budget.snow then grow(snow, budget.snow, spawnSnow) end
  if splash.n < budget.splash then grow(splash, budget.splash, spawnSplash) end
  if wetGround.n < math.max(64, (budget.splash or 40) * 3) then
    grow(wetGround, math.max(64, (budget.splash or 40) * 3), function(i)
      wetGround.x[i], wetGround.y[i] = 0, 0
      wetGround.cx[i], wetGround.cy[i] = 0, 0
      wetGround.t[i] = -1
      wetGround.sz[i] = 1
    end)
  end

  -- the grain mix has to be set before the pool grows, or the first fill
  -- is all hail whatever the weather
  kindMix[1] = math.max(0, ch.hail or 0)
  kindMix[2] = math.max(0, (ch.sand or 0) * 1.85)   -- sand density (channels may exceed 1)
  kindMix[3] = math.max(0, ch.debris or 0)
  -- Ash weather: half gray ash, half black ash (same count total)
  local ash = math.max(0, ch.ash or 0)
  kindMix[4] = ash * 0.25
  kindMix[5] = ash * 0.25
  kindTotal = kindMix[1] + kindMix[2] + kindMix[3] + kindMix[4] + kindMix[5]
  if grain.n < budget.grain then grow(grain, budget.grain, spawnGrain) end

  rain.active = math.min(rain.n, math.floor(budget.rain * math.min(3.0, (ch.rain or 0)) + 0.5))
  snow.active = math.min(snow.n, math.floor(budget.snow * math.min(3.0, (ch.snow or 0)) + 0.5))
  grain.active = math.min(grain.n, math.floor(budget.grain * math.min(2.5, kindTotal) + 0.5))

  -- ------- rain
  local fall = 210 * (ch.rainSpeed or 1) * px
  local lean = math.tan(ch.rainAngle or 0)
  local drift = (lean * fall) + wind * px
  local splashChance = splashesOn and (ch.splash or 0) or 0
  for i = 1, rain.active do
    local vs = rain.vs[i]
    local ny = rain.y[i] + fall * vs * dt
    local nx = rain.x[i] + drift * vs * dt
    if ny >= rain.ld[i] then
      -- Land it.  A splash for a FRACTION of drops rather than all of
      -- them: every drop bursting reads as a solid line of foam, and the
      -- fraction is the channel, so a drizzle ticks and a downpour boils.
      if splashChance > 0 and rnd(0, 1) < splashChance * 0.35 then
        addSplash(nx, rain.ld[i], camX, camY, rnd(0.7, 1.3), 1)
      end
      spawnRain(i, false)
    elseif nx < -0.3 * rect.w or nx > 1.3 * rect.w then
      spawnRain(i, false)
    else
      rain.x[i], rain.y[i] = nx, ny
    end
  end

  -- ------- snow
  -- Realistic flake fall: slower base, layered sine sway (not straight down)
  local sfall = 28 * (ch.snowSpeed or 1) * px
  local sdrift = math.max(0.35, ch.snowDrift or 0.55)
  for i = 1, snow.active do
    local depth = snow.dp[i] or 0.5
    snow.ph[i] = snow.ph[i] + dt * (0.42 + snow.sw[i] * 0.55 + depth * 0.12)
    -- Multi-frequency drift (real flakes do not sway on one sine)
    local sway = math.sin(snow.ph[i]) * 32 * sdrift * snow.sw[i] * px
               + math.sin(snow.ph[i] * 1.73 + 0.4) * 16 * sdrift * px
               + math.sin(snow.ph[i] * 0.37) * 8 * sdrift * (0.4 + depth) * px
    local ny = snow.y[i] + sfall * snow.vs[i] * dt * (0.88 + depth * 0.22)
    local nx = snow.x[i] + (sway + wind * px * (0.35 + depth * 0.35)) * dt
    -- Panoramic wrap around the view (do not despawn at left/right edges)
    local margin = 0.2 * rect.w
    local span = rect.w + margin * 2
    if nx < -margin then
      nx = nx + span
    elseif nx > rect.w + margin then
      nx = nx - span
    end
    -- pathH is the end screen-Y for this layer (not travel distance)
    local endY = snow.pathH[i] or rect.h
    if ny >= endY then
      spawnSnow(i, false)
    else
      snow.x[i], snow.y[i] = nx, ny
    end
  end

  -- ------- grains
  --
  -- One loop for all three kinds: the kind only picks the base speeds,
  -- which were baked into vx/vy at spawn, so the motion here is common.
  local base = 150 * px
  for i = 1, grain.active do
    local kind = grain.kind[i]
    local vx = grain.vx[i] * base + wind * px * (kind == 1 and 0.5 or 1.2)
    local vy = grain.vy[i] * base
    local nx = grain.x[i] + vx * dt
    local ny = grain.y[i] + vy * dt
    -- Ash uses spin as a color flag (0/1), not angular velocity.
    if grain.kind[i] ~= 4 and grain.spin[i] ~= 0 then
      grain.rot[i] = grain.rot[i] + grain.spin[i] * dt
    end
    if (kind == 4 or kind == 5) then
      local endY = grain.pathH[i] or rect.h
      if ny >= endY then
        spawnGrain(i, false)
      else
        grain.x[i], grain.y[i] = nx, ny
      end
    elseif kind == 1 then
      -- Hail path by depth layer (same idea as snow/ash)
      local endY = grain.pathH[i] or rect.h
      if ny >= endY then
        if splashesOn and rnd(0, 1) < 0.35 then
          addSplash(nx, math.min(endY, rect.h * 0.98), camX, camY, rnd(0.5, 0.9), 2)
        end
        spawnGrain(i, false)
      else
        grain.x[i], grain.y[i] = nx, ny
      end
    elseif ny >= rect.h * 1.2 or ny < -0.35 * rect.h
        or nx < -0.35 * rect.w or nx > 1.35 * rect.w then
      spawnGrain(i, false)
    else
      grain.x[i], grain.y[i] = nx, ny
    end
  end

  -- ------- splashes
  for i = 1, splash.n do
    local t = splash.t[i]
    if t >= 0 then
      t = t + dt
      splash.t[i] = (t >= SPLASH_LIFE) and -1 or t
    end
  end
  -- ------- ground wet residual (2s)
  for i = 1, wetGround.n do
    local t = wetGround.t[i]
    if t >= 0 then
      t = t + dt
      wetGround.t[i] = (t >= WET_LIFE) and -1 or t
    end
  end

  -- Random small wet flecks across the whole playfield while raining.
  local rainAmt = ch.rain or 0
  if rainAmt > 0.05 and wetGround.n > 0 then
    local rate = 18 * math.min(1.5, rainAmt) * dt
    local nSpawn = math.floor(rate)
    if rnd(0, 1) < (rate - nSpawn) then nSpawn = nSpawn + 1 end
    for _ = 1, nSpawn do
      wetCursor = wetCursor % wetGround.n + 1
      local w = wetCursor
      wetGround.x[w] = rnd(0, rect.w)
      wetGround.y[w] = rnd(rect.h * 0.35, rect.h * 0.98)
      wetGround.cx[w], wetGround.cy[w] = camX, camY
      wetGround.t[w] = 0
      wetGround.sz[w] = 0.25 + rnd(0, 0.4)
    end
  end
end

-- ------- the draw
--
-- Colours are chosen to read on the Game Boy's four-shade palettes as well
-- as on a full-colour diorama: rain is a cool near-white at low alpha (it
-- reads as a lightening streak on dark tiles and a darkening one on
-- light), snow and hail are flat white, sand is a warm tan, debris is a
-- dark olive.

local RAIN_R, RAIN_G, RAIN_B = 0.74, 0.83, 0.98
local GRAIN_COLOR = {
  { 0.92, 0.96, 1.00 },   -- hail: white with a blue edge
  { 0.85, 0.72, 0.48 },   -- sand: warm tan
  { 0.45, 0.42, 0.24 },   -- debris: dry olive
  { 0.62, 0.62, 0.60 },   -- ash: ash gray
  { 0.08, 0.08, 0.09 },   -- black ash
}
local SPLASH_COLOR = {
  { RAIN_R, RAIN_G, RAIN_B },
  { 0.92, 0.96, 1.00 },
  { 0.80, 0.70, 0.50 },
}

function P.draw(alpha, ch)
  local total = rain.active + snow.active + grain.active + splash.n * 2
  if total <= 0 or alpha <= 0 then return end
  local b = ensureBatch(math.max(64, total + 32))
  if not b then return end
  b:clear()

  local px = rect.scale
  local added = 0

  -- rain: a 1x1 pixel stretched to (length, thickness) and rotated to the
  -- direction of travel, so the streak always points the way the drop is
  -- going however hard the wind is blowing
  if rain.active > 0 then
    local angle = atan2(1, math.tan(ch.rainAngle or 0))
    local len = 9 * (ch.rainLen or 1) * px
    local thick = math.max(1, 0.7 * px)
    local base = alpha * 0.55
    for i = 1, rain.active do
      local depth = rain.dp[i] or 0.5
      local la = base * rain.a[i] * (0.42 + depth * 0.58)
      local ll = len * rain.ls[i] * (0.70 + depth * 0.55)
      local th = math.max(1, thick * (0.65 + depth * 0.55))
      b:setColor(RAIN_R, RAIN_G, RAIN_B, la)
      b:add(rain.x[i], rain.y[i], angle, ll, th, 0, 0.5)
      added = added + 1
    end
  end

  -- snow: depth-layered flakes (near large/opaque, far small/faint — like rain depth)
  if snow.active > 0 then
    local base = alpha * 0.9
    for i = 1, snow.active do
      local depth = snow.dp[i] or 0.5
      local s = snow.sz[i] * px * (0.75 + depth * 0.55)
      local a = base * snow.a[i] * (0.45 + depth * 0.55)
      local x, y = snow.x[i], snow.y[i]
      b:setColor(0.95, 0.97, 1.0, a)
      b:add(x, y, 0, s, s, 0.5, 0.5)
      local arm = s * 0.55
      b:setColor(0.95, 0.97, 1.0, a * 0.7)
      b:add(x - arm, y, 0, arm, s * 0.35, 0.5, 0.5)
      b:add(x + arm, y, 0, arm, s * 0.35, 0.5, 0.5)
      b:add(x, y - arm, 0, s * 0.35, arm, 0.5, 0.5)
      b:add(x, y + arm, 0, s * 0.35, arm, 0.5, 0.5)
      added = added + 5
    end
  end

  -- grains: hail is a short vertical dash, sand a long horizontal one,
  -- debris a tumbling flake.  All three are the same quad at different
  -- aspect ratios and rotations.
  if grain.active > 0 then
    for i = 1, grain.active do
      local kind = grain.kind[i]
      local c = GRAIN_COLOR[kind]
      local depth = grain.dp[i] or 0.5
      local s = grain.sz[i] * px * (0.72 + depth * 0.50)
      local depthA = 0.42 + depth * 0.58
      local w, h, rot
      if kind == 2 then
        w, h, rot = s * 3.2, math.max(1, s * 0.45), grain.rot[i] * 0 + 0.12
      elseif kind == 4 or kind == 5 then
        -- Soft irregular ash flake (gray ash or black ash)
        local seed = grain.rot[i] or 0
        local aw = 0.85 + (seed % 0.55)
        local ah = 0.70 + ((seed * 0.41) % 0.50)
        w, h, rot = s * aw, s * ah, grain.rot[i]
      elseif kind == 3 then
        -- Leaf-like aspect from stable rot seed (no per-frame flicker)
        local seed = grain.rot[i] or 0
        local aw = 1.2 + (seed % 1.25)
        local ah = 0.45 + ((seed * 0.37) % 0.7)
        w, h, rot = s * aw, s * ah, grain.rot[i]
      else
        -- Hail balls
        w, h, rot = math.max(1.5, s * 1.0), math.max(1.5, s * 1.0), 0
      end
      if kind == 4 then
        -- Ash gray layered flake
        local gx, gy = grain.x[i], grain.y[i]
        local aa = alpha * grain.a[i] * depthA
        b:setColor(0.58, 0.58, 0.56, aa * 0.55)
        b:add(gx, gy, rot, w * 1.25, h * 1.15, 0.5, 0.5)
        b:setColor(0.68, 0.68, 0.66, aa * 0.85)
        b:add(gx, gy, rot + 0.4, w, h, 0.5, 0.5)
        b:setColor(0.48, 0.48, 0.46, aa * 0.40)
        b:add(gx + w * 0.15, gy - h * 0.1, rot - 0.25, w * 0.55, h * 0.55, 0.5, 0.5)
        added = added + 3
      elseif kind == 5 then
        -- Black ash — same flake animation, black color
        local gx, gy = grain.x[i], grain.y[i]
        local aa = alpha * grain.a[i] * depthA
        b:setColor(0.08, 0.08, 0.09, aa * 0.50)
        b:add(gx, gy, rot, w * 1.25, h * 1.15, 0.5, 0.5)
        b:setColor(0.14, 0.14, 0.15, aa * 0.85)
        b:add(gx, gy, rot + 0.4, w, h, 0.5, 0.5)
        b:setColor(0.05, 0.05, 0.06, aa * 0.40)
        b:add(gx + w * 0.15, gy - h * 0.1, rot - 0.25, w * 0.55, h * 0.55, 0.5, 0.5)
        added = added + 3
      else
        b:setColor(c[1], c[2], c[3], alpha * grain.a[i] * 0.9 * depthA)
        b:add(grain.x[i], grain.y[i], rot, w, h, 0.5, 0.5)
        added = added + 1
      end
    end
  end

  -- Ground wet residual (dark spots that dry over 2s)
  if wetGround.n > 0 then
    for i = 1, wetGround.n do
      local t = wetGround.t[i]
      if t >= 0 then
        local k = t / WET_LIFE
        local a = alpha * 0.40 * (1 - k) * (1 - k)
        if a > 0.02 then
          local ox = wetGround.x[i] + (wetGround.cx[i] - P.camX) * px
          local oy = wetGround.y[i] + (wetGround.cy[i] - P.camY) * px
          local sz = wetGround.sz[i] * px * (0.7 + k * 0.15)
          b:setColor(0.22, 0.26, 0.32, a)
          b:add(ox, oy, 0, math.max(1, sz * 1.1), math.max(1, sz * 0.45), 0.5, 0.5)
          added = added + 1
        end
      end
    end
  end

  -- splashes: two ticks thrown apart and up, shrinking as they fade, drawn
  -- at the camera offset they were born with so they stay on the ground
  if splash.n > 0 then
    for i = 1, splash.n do
      local t = splash.t[i]
      if t >= 0 then
        local k = t / SPLASH_LIFE
        local kind = splash.kind[i]
        local c = SPLASH_COLOR[kind] or SPLASH_COLOR[1]
        local spread = (1 + k * (kind == 2 and 2.0 or 3.2)) * splash.sz[i] * px
        local rise = -k * (kind == 2 and 3.4 or 2.4) * px
        local a = alpha * 0.7 * (1 - k) * (1 - k)
        local ox = splash.x[i] + (splash.cx[i] - P.camX) * px
        local oy = splash.y[i] + (splash.cy[i] - P.camY) * px
        local w = math.max(1, 1.1 * px * (1 - k * 0.5))
        b:setColor(c[1], c[2], c[3], a)
        b:add(ox - spread, oy + rise, 0, w, math.max(1, 0.7 * px), 0.5, 0.5)
        b:add(ox + spread, oy + rise, 0, w, math.max(1, 0.7 * px), 0.5, 0.5)
        added = added + 2
      end
    end
  end

  if added == 0 then return end
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(b)
end

-- The camera the CURRENT frame is drawn at; splashes subtract the one they
-- were born at from it.  Set by Draw before P.draw.
P.camX, P.camY = 0, 0

function P.counts()
  return rain.active, snow.active, grain.active, splash.n
end

-- The y of one live splash, or nil for a dead slot.  For the test suite:
-- "splashes land at many depths" is the property that makes rain read as
-- falling ONTO a top-down world rather than behind it, and it is worth
-- asserting rather than eyeballing.
function P.splashY(i)
  if i < 1 or i > splash.n then return nil end
  if splash.t[i] < 0 then return nil end
  return splash.y[i]
end

function P.reset()
  rain.active, snow.active, grain.active = 0, 0, 0
  for i = 1, splash.n do splash.t[i] = -1 end
  for i = 1, wetGround.n do wetGround.t[i] = -1 end
end

return P
