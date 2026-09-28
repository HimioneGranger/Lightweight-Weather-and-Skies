-- A flat cloud deck, drifting overhead.
--
-- ------- what it is
--
-- One tiling sheet of clouds high over the map: a 512x512 texture of
-- tileable value noise, and every texel of it wears an alpha of its own
-- read straight off the noise -- clear below a coverage cut, then more solid
-- with density up to the hearts of the thickest banks. Broad authored alpha
-- levels retain the pixel contrast, with a short fade between them. No dither
-- pattern lays over it: a cloud is a field of big square pixels each a little more or less see-through
-- than its neighbours, the way the sky's own bands are whole pixels of
-- one tone or another. It drifts slowly while a very low-frequency flow
-- bends the texture coordinates by only a puff or two, so the banks breathe
-- and change silhouette instead of travelling as one frozen cut-out. The
-- sheet is snapped to the camera in whole tiles so it reads as endless with
-- no seam. (The recipe
-- began as the player's own three.js page; the per-pixel alpha in place
-- of that page's ordered dither is the player's later call.)
--
-- ------- where it shows, and where it does not
--
-- OVERHEAD only where the camera stands in the world: the free-roam eye
-- (1ST and 3RD, the headset's 1ST modes) and a staged fight's placed shot.
-- Never over a DIORAMA -- the flat orbit rungs, the headset's tabletop --
-- where a deck of cloud sixty metres over a model on a table would sit
-- between the player and the thing they are looking at. There the clouds
-- show in the WATER alone: lib/Water's reflected rays meet the same deck
-- (the same texture, altitude and drift, handed to its shader), so a lake
-- on the table reflects a sky with clouds in it that the table itself
-- does not show. Which is the player's own rule for it.
--
-- ------- the far end
--
-- The reference dissolves the deck into the sky with a screen-space
-- dither. This pipeline's scene shader has FOG instead -- per vertex, so
-- the deck is a mesh of many cells rather than one quad -- and the deck
-- draws with a fog of its own, coloured the hour's haze, that takes it
-- out over a few hundred cells: where the deck reaches the horizon it is
-- the colour of the horizon, and the sheet's own edge never shows.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local CloudLight = V.require("CloudLight")
local cloudLight = {1,1,1}

local Clouds = {}
local cloudSpace = V.require('CloudSpace').new()
function Clouds.observeMap(map,neighbors) cloudSpace:observe(map,neighbors) end

-- ------- the deck, in world pixels (a map cell is 16)

Clouds.TEX = 512            -- larger unique field; same world size per texel
Clouds.PUFF = 20            -- world px per texel: how big a puff is (2 m)
Clouds.TILE = Clouds.TEX * Clouds.PUFF   -- one repeat of the sheet
Clouds.ALT = 1920           -- raised base deck in world pixels, game-wide
Clouds.DRIFT = 5.0          -- world px per second, along +X
Clouds.MORPH_PERIOD = 210   -- seconds for one complete, seamless evolution
Clouds.MORPH_WARP = 1.25 / Clouds.TEX
                            -- secondary motion: about 1.25 cloud texels
Clouds.MORPH_DENSITY = 0.075 -- restrained growth/erosion around the banks
Clouds.EXTENT = 10240       -- the sheet's side: a kilometre, fogged out
Clouds.CELLS = 40           -- ...tessellated this many cells a side
-- Same 40x40 mesh and near-field spacing. Only distant rings spread outward
-- to less than 0.3 degrees above the horizon; no additional cloud layer.
Clouds.HORIZON_EXTENT = 262144
function Clouds.deckCoordinate(index)
  local p=(index/Clouds.CELLS-0.5)*Clouds.EXTENT
  local core=Clouds.EXTENT/4
  if math.abs(p)<=core then return p end
  local u=(math.abs(p)-core)/core
  return (p<0 and -1 or 1)*(core+u*u*u*(Clouds.HORIZON_EXTENT/2-core))
end
Clouds.COVERAGE = 0.30      -- the share of the noise's range that is cloud
Clouds.SOFTNESS = 0.28      -- how far into that the cover turns solid
Clouds.STEPS = 4            -- alpha levels from clear to solid
Clouds.SEED = 1337
Clouds.EVOLVE_SEED_A = 7331
Clouds.EVOLVE_SEED_B = 9317

-- The scene shader discards a texel under alpha 0.5 (a sprite's key colour
-- must not write depth); the deck's draw lowers that cut to this so its
-- faint texels are drawn and BLENDED, and a cloud's edge is pixels of
-- varying transparency rather than a solid rim (Voxel3D.skyDeck).
Clouds.ALPHA_CUT = 0.05

-- the underside, which is all that is ever seen of a deck overhead
Clouds.COLOR = { 0.80, 0.85, 0.93 }

-- q90 weather coupling. The World publishes already-eased scalar channels;
-- this second, deliberately slow response makes the deck gather before rain
-- feels heavy and relax after it passes instead of snapping between presets.
-- These are upper bounds, not a second cloud renderer: q89's exact texture,
-- morph speed, opacity steps, altitude, and draw path remain untouched.
Clouds.WEATHER_COVERAGE = 0.86
-- Separate the visible sky coverage of mostly cloudy, light rain and heavy
-- rain without changing the deck's texture, geometry or particle budget.
-- Storm remains darker through its independent color/overcast treatment.
Clouds.RAIN_TARGETS = { RAIN_LIGHT = 0.75, RAIN_HEAVY = 1.0, HEAVY_RAIN = 1.0 }
Clouds.WEATHER_COLOR = { 0.46, 0.51, 0.61 }
Clouds.WEATHER_FADE_IN = 5.0
Clouds.WEATHER_FADE_OUT = 9.0

-- the dissolve: fog density and start (world px) for the deck's own draw.
-- Clear to a hundred metres out, a fifth left at three hundred, and gone
-- (under four percent) by the sheet's own edge, so that edge never shows.
Clouds.FOG_DENSITY = 0.000035
Clouds.FOG_START = 4000

-- a texel's alpha at a level: even fractions from clear to solid, a
-- quarter at a time -- the faintest survives the deck's own alpha cut
-- (Clouds.ALPHA_CUT), so it is drawn and blended rather than dropped
local function stepAlpha(level, steps)
  if level <= 0 then return 0 end
  return level / steps
end
Clouds.alphaOf = stepAlpha

-- ------- tileable value noise (the reference's, in Lua)

local function smooth(t) return t * t * (3 - 2 * t) end

local function lattice(nx, ny, rng)
  local a = {}
  for i = 1, nx * ny do a[i] = rng:random() end
  return a
end

-- LOVE's seeded generator where it exists; a seeded LCG (Park-Miller) of
-- the same shape where it does not -- the test harness's sandbox stopped
-- handing love.math over, and the crash took the suite's tail with it.
-- The field stays deterministic either way; a real build, whose love.math
-- is whole, never takes the fallback.
local function newRng(seed)
  local lm = love and love.math
  if lm and lm.newRandomGenerator then
    return lm.newRandomGenerator(seed)
  end
  local s = (tonumber(seed) or 0) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return { random = function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end }
end

-- x, y in [0, 1) walk the whole lattice exactly once, so the field wraps
-- on both axes. Mildly non-square, domain-warped lattices create irregular
-- banks rather than the old strongly stretched, parallel rows.
local function sample(a, nx, ny, x, y)
  local fx, fy = x * nx, y * ny
  local x0, y0 = math.floor(fx), math.floor(fy)
  local tx, ty = smooth(fx - x0), smooth(fy - y0)
  x0, y0 = x0 % nx, y0 % ny
  local x1, y1 = (x0 + 1) % nx, (y0 + 1) % ny
  local a00, a10 = a[y0 * nx + x0 + 1], a[y0 * nx + x1 + 1]
  local a01, a11 = a[y1 * nx + x0 + 1], a[y1 * nx + x1 + 1]
  return (a00 * (1 - tx) + a10 * tx) * (1 - ty) + (a01 * (1 - tx) + a11 * tx) * ty
end

-- One normalised fBm field, TEX x TEX. The octave list is explicit so the
-- authored cloud body can retain its fine detail while the two evolution
-- fields use broader features that grow and erode coherent banks.
local function buildField(seed, octaves)
  local n = Clouds.TEX
  local rng = newRng(seed)
  -- Bake a seamless, irregular domain into the field instead of placing all
  -- banks along the same lattice rows. No extra per-frame texture samples.
  local bendX = lattice(3, 4, rng)
  local bendY = lattice(4, 3, rng)
  local total = 0
  for _, o in ipairs(octaves) do
    o.a = lattice(o.nx, o.ny, rng)
    total = total + o.w
  end
  local field, lo, hi = {}, 1, 0
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local v = 0
      local u, t = x / n, y / n
      local sx = u + (sample(bendX, 3, 4, u, t) - 0.5) * 0.14
      local sy = t + (sample(bendY, 4, 3, u, t) - 0.5) * 0.14
      for _, o in ipairs(octaves) do
        v = v + o.w * sample(o.a, o.nx, o.ny, sx, sy)
      end
      v = v / total
      field[y * n + x + 1] = v
      if v < lo then lo = v end
      if v > hi then hi = v end
    end
  end
  local span = (hi - lo)
  if span <= 0 then span = 1 end
  for i = 1, #field do field[i] = (field[i] - lo) / span end
  return field
end

-- the authored body, including its fine texel-scale variation
local function bodyField(seed, scale)
  local octaves = {
    { nx = 12, ny = 15, w = 1.0 }, { nx = 25, ny = 29, w = 0.5 },
    { nx = 49, ny = 57, w = 0.25 }, { nx = 97, ny = 113, w = 0.12 },
    -- ...and one at the texel itself, so no two neighbouring pixels of a
    -- bank read quite the same density
    { nx = 256, ny = 512, w = 0.1 },
  }
  for i=1,#octaves-1 do
    octaves[i].nx=math.max(2,math.floor(octaves[i].nx*scale+.5))
    octaves[i].ny=math.max(2,math.floor(octaves[i].ny*scale+.5))
  end
  return buildField(seed,octaves)
end

-- Four independently seeded bank patterns, blended once at texture creation.
-- Periodic smooth weights hide joins; mixed spatial scales avoid repeated
-- equal-sized islands. The live renderer still samples one packed texture.
Clouds.VARIANTS = 4
function Clouds.field(seed)
  seed = seed or Clouds.SEED
  local fields = {}
  local scales={.65,1.0,1.35,.85}
  for i=1,Clouds.VARIANTS do fields[i]=bodyField(seed+(i-1)*104729,scales[i]) end
  local n, result, lo, hi = Clouds.TEX, {}, math.huge, -math.huge
  for y=0,n-1 do for x=0,n-1 do
    local u,v=x/n,y/n
    local a=.5+.5*math.sin(2*math.pi*u+.7*math.sin(2*math.pi*v))
    local b=.5+.5*math.sin(2*math.pi*v+.6*math.sin(2*math.pi*u))
    local i=y*n+x+1
    local value=(fields[1][i]*(1-a)+fields[2][i]*a)*(1-b)
      +(fields[3][i]*(1-a)+fields[4][i]*a)*b
    result[i]=value;lo=math.min(lo,value);hi=math.max(hi,value)
  end end
  local span=math.max(.0001,hi-lo)
  for i=1,#result do result[i]=(result[i]-lo)/span end
  return result
end

-- Broad, independent fields. They never replace the authored body; the shader
-- adds a small signed amount from each, so only densities near a cloud edge
-- cross the coverage threshold while clear sky and dense cores remain stable.
function Clouds.evolutionField(seed)
  return buildField(seed, {
    { nx = 12, ny = 15, w = 1.0 },
    { nx = 25, ny = 29, w = 0.55 },
    { nx = 49, ny = 57, w = 0.25 },
  })
end

-- The texture's alpha, texel by texel, from the texel's own density: the
-- noise below the coverage cut is clear sky, and above it the cover
-- thickens with the noise -- linearly, over SOFTNESS of the noise's range
-- -- to solid at the hearts of the thickest banks. This legacy level table
-- still validates coverage and the procedural field; the live cloud shader
-- eases between the corresponding opacity levels so evolving density changes
-- fade without making the entire cloud uniformly soft. Returns TEX x TEX
-- levels, 0..STEPS.
function Clouds.levels(field)
  local n = Clouds.TEX
  local cut = 1 - Clouds.COVERAGE      -- where cloud begins
  local band = Clouds.SOFTNESS         -- ...and how far above it is solid
  if band < 0.001 then band = 0.001 end
  local steps = Clouds.STEPS
  local out = {}
  for i = 1, n * n do
    local dens = (field[i] - cut) / band
    if dens < 0 then dens = 0 elseif dens > 1 then dens = 1 end
    out[i] = math.floor(dens * steps + 0.5)
  end
  return out
end

-- ------- the texture and the mesh, memoised

local image = nil          -- love Image, false once refused
local mesh = nil

-- One packed texture and still one texture fetch in the scene shader:
-- red is the authored density, green/blue are the two broad evolution fields,
-- and alpha is unused. The cloud-only shader reconstructs the unchanged
-- colour and four opacity steps after evolving density around the threshold.
-- Wrapping and nearest sampling remain exactly as before.
function Clouds.image()
  if image ~= nil then return image or nil end
  image = false
  pcall(function()
    local n = Clouds.TEX
    local base = Clouds.field(Clouds.SEED)
    local evolveA = Clouds.evolutionField(Clouds.EVOLVE_SEED_A)
    local evolveB = Clouds.evolutionField(Clouds.EVOLVE_SEED_B)
    local levels = Clouds.levels(base)
    local data = love.image.newImageData(n, n)
    for y = 0, n - 1 do
      for x = 0, n - 1 do
        local i = y * n + x + 1
        data:setPixel(x, y, base[i], evolveA[i], evolveB[i],
          stepAlpha(levels[i], Clouds.STEPS))
      end
    end
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    img:setWrap("repeat", "repeat")
    image = img
  end)
  return image or nil
end

-- The sheet: EXTENT square, CELLS cells a side, lying flat, its texture
-- coordinates in TILE units of its own position -- so a sheet placed at a
-- whole-tile multiple wears the pattern in world alignment, and one placed
-- a fraction further along wears it drifted by that fraction.
local function buildMesh()
  local ext, cells = Clouds.EXTENT, Clouds.CELLS
  local step = ext / cells
  local verts, tris = {}, {}
  for j = 0, cells do
    for i = 0, cells do
      local x = Clouds.deckCoordinate(i)
      local z = Clouds.deckCoordinate(j)
      verts[#verts + 1] = { x, 0, z, x / Clouds.TILE, z / Clouds.TILE, 1 }
    end
  end
  -- LOVE's vertex map is 1-BASED (Voxel3D.pushQuad writes b+1..b+4): a
  -- 0-based list here drew the sheet as one skewed dark polygon
  local w = cells + 1
  for j = 0, cells - 1 do
    for i = 0, cells - 1 do
      local a = j * w + i + 1
      local b, c, d = a + 1, a + w, a + w + 1
      tris[#tris + 1] = a; tris[#tris + 1] = c; tris[#tris + 1] = b
      tris[#tris + 1] = b; tris[#tris + 1] = c; tris[#tris + 1] = d
    end
  end
  return Voxel3D.newMesh(verts, tris)
end

function Clouds.mesh()
  if mesh ~= nil then return mesh or nil end
  local ok, m = pcall(buildMesh)
  mesh = (ok and m) or false
  return mesh or nil
end

-- ------- the drift and the breath
--
-- One game-frame clock feeds both eyes. Reading love.timer independently
-- from each eye would put them a few milliseconds apart; tiny at this speed,
-- but a world-space deck has no reason to accept even that stereo mismatch.
local animationTime = 0
local weatherProvider = nil
local weatherVisuals = {
  rain = 0, snow = 0, dim = 0, gust = 0, ash = 0,
  intensity = 0,
  snowMix = 0, stormMix = 0,
  opacity = 1,
  coverage = Clouds.COVERAGE,
  color = { Clouds.COLOR[1], Clouds.COLOR[2], Clouds.COLOR[3] },
  provider = false,
}

-- 215,040 seconds is an exact multiple of both the 2048-second tile drift and
-- the 210-second morph period. Wrapping there keeps long sessions numerically
-- small without introducing a jump in either animation.
Clouds.TIME_WRAP = 215040

local function clamp01(value)
  value = tonumber(value) or 0
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

local function mix(a, b, t) return a + (b - a) * t end

-- Provider contract: rain, snow, dim, gust, ash. It is called only from the
-- once-per-frame update, never once per eye, and a missing/failed weather mod
-- naturally fades back to q89's clear-sky deck.
function Clouds.setWeatherProvider(provider)
  weatherProvider = type(provider) == "function" and provider or nil
  weatherVisuals.provider = weatherProvider ~= nil
  return weatherVisuals.provider
end

local function sampleWeather()
  if not weatherProvider then return 0, 0, 0, 0, 0 end
  local ok, rain, snow, dim, gust, ash, id, recovery = pcall(weatherProvider)
  if not ok then return 0, 0, 0, 0, 0 end
  return tonumber(rain) or 0, tonumber(snow) or 0, tonumber(dim) or 0,
         tonumber(gust) or 0, tonumber(ash) or 0, id, tonumber(recovery)
end

local function updateWeather(dt)
  local rain, snow, dim, gust, ash, id, recovery = sampleWeather()
  weatherVisuals.rain, weatherVisuals.snow = rain, snow
  weatherVisuals.dim, weatherVisuals.gust, weatherVisuals.ash = dim, gust, ash

  -- Normalize against the strongest retained q90 definitions. Rain is the
  -- primary cloud maker; snow/ash and dimness can still close the sky, while
  -- wind alone only contributes through its weather's small dim channel.
  local target = math.max(clamp01(rain / 1.30), clamp01(dim / 0.34),
                          clamp01(snow / 1.08) * 0.55,
                          clamp01(ash / 0.95) * 0.45)
  local regional=Clouds.stormFrontProvider and Clouds.stormFrontProvider()~=nil
  if regional then target=0 end -- the spatial shader owns this storm, not global coverage
  if id=='PARTLY_CLOUDY' or id=='PARTLY_SNOW' then target=.30 end
  if id=='MOSTLY_CLOUDY' then target=.45 end
  local rainTarget=Clouds.RAIN_TARGETS[id]
  if rainTarget and not regional then target=math.max(target,rainTarget) end
  local current = weatherVisuals.intensity
  local seconds = target > current and Clouds.WEATHER_FADE_IN
                                      or Clouds.WEATHER_FADE_OUT
  local amount = 1 - math.exp(-math.max(0, dt) / math.max(0.001, seconds))
  current = mix(current, target, amount)
  if math.abs(current - target) < 0.0001 then current = target end
  weatherVisuals.intensity = current
  weatherVisuals.coverage = mix(Clouds.COVERAGE,
                                Clouds.WEATHER_COVERAGE, current)
  for i = 1, 3 do
    weatherVisuals.color[i] = mix(Clouds.COLOR[i], Clouds.WEATHER_COLOR[i], current)
  end
  -- Independent eased targets: snow is overcast silver-grey, storms charcoal.
  local snowTarget = (type(id)=='string' and id~='PARTLY_SNOW' and id:find('SNOW',1,true)) and 1 or 0
  local stormTarget = id=='STORM' and 1 or 0
  -- The post-storm signal lasts for about a minute. Keep a hint of lingering
  -- cloud on Clear, without holding its deck near storm coverage throughout.
  if recovery then
    local recoveryWeight = (id=='CLEAR' or id=='SUNNY') and 0.15 or 1
    stormTarget=math.max(stormTarget,clamp01(recovery)*recoveryWeight)
  end
  if regional then stormTarget=0 end
  local response=1-math.exp(-math.max(0,dt)/9)
  weatherVisuals.snowMix=mix(weatherVisuals.snowMix,snowTarget,response)
  weatherVisuals.stormMix=mix(weatherVisuals.stormMix,stormTarget,response)
  weatherVisuals.opacity=1
  weatherVisuals.coverage=mix(weatherVisuals.coverage,.90,weatherVisuals.snowMix)
  weatherVisuals.coverage=mix(weatherVisuals.coverage,.94,weatherVisuals.stormMix)
  local snowColor,stormColor={.65,.69,.76},{.28,.32,.40}
  for i=1,3 do
    weatherVisuals.color[i]=mix(weatherVisuals.color[i],snowColor[i],weatherVisuals.snowMix)
    weatherVisuals.color[i]=mix(weatherVisuals.color[i],stormColor[i],weatherVisuals.stormMix)
  end
end

function Clouds.update(dt)
  -- Once per frame, shared by both eyes. Failed clocks retain neutral lighting.
  local ok,t=pcall(function()return V.require('DayNight').time()end)
  CloudLight.sample(ok and t or 300,cloudLight)
  dt = tonumber(dt) or 0
  if dt > 0 then
    animationTime = (animationTime + dt) % Clouds.TIME_WRAP
    updateWeather(dt)
  end
end

function Clouds.weatherVisuals()
  return weatherVisuals
end

function Clouds.animationTime()
  return animationTime
end

-- how far the sheet has drifted along +X, in world px, wrapped to a tile
function Clouds.driftPx()
  return (animationTime * Clouds.DRIFT) % Clouds.TILE
end

-- ...and the same as a fraction of a tile, for a shader's texture offset
function Clouds.offset()
  return Clouds.driftPx() / Clouds.TILE
end

-- The vertex warp supplies subtle local travel. Two phase-shifted density
-- weights supply the visible part: coherent banks grow and erode instead of
-- merely translating. Both weights are zero at launch, so the cycle begins on the
-- exact q82 cloud shape, and both are periodic for a seamless loop.
function Clouds.morph()
  local phase = (animationTime % Clouds.MORPH_PERIOD)
                / Clouds.MORPH_PERIOD * math.pi * 2
  return phase, Clouds.MORPH_WARP,
         math.sin(phase), math.sin(phase * 2)
end

-- ------- where the deck shows overhead
--
-- Standing in the world only (see the header): the free-roam rungs when
-- the headset is not presenting them as a tabletop, and a staged fight's
-- shot for the same condition.
function Clouds.overhead()
  local dio = false
  pcall(function() dio = V.require("VR").dioramaMode() end)
  if dio then return false end
  -- ...and never over the ROOM: 1ST PERSON AR replaces the outdoor sky
  -- with the headset's passthrough, and a deck of cloud floating under a
  -- real ceiling is not the sky it stands in for
  local room = false
  pcall(function() room = V.require("VoxelScene").passthroughSky ~= nil end)
  if room then return false end
  local fp = false
  pcall(function() fp = V.require("FirstPerson").engaged() end)
  if fp then return true end
  local fight = false
  pcall(function()
    fight = V.require("OverworldBattle").stageShot() ~= nil
  end)
  return fight
end

-- Draw the deck from inside a scene pass, for an eye at `eye` (world px).
-- The sheet is snapped to the eye in whole tiles and slid by the drift, so
-- the pattern under any point of the world is the same from every eye and
-- every frame -- the two eyes see one deck.
function Clouds.draw(eye)
  local img, m = Clouds.image(), Clouds.mesh()
  if not (img and m and eye) then return false end
  local tile = Clouds.TILE
  local off = Clouds.driftPx()
  local sx,sz = cloudSpace:placement(eye,tile,off)
  local model = Mat4.translate(sx, Clouds.ALT, sz)
  -- no sun on it, the hour's tint kept, and its own fog toward the hour's
  -- haze -- the colour the sky meets the horizon in, so the deck's far end
  -- is the horizon's own colour where it reaches it
  local haze = nil
  pcall(function() haze = V.require("Sky").haze() end)
  Voxel3D.glass(false)
  Voxel3D.seams(false)
  local phase, warp, shapeA, shapeB = Clouds.morph()
  local weather = weatherVisuals
  Voxel3D.skyDeck(true, Clouds.FOG_DENSITY, Clouds.FOG_START, haze,
                  Clouds.ALPHA_CUT, {
                    phase = phase,
                    warp = warp,
                    shapeA = shapeA,
                    shapeB = shapeB,
                    density = Clouds.MORPH_DENSITY,
                    coverage = weather.coverage,
                    softness = Clouds.SOFTNESS,
                    steps = Clouds.STEPS,
                    color = weather.color,
                    light = cloudLight,
                    opacity = weather.opacity,
                    overcast = weather.stormMix,
                    lightning = Clouds.lightningProvider and Clouds.lightningProvider(),
                    stormFront = Clouds.stormFrontProvider and Clouds.stormFrontProvider(),
                  })
  Voxel3D.draw(m, img, model)
  Voxel3D.skyDeck(false)
  Voxel3D.seams(true)
  Voxel3D.glass(true)
  return true
end

-- a lost GL context, a hot reload
function Clouds.invalidate()
  image, mesh = nil, nil
end

return Clouds
