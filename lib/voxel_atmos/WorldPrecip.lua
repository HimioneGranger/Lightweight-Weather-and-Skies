-- ============================================================================
-- INDEPENDENT WORLD-SPACE WEATHER PARTICLES
-- ============================================================================
-- Architecture (absolute rules):
--   WORLD → WEATHER STATE / WIND → PARTICLE SIM → individual {x,y,z,vx,vy,vz,life}
--   Camera only *views* particles (billboard). Camera never parents or orients the sim.
--   Player position only *streams* the active volume; particles do not inherit player motion.
--   Each rain/snow/grain particle has its own position, velocity, lifetime, size, seed.
--   Respawn uses world coords around player focus — never "in front of camera".
--   Off-screen particles keep integrating until lifetime/range ends.
-- ============================================================================
--
-- WHY THIS FILE WAS REWRITTEN (4.28.69) — read before "simplifying" anything.
--
-- 1. THIS MODULE DID NOT LOAD AT ALL UNDER LUAJIT.
--    The old `hash()` helper used `~`, `>>` and `&`. Those are Lua 5.3
--    operators. LuaJIT is 5.1 and has no bitwise operators at all — it has the
--    `bit` library instead. So the file was a *compile* error, `V.require
--    ("WorldPrecip")` threw, `WorldPrecip` stayed nil forever, and
--    CinematicAtmos silently took its `else` branch: `drawRain` and, since
--    4.28.68 disabled `drawSnow3D`, no 3D snow of any kind. Every "the snow is
--    a flat overlay" report traces to this one line. `hash()` was never called
--    by anything, so nothing else hinted at it. It is gone; the float-only
--    `fhash()` below replaces it and is Lua 5.1-safe.
--
-- 2. FOUR FUNCTIONS WERE CALLED BUT NEVER DEFINED.
--    `far()`, `addGroundSnow()`, `spawnGrainAt()` were plain nil globals, and
--    `getGrainShader` was called ~16 lines above its `local function`
--    declaration (so it resolved as a nil global too). `WP.update` and
--    `WP.draw` share one `pcall` in CinematicAtmos, so each of these aborted
--    the whole frame's precipitation with no log line. Even on a Lua 5.4 host
--    where the file compiles, rain died on its first particle. All four are
--    defined now, and every helper is declared before its first use.
--
-- 3. `ensureGSnow()` existed and was never called, so `gsnow.n` stayed 0,
--    `gsnow.active` was never assigned, and ground accumulation could not draw.
--
-- 4. THE DRAW PATH ALLOCATED ~25,000 LUA TABLES PER FRAME.
--    `verts[#verts+1] = { ... }` per vertex, plus a fresh `push` closure per
--    particle. At the snow cap that is 4200 x 6 tables + 4200 closures every
--    frame — the GC, not the GPU, was the ceiling. Vertices now go into a
--    persistent preallocated buffer that is mutated in place and uploaded as a
--    prefix (`setVertices(buf, 1, n)` + `setDrawRange`). Steady-state
--    allocation in the draw path is zero.
--
-- 5. SNOW SPENT ITS BUDGET WHERE IT COULD NOT BE SEEN.
--    720-unit radius against rain's known-good 220. Area goes as r^2, so ~90%
--    of flakes lived past the distance where a sub-unit billboard covers less
--    than a pixel — paying full sim + vertex cost to render nothing, while the
--    space you actually walk through was empty. Snow now uses a 300-unit volume
--    with radial sampling biased hard toward the focus, so the budget lands
--    within arm's reach and out to the fog line. See SNOW_RADIAL_BIAS.
--
-- 6. FLAKES EVAPORATED IN MID-AIR. `maxLife` was a flat 3.5-10.5s while the
--    spawn ceiling was up to 300 units at ~8 units/s of fall. Most flakes
--    expired well above head height and were recycled — which is precisely the
--    "screensaver" read: snow that never arrives anywhere. Lifetime is now
--    *derived* from the fall: time-to-ground plus a margin. Flakes land.
--
-- 7. `snow.rot` / `snow.spin` were simulated every frame and then never used by
--    the renderer. Every flake drew as the same axis-aligned soft blob. The
--    billboard basis is rotated now, so flakes tumble.
--
-- The original spawn distribution, particle cap, and streak geometry remain.
-- All renderers apply the weather profile's rainSpeed to vertical travel
-- after the user reported slow rainfall.
-- The cloud bank lives in CinematicAtmos.drawClouds and
-- is not touched here; snow's spawn ceiling only *reads* a deck height so
-- flakes fall out of the bank instead of out of a fixed slab.
-- ============================================================================

local V = ...

local floor, sqrt, abs, min, max = math.floor, math.sqrt, math.abs, math.min, math.max
local sin, cos, random = math.sin, math.cos, math.random
local PI2 = math.pi * 2

local WP = {}
local DesktopWeatherProfile = V.require('DesktopWeatherProfile')

-- ---------------------------------------------------------------------------
-- TUNABLES
-- ---------------------------------------------------------------------------
-- Rain values are the shipped ones and are not to be retuned here.
local RAIN_MAX = 900
local STREAM_RADIUS = 220
local STREAM_R2 = STREAM_RADIUS * STREAM_RADIUS
local GRAIN_MAX = 600

-- Snow. Every one of these is reachable from WP.tune() because none of them
-- can be verified without a human looking at the screen.
--
-- ONE TILE IS 16 WORLD UNITS. CinematicAtmos's puddle and snow-pack scans both
-- index map cells as `cx * 16 + 8`, so that is the conversion for anything
-- expressed in tiles below.
local TILE = 16

-- Hard ceiling on live flakes. This is a budget, not a target: the actual count
-- is derived from the rendered area (see SNOW_PER_TILE) and clamped here.
local SNOW_MAX = 9000

-- Standalone Quest contract: these are hard ceilings, not merely quality
-- suggestions. The 2D particle budgets and the true 3D pools now agree.
if V.questLitePrivate then
  RAIN_MAX = 90
  SNOW_MAX = 240
  GRAIN_MAX = 60
end

-- FLAKES PER TILE OF RENDERED GROUND, at full intensity.
--
-- This is the number that makes snow cover the world instead of following the
-- player. Deriving the count from area means a wider render distance gets
-- proportionally more flakes rather than stretching the same handful thinner --
-- "if the game is rendering more than normal, it should be snowing everywhere
-- there are rendered tiles". It is also how the rest of CinematicAtmos already
-- works: eachWeatherCell holds density per WORLD CELL constant and lets a
-- landscape viewport cover more cells.
-- 8.0 measured: at the default 300-unit radius that is ~8800 live flakes, just
-- inside SNOW_MAX. Raising it from 3.8 was not cosmetic -- at 3.8 a flake
-- reached the eye roughly once every several minutes, because spreading flakes
-- evenly over the whole rendered disk (correctly) puts far fewer of them within
-- arm's reach than the old near-biased spawn did. Density is the honest dial
-- for that, not a distribution that empties the map.
local SNOW_PER_TILE = 22.0

-- Radius of the simulated disk. Follows the camera far plane when the host
-- publishes one (same source NightSky and CelestialBodies use), so the snow
-- volume tracks whatever the host is actually rendering.
local SNOW_STREAM_RADIUS = 600
local SNOW_RADIUS_MIN = 320
local SNOW_RADIUS_MAX = 750
local SNOW_FAR_FRACTION = 0.95   -- of the far plane

-- RADIAL SAMPLING EXPONENT.  rad = R * u^BIAS.
--
-- 0.5 is uniform density per unit AREA, which is what real snowfall is and what
-- "snowing all over the rendered world" means. Anything above 0.5 concentrates
-- flakes toward the focus.
--
-- 4.28.69 shipped 4.0 here, chasing near-field density for first person. That
-- was a mistake and it is worth writing down why, because the reasoning looked
-- sound: at 4.0 roughly 38% of live flakes sit within 25 units of you, which
-- reads on screen as a snow globe travelling with the player over an otherwise
-- clear world. Density near the camera is not something the spawn distribution
-- should manufacture -- perspective already delivers it, because near flakes
-- subtend far more screen area than far ones. Distribute uniformly and let the
-- projection do its job; if the near field still looks thin, the fix is more
-- flakes per tile, not a bias that empties the rest of the map.
local SNOW_RADIAL_BIAS = 0.5
local SNOW_MIN_R = 0.6      -- flakes may spawn essentially on top of the focus

-- Culling distance for the vertex build. The sim keeps running past this
-- (architecture rule: off-screen particles keep integrating); we only stop
-- emitting geometry for flakes that cannot cover a pixel.
local SNOW_DRAW_RADIUS = 750

-- Height of the falling column above the focus. ONE deck for the whole field,
-- not a per-flake value that scaled with spawn radius.
--
-- The old version gave near flakes a low ceiling and far flakes a tall one. That
-- silently skewed the standing population: a flake with a short column recycles
-- in a couple of seconds while one with a tall column lives ten times as long,
-- so even a uniform spawn ended up with far more live flakes far away. A single
-- deck height makes standing density match spawn density, which is the only way
-- uniform coverage actually stays uniform.
local SNOW_CEIL = 96
local SNOW_CEIL_SPAN = 64
local SNOW_LIFE_MARGIN = 1.15   -- x time-to-ground, so flakes land, not vanish
local SNOW_LIFE_CAP = 60

-- Face contact. A flake that passes within FACE_R of the eye is consumed and
-- leaves a melting speck. This is a *consequence of the simulation* — the
-- speck exists only because a real simulated flake really intersected the eye
-- sphere — not a screen-space overlay bolted on top. It is drawn as world
-- geometry in the same depth-tested pass as everything else.
-- A tile is 16 units, so a head is about 6 units across. 1.5 was a guess that
-- made contact vanishingly rare once the field became uniform; 3.0 is the
-- actual scale of the thing being hit. Measured at the default density this is
-- one flake on the face roughly every 10 seconds -- present, not constant.
local FACE_R = 3.0
local FACE_R2 = FACE_R * FACE_R
local FACE_MAX = 20
local FACE_LIFE = 1.35
local FACE_DIST = 0.55      -- how far off the eye the speck sits

-- Ground plane, measured down from the focus.
--
-- Was 1.5, which left flakes settling a tile above where the world's floor
-- reads. GROUND_EXTRA_TILES is the correction and is expressed in tiles rather
-- than raw units so it stays meaningful if the focus origin ever moves; raise
-- it to 2 if snow still stops short, drop it to 0 to restore the old plane.
local GROUND_EXTRA_TILES = 1
local GROUND_DROP = 1.5 + GROUND_EXTRA_TILES * TILE

-- ---------------------------------------------------------------------------
-- POOLS  (struct-of-arrays; index-parallel, never re-sorted)
-- ---------------------------------------------------------------------------
local rain = { n = 0, active=0, x={},y={},z={}, vx={},vy={},vz={}, life={}, maxLife={}, size={}, a={}, id={}, seed={} }
local snow = { n = 0, active=0, x={},y={},z={}, vx={},vy={},vz={}, life={}, maxLife={}, size={}, a={}, ph={}, id={}, seed={}, rot={}, spin={}, y0={}, pathH={}, br={} }
-- kind: 1=hail, 2=sand, 3=debris/leaves, 4=ash, 5=black ash
local grain = { n = 0, active=0, x={},y={},z={}, vx={},vy={},vz={}, life={}, maxLife={}, size={}, a={}, kind={}, spin={}, id={}, seed={} }
local nextId = 1
local function allocId()
  local id = nextId
  nextId = nextId + 1
  if nextId > 1e9 then nextId = 1 end
  return id
end

-- Ground snow patches (accumulate in snow, melt when not snowing).
local GSNOW_MAX = 280
local gsnow = { n = 0, active=0, x={}, z={}, y={}, amount={}, size={} }
local gsnowCursor = 0
local groundSnowTarget = 0  -- 0..1 desired coverage from weather

-- Ground wet marks: appear where a drop lands, dry after WET_LIFE seconds.
local WET_LIFE = 1.0
local WET_MAX = 700
local wet = { n = 0, active = 0, x={}, z={}, y={}, age={}, size={}, a={} }
local wetCursor = 0

-- Melting specks on the eye, seeded only by real flake/eye intersections.
local face = { n = 0, active = 0, dx={}, dy={}, dz={}, age={}, size={}, seed={} }
local faceCursor = 0
local faceHitTotal = 0

-- Fate counters. A flake that expires in mid air never arrived anywhere, and a
-- field where most flakes do that is the thing that reads as a screensaver.
-- These are on the debug line so the ratio is checkable at a glance, and the
-- test suite asserts on them -- ground-snow coverage cannot stand in for this,
-- because ambient scatter seeds drifts whether or not a single flake lands.
local snowLanded = 0
local snowExpiredAir = 0

-- Deepest a flake has actually descended below the focus, in world units.
-- Exists because GROUND_DROP is a constant, and a constant is exactly the kind
-- of thing a test can assert on without proving the simulation honours it --
-- removing a whole tile of fall depth changed no test result at all until this
-- was added. What matters is where flakes REACH, not what the constant says.
local snowDeepest = 0

local rainMesh, snowMesh, wetMesh, grainMesh, gsnowMesh, faceMesh
local rainShader, snowShader, grainShader
local simTime = 0
local lastEye = nil          -- filled by draw(); update() uses it for face hits
local lastFar = nil          -- filled by draw(); the host's camera far plane
local drawnSnowVerts = 0
local drawnRainVerts = 0

-- ---------------------------------------------------------------------------
-- MATH HELPERS
-- ---------------------------------------------------------------------------

-- Float-only hash. Replaces the 5.3-bitwise version that would not compile
-- under LuaJIT. Deterministic per (i, salt), 0..1, no integer ops.
local function fhash(i, salt)
  local n = (i * 0.6180339887 + salt * 0.7548776662) * 43758.5453
  return n - floor(n)
end

-- Sine lookup. Snow turbulence is 3 trig calls per flake per frame; at the cap
-- that is ~12,600 libm calls a frame for a wobble nobody can measure to the
-- fourth decimal. A 1024-entry table is visually identical and much cheaper.
local SIN_N = 1024
local SIN_TAB = {}
for i = 0, SIN_N - 1 do SIN_TAB[i] = sin(i * PI2 / SIN_N) end
local SIN_SCALE = SIN_N / PI2
local COS_OFF = floor(SIN_N * 0.25)
local function fsin(a)
  return SIN_TAB[floor(a * SIN_SCALE) % SIN_N]
end
local function fcos(a)
  return SIN_TAB[(floor(a * SIN_SCALE) + COS_OFF) % SIN_N]
end

-- Was called on every rain and grain particle every frame and never existed.
-- Squared compare; no sqrt.
local function far(x, z, px, pz)
  local dx, dz = x - px, z - pz
  return (dx * dx + dz * dz) > STREAM_R2
end

-- ---------------------------------------------------------------------------
-- POOL GROWTH
-- ---------------------------------------------------------------------------
local function ensureRain(n)
  while rain.n < n do
    local i = rain.n + 1
    rain.x[i], rain.y[i], rain.z[i] = 0, 0, 0
    rain.vx[i], rain.vy[i], rain.vz[i] = 0, -1, 0
    rain.life[i], rain.maxLife[i] = 0, 1
    rain.size[i], rain.a[i] = 1, 1
    rain.id[i], rain.seed[i] = 0, 0
    rain.n = i
  end
end

local function ensureSnow(n)
  while snow.n < n do
    local i = snow.n + 1
    snow.x[i], snow.y[i], snow.z[i] = 0, 0, 0
    snow.vx[i], snow.vy[i], snow.vz[i] = 0, -1, 0
    snow.life[i], snow.maxLife[i] = 0, 1
    snow.size[i], snow.a[i], snow.ph[i] = 1, 1, 0
    snow.id[i], snow.seed[i] = 0, 0
    snow.rot[i], snow.spin[i] = 0, 0
    snow.y0[i], snow.pathH[i] = 0, 100
    snow.br[i] = 1
    snow.n = i
  end
end

local function ensureGrain(n)
  while grain.n < n do
    local i = grain.n + 1
    grain.x[i], grain.y[i], grain.z[i] = 0, 0, 0
    grain.vx[i], grain.vy[i], grain.vz[i] = 0, -1, 0
    grain.life[i], grain.maxLife[i] = 0, 1
    grain.size[i], grain.a[i] = 1, 1
    grain.kind[i], grain.spin[i] = 2, 0
    grain.id[i], grain.seed[i] = 0, 0
    grain.n = i
  end
end

local function ensureGSnow()
  while gsnow.n < GSNOW_MAX do
    local i = gsnow.n + 1
    gsnow.x[i], gsnow.z[i], gsnow.y[i] = 0, 0, 0
    gsnow.amount[i], gsnow.size[i] = 0, 1
    gsnow.n = i
  end
end

local function ensureWet()
  while wet.n < WET_MAX do
    local i = wet.n + 1
    wet.x[i], wet.z[i], wet.y[i] = 0, 0, 0
    wet.age[i], wet.size[i], wet.a[i] = 99, 1, 0
    wet.n = i
  end
end

local function ensureFace()
  while face.n < FACE_MAX do
    local i = face.n + 1
    face.dx[i], face.dy[i], face.dz[i] = 0, 1, 0
    face.age[i], face.size[i], face.seed[i] = 99, 1, 0
    face.n = i
  end
end

-- ---------------------------------------------------------------------------
-- DEPOSITS  (ring buffers — bounded, no allocation, no compaction)
-- ---------------------------------------------------------------------------
local function addWetMark(x, y, z, size)
  ensureWet()
  wetCursor = wetCursor % WET_MAX + 1
  local i = wetCursor
  wet.x[i], wet.z[i], wet.y[i] = x, z, y
  wet.age[i] = 0
  wet.size[i] = max(0.25, (size or 0.4) * (0.55 + random() * 0.5))
  wet.a[i] = 0.30 + random() * 0.35
  if wetCursor > wet.active then wet.active = wetCursor end
end

-- Was a nil global. Called wherever a flake reaches the ground plane.
local function addGroundSnow(x, y, z, size)
  -- 4.30.76: remove the 3D splash/disc layer. It reads as snow painted on
  -- terrain and is especially distracting over the native map tiles.
  return nil
end

local function addFaceHit(dx, dy, dz, size)
  ensureFace()
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-4 then return end
  faceCursor = faceCursor % FACE_MAX + 1
  local i = faceCursor
  face.dx[i], face.dy[i], face.dz[i] = dx / l, dy / l, dz / l
  face.age[i] = 0
  face.size[i] = max(0.05, (size or 0.5) * 0.16)
  face.seed[i] = random()
  faceHitTotal = faceHitTotal + 1
  if faceCursor > face.active then face.active = faceCursor end
end

-- ---------------------------------------------------------------------------
-- SPAWNERS
-- ---------------------------------------------------------------------------

-- RAIN — original spawn distribution and shape; fall speed is applied
-- during integration below, not baked into these per-drop velocities.
-- Spawn one particle in the volume around player (full 360 degrees, not view cone).
local function spawnRainAt(i, px, py, pz, intensity, windX, windZ)
  -- Independent world spawn — 20 spread depth layers around the player (360).
  local seed = random()
  local ang = random() * PI2
  local layer = min(19, floor(random() * 20))
  local layerT = layer / 19  -- 0 near -> 1 far
  local near = 1.0 - layerT
  local rad0 = STREAM_RADIUS * (0.04 + layerT * 0.90)
  local rad1 = STREAM_RADIUS * (0.14 + layerT * 0.86)
  local rad = rad0 + random() * max(3, rad1 - rad0)
  rain.x[i] = px + cos(ang) * rad
  rain.z[i] = pz + sin(ang) * rad
  local y0 = py + 18 + layerT * 95
  local ySpan = 45 + layerT * 120
  rain.y[i] = y0 + random() * ySpan
  local fall = -(48 + random() * 42) * (0.65 + near * 0.40) * (0.80 + intensity * 0.28)
  local wv = 0.65 + random() * 0.7
  rain.vx[i] = windX * (10 + random() * 14) * wv + (random() - 0.5) * 3.5
  rain.vy[i] = fall
  rain.vz[i] = windZ * (10 + random() * 14) * wv + (random() - 0.5) * 3.5
  rain.maxLife[i] = (0.9 + random() * 1.8) * (0.85 + layerT * 0.4)
  rain.life[i] = 0
  rain.size[i] = (0.55 + random() * 1.5) * (0.48 + near * 0.62)
  rain.a[i] = (0.24 + random() * 0.32) + near * 0.40
  rain.seed[i] = seed
  rain.id[i] = allocId()
end

-- SNOW — a world field, not a system that follows you.
--
-- Placement is world XZ around the streaming focus over a full 360-degree disk,
-- Y from the cloud deck down. The camera contributes nothing to placement or
-- orientation; it is a streaming anchor and, at draw time only, a billboard
-- target. Walking moves *you* through a field that was already there.
--
-- THE DISTRIBUTION IS UNIFORM PER UNIT AREA. rad = R * sqrt(u) gives constant
-- flakes-per-tile everywhere inside the disk, which is what makes it snow over
-- the whole rendered world rather than in a dense knot around the player. See
-- SNOW_RADIAL_BIAS for why the previous near-biased version was wrong.
--
-- Two supporting properties, both of which have to hold or uniform spawning
-- still produces a non-uniform field:
--
--   * ONE DECK HEIGHT for every flake. Column height sets lifetime, lifetime
--     sets how long a flake stays counted, so a per-radius column silently
--     reweights the standing population even when spawning is even.
--   * SIZE IS INDEPENDENT OF SPAWN RADIUS. A flake's physical size has nothing
--     to do with where it happened to appear. The old code multiplied size and
--     alpha by a `near` term at spawn AND applied a depth cue again at draw
--     time, attenuating distant flakes twice and helping hollow out the far
--     field. Perspective alone is the correct and sufficient depth cue.
local snowCeil = 0     -- extra ceiling contributed by the cloud deck, if known
local function spawnSnowAt(i, px, py, pz, intensity, windX, windZ)
  local seed = random()
  local ang = random() * PI2
  -- Uniform-by-area radial sampling (see SNOW_RADIAL_BIAS).
  local t = random() ^ SNOW_RADIAL_BIAS
  local rad = SNOW_MIN_R + t * (SNOW_STREAM_RADIUS - SNOW_MIN_R)
  snow.x[i] = px + cos(ang) * rad
  snow.z[i] = pz + sin(ang) * rad

  -- Fall FROM THE SKY: one deck over the whole field, lifted by the cloud bank
  -- when the host publishes a base height.
  snow.y[i] = py + SNOW_CEIL + snowCeil + random() * SNOW_CEIL_SPAN

  -- Soft snowfall. Real flakes settle around 1 m/s; rain here runs 48-90
  -- units/s for roughly 9 m/s, so a unit is about 6 cm and snow wants ~5-12.
  -- Intensity leans it faster (a blizzard drives flakes down, not just sideways).
  local fall = (5.0 + random() * 6.5) * (0.75 + min(2.2, intensity) * 0.30)
  local wv = 0.45 + random() * 1.20
  snow.vx[i] = windX * (4 + random() * 14) * wv + (random() - 0.5) * 2.2
  snow.vy[i] = -fall
  snow.vz[i] = windZ * (4 + random() * 14) * wv + (random() - 0.5) * 2.2

  -- Live long enough to land, plus margin for the wobble and for the wind
  -- carrying it out of range first. The old flat 3.5-10.5s expired most flakes
  -- in mid air, which is the single most "fake" thing a snow system can do.
  local drop = snow.y[i] - (py - GROUND_DROP)
  snow.maxLife[i] = min(SNOW_LIFE_CAP, (drop / max(1.5, fall)) * SNOW_LIFE_MARGIN + 0.5)
  snow.life[i] = 0

  snow.size[i] = 0.34 + random() * 0.62
  snow.a[i] = 0.40 + random() * 0.38
  snow.br[i] = 0.82 + random() * 0.18      -- per-flake brightness; breaks up the sheet
  snow.ph[i] = random() * PI2
  snow.rot[i] = random() * PI2
  snow.spin[i] = (random() - 0.5) * 2.4
  snow.seed[i] = seed
  snow.id[i] = allocId()
  snow.y0[i] = snow.y[i]
  snow.pathH[i] = drop
end

-- GRAIN — was a nil global; the sand/ash/debris path could never run.
-- kind: 1=hail, 2=sand, 3=debris/leaves, 4=ash, 5=black ash
local function spawnGrainAt(i, px, py, pz, kind, windX, windZ)
  local seed = random()
  local ang = random() * PI2
  local t = random() ^ 1.6
  local rad = 4 + t * (STREAM_RADIUS - 4)
  local near = 1.0 - t
  grain.x[i] = px + cos(ang) * rad
  grain.z[i] = pz + sin(ang) * rad
  grain.kind[i] = kind
  grain.seed[i] = seed
  grain.life[i] = 0
  grain.id[i] = allocId()
  grain.spin[i] = random()

  if kind == 2 then
    -- Sand/dust: driven almost horizontally, hugging the ground.
    grain.y[i] = py - 1 + random() * 26
    local drive = 26 + random() * 34
    grain.vx[i] = windX * drive + (random() - 0.5) * 10
    grain.vy[i] = -(1.0 + random() * 4.0)
    grain.vz[i] = windZ * drive + (random() - 0.5) * 10
    grain.maxLife[i] = 1.6 + random() * 2.4
    grain.size[i] = (0.28 + random() * 0.55) * (0.5 + near * 0.8)
    grain.a[i] = 0.20 + random() * 0.30 + near * 0.22
  elseif kind == 4 then
    -- Ashfall: slow, near-vertical, drifting. Half the pool is the dark variant
    -- (the renderer keys black ash off spin >= 0.5).
    grain.y[i] = py + 10 + random() * 90
    grain.vx[i] = windX * (3 + random() * 7) + (random() - 0.5) * 3
    grain.vy[i] = -(2.5 + random() * 5.0)
    grain.vz[i] = windZ * (3 + random() * 7) + (random() - 0.5) * 3
    grain.maxLife[i] = 4.0 + random() * 6.0
    grain.size[i] = (0.24 + random() * 0.46) * (0.55 + near * 0.75)
    grain.a[i] = 0.22 + random() * 0.30 + near * 0.20
  elseif kind == 3 then
    -- Leaves/debris: tumbling, lofted, strongly wind-driven.
    grain.y[i] = py - 0.5 + random() * 34
    local drive = 16 + random() * 30
    grain.vx[i] = windX * drive + (random() - 0.5) * 12
    grain.vy[i] = -(0.5 + random() * 3.0) + random() * 5.0
    grain.vz[i] = windZ * drive + (random() - 0.5) * 12
    grain.maxLife[i] = 2.2 + random() * 3.4
    grain.size[i] = (0.55 + random() * 1.05) * (0.5 + near * 0.85)
    grain.a[i] = 0.35 + random() * 0.35 + near * 0.20
  else
    -- Hail (kind 1) and anything unmapped: hard, fast, straight down.
    grain.y[i] = py + 24 + random() * 110
    grain.vx[i] = windX * (6 + random() * 10)
    grain.vy[i] = -(34 + random() * 26)
    grain.vz[i] = windZ * (6 + random() * 10)
    grain.maxLife[i] = 1.4 + random() * 2.0
    grain.size[i] = (0.45 + random() * 0.65) * (0.6 + near * 0.7)
    grain.a[i] = 0.45 + random() * 0.35
  end
end

-- ---------------------------------------------------------------------------
-- WEATHER CLASSIFICATION
-- ---------------------------------------------------------------------------
-- The old inline check missed every FROST* variant, ICEBOUND and WHITEOUT —
-- those weathers produced literally zero 3D snow even once the module loaded.
-- Exact ids first, then prefixes, so a new FROSTWHATEVER is snowy by default.
local SNOW_TARGET = {
  BLIZZARD = 2.2, WHITEOUT = 2.4, THUNDERSNOW = 3.0, DRAGONSTORM = 1.8,
  SNOW = 1.9, SNOW_LIGHT = 1.9, SNOWY = 1.9, TSNOW = 2.0,
  ICEBOUND = 1.6, HAIL = 0.6, SLEET = 0.5,
}

local function snowyTarget(wxId)
  if not wxId or wxId == "" then return 0 end
  local t = SNOW_TARGET[wxId]
  if t then return t end
  if wxId:find("SNOW", 1, true) then return 1.4 end
  if wxId:sub(1, 5) == "FROST" then return 1.2 end
  if wxId:sub(1, 3) == "ICE" then return 1.2 end
  return 0
end

-- ---------------------------------------------------------------------------
-- CACHED HOST QUERIES
-- ---------------------------------------------------------------------------
-- These used to be a `pcall(function() ... end)` per frame: a fresh closure
-- every update just to read a number that changes on a menu press.
local qScale, qAt = 1.0, -1
local function qualityScale()
  -- Counts are already capped above. Scaling them down again would turn the
  -- light profiles into a few isolated streaks and make the three rain levels
  -- indistinguishable.
  if V.questLitePrivate then return 1.0 end
  if simTime - qAt < 1.0 then return qScale end
  qAt = simTime
  pcall(function()
    local Q = V.require("Quality")
    if Q and Q.budget then
      local b = Q.budget(1)
      if b and b.worldPrecip then qScale = b.worldPrecip end
    end
  end)
  return qScale
end

local fpv, fpvAt = false, -1
local function firstPerson()
  if simTime - fpvAt < 1.0 then return fpv end
  fpvAt = simTime
  pcall(function()
    local S = V.require("Settings")
    if S and S.isFirstPerson then fpv = S.isFirstPerson() and true or false end
  end)
  return fpv
end

-- ---------------------------------------------------------------------------
-- UPDATE
-- ---------------------------------------------------------------------------
function WP.rainSurface(weather,x,z,legacy)
  if not V.questLitePrivate then return legacy end
  if not(weather and type(weather.surfaceAt)=='function')then return nil end
  local y=weather.surfaceAt(x,z)
  if type(y)~='number' or y~=y or math.abs(y)>10000 then return nil end
  return y
end
function WP.update(dt, focus, weather)
  if not focus then return end
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end
  if dt > 0.1 then dt = 0.1 end
  simTime = simTime + dt

  local px = focus[1] or 0
  local py = focus[2] or 0
  local pz = focus[3] or 0
  local rainI = tonumber(weather and weather.rainIntensity) or 0
  local snowI = tonumber(weather and weather.snowIntensity) or 0
  local wxId = tostring((weather and weather.wxId) or ""):upper()
  -- Fallback: WX snowy weathers must produce falling snow even if profile
  -- intensity was 0 (CinematicAtmos only wires a subset of ids).
  if snowI <= 0.02 then
    snowI = snowyTarget(wxId)
  end
  -- The cloud deck sets how high the far column reaches, so flakes visibly come
  -- out of the bank rather than out of a fixed slab. Read-only; the bank itself
  -- belongs to CinematicAtmos and is not touched.
  snowCeil = max(0, (tonumber(weather and weather.cloudBase) or 0) * 0.35)

  local windS = tonumber(weather and weather.rainWind) or 1
  if snowI > 0 then
    windS = tonumber(weather and weather.snowWind) or windS
  end
  -- World wind along XZ (fixed axes — not camera relative)
  local windX = 0.55 * windS
  local windZ = 0.25 * windS
  if weather and weather.windX and weather.windZ then
    -- Same world-space heading as the moving storm, never headset-relative.
    -- Preserve the old vector magnitude and the fixed particle budgets.
    windX=weather.windX*.6041523*windS
    windZ=weather.windZ*.6041523*windS
  end

  local q = qualityScale()
  local desktopProfile = DesktopWeatherProfile.current()

  local wantRain = 0
  if rainI > 0.02 then
    -- Storm-only density increase. Keep original per-drop size/opacity.
    local rainBudget=RAIN_MAX
    if V.questLitePrivate and weather and weather.wxId=='STORM' then rainBudget=120 end
    local budgetKey = weather and weather.wxId == 'STORM' and 'stormRainMax' or 'rainMax'
    rainBudget = floor(DesktopWeatherProfile.value(desktopProfile, budgetKey, rainBudget, 2000))
    wantRain = min(rainBudget, floor(rainBudget * min(1.5, rainI) * 0.85 * q + 0.5))
  end

  -- SNOW VOLUME TRACKS WHAT THE HOST RENDERS.
  -- If the camera's far plane says more world is on screen, the disk grows to
  -- match and the flake count grows with its AREA -- so density per tile holds
  -- instead of the same handful of flakes being smeared over more ground. A
  -- host that publishes no far plane keeps the default radius.
  if lastFar then
    SNOW_STREAM_RADIUS = max(SNOW_RADIUS_MIN, min(SNOW_RADIUS_MAX, lastFar * SNOW_FAR_FRACTION))
    SNOW_DRAW_RADIUS = SNOW_STREAM_RADIUS
  end

  local wantSnow = 0
  if snowI > 0.02 then
    -- flakes = per-tile density x rendered tiles x intensity x quality
    local tiles = (math.pi * SNOW_STREAM_RADIUS * SNOW_STREAM_RADIUS) / (TILE * TILE)
    local want = SNOW_PER_TILE * tiles * min(1.0, snowI / 1.9) * q
    local snowBudget = floor(DesktopWeatherProfile.value(desktopProfile, 'snowMax', SNOW_MAX, 9000))
    wantSnow = min(snowBudget, floor(want + 0.5))
  end

  ensureRain(wantRain)
  ensureSnow(wantSnow)

  -- ---- RAIN ---------------------------------------------------------------
  local rx, ry, rz = rain.x, rain.y, rain.z
  local rvx, rvy, rvz = rain.vx, rain.vy, rain.vz
  local rlife, rmax, rseed = rain.life, rain.maxLife, rain.seed
  -- Weather profiles already select rainSpeed. A stronger vertical baseline
  -- keeps ordinary rain visibly moving and preserves each storm profile's
  -- relative pace. This changes no particle budgets or draw geometry.
  local fallScale = 1.50 * max(0.5, min(1.5, tonumber(weather and weather.rainSpeed) or 1.0))
  for i = 1, wantRain do
    if rx[i] == 0 and ry[i] == 0 and rz[i] == 0 and rlife[i] == 0 then
      spawnRainAt(i, px, py, pz, rainI, windX, windZ)
    end
    rlife[i] = rlife[i] + dt
    -- Integrate independent velocity (world axes only)
    rx[i] = rx[i] + rvx[i] * dt
    ry[i] = ry[i] + rvy[i] * dt * fallScale
    rz[i] = rz[i] + rvz[i] * dt
    -- Mild gravity reinforcement (per-drop variation already in vy)
    rvy[i] = rvy[i] - (18 + (rseed[i] or 0) * 8) * dt
    local surface=WP.rainSurface(weather,rx[i],rz[i],py-2)
    if surface and ry[i] < surface then
      addWetMark(rx[i], V.questLitePrivate and surface+0.05 or py-1.2, rz[i], 0.35 + random() * 0.45)
      spawnRainAt(i, px, py, pz, rainI, windX, windZ)
    elseif rlife[i] >= rmax[i] or far(rx[i], rz[i], px, pz) then
      spawnRainAt(i, px, py, pz, rainI, windX, windZ)
    end
  end
  rain.active = wantRain

  -- Age wet marks (dry-up).
  local wActive = wet.active or 0
  local wage = wet.age
  for i = 1, wActive do
    if wage[i] < WET_LIFE then wage[i] = wage[i] + dt end
  end

  -- Random small wet flecks across the whole rain volume (not only under the player).
  if rainI > 0.05 then
    local rate = 28 * min(1.6, rainI) * dt
    local nSpawn = floor(rate)
    if random() < (rate - nSpawn) then nSpawn = nSpawn + 1 end
    for _ = 1, nSpawn do
      local ang = random() * PI2
      local rad = (random() ^ 0.4) * STREAM_RADIUS
      local x,z=px+cos(ang)*rad,pz+sin(ang)*rad
      local surface=WP.rainSurface(weather,x,z,py-1.15)
      if surface then addWetMark(x,V.questLitePrivate and surface+0.05 or surface,z,0.22+random()*0.38) end
    end
  end

  -- ---- SNOW ----------------------------------------------------------------
  local sx, sy, sz = snow.x, snow.y, snow.z
  local svx, svy, svz = snow.vx, snow.vy, snow.vz
  local slife, smax, sseed = snow.life, snow.maxLife, snow.seed
  local sph, srot, sspin = snow.ph, snow.rot, snow.spin
  local groundY = py - GROUND_DROP
  local recycleR2 = (SNOW_STREAM_RADIUS * 1.25) * (SNOW_STREAM_RADIUS * 1.25)
  -- Face contact only matters in first person and only once we know where the
  -- eye is (draw() records it; frame 1 has none and simply skips).
  local eye = lastEye
  local wantFace = (eye ~= nil) and firstPerson()
  local ex, ey, ez = 0, 0, 0
  if wantFace then ex, ey, ez = eye[1] or 0, eye[2] or 0, eye[3] or 0 end

  for i = 1, wantSnow do
    if (slife[i] <= 0 and smax[i] <= 0)
        or (sx[i] == 0 and sy[i] == 0 and sz[i] == 0 and slife[i] == 0) then
      spawnSnowAt(i, px, py, pz, snowI, windX, windZ)
    end
    slife[i] = slife[i] + dt
    local seed = sseed[i] or 0.5
    local ph = (sph[i] or 0) + dt * (0.7 + seed * 1.4)
    sph[i] = ph
    srot[i] = (srot[i] or 0) + (sspin[i] or 0) * dt

    -- Flutter. Amplitude is deliberately well under the fall rate: a real flake
    -- wobbles about its own width, it does not orbit. The old 1.6+seed*3.8 was
    -- comparable to fall speed, which read as a swarm of insects.
    local turb = 0.55 + seed * 1.5
    sx[i] = sx[i] + (svx[i] + fsin(ph) * turb + fsin(ph * 1.6 + seed) * turb * 0.45) * dt
    sy[i] = sy[i] + svy[i] * dt
    sz[i] = sz[i] + (svz[i] + fcos(ph * 0.85 + seed) * turb * 0.8) * dt

    -- Soft gravity drift, clamped: a flake reaches terminal velocity, it does
    -- not keep accelerating into a raindrop the way the old version let it.
    if svy[i] > -22 then
      svy[i] = svy[i] - (1.2 + seed * 2.0) * dt
    end

    -- NO player wrap. Flakes keep world positions. Only recycle when:
    --   hit the eye, hit ground, lifetime ends, or drifted out of the volume.
    local recycle = false

    if wantFace then
      local fx, fy, fz = sx[i] - ex, sy[i] - ey, sz[i] - ez
      if (fx * fx + fy * fy + fz * fz) < FACE_R2 then
        -- A real flake really reached the eye. Consume it and leave a speck.
        addFaceHit(fx, fy, fz, snow.size[i])
        recycle = true
      end
    end

    if not recycle then
      local dx = sx[i] - px
      local dz = sz[i] - pz
      local depth = py - sy[i]
      if depth > snowDeepest then snowDeepest = depth end
      if sy[i] < groundY then
        addGroundSnow(sx[i], groundY + 0.3, sz[i], 0.18 + random() * 0.30)
        snowLanded = snowLanded + 1
        recycle = true
      elseif slife[i] >= (smax[i] or 8) then
        snowExpiredAir = snowExpiredAir + 1
        recycle = true
      elseif (dx * dx + dz * dz) > recycleR2 then
        recycle = true
      end
    end

    if recycle then
      spawnSnowAt(i, px, py, pz, snowI, windX, windZ)
    end
  end
  snow.active = wantSnow

  -- Age face specks.
  local fActive = face.active or 0
  for i = 1, fActive do
    if face.age[i] < FACE_LIFE then face.age[i] = face.age[i] + dt end
  end

  -- ---- GRAINS: sand / dust / ash / leaves ---------------------------------
  local sandI = tonumber(weather and weather.sandIntensity) or 0
  local ashI = tonumber(weather and weather.ashIntensity) or 0
  local debrisI = tonumber(weather and weather.debrisIntensity) or 0
  local wantGrain = 0
  local grainKind = 2
  if sandI > 0.02 then
    wantGrain = min(GRAIN_MAX, floor(GRAIN_MAX * min(1.8, sandI) * 0.7 * q + 0.5))
    grainKind = 2
  elseif ashI > 0.02 then
    wantGrain = min(GRAIN_MAX, floor(GRAIN_MAX * min(1.6, ashI) * 0.325 * q + 0.5))
    grainKind = 4
  elseif debrisI > 0.02 then
    wantGrain = min(GRAIN_MAX, floor(GRAIN_MAX * min(1.5, debrisI) * 0.6 * q + 0.5))
    grainKind = 3
  end
  ensureGrain(wantGrain)
  local gx, gy, gz = grain.x, grain.y, grain.z
  local gvx, gvy, gvz = grain.vx, grain.vy, grain.vz
  for i = 1, wantGrain do
    -- Fresh slots start at origin with maxLife=1 — force a real spawn.
    if (gx[i] == 0 and gy[i] == 0 and gz[i] == 0 and grain.life[i] == 0)
        or grain.kind[i] ~= grainKind then
      spawnGrainAt(i, px, py, pz, grainKind, windX, windZ)
    end
    grain.life[i] = grain.life[i] + dt
    gx[i] = gx[i] + gvx[i] * dt
    gy[i] = gy[i] + gvy[i] * dt
    gz[i] = gz[i] + gvz[i] * dt
    if grain.life[i] >= grain.maxLife[i] or gy[i] < py - 3 or far(gx[i], gz[i], px, pz) then
      spawnGrainAt(i, px, py, pz, grainKind, windX, windZ)
    end
  end
  grain.active = wantGrain

  -- 4.30.76: snow remains an atmospheric effect; do not leave ground discs.
  groundSnowTarget = 0
  gsnow.active = 0
end

-- ---------------------------------------------------------------------------
-- VERTEX BUFFER
-- ---------------------------------------------------------------------------
-- One persistent table-of-tables per stream, mutated in place. The previous
-- code built a fresh `verts` table and a fresh 7-field table per vertex every
-- frame — at the snow cap that is 25,200 allocations per frame before the GPU
-- sees anything. Nothing here allocates once the buffer has reached its high
-- water mark.
local RAIN_FMT = {
  { "VertexPosition", "float", 3 },
  { "RainTint", "float", 4 },
}
local SNOW_FMT = {
  { "VertexPosition", "float", 3 },
  { "SnowTint", "float", 4 },
}
local GRAIN_FMT = {
  { "VertexPosition", "float", 3 }, { "RainTint", "float", 4 },
  { "LeafData", "float", 3 }, -- UV and leaf-only variant; zero for other grains
}

local Buf = {}
Buf.__index = Buf

local function newBuf(width)
  return setmetatable({ v = {}, cap = 0, n = 0, width=width or 7 }, Buf)
end

function Buf:reset() self.n = 0 end

-- Grow the backing store to at least n entries. Needed because the mesh is
-- allocated with headroom past the current fill, and setVertices reads real
-- table entries -- without reserving, the mesh could only ever be created at
-- exactly the high water mark, so a fluctuating particle count reallocated the
-- VBO every time the count ticked up.
function Buf:reserve(n)
  local v = self.v
  for i = self.cap + 1, n do
    local row={};for k=1,self.width do row[k]=0 end;v[i]=row
  end
  if n > self.cap then self.cap = n end
end

function Buf:push(x, y, z, r, g, b, a)
  local n = self.n + 1
  self.n = n
  local t = self.v[n]
  if t then
    t[1], t[2], t[3], t[4], t[5], t[6], t[7] = x, y, z, r, g, b, a
  else
    self.v[n] = { x, y, z, r, g, b, a }
    self.cap = n
  end
  -- Entries past n from a previous, busier frame stay in the table untouched;
  -- they are never uploaded because the upload is a prefix of length n.
end

local rainBuf, snowBuf, wetBuf, grainBuf, gsnowBuf, faceBuf =
  newBuf(), newBuf(), newBuf(), newBuf(10), newBuf(), newBuf()
function Buf:grainVertex(x,y,z,r,g,b,a,u,v,leaf)
  self:push(x,y,z,r,g,b,a)
  local row=self.v[self.n];row[8],row[9],row[10]=u,v,leaf
end

-- Meshes are allocated at the buffer's high water mark and only re-created when
-- it grows, so the common case is a prefix upload into an existing VBO.
local meshCap = {}
local prefixUpload = nil   -- nil = untested, true/false = known

local function uploadMesh(mesh, fmt, buf)
  local n = buf.n
  if n < 3 then return nil end
  local cap = (mesh and meshCap[mesh]) or 0
  if (not mesh) or cap < n then
    if mesh then meshCap[mesh] = nil end
    -- Grow with headroom so a slowly rising particle count does not reallocate
    -- every frame. Never past what the buffer can actually supply.
    local want = floor(n * 1.35) + 256
    buf:reserve(want)
    local ok, m = pcall(love.graphics.newMesh, fmt, want, "triangles", "stream")
    if not ok or not m then return nil end
    mesh = m
    meshCap[mesh] = want
  end

  if prefixUpload ~= false then
    local ok = pcall(mesh.setVertices, mesh, buf.v, 1, n)
    if ok then
      prefixUpload = true
      pcall(mesh.setDrawRange, mesh, 1, n)
      return mesh
    end
    prefixUpload = false
  end

  -- Fallback host without the 3-argument setVertices: upload a slice. One table
  -- per frame instead of tens of thousands — still worth it.
  local slice = {}
  local v = buf.v
  for i = 1, n do slice[i] = v[i] end
  if not pcall(mesh.setVertices, mesh, slice) then
    meshCap[mesh] = nil
    return nil
  end
  pcall(mesh.setDrawRange, mesh, 1, n)
  return mesh
end

-- ---------------------------------------------------------------------------
-- SHADERS
-- ---------------------------------------------------------------------------
local function getRainShader()
  if rainShader ~= nil then return rainShader or nil end
  if not (love and love.graphics and love.graphics.newShader) then
    rainShader = false
    return nil
  end
  local ok, sh = pcall(love.graphics.newShader, [[
#ifdef VERTEX
  extern mat4 vp;
  attribute vec4 RainTint;
  varying float vA;
  vec4 position(mat4 t, vec4 v) {
    vA = RainTint.a;
    return vp * vec4(v.xyz, 1.0);
  }
#endif
#ifdef PIXEL
  varying float vA;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    return vec4(0.72, 0.82, 0.95, vA) * color;
  }
#endif
]])
  rainShader = (ok and sh) or false
  return rainShader or nil
end

-- Snow shader now uses the per-vertex tint instead of a hardcoded white, and
-- reads its soft falloff from the quad's own UVs. Two reasons: per-flake
-- brightness breaks up the "one sprite repeated 4000 times" read, and the round
-- falloff is what keeps a flake from looking like a square at close range —
-- which matters far more now that flakes routinely pass within a unit of you.
local function getSnowShader()
  if snowShader ~= nil then return snowShader or nil end
  if not (love and love.graphics and love.graphics.newShader) then
    snowShader = false
    return nil
  end
  local ok, sh = pcall(love.graphics.newShader, [[
#ifdef VERTEX
  extern mat4 vp;
  attribute vec4 SnowTint;
  varying vec4 vCol;
  vec4 position(mat4 t, vec4 v) {
    vCol = SnowTint;
    return vp * vec4(v.xyz, 1.0);
  }
#endif
#ifdef PIXEL
  varying vec4 vCol;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec2 p = vec2(vCol.g, vCol.b) * 2.0 - 1.0;
    float d = dot(p, p);
    float soft = 1.0 - smoothstep(0.10, 1.0, d);
    soft = soft * soft;
    vec3 rgb = vec3(0.95, 0.97, 1.0) * (0.55 + vCol.r * 0.55);
    return vec4(rgb, vCol.a * soft) * color;
  }
#endif
]])
  snowShader = (ok and sh) or false
  return snowShader or nil
end

-- Declared before drawGrains uses it. In the previous file this sat *below*
-- drawGrains, so the call resolved to a nil global and threw every frame.
local function getGrainShader()
  if grainShader ~= nil then return grainShader or nil end
  if not (love and love.graphics and love.graphics.newShader) then
    grainShader = false
    return nil
  end
  local ok, sh = pcall(love.graphics.newShader, [[
#ifdef VERTEX
  extern mat4 vp;
  attribute vec4 RainTint;
  attribute vec3 LeafData;
  varying vec3 vLeaf;
  varying vec4 vCol;
  vec4 position(mat4 t, vec4 v) {
    vCol = RainTint;
    vLeaf = LeafData;
    return vp * vec4(v.xyz, 1.0);
  }
#endif
#ifdef PIXEL
  varying vec3 vLeaf;
  varying vec4 vCol;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    if (vLeaf.z < 0.5) return vec4(vCol.rgb, vCol.a) * color;
    // Code-native leaf texture: pointed silhouette, curved midrib, side veins.
    // One existing quad, no texture upload or extra leaf draw.
    float y=vLeaf.y, x=(vLeaf.x-0.5)*2.0;
    float variant=vLeaf.z-1.0;
    float bend=0.12*sin(y*3.14159265)*(variant-1.0);
    float width=pow(max(0.0,sin(y*3.14159265)),0.80+variant*0.14)*0.73;
    width*=1.0-0.045*cos(y*38.0+variant);
    float aa=max(fwidth(x),0.015);
    float edge=1.0-smoothstep(width-aa,width+aa,abs(x-bend));
    float midrib=1.0-smoothstep(0.016,0.035+aa,abs(x-bend));
    float veins=1.0-smoothstep(0.025,0.09,abs(fract(y*5.0-abs(x-bend)*1.4)-0.5));
    float shade=0.76+0.20*(x-bend)+0.14*sin(y*3.14159265);
    vec3 rgb=vCol.rgb*shade;
    rgb=mix(rgb,vCol.rgb*1.25,(midrib*0.6+veins*0.2)*edge);
    return vec4(rgb,vCol.a*edge) * color;
  }
#endif
]])
  grainShader = (ok and sh) or false
  return grainShader or nil
end

local function beginPass(Voxel3D, sh)
  pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
  pcall(love.graphics.setDepthMode, "lequal", false)
  local began = false
  if Voxel3D.beginEffect and sh then began = Voxel3D.beginEffect(sh) end
  if sh then
    if not began then pcall(love.graphics.setShader, sh) end
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "vp", Voxel3D.vp)
  end
end

local function endPass(Voxel3D)
  if Voxel3D.endEffect then pcall(Voxel3D.endEffect)
  else pcall(love.graphics.setShader) end
  pcall(love.graphics.setDepthMode, "lequal", true)
end

-- ---------------------------------------------------------------------------
-- DRAW: RAIN STREAKS (geometry unchanged)
-- ---------------------------------------------------------------------------
local function drawRainStreaks(Voxel3D)
  local active = rain.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then
    drawnRainVerts = 0
    return
  end
  local eye = Voxel3D.eye or { 0, 0, 0 }
  local ex, ey, ez = eye[1] or 0, eye[2] or 0, eye[3] or 0
  local buf = rainBuf
  buf:reset()

  local ax, ay, az = rain.x, rain.y, rain.z
  local avx, avy, avz = rain.vx, rain.vy, rain.vz
  local asize, aa, alife, amax = rain.size, rain.a, rain.life, rain.maxLife
  local DEPTH = STREAM_RADIUS * 1.15

  for i = 1, active do
    local x, y, z = ax[i], ay[i], az[i]
    local size = asize[i]
    local a = aa[i]
    local lifeT = alife[i] / max(0.05, amax[i])
    if lifeT < 0.08 then a = a * (lifeT / 0.08) end
    if lifeT > 0.85 then a = a * (1 - (lifeT - 0.85) / 0.15) end
    local tx, ty, tz = ex - x, ey - y, ez - z
    local tl = sqrt(tx * tx + ty * ty + tz * tz)
    if tl >= 1e-3 then
      local near = 1.0 - min(1.0, tl / DEPTH)
      size = size * (0.40 + near * 1.35)
      a = a * (0.35 + near * 0.65)
      local rx, rz = -tz, tx
      local rl = sqrt(rx * rx + rz * rz)
      if rl < 1e-4 then rx, rz = 1, 0 else rx, rz = rx / rl, rz / rl end
      -- Rain streak along velocity
      local vx, vy, vz = avx[i], avy[i], avz[i]
      local vl = sqrt(vx * vx + vy * vy + vz * vz)
      if vl < 1e-3 then vx, vy, vz = 0, -1, 0 else vx, vy, vz = vx / vl, vy / vl, vz / vl end
      local len = size * 2.8
      local half = size * 0.12
      local hx, hy, hz = x - vx * len * 0.5, y - vy * len * 0.5, z - vz * len * 0.5
      local tx2, ty2, tz2 = x + vx * len * 0.5, y + vy * len * 0.5, z + vz * len * 0.5
      local hrx, hrz = rx * half, rz * half
      buf:push(hx - hrx, hy, hz - hrz, a, a, a, a)
      buf:push(hx + hrx, hy, hz + hrz, a, a, a, a)
      buf:push(tx2 + hrx, ty2, tz2 + hrz, a, a, a, a)
      buf:push(hx - hrx, hy, hz - hrz, a, a, a, a)
      buf:push(tx2 + hrx, ty2, tz2 + hrz, a, a, a, a)
      buf:push(tx2 - hrx, ty2, tz2 - hrz, a, a, a, a)
    end
  end

  drawnRainVerts = buf.n
  rainMesh = uploadMesh(rainMesh, RAIN_FMT, buf)
  if not rainMesh then return end
  beginPass(Voxel3D, getRainShader())
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, rainMesh)
  endPass(Voxel3D)
end

-- ---------------------------------------------------------------------------
-- DRAW: SNOW
-- ---------------------------------------------------------------------------
-- Each flake is a camera-facing quad *rotated by its own tumble angle* around
-- the view axis. The tumble was already simulated and previously discarded,
-- which is why every flake looked like the same stamp.
--
-- The quad UVs travel in the tint's g/b channels rather than a texture coord
-- pair, because this vertex format is position + one vec4 and adding a third
-- attribute would mean a second format and a second mesh for no gain.
local function drawSnowFlakes(Voxel3D)
  local active = snow.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then return end
  local eye = Voxel3D.eye or { 0, 0, 0 }
  local ex, ey, ez = eye[1] or 0, eye[2] or 0, eye[3] or 0
  local buf = snowBuf
  buf:reset()

  local ax, ay, az = snow.x, snow.y, snow.z
  local asize, aa, alife, amax = snow.size, snow.a, snow.life, snow.maxLife
  local arot, abr = snow.rot, snow.br
  local DEPTH = SNOW_DRAW_RADIUS * 1.15
  local CULL2 = SNOW_DRAW_RADIUS * SNOW_DRAW_RADIUS

  for i = 1, active do
    local x, y, z = ax[i], ay[i], az[i]
    local tx, ty, tz = ex - x, ey - y, ez - z
    local t2 = tx * tx + ty * ty + tz * tz
    -- Cull the vertex build only. The particle keeps integrating; it simply is
    -- not worth six vertices at a range where it covers no pixels.
    if t2 < CULL2 and t2 > 1e-6 then
      local size = asize[i]
      local a = aa[i]
      local lifeT = alife[i] / max(0.05, amax[i])
      if lifeT < 0.08 then a = a * (lifeT / 0.08) end
      if lifeT > 0.90 then a = a * (1 - (lifeT - 0.90) / 0.10) end

      local tl = sqrt(t2)
      local near = 1.0 - min(1.0, tl / DEPTH)
      -- FPV depth: near flakes larger; far still visible for map-wide snow.
      size = size * (0.50 + near * 1.15)
      a = a * (0.30 + near * 0.70)

      if a > 0.012 then
        tx, ty, tz = tx / tl, ty / tl, tz / tl
        -- right = worldUp x toEye, up = toEye x right; then roll both axes by
        -- the tumble angle so flakes are not all stamped at one orientation.
        local rx, rz = -tz, tx
        local rl = sqrt(rx * rx + rz * rz)
        if rl < 1e-4 then rx, rz = 1, 0 else rx, rz = rx / rl, rz / rl end
        local ux = ty * rz
        local uy = tz * rx - tx * rz
        local uz = -ty * rx
        local ul = sqrt(ux * ux + uy * uy + uz * uz)
        if ul < 1e-4 then ux, uy, uz = 0, 1, 0 else ux, uy, uz = ux / ul, uy / ul, uz / ul end

        local ang = arot[i] or 0
        local ca, sa = fcos(ang), fsin(ang)
        local hs = size * 0.55
        local axx = (rx * ca + ux * sa) * hs
        local axy = (uy * sa) * hs
        local axz = (rz * ca + uz * sa) * hs
        local ayx = (ux * ca - rx * sa) * hs
        local ayy = (uy * ca) * hs
        local ayz = (uz * ca - rz * sa) * hs

        local br = abr[i] or 1

        local c1x, c1y, c1z = x - axx + ayx, y - axy + ayy, z - axz + ayz
        local c2x, c2y, c2z = x + axx + ayx, y + axy + ayy, z + axz + ayz
        local c3x, c3y, c3z = x + axx - ayx, y + axy - ayy, z + axz - ayz
        local c4x, c4y, c4z = x - axx - ayx, y - axy - ayy, z - axz - ayz

        buf:push(c1x, c1y, c1z, br, 0, 0, a)
        buf:push(c2x, c2y, c2z, br, 1, 0, a)
        buf:push(c3x, c3y, c3z, br, 1, 1, a)
        buf:push(c1x, c1y, c1z, br, 0, 0, a)
        buf:push(c3x, c3y, c3z, br, 1, 1, a)
        buf:push(c4x, c4y, c4z, br, 0, 1, a)
      end
    end
  end

  drawnSnowVerts = buf.n
  snowMesh = uploadMesh(snowMesh, SNOW_FMT, buf)
  if not snowMesh then return end
  beginPass(Voxel3D, getSnowShader())
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, snowMesh)
  endPass(Voxel3D)
end

-- ---------------------------------------------------------------------------
-- DRAW: FACE SPECKS
-- ---------------------------------------------------------------------------
-- Only reachable when a simulated flake actually intersected the eye sphere.
-- The quad is world geometry pinned a fraction of a unit off the eye along the
-- direction the flake arrived from, so it turns with the head like something
-- stuck to you rather than sliding like a screen decal. It swells slightly and
-- fades: melt, not wipe.
local function drawFaceSpecks(Voxel3D)
  local active = face.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then return end
  local eye = Voxel3D.eye
  if not eye then return end
  local ex, ey, ez = eye[1] or 0, eye[2] or 0, eye[3] or 0
  local buf = faceBuf
  buf:reset()

  for i = 1, active do
    local age = face.age[i] or 99
    if age < FACE_LIFE then
      local t = age / FACE_LIFE
      local a = (1 - t * t) * 0.55
      if t < 0.10 then a = a * (t / 0.10) end
      if a > 0.02 then
        local dx, dy, dz = face.dx[i], face.dy[i], face.dz[i]
        -- Melt: spreads a little and slides a touch downward as it goes.
        local hs = face.size[i] * (1.0 + t * 0.55)
        local x = ex + dx * FACE_DIST
        local y = ey + dy * FACE_DIST - t * face.size[i] * 0.8
        local z = ez + dz * FACE_DIST
        -- Billboard against the arrival direction.
        local rx, rz = -dz, dx
        local rl = sqrt(rx * rx + rz * rz)
        if rl < 1e-4 then rx, rz = 1, 0 else rx, rz = rx / rl, rz / rl end
        local ux = dy * rz
        local uy = dz * rx - dx * rz
        local uz = -dy * rx
        local ul = sqrt(ux * ux + uy * uy + uz * uz)
        if ul < 1e-4 then ux, uy, uz = 0, 1, 0 else ux, uy, uz = ux / ul, uy / ul, uz / ul end
        local c1x, c1y, c1z = x - rx * hs + ux * hs, y + uy * hs, z - rz * hs + uz * hs
        local c2x, c2y, c2z = x + rx * hs + ux * hs, y + uy * hs, z + rz * hs + uz * hs
        local c3x, c3y, c3z = x + rx * hs - ux * hs, y - uy * hs, z + rz * hs - uz * hs
        local c4x, c4y, c4z = x - rx * hs - ux * hs, y - uy * hs, z - rz * hs - uz * hs
        buf:push(c1x, c1y, c1z, 1, 0, 0, a)
        buf:push(c2x, c2y, c2z, 1, 1, 0, a)
        buf:push(c3x, c3y, c3z, 1, 1, 1, a)
        buf:push(c1x, c1y, c1z, 1, 0, 0, a)
        buf:push(c3x, c3y, c3z, 1, 1, 1, a)
        buf:push(c4x, c4y, c4z, 1, 0, 1, a)
      end
    end
  end

  faceMesh = uploadMesh(faceMesh, SNOW_FMT, buf)
  if not faceMesh then return end
  beginPass(Voxel3D, getSnowShader())
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, faceMesh)
  endPass(Voxel3D)
end

-- ---------------------------------------------------------------------------
-- DRAW: GROUND LAYERS
-- ---------------------------------------------------------------------------
local function drawWetMarks(Voxel3D)
  local active = wet.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then return end
  local buf = wetBuf
  buf:reset()
  for i = 1, active do
    local age = wet.age[i] or 99
    if age < WET_LIFE then
      local t = age / WET_LIFE
      -- Appear fast, hold, then dry (alpha -> 0 over the last half)
      local a = wet.a[i] * (1.0 - t * t)
      if t < 0.08 then a = a * (t / 0.08) end
      if a > 0.02 then
        local x, y, z = wet.x[i], wet.y[i], wet.z[i]
        local r = wet.size[i] * (0.55 + t * 0.15)
        -- Flat quad on ground (world XZ)
        buf:push(x - r, y, z - r, a, a, a, a)
        buf:push(x + r, y, z - r, a, a, a, a)
        buf:push(x + r, y, z + r, a, a, a, a)
        buf:push(x - r, y, z - r, a, a, a, a)
        buf:push(x + r, y, z + r, a, a, a, a)
        buf:push(x - r, y, z + r, a, a, a, a)
      end
    end
  end
  wetMesh = uploadMesh(wetMesh, RAIN_FMT, buf)
  if not wetMesh then return end
  beginPass(Voxel3D, getRainShader())
  -- Darker wet tint
  pcall(love.graphics.setColor, 0.25, 0.30, 0.38, 1)
  pcall(love.graphics.draw, wetMesh)
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  endPass(Voxel3D)
end

-- Ground snow uses the grain shader, not the rain shader: the rain shader
-- hardcodes a blue-grey pixel colour and would have painted every drift the
-- colour of a puddle. The grain shader passes the per-vertex tint through.
local function drawGroundSnow(Voxel3D)
  local active = gsnow.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then return end
  local buf = gsnowBuf
  buf:reset()
  for i = 1, active do
    local amt = gsnow.amount[i] or 0
    if amt > 0.04 then
      local x, y, z = gsnow.x[i], gsnow.y[i], gsnow.z[i]
      local r = gsnow.size[i] * (0.6 + amt * 0.8)
      local a = 0.35 + amt * 0.55
      buf:push(x - r, y, z - r, 0.92, 0.95, 1.0, a)
      buf:push(x + r, y, z - r, 0.92, 0.95, 1.0, a)
      buf:push(x + r, y, z + r, 0.92, 0.95, 1.0, a)
      buf:push(x - r, y, z - r, 0.92, 0.95, 1.0, a)
      buf:push(x + r, y, z + r, 0.92, 0.95, 1.0, a)
      buf:push(x - r, y, z + r, 0.92, 0.95, 1.0, a)
    end
  end
  gsnowMesh = uploadMesh(gsnowMesh, RAIN_FMT, buf)
  if not gsnowMesh then return end
  beginPass(Voxel3D, getGrainShader())
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, gsnowMesh)
  endPass(Voxel3D)
end

local function drawGrains(Voxel3D)
  local active = grain.active or 0
  if active <= 0 or not (Voxel3D and Voxel3D.vp) then return end
  local eye = Voxel3D.eye or { 0, 0, 0 }
  local ex, ey, ez = eye[1] or 0, eye[2] or 0, eye[3] or 0
  local buf = grainBuf
  buf:reset()
  local DEPTH = STREAM_RADIUS * 1.15
  -- Read the user's seasonal tint once, not once per airborne leaf.
  local leafColor="green"
  pcall(function()local s=V.require('Settings');if s and s.leafColor then leafColor=s.leafColor() or 'green' end end)
  for i = 1, active do
    local x, y, z = grain.x[i], grain.y[i], grain.z[i]
    local size, a = grain.size[i], grain.a[i]
    local lifeT = grain.life[i] / max(0.05, grain.maxLife[i])
    if lifeT < 0.08 then a = a * (lifeT / 0.08) end
    if lifeT > 0.85 then a = a * (1 - (lifeT - 0.85) / 0.15) end
    local tx, ty, tz = ex - x, ey - y, ez - z
    local t2 = tx * tx + ty * ty + tz * tz
    if t2 > 1e-6 then
      local tl = sqrt(t2)
      local near = 1.0 - min(1.0, tl / DEPTH)
      size = size * (0.40 + near * 1.35)
      a = a * (0.35 + near * 0.65)
      local rx, rz = -tz / tl, tx / tl
      local rl = sqrt(rx * rx + rz * rz)
      if rl < 1e-4 then rx, rz = 1, 0 else rx, rz = rx / rl, rz / rl end
      local hs = size * 0.5
      local kind = grain.kind[i]
      local cr, cg, cb = 0.85, 0.72, 0.48
      if kind == 4 then
        if (grain.spin[i] or 0) >= 0.5 then cr, cg, cb = 0.1, 0.1, 0.11
        else cr, cg, cb = 0.62, 0.62, 0.60 end
      elseif kind == 3 then
        local leaf = leafColor
        if leaf == "yellow" then cr, cg, cb = 0.78, 0.68, 0.18
        elseif leaf == "orange" then cr, cg, cb = 0.82, 0.42, 0.14
        elseif leaf == "brown" then cr, cg, cb = 0.48, 0.30, 0.14
        else cr, cg, cb = 0.30, 0.58, 0.22 end
      end
      local hrx, hrz = rx * hs, rz * hs
      local upx,upy,upz=0,hs,0
      local hy=0
      local variant=0
      if kind==3 then
        local seed=grain.seed[i] or 0
        local angle=seed*PI2+simTime*(0.7+(grain.spin[i] or 0)*1.3)
        local c,s=cos(angle),sin(angle)
        local flutter=0.40+0.60*abs(cos(simTime*1.7+seed*9))
        hrx,hy,hrz=rx*hs*c*flutter,hs*s*flutter,rz*hs*c*flutter
        upx,upy,upz=-rx*hs*s,hs*c,-rz*hs*s
        variant=1+floor(seed*3)
      end
      buf:grainVertex(x-hrx+upx,y-hy+upy,z-hrz+upz,cr,cg,cb,a,0,0,variant)
      buf:grainVertex(x+hrx+upx,y+hy+upy,z+hrz+upz,cr,cg,cb,a,1,0,variant)
      buf:grainVertex(x+hrx-upx,y+hy-upy,z+hrz-upz,cr,cg,cb,a,1,1,variant)
      buf:grainVertex(x-hrx+upx,y-hy+upy,z-hrz+upz,cr,cg,cb,a,0,0,variant)
      buf:grainVertex(x+hrx-upx,y+hy-upy,z+hrz-upz,cr,cg,cb,a,1,1,variant)
      buf:grainVertex(x-hrx-upx,y-hy-upy,z-hrz-upz,cr,cg,cb,a,0,1,variant)
    end
  end
  grainMesh = uploadMesh(grainMesh, GRAIN_FMT, buf)
  if not grainMesh then return end
  beginPass(Voxel3D, getGrainShader())
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  pcall(love.graphics.draw, grainMesh)
  endPass(Voxel3D)
end

-- ---------------------------------------------------------------------------
-- PUBLIC DRAW
-- ---------------------------------------------------------------------------
function WP.draw(Voxel3D, frame)
  if not Voxel3D then return end
  -- Record the eye for the next update's face-contact test. Draw is the only
  -- place the eye is available, and it is used purely as a *reader* — placement
  -- and orientation of the simulation still never consult it.
  if Voxel3D.eye then lastEye = Voxel3D.eye end
  -- Track how far the host is actually rendering, so the snow volume can match
  -- it. Same source NightSky and CelestialBodies read for the sky radius.
  local f = Voxel3D.far or (Voxel3D.camera and Voxel3D.camera.far)
  if type(f) == "number" and f > 80 then lastFar = f end

  local weather = frame and frame.weather
  local rainI = tonumber(weather and weather.rainIntensity) or 0
  local snowI = tonumber(weather and weather.snowIntensity) or 0
  local wxId = tostring((weather and weather.wxId) or ""):upper()
  if snowI <= 0.02 then
    snowI = snowyTarget(wxId)
  end
  local sandI = tonumber(weather and weather.sandIntensity) or 0
  local ashI = tonumber(weather and weather.ashIntensity) or 0
  local debrisI = tonumber(weather and weather.debrisIntensity) or 0

  drawWetMarks(Voxel3D)
  drawGroundSnow(Voxel3D)
  if rainI > 0.02 then
    drawRainStreaks(Voxel3D)
  else
    drawnRainVerts = 0
  end
  if snowI > 0.02 then
    drawSnowFlakes(Voxel3D)
    drawFaceSpecks(Voxel3D)
  else
    -- Belt and braces. `snow.active` drops to 0 in update() when the weather
    -- stops being snowy, and drawingSnow() checks that too, so this is not the
    -- only thing standing between clear weather and a suppressed 2D layer --
    -- but a stale vertex count is a trap for the next reader either way.
    drawnSnowVerts = 0
  end
  if sandI > 0.02 or ashI > 0.02 or debrisI > 0.02 then
    drawGrains(Voxel3D)
  end
end

function WP.invalidate()
  rainMesh, snowMesh, wetMesh, grainMesh, gsnowMesh, faceMesh = nil, nil, nil, nil, nil, nil
  rainShader, snowShader, grainShader = nil, nil, nil
  rain.active, snow.active, grain.active = 0, 0, 0
  wet.active, gsnow.active, face.active = 0, 0, 0
  wetCursor=0
  for i=1,wet.n do wet.age[i]=99 end
  groundSnowTarget = 0
  meshCap = {}
  prefixUpload = nil
  lastEye = nil
  drawnSnowVerts, drawnRainVerts = 0, 0
  snowLanded, snowExpiredAir = 0, 0
  snowDeepest = 0
end

function WP.describe()
  local fate = snowLanded + snowExpiredAir
  return string.format("wp rain=%d snow=%d(v%d) grain=%d gsnow=%d face=%d/%d land=%d/%d fpv=%s q=%.2f",
    rain.active or 0, snow.active or 0, drawnSnowVerts,
    grain.active or 0, gsnow.active or 0,
    face.active or 0, faceHitTotal,
    snowLanded, fate,
    tostring(fpv), qScale)
end

--- True only when flake geometry was actually emitted on the last drawn frame.
--- DramalessAtmos.handlesSnow() uses this to decide whether the 2D snow sheet
--- is redundant. It deliberately reports what happened, not what was intended:
--- "snow intensity is nonzero" was the assumption that let the 2D layer get
--- switched off while the 3D layer was silently failing to load.
--- Share (0..1) of currently live flakes within `radius` of a world XZ point,
--- measured across the WHOLE active pool.
---
--- This exists because the obvious way to check near-field density -- read
--- WP.sample() every frame and count -- is a peephole: sample() returns at most
--- 12 entries and always the same low pool indices, so it is a small correlated
--- sample whose answer swung between 36% and 68% run to run. The near field is
--- the whole point of the FPV rework, so it gets a real statistic rather than
--- one that has to be eyeballed for flakiness.
function WP.snowNearShare(px, pz, radius)
  local active = snow.active or 0
  if active <= 0 then return 0, 0 end
  local r2 = (radius or 25) * (radius or 25)
  local sxa, sza = snow.x, snow.z
  local hits = 0
  for i = 1, active do
    local dx, dz = sxa[i] - px, sza[i] - pz
    if (dx * dx + dz * dz) < r2 then hits = hits + 1 end
  end
  return hits / active, active
end

--- Flakes per 1000 square world units inside the annulus [r0, r1).
--- The statistic that says whether it is snowing over the world or only on the
--- player: for a correct field this is the same number in every annulus.
function WP.snowAreaDensity(px, pz, r0, r1)
  local active = snow.active or 0
  if active <= 0 or r1 <= r0 then return 0 end
  local a2, b2 = r0 * r0, r1 * r1
  local sxa, sza = snow.x, snow.z
  local hits = 0
  for i = 1, active do
    local dx, dz = sxa[i] - px, sza[i] - pz
    local d2 = dx * dx + dz * dz
    if d2 >= a2 and d2 < b2 then hits = hits + 1 end
  end
  local area = math.pi * (b2 - a2)
  return hits * 1000.0 / area
end

--- The radius the sim is currently covering, and the flakes-per-tile it is
--- achieving there. Both are derived at runtime from the host's far plane, so
--- this is the only honest way to report them.
function WP.snowCoverage()
  local r = SNOW_STREAM_RADIUS
  local tiles = (math.pi * r * r) / (TILE * TILE)
  return r, (snow.active or 0) / max(1, tiles)
end

--- How many flakes finished their life on the ground versus in mid air.
--- Used by the test suite; also the fastest way to tell from the debug HUD
--- whether snow is actually reaching the world or just decorating the air.
--- Deepest a flake has descended below the focus (world units), and the ground
--- plane it is aiming for. Behavioural, not declarative: this reports where
--- flakes got to, so a change to GROUND_DROP that the sim does not actually
--- honour shows up as a discrepancy rather than passing silently.
function WP.snowDepth()
  return snowDeepest, GROUND_DROP, TILE
end

function WP.snowFate()
  return snowLanded, snowExpiredAir
end

function WP.drawingSnow()
  return (snow.active or 0) > 0 and drawnSnowVerts >= 3
end

--- True only when rain geometry was emitted on the last drawn frame.
function WP.drawingRain()
  return (rain.active or 0) > 0 and drawnRainVerts >= 3
end

function WP.drawingGrains()
  return (grain.active or 0) > 0
end

--- Sample independent particle identities (debug HUD / tests).
function WP.sample(limit)
  limit = min(limit or 6, 12)
  local out = {}
  local n = 0
  for i = 1, (rain.active or 0) do
    if n >= limit then break end
    n = n + 1
    out[n] = string.format(
      "Rain#%d pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) life=%.2f/%.2f",
      rain.id[i] or i, rain.x[i], rain.y[i], rain.z[i],
      rain.vx[i], rain.vy[i], rain.vz[i],
      rain.life[i] or 0, rain.maxLife[i] or 0)
  end
  for i = 1, (snow.active or 0) do
    if n >= limit then break end
    n = n + 1
    out[n] = string.format(
      "Snow#%d pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) life=%.2f/%.2f",
      snow.id[i] or i, snow.x[i], snow.y[i], snow.z[i],
      snow.vx[i], snow.vy[i], snow.vz[i],
      snow.life[i] or 0, snow.maxLife[i] or 0)
  end
  for i = 1, (grain.active or 0) do
    if n >= limit then break end
    n = n + 1
    local kn = ({[1]="Hail",[2]="Sand",[3]="Leaf",[4]="Ash",[5]="BlkAsh"})[grain.kind[i] or 2] or "Grain"
    out[n] = string.format(
      "%s#%d pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) life=%.2f/%.2f",
      kn, grain.id[i] or i, grain.x[i], grain.y[i], grain.z[i],
      grain.vx[i], grain.vy[i], grain.vz[i],
      grain.life[i] or 0, grain.maxLife[i] or 0)
  end
  return out
end

--- Live tuning hook. The snow numbers live here rather than baked in because
--- none of them can be validated without a human looking at the screen.
function WP.tune(t)
  if type(t) ~= "table" then return false end
  if tonumber(t.radius) then
    -- An explicit radius pins the volume: clear the tracked far plane, or the
    -- next update would immediately recompute over the top of it.
    SNOW_STREAM_RADIUS = max(40, tonumber(t.radius))
    SNOW_DRAW_RADIUS = SNOW_STREAM_RADIUS
    lastFar = nil
  end
  if tonumber(t.drawRadius) then SNOW_DRAW_RADIUS = max(20, tonumber(t.drawRadius)) end
  if tonumber(t.bias) then SNOW_RADIAL_BIAS = max(0.3, tonumber(t.bias)) end
  if tonumber(t.max) then
    SNOW_MAX = max(64, floor(tonumber(t.max)))
    if V.questLitePrivate then SNOW_MAX = min(240, SNOW_MAX) end
  end
  if tonumber(t.ceil) then SNOW_CEIL = tonumber(t.ceil) end
  if tonumber(t.ceilSpan) then SNOW_CEIL_SPAN = tonumber(t.ceilSpan) end
  if tonumber(t.perTile) then SNOW_PER_TILE = max(0.05, tonumber(t.perTile)) end
  if tonumber(t.groundTiles) then
    GROUND_EXTRA_TILES = tonumber(t.groundTiles)
    GROUND_DROP = 1.5 + GROUND_EXTRA_TILES * TILE
  end
  if tonumber(t.faceRadius) then
    FACE_R = max(0, tonumber(t.faceRadius))
    FACE_R2 = FACE_R * FACE_R
  end
  return true
end

--- Exposed for the test suite: what the module thinks a WX id means, and the
--- current snow tunables. `fhash` is exported so it has a caller and cannot be
--- mistaken for the dead helper it replaced.
WP.snowyTarget = snowyTarget
WP.hash = fhash
function WP.snowTunables()
  return {
    radius = SNOW_STREAM_RADIUS, drawRadius = SNOW_DRAW_RADIUS,
    bias = SNOW_RADIAL_BIAS, max = SNOW_MAX,
    ceil = SNOW_CEIL, ceilSpan = SNOW_CEIL_SPAN,
    perTile = SNOW_PER_TILE, groundTiles = GROUND_EXTRA_TILES,
    groundDrop = GROUND_DROP,
    faceRadius = FACE_R,
  }
end

return WP
