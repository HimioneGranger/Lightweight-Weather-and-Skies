-- TIME OF DAY: a clock, a Gold/Silver/Crystal colour grade, and the
-- engine's `world.tod` answer.
--
-- WHY THIS MOD OWNS A CLOCK AT ALL.  Version 1 borrowed Dramatic Shape's,
-- which meant that without that mod installed there was no night, and
-- "fog is likelier after dark" was dead code.  A weather system with no
-- clock is half a weather system, so this one carries its own -- and
-- still defers to Dramatic Shape when that mod is present, because two
-- clocks disagreeing about what time it is would be worse than either.
--
-- FOUR SOURCES, chosen in config.lua under `time.source`:
--
--   auto    Dramatic Shape's clock if that mod is loaded, else `cycle`.
--           The default, and the only one that needs no decision.
--   system  the device's real clock, which is what GSC actually did --
--           play at night and it is night.
--   cycle   this mod's own accelerated day, `cycleMinutes` long.
--   fixed   pinned to one phase, for screenshots and for players who
--           want the look without the schedule.
--   off     no clock, no grade, no world.tod.  Vanilla lighting.
--
-- THE PHASES are GSC's, plus one.  Gold and Silver shipped three palette
-- sets -- morning, day and night -- and Crystal kept them.  This adds EVE
-- between day and night, because the interesting half of a sunset is the
-- half GSC had no palette for, and because the grade here is a continuous
-- blend rather than three fixed palettes, so a fourth costs one table row.
-- `world.tod` publishes all four; the engine treats the value as opaque
-- and hands it to `map.palette` for palette mods to key off, so a mod that
-- only knows MORN/DAY/NITE simply never matches EVE and falls through to
-- its default -- which is the correct behaviour, not a bug.
--
-- THE GRADE IS A MULTIPLY PLUS AN ADD, not a palette swap.  A palette swap
-- is what the hardware did and would be more faithful, but it needs a
-- second full set of palettes authored per map per colour mode, and it
-- would fight every other palette mod for the same registry.  A grade over
-- the finished world costs one rectangle, works identically in every
-- colour mode the engine offers (mono, SGB, GBC, OG RED), rides through
-- GBC FX because that runs after it, and composes with weather because it
-- is drawn in the same pass by the same compositor.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Interop = V.require("Interop")

local TOD = {}

-- ------- phases
--
-- `at` is the hour the phase is fully itself; the grade blends between
-- neighbours, so these are anchors rather than boundaries.  Ordering is
-- circular: NITE wraps past midnight to MORN.
--
--   mul   multiplied over the frame -- what darkens and colours it
--   add   added after -- a little light back into the shadows, which is
--         what stops a night grade reading as "the brightness is broken"
--
-- The values are tuned against GSC's own palettes rather than invented:
-- morning is a warm lift, day is exactly neutral (so DAY costs nothing at
-- all -- see `active`), evening is amber with the blue pulled down, and
-- night is the blue-violet GSC used, which darkens far less than it
-- recolours.  A night you cannot read the map through is not authentic,
-- it is just dark.

-- Morning and evening were far too timid in 2.1.x: at 09:00 the blend sat
-- around a 0.97 green and a 0.91 blue, which is under the noise floor of a
-- handheld LCD photographed in a lit room -- indistinguishable from "not
-- working".  GSC's morning palette is a genuinely visible warm shift, so
-- these now are too.  DAY stays EXACTLY neutral, which is what lets the
-- grade cost nothing at noon.
TOD.PHASES = {
  { id = "NITE", at = 1.0,  mul = { 0.52, 0.55, 0.85 }, add = { 0.00, 0.01, 0.07 } },
  { id = "MORN", at = 7.0,  mul = { 1.00, 0.90, 0.74 }, add = { 0.08, 0.04, 0.00 } },
  { id = "DAY",  at = 13.0, mul = { 1.00, 1.00, 1.00 }, add = { 0.00, 0.00, 0.00 } },
  { id = "EVE",  at = 19.0, mul = { 1.00, 0.74, 0.58 }, add = { 0.10, 0.03, 0.00 } },
  { id = "NITE", at = 22.5, mul = { 0.52, 0.55, 0.85 }, add = { 0.00, 0.01, 0.07 } },
}

-- The ladder rungs of the TIME pipeline, in order.  Rung 1 is AUTO (follow
-- the clock); rungs 2+ pin a phase, which is how a player checks the grade
-- is working without editing a config file on a device with no keyboard.
TOD.LEVEL_LABELS = { "OFF", "AUTO", "MORN", "DAY", "EVE", "NITE" }
TOD.LEVEL_PHASES = { false, nil, "MORN", "DAY", "EVE", "NITE" }

-- nil = follow the clock.  Set from the pipeline's level each tick.
TOD.pin = nil
-- When Dramaless (or other host) owns the clock, Weather FX TIME stays OFF.
TOD._forceOffByHost = false

function TOD.setPinFromLevel(level)
  local phase = TOD.LEVEL_PHASES[(level or 0) + 1]
  TOD.pin = (type(phase) == "string") and phase or nil
end

-- The phase NAME for a given hour.  Boundaries, not anchors: this is what
-- `world.tod` publishes, and a hook answer has to be a step function even
-- though the grade is continuous.
function TOD.phaseAt(hour)
  if hour >= 4 and hour < 10 then return "MORN" end
  if hour >= 10 and hour < 17 then return "DAY" end
  if hour >= 17 and hour < 20 then return "EVE" end
  return "NITE"
end

-- ------- the clock

TOD.elapsed = 0          -- seconds the cycle source has run
TOD.hour = 13            -- 0..24, the live answer
TOD.tod = "DAY"          -- the published phase
TOD.source = "none"      -- what actually answered, for the debug row

local ds = { tried = false, DayNight = nil, broken = false }

-- Dramatic Shape's DayNight module, or nil.  Resolved LAZILY, on first
-- use rather than at load: a handle taken at load could be taken before
-- that mod's entry chunk assigned its exports on some load orderings, and
-- a nil cached then would be a nil forever.  Re-probed while the answer is
-- nil, never after a failure.
local function dayNight()
  if ds.broken or not Config.get().time then return nil end
  if ds.DayNight then return ds.DayNight end
  -- Either fork of the voxel diorama; lib/Interop.lua knows the family and
  -- shape-checks the module, so a fork that renamed it costs a lighting
  -- nuance rather than a crash.
  local ok, module, id = pcall(Interop.dayNight)
  if not ok then
    ds.broken = true
    mod.log:warn("voxel clock probe failed (%s); using this mod's own",
      tostring(module))
    return nil
  end
  if not module then return nil end
  ds.DayNight = module
  ds.id = id
  return module
end

function TOD.voxelClockAvailable()
  return dayNight() ~= nil
end

local FIXED_HOUR = { MORN = 7, DAY = 13, EVE = 19, NITE = 1 }

-- Hours 0..24 from Dramatic Shape's dial.  Its clock is `CYCLE` seconds
-- around with the sun owning the first `DAY_LEN` of it, so the mapping is
-- "the sun's half is 06:00-18:00, the moon's half is the rest" -- which
-- puts its pinned DAY at our noon and its pinned NIGHT at our midnight.
local function voxelHours(dn)
  local ok, hour = pcall(function()
    -- `time()` is the host's EFFECTIVE clock: it includes a running cycle and
    -- every player pin. `hours()` is only the wall clock on Battle Art and
    -- would silently ignore DAY/NIGHT/DUSK/DAWN/CYCLE, splitting q90 into two
    -- skies. Prefer the effective dial and use hours only for older hosts.
    if type(dn.time) == "function" then
      local t, cycle, dayLen = dn.time(), dn.CYCLE or 1200, dn.DAY_LEN or 600
      if type(t) == "number" and t == t and cycle > 0 then
        t = t % cycle
        if t < dayLen then return 6 + (t / dayLen) * 12 end
        return (18 + ((t - dayLen) / (cycle - dayLen)) * 12) % 24
      end
    end
    if type(dn.hours) == "function" then
      local h = dn.hours()
      if type(h) == "number" and h == h then return h % 24 end
    end
    return nil
  end)
  if ok and type(hour) == "number" and hour == hour then return hour end
  ds.broken = true
  return nil
end

--- Call when DRAMALESS_SHAPE (etc.) is active: Weather FX TIME setting behaves as OFF.
function TOD.setHostOwnsClock(yes)
  TOD._forceOffByHost = yes and true or false
  if TOD._forceOffByHost then
    TOD.pin = nil
    TOD.hour, TOD.tod, TOD.source = 13, "DAY", "off"
    pcall(function()
      local c = Config.get()
      if c and c.time then c.time.source = "off" end
    end)
  end
end

function TOD.update(dt)
  local cfg = Config.get().time
  -- Host voxel mods (Dramaless) own day/night; keep our TIME feature off.
  if TOD._forceOffByHost then
    TOD.pin = nil
    TOD.hour, TOD.tod, TOD.source = 13, "DAY", "off"
    return
  end
  if cfg.source == "off" then
    TOD.hour, TOD.tod, TOD.source = 13, "DAY", "off"
    return
  end

  dt = tonumber(dt) or 0
  if dt > 0 and dt < 0.25 then TOD.elapsed = TOD.elapsed + dt end

  -- A pinned rung outranks every clock source: it exists to answer "is
  -- this drawing at all", and an answer the clock could override would not
  -- be one.
  if TOD.pin then
    TOD.hour = FIXED_HOUR[TOD.pin] or 13
    TOD.tod = TOD.pin
    TOD.source = "pinned"
    return
  end

  local hour = nil
  local source = cfg.source

  if source == "auto" then
    local dn = dayNight()
    if dn then
      hour = voxelHours(dn)
      if hour then TOD.source = (ds.id == "DRAMALESS_SHAPE") and "dramaless" or "voxel" end
    end
    if not hour then source = "cycle" end
  end

  if not hour and source == "system" then
    local ok, t = pcall(os.date, "*t")
    if ok and type(t) == "table" then
      hour = (t.hour or 12) + (t.min or 0) / 60
      TOD.source = "system"
    else
      source = "cycle"
    end
  end

  if not hour and source == "fixed" then
    hour = FIXED_HOUR[cfg.fixedPhase] or 13
    TOD.source = "fixed"
  end

  if not hour then
    local period = math.max(30, (cfg.cycleMinutes or 24) * 60)
    hour = ((TOD.elapsed / period) * 24) % 24
    TOD.source = "cycle"
  end

  TOD.hour = hour % 24
  TOD.tod = TOD.phaseAt(TOD.hour)
end

-- 0 = deep night, 1 = full daylight.  The number AUTO weather weights
-- against; a cosine over the daylight window so dawn and dusk ramp rather
-- than snap.
function TOD.daylight()
  local h = TOD.hour
  -- sun up 06:00-18:00, with a soft shoulder either side
  local x = (h - 6) / 12
  if x <= 0 or x >= 1 then
    -- the night side: never quite zero, so a moonlit blizzard is still visible
    return 0.05
  end
  return math.max(0.05, math.sin(x * math.pi) ^ 0.55)
end

function TOD.isNight()
  return TOD.tod == "NITE"
end

-- ------- the grade
--
-- Returns multiply rgb and additive rgb for the current hour, already
-- scaled by config strength and by how much of it reaches an interior.
-- Returns nil when there is nothing to draw, which is the common case
-- (mid-day, or the grade switched off) and costs the compositor a nil
-- check rather than an identity rectangle.

local function lerp(a, b, t) return a + (b - a) * t end

function TOD.grade(indoors)
  local cfg = Config.get().time
  if not cfg.grade or cfg.source == "off" then return nil end
  local strength = cfg.gradeStrength or 1
  if indoors then strength = strength * (cfg.indoors or 0) end
  if strength <= 0.001 then return nil end

  local h = TOD.hour
  -- find the bracketing anchors on the circular list
  local prev, next_ = TOD.PHASES[1], TOD.PHASES[#TOD.PHASES]
  for i = 1, #TOD.PHASES - 1 do
    if h >= TOD.PHASES[i].at and h < TOD.PHASES[i + 1].at then
      prev, next_ = TOD.PHASES[i], TOD.PHASES[i + 1]
      break
    end
  end
  local span, into
  if h < TOD.PHASES[1].at then
    -- before the first anchor: wrap from the last (both are NITE, so the
    -- blend is a no-op and this is really just "it is the small hours")
    prev, next_ = TOD.PHASES[#TOD.PHASES], TOD.PHASES[1]
    span = (24 - prev.at) + next_.at
    into = (h + (24 - prev.at)) / span
  elseif h >= TOD.PHASES[#TOD.PHASES].at then
    prev, next_ = TOD.PHASES[#TOD.PHASES], TOD.PHASES[1]
    span = (24 - prev.at) + next_.at
    into = (h - prev.at) / span
  else
    span = next_.at - prev.at
    into = span > 0 and (h - prev.at) / span or 0
  end
  -- smoothstep, so an anchor is a plateau rather than a corner
  into = into * into * (3 - 2 * math.max(0, math.min(1, into)))

  local mr = lerp(prev.mul[1], next_.mul[1], into)
  local mg = lerp(prev.mul[2], next_.mul[2], into)
  local mb = lerp(prev.mul[3], next_.mul[3], into)
  local ar = lerp(prev.add[1], next_.add[1], into) * strength
  local ag = lerp(prev.add[2], next_.add[2], into) * strength
  local ab = lerp(prev.add[3], next_.add[3], into) * strength

  -- pull the multiply toward white by (1 - strength)
  mr = 1 - (1 - mr) * strength
  mg = 1 - (1 - mg) * strength
  mb = 1 - (1 - mb) * strength

  -- Night ambient vs distance to buildings (true night only).
  -- ≤5 steps: lightest; ≥20 steps: clearly darker night. Independent of render distance.
  if not indoors and TOD.isNight and TOD.isNight() then
    local scale = 1
    pcall(function()
      local BL = nil
      if not BL then pcall(function() BL = V.require("BuildingLight") end) end
      if BL and BL.nightAmbientScale then scale = BL.nightAmbientScale() end
    end)
    if type(scale) == "number" and scale < 0.999 then
      mr, mg, mb = mr * scale, mg * scale, mb * scale
      -- Extra cool darkness in the far wild so night reads as night
      local far = math.max(0, (1 - scale) / 0.52)  -- 0 near, ~1 at AMBIENT_FAR
      mr = mr * (1 - 0.06 * far)
      mg = mg * (1 - 0.04 * far)
      mb = math.min(1, mb * (1 + 0.08 * far))
    end
  end

  -- Nothing to draw at full daylight: DAY is exactly neutral, so the
  -- common case is free rather than an identity multiply per frame.
  if mr > 0.998 and mg > 0.998 and mb > 0.998
      and ar < 0.002 and ag < 0.002 and ab < 0.002 then
    return nil
  end
  return mr, mg, mb, ar, ag, ab
end

function TOD.describe()
  return ("%s %02d:%02d/%s"):format(TOD.tod, math.floor(TOD.hour),
    math.floor((TOD.hour % 1) * 60), TOD.source)
end

return TOD
