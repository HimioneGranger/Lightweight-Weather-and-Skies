-- THE WEATHER ITSELF: what it is, what it is becoming, and when it changes.
--
-- Everything the draw path and the battle layer read comes out of here --
-- as a number (State.channel) or as an id (State.id) -- and neither of
-- them ever asks what the weather is called in order to decide how to
-- behave.  That separation is what lets a transition be arithmetic and
-- lets a new weather type arrive without a line of renderer changing.
--
-- ---------------------------------------------------------------------
-- WHAT DECIDES THE WEATHER, highest priority first
-- ---------------------------------------------------------------------
--
--   1. config.force        the file pins one weather everywhere
--   2. config.locations    the file pins one on THIS map
--   3. the OPTIONS ladder  OFF / AUTO / a pinned weather
--   4. the AUTO clock      weighted roll, on a timer
--
-- All four land on the same one-line answer -- an id -- which is then
-- eased into.  There is no second code path for a forced weather: forcing
-- is just a different way of choosing the id, so a forced storm fades in
-- like any other storm and every effect downstream is identical.
--
-- A LOCATION OVERRIDE PARKS THE CLOCK rather than consuming it.  Walk into
-- Lavender Town under a pinned fog and the AUTO timer stops where it is;
-- walk out and it resumes with the same time left on the same spell.
-- Otherwise a player who spent ten minutes in an overridden town would
-- come out into a sky that had silently rolled six times.
--
-- ---------------------------------------------------------------------
-- THE LADDER IS THE MODE
-- ---------------------------------------------------------------------
--
-- The engine's render_pipelines registry gives a pipeline an OFF/1/2/3
-- ladder, an OPTIONS row, persistence in save.options.pipelines and a
-- gate, all from the record's `levels` list.  So the ladder is not "how
-- strong is the weather", it is WHICH WEATHER -- level 1 is AUTO and
-- levels 2+ pin a type.  The player gets a weather picker on the main
-- OPTIONS menu without this mod drawing a single menu widget, and OFF is
-- genuinely off: at level 0 nothing here ticks, the present pass is not
-- eligible, and the engine skips allocating the present canvas entirely,
-- so the frame is byte-for-byte vanilla.
--
-- ---------------------------------------------------------------------
-- WHAT IS PERSISTED, AND WHERE
-- ---------------------------------------------------------------------
--
--   * the MODE (the ladder level) is a display setting and rides in
--     save.options.pipelines with TILT and ZOOM.  The engine writes it.
--   * the WEATHER (which spell is running, and how much is left) is world
--     state and rides in this mod's own save namespace (mod.save ->
--     save.modData.weather_fx).  Load a save from the middle of a storm
--     and it is still storming.
--
-- The eased channel values are deliberately NOT persisted: they are
-- recomputed from the weather in a couple of seconds, and a save carrying
-- them could restore a half-faded frame.  Loading snaps them instead.

local V = ...
local Harden = nil
pcall(function() Harden = V.require("Harden") end)
local mod = V.mod
local Types = V.require("Types")
local Settings = V.require("Settings")
local Config = V.require("Config")
local TOD = V.require("TimeOfDay")
local Seasons = V.require("Seasons")
local Fronts = V.require("Fronts")
local Psystorm = V.require("Psystorm")
local Legendary = nil
local function getLegendary()
  if not Legendary then Legendary = V.require("Legendary") end
  return Legendary
end

local State = {}

-- ------- the ladder
--
-- Built from Types.PINNED so the two can never disagree: add an id there
-- and the row grows a rung.

-- OFF, then two automatic modes, then one rung per pinned weather.
--
-- CYCLE exists because AUTO is honest weather and honest weather is mostly
-- nothing happening: CLEAR carries the largest weight and spells run for
-- minutes, so a player can walk a long way between visible skies and
-- reasonably conclude the mod is broken.  CYCLE gives up realism for
-- variety -- it walks the catalogue in order, skipping clear skies, so
-- something is always falling and every weather gets its turn.
State.LEVEL_LABELS = { "OFF", "AUTO", "CYCLE" }
State.LEVEL_IDS = { false, "AUTO", "CYCLE" }   -- parallel: what each rung means
for _, id in ipairs(Types.PINNED) do
  State.LEVEL_LABELS[#State.LEVEL_LABELS + 1] = Types.get(id).label
  State.LEVEL_IDS[#State.LEVEL_IDS + 1] = id
end

-- ------- live state


-- Single entry for changing active weather id (avoids ad-hoc State.id writes).
function State.setWeather(id, reason)
  if type(id) ~= "string" or id == "" then return false end
  local Types = select(2, pcall(V.require, "Types"))
  if Types and Types.get then
    local def = Types.get(id)
    if def and def.id then id = def.id end
  end
  State.id = id
  if reason then State.pinnedBy = reason end
  return true
end

State.id = Types.DEFAULT      -- the weather actually running
State.left = 0                -- seconds until AUTO picks again
State.level = 0               -- last ladder level seen
State.ch = {}                 -- eased channel values: the draw path's input
State._indoorAccum = 0
State._wasIndoors = false
State._pausedWeatherId = nil
State.elapsed = 0             -- seconds of weather clock, for oscillators
State.dirty = false           -- channels hold values the OFF path must clear
State.pinnedBy = "none"       -- what chose the current weather, for the debug row
-- True on the first AUTO roll after the system is switched on.  AUTO is
-- honest weather, so CLEAR carries the biggest weight and spells run for
-- minutes -- which means the most likely first experience of switching the
-- mod on is a long dry sky, indistinguishable from a mod that is not
-- working.  The FIRST spell after switching on is therefore never CLEAR.
-- Every roll after that is unweighted by this.
State.fresh = false
State._bootSnapFog = true
-- Where CYCLE has got to.  Not persisted: which weather comes next is not
-- worth a save slot, and starting a session on a fresh one is no worse
-- than resuming mid-rotation.
State.cycleIndex = 0
State.mode = "AUTO"           -- AUTO | CYCLE | PIN, decided by the ladder
State.overrideMap = nil       -- the map an active location override belongs to
-- Soft handoff when regional front / AUTO target changes (map walks).
-- Forced menu pins and legend events still snap.
State.softFrom = nil
State.softTo = nil
State.softT = 0
State.softDur = 0
State.mapsTowardCommit = 0

for _, key in ipairs(Types.channels) do State.ch[key] = 0 end

local function rand(a, b)
  if love and love.math and love.math.random then
    if a then return love.math.random(a, b) end
    return love.math.random()
  end
  if a then return math.random(a, b) end
  return math.random()
end

-- ------- region bias
--
-- Geography answers "where does it snow" with ALTITUDE AND WATER -- the
-- two things the map does say.  Seasons (lib/Seasons.lua) multiply the
-- same weights when SEASONS is ON.  A seasonal multiplier of 0 is a hard
-- gate (no snow in summer, no heatwave in winter) even on maps that
-- normally bias toward that weather; non-zero values only lean the dice.
--
-- These are the BUILT-IN defaults.  config.lua's `bias` table is merged
-- over them, so a player adds a region by adding a row rather than by
-- editing this file.

State.BIAS = {
  ROUTE_23        = { frozen = 6.0, fog = 1.6 },
  INDIGO_PLATEAU  = { frozen = 8.0, fog = 1.6 },
  ROUTE_22        = { frozen = 2.0 },
  ROUTE_19        = { fog = 2.6, wet = 1.4 },
  ROUTE_20        = { fog = 2.6, wet = 1.4 },
  ROUTE_21        = { fog = 2.4, wet = 1.4, sandy = 1.8 },
  CINNABAR_ISLAND = { fog = 2.0, wet = 1.3, sunny = 1.8, sandy = 3.5 },
  VERMILION_CITY  = { fog = 1.8 },
  LAVENDER_TOWN   = { fog = 3.2 },
  ROUTE_12        = { fog = 1.8, wet = 1.2 },
  VIRIDIAN_FOREST = { fog = 2.2, wet = 1.3 },
}

-- Multiplier for one weather type on one map.  Types are matched by the
-- capability tags they already carry for the battle layer (`wet`,
-- `frozen`, `sunny`, `sandy`) plus a `fog` tag inferred from the channel
-- table -- so a NEW TYPE IS BIASED CORRECTLY without being added to a
-- second list anywhere.
local function biasFor(mapId, def)
  local row = Config.get().bias[mapId or ""] or State.BIAS[mapId or ""]
  local mult = 1
  if row then
    if def.frozen and row.frozen then mult = mult * row.frozen end
    if def.wet and row.wet then mult = mult * row.wet end
    if def.sunny and row.sunny then mult = mult * row.sunny end
    if def.sandy and row.sandy then mult = mult * row.sandy end
    if Types.channel(def, "fog") > 0 and row.fog then mult = mult * row.fog end
  end
  -- Snow, ice and grit anywhere else in Kanto are novelties rather than
  -- forecasts -- but "novelty" tuned for plausibility made them
  -- effectively invisible, so the RARE WX setting scales the suppression
  -- rather than the weather.  The geography still shows through at every
  -- setting except OFTEN: a map that argues for snow keeps its bonus, and
  -- this only decides how hard everywhere else is pushed down.
  local exotic = Settings.exoticScale()
  local function suppress(base)
    -- exotic 0 removes it, 1 is the realistic original, higher relaxes
    -- toward no suppression at all
    if exotic <= 0 then return 0 end
    local relaxed = base + (1 - base) * math.min(1, (exotic - 1) / 6)
    return math.min(1, relaxed)
  end
  if def.frozen and not (row and row.frozen) then mult = mult * suppress(0.2) end
  if def.sandy and not (row and row.sandy) then mult = mult * suppress(0.25) end
  return mult
end

-- ------- the AUTO picker

local function weightOf(def, mapId, previousId, daylight)
  if def.natural == false then return 0 end       -- primal weathers are never rolled
  if not Config.weatherEnabled(def.id) then return 0 end
  -- Hard ban: sun / heat never rolls at night (real night or TIME → NITE).
  -- nightWeight=0 was not enough when TIME OF DAY was off, or when a day
  -- spell was still ticking after sundown.
  if def.sunny then
    local night = false
    if TOD.isNight and TOD.isNight() then night = true
    elseif (tonumber(daylight) or 1) < 0.18 then night = true end
    if night then return 0 end
  end
  local w = (def.weight or 1) * (Config.tuningFor(def.id).weight or 1)
  if def.id == previousId then w = w * 0.15 end   -- rarely repeat a spell
  if def.follows and def.follows[previousId or ""] then w = w * 2.8 end
  if Settings.is("daytime", "on") then
    -- daylight is 1 at noon and ~0 at midnight; blend each type's two
    -- weights along it rather than switching at a threshold, so an evening
    -- is genuinely halfway and not "day until it is suddenly night"
    local day = def.dayWeight or 1
    local night = def.nightWeight or 1
    w = w * (night + (day - night) * daylight)
  end
  -- Seasonal multiplier (1 when SEASONS is OFF).  Applied after geography
  -- so a 0 (summer snow, winter heatwave) kills the roll even on a map
  -- that biases hard toward that weather; non-zero values only lean it.
  w = w * Seasons.multiplier(def)
  if V.questLitePrivate then w=w*V.require('QuestRegional').weight(mapId,def.id)end
  return w * biasFor(mapId, def)
end

-- Total-weight roulette over the whole catalogue, so every type stays
-- reachable however the biases stack; a table that somehow sums to zero
-- falls back to CLEAR rather than to nil.
-- `exclude` drops one id from the roll entirely, used for the first spell
-- after switching on.
-- Fronts rolls each region's weather with the SAME weighting the global
-- AUTO uses, so the geography that favours snow on a mountain pass still
-- does.  Passed as a function rather than required back, because Fronts is
-- required from here and the reverse would be a cycle.
-- `exclude` is passed through: the opening roll uses it to keep a fresh
-- world from starting every front on CLEAR, and dropping it silently was
-- why it did exactly that.

-- True when the sky must not stay sunny (night / NITE).
local function sunForbidden()
  if TOD.isNight and TOD.isNight() then return true end
  if TOD.daylight and (tonumber(TOD.daylight()) or 1) < 0.18 then return true end
  return false
end

local function breakSunnyIfNight()
  if not sunForbidden() then return end
  local def = Types.get(State.id)
  if not (def and def.sunny) then return end
  -- Replace with a non-sunny pick; CLEAR is the safe fallback.
  local mapId = State.lastMapId
  local nextId = State.pick(mapId, State.id)
  if not nextId or Types.get(nextId).sunny then nextId = Types.DEFAULT end
  State.id = nextId
  State.left = dwellFor(Types.get(nextId))
  State.persist()
end

Fronts.pick = function(mapId, exclude) return State.pick(mapId, exclude) end

function State.pick(mapId, exclude)
  local daylight = TOD.daylight()
  State.recentAuto = State.recentAuto or {}
  local total, weights = 0, {}
  for i, def in ipairs(Types.list) do
    local w = weightOf(def, mapId, State.id, daylight)
    -- 6.3.4: prevent AUTO becoming a two-weather ping-pong on strongly biased
    -- maps (reported on Silver as rain/fog forever). Recent skies remain
    -- possible later, but the next roll must explore the wider catalogue.
    for _,rid in ipairs(State.recentAuto) do if def.id==rid then w=w*0.03 end end
    if w ~= w or w < 0 then w = 0 end             -- NaN and negatives out
    if exclude and def.id == exclude then w = 0 end
    weights[i] = w
    total = total + w
  end
  if total <= 0 then return Types.DEFAULT end
  local roll = rand() * total
  for i, w in ipairs(weights) do
    roll = roll - w
    if roll <= 0 then
      local picked=Types.list[i].id
      State.recentAuto[#State.recentAuto+1]=picked
      while #State.recentAuto>2 do table.remove(State.recentAuto,1) end
      return picked
    end
  end
  local picked=Types.list[#Types.list].id
  State.recentAuto[#State.recentAuto+1]=picked
  while #State.recentAuto>2 do table.remove(State.recentAuto,1) end
  return picked
end

-- The rotation CYCLE walks: every natural weather that actually shows
-- something, in catalogue order, minus anything switched off in the
-- config.  Rebuilt each time it is needed rather than cached, because the
-- config can change under a hot reload and the list is nineteen entries.
function State.cycleList()
  local out = {}
  for _, def in ipairs(Types.list) do
    if def.natural ~= false
        and def.id ~= Types.DEFAULT
        and Config.weatherEnabled(def.id) then
      out[#out + 1] = def.id
    end
  end
  return out
end

local function nextInCycle()
  local list = State.cycleList()
  if #list == 0 then return Types.DEFAULT end
  -- Skip sunny entries at night so CYCLE cannot land on SUNNY/HEATWAVE.
  for _ = 1, #list do
    State.cycleIndex = (State.cycleIndex % #list) + 1
    local id = list[State.cycleIndex]
    local def = Types.get(id)
    if not (def and def.sunny and sunForbidden and sunForbidden()) then
      return id
    end
  end
  return Types.DEFAULT
end

local function dwellFor(def)
  local lo = (def.minMin or 4) * 60
  local hi = (def.maxMin or 10) * 60
  if hi < lo then hi = lo end
  local seconds = lo + rand() * (hi - lo)
  local tuning = Config.tuningFor(def.id)
  local regional=1
  if V.questLitePrivate and State.LEVEL_IDS[State.level+1]=='AUTO' then
    regional=V.require('QuestRegional').duration(State.lastMapId,def.id)
  end
  return math.max(2, seconds * Settings.speedScale() * (tuning.duration or 1)*regional)
end

-- ------- setting the weather

function State.set(id, snap)
  State.id = Types.get(id).id
  if snap then State.settle() end
  State.persist()
end

-- Slam every channel to the current weather's value.  Used on load and on
-- hot reload, never during play.

-- 2D fog/veil overlay is only for true fog-family weather.
-- Other types may use light atmospheric channels in Types, but those must
-- not paint the screen-space fog bank (boot residual / clear-sky haze).
local FOG_WEATHER = {
  FOG = true, MIST = true, HAUNTED_MIST = true, SMOG = true,
}
function State.isFogWeather(id)
  id = tostring(id or State.id or ""):upper()
  return FOG_WEATHER[id] and true or false
end

function State.settle()
  local def = Types.get(State.id)
  for _, key in ipairs(Types.channels) do
    State.ch[key] = Types.channel(def, key)
  end
  -- Never keep fog/veil unless this weather is fog-family (fixes boot haze).
  if not State.isFogWeather(def.id) then
    State.ch.fog = 0
    State.ch.veil = 0
    State.ch.fogSpeed = 0
  end
  if def.id == "CLEAR" then
    for _, key in ipairs(Types.channels) do
      State.ch[key] = 0
    end
  end
  State.dirty = true
end

function State.clearChannels()
  for _, key in ipairs(Types.channels) do
    State.ch[key] = 0
  end
  State.dirty = true
end

function State.markGentleIntro(seconds)
  State._gentleIntro = math.max(State._gentleIntro or 0, tonumber(seconds) or 6.0)
end

function State.current()
  if State.indoors then return nil end
  return Types.get(State.id)
end

function State.channel(key)
  local v = State.ch[key]
  if type(v) ~= "number" or v ~= v then return 0 end
  if V.questLitePrivate and State.id=='STORM' then
    local front=V.require('QuestStormFront')
    if front.managed and (key=='rain' or key=='dim' or key=='gust' or key=='strike')then
      v=v*front.coverage
      if key=='gust' then v=math.max(v,(front.warning or 0)*.75) end
    end
  end
  return v
end

-- ------- the tick

-- Seconds for a channel to cover most of the distance to its target.  Fog
-- rolls in slowly, rain starts and stops briskly, and the light changes
-- fastest of all because the sky darkening ahead of a storm is the cue
-- that sells it.  Scaled by config.transitionSeconds.
local TAU = {
  rain = 2.8, rainSpeed = 2.2, rainLen = 1.6, rainAngle = 1.8, splash = 1.4,
  snow = 3.4, snowSpeed = 2.6, snowDrift = 2.8,
  hail = 2.4, sand = 3.0, debris = 2.8, ash = 3.6,
  fog = 3.8, fogSpeed = 3.2, veil = 3.2,
  dim = 2.0, cool = 2.2, warm = 2.2, glare = 1.8,
  gust = 2.4, strike = 1.6,
}
local TAU_CLEAR_OUT = {
  fog = 0.12, fogSpeed = 0.12, veil = 0.10, dim = 0.35,
}
local TAU_DEFAULT = 1.0

local function ease(current, target, dt, tau)
  if current == target then return target end
  -- Exponential approach: frame-rate independent, and it cannot overshoot
  -- however large dt is, which a linear step toward a target can.
  local k = 1 - math.exp(-dt / tau)
  local next_ = current + (target - current) * k
  if math.abs(target - next_) < 0.0005 then return target end
  return next_
end

-- Channels that are AMOUNTS (and so scale with intensity/density) rather
-- than rates, angles or counts (which must not).
local AMOUNT = {
  rain = true, snow = true, hail = true, sand = true, debris = true,
  fog = true, veil = true, dim = true, splash = true, warm = true,
  cool = true, glare = true,
}

-- Resolve the weather this frame should be heading toward, and say who
-- decided.  Returns nil to mean "leave it alone" (AUTO between rolls).
local function resolveTarget(mapId, indoors)
  local cfg = Config.get()

  -- The diagnostic switch outranks everything, including `force`: its job
  -- is to answer "is this mod working", and an answer that could itself be
  -- overridden would not be an answer.
  if Settings.debugRain(Config) then
    State.pinnedBy = "debug"
    State.overrideMap = nil
    return "RAIN_HEAVY", true
  end

  if cfg.force then
    State.pinnedBy = "config"
    State.overrideMap = nil
    return cfg.force, true
  end

  -- The ALWAYS row: the same "pin one weather everywhere" as config.force,
  -- from the mod manager instead of a text file.  Below `force` rather
  -- than above it because the file is the deliberate per-playthrough
  -- setting and the row is the convenient one -- and a player who set both
  -- is better served by the one that took more effort to express.
  local always = Settings.alwaysWeather()
  if always then
    State.pinnedBy = "always"
    State.overrideMap = nil
    return always, true
  end

  -- WHO OUTRANKS WHOM, and why this order.
  --
  -- The ladder rung is read FIRST when it names a weather, because that
  -- rung is the player standing in the OPTIONS menu choosing a sky. A
  -- location override is a default for the unattended case -- it says
  -- "Lavender Town is usually foggy", not "Lavender Town is always foggy
  -- no matter what you asked for".
  --
  -- Reported from play: PRIML pinned on the row, and the sky (and so the
  -- battle) was the map's weather instead. Reading the override first made
  -- every certainty override a silent veto on the menu, and the player has
  -- no way to see why the row they just moved did nothing.
  --
  -- AUTO and CYCLE are NOT the player naming a weather, so they fall
  -- through to the override below exactly as before.
  local rung = State.LEVEL_IDS[State.level + 1]
  if rung ~= nil and rung ~= false and rung ~= "AUTO" and rung ~= "CYCLE" then
    State.overrideMap = nil
    State.mode = "PIN"
    State.pinnedBy = "menu"
    return rung, false
  end

  if V.questLitePrivate then
    local front=V.require('QuestStormFront')
    if front.managed and front.cell then
      State.pinnedBy='quest-front';State.overrideMap=nil
      return 'STORM',false
    end
  end
  local override = Config.locationFor(mapId, indoors)
  if V.questLitePrivate and rung=='AUTO' and not override then
    local snow=V.require('QuestMountainSnow').target(mapId,indoors)
    if snow then State.pinnedBy='mountain-snow';State.overrideMap=nil;return snow,true end
    if State.pinnedBy=='mountain-snow' then
      State.pinnedBy='auto';return 'CLEAR',false
    end
  end
  if override then
    if override.chance >= 1 then
      State.pinnedBy = "location"
      State.overrideMap = mapId
      return override.weather, true
    end
    -- A chance override is rolled ONCE per arrival, not per frame: the
    -- map is remembered, so walking in and out re-rolls but standing
    -- still does not flicker.
    if State.overrideMap ~= mapId then
      State.overrideMap = mapId
      if rand() < override.chance then
        State.pinnedBy = "location"
        return override.weather, true
      end
      State.pinnedBy = "auto"
    elseif State.pinnedBy == "location" then
      return override.weather, true
    end
  else
    State.overrideMap = nil
  end

  if rung == "CYCLE" then
    State.mode = "CYCLE"
    State.pinnedBy = "cycle"
    return nil, false
  end

  -- THE PSYSTORM, which is not weather but a reaction to what is standing
  -- here.  Above the front -- when Mewtwo's cave is storming and the
  -- region's front says fog, the cave wins -- and below anything the
  -- player or the config asked for explicitly.  The front is only
  -- overruled, never overwritten, so it resumes on the way out.
  local psy = Psystorm.weatherFor(mapId)
  if psy then
    State.pinnedBy = "psystorm"
    return psy, true
  end

  -- A BIRD, if one has stirred here.  Below the psystorm, which is a place
  -- reacting to what is standing in it, and above the region's front,
  -- which is only the ordinary sky.  Like the psystorm it overrules the
  -- front rather than overwriting it, so the front resumes on the way out.
  local bird = getLegendary().update(mapId, indoors)
  if bird then
    State.pinnedBy = "legend"
    return bird, true
  end

  -- THE FRONT OVER THIS MAP, if there is one.
  --
  -- Below everything the player or the config asked for explicitly --
  -- force, a location override, a pinned rung -- and above the global AUTO
  -- clock, which is what it replaces.  A map in no region (every interior,
  -- and anywhere the region table does not reach) falls through to AUTO
  -- exactly as before, so nothing is lost where fronts do not apply.
  --
  -- `parksClock` is true: the global clock must not keep rolling
  -- underneath, or leaving a front's region would drop the player into a
  -- stale global weather that had been advancing unseen.
  State.mode = "AUTO"
  local front = Fronts.weatherFor(mapId)
  if front then
    State.pinnedBy = "front"
    return front, true
  end

  State.pinnedBy = "auto"
  return nil, false
end

-- The whole per-frame job.  `level` is the ladder rung the engine hands
-- the pipeline; everything below keys off it, including doing nothing at 0.
function State.update(dt, level, mapId, indoors)
  State.indoors = indoors and true or false
  if Settings.worldWeatherEnabled and not Settings.worldWeatherEnabled() then
    State.id="CLEAR"
    State.level=0
    State.left=0
    if type(State.ch)=="table" then
      for k in pairs(State.ch) do State.ch[k]=0 end
    end
    return
  end
  dt = tonumber(dt) or 0
  if dt < 0 or dt ~= dt then dt = 0 end
  if dt > 0.25 then dt = 0.25 end   -- a load hitch is not eight seconds of weather
  if type(State.ch) ~= "table" then State.ch = {} end
  if type(State.id) ~= "string" or State.id == "" then
    State.id = (Types and Types.DEFAULT) or "CLEAR"
  end

  local wasOff = (State.level or 0) <= 0
  State.level = level or 0
  if wasOff and State.level > 0 then State.fresh = true end

  -- NOTE: debug rain does NOT fake a level here, and 2.0.1's attempt to
  -- was a real bug.  The engine gates every pipeline stage on
  -- Pipelines.level() before it asks this mod anything, so an internal
  -- override pinned the weather and eased every channel while drawing
  -- nothing at all.  lib/Ladder.lua moves the engine's own number instead.

  if State.level <= 0 then
    -- OFF: no clock, no easing, no draw.  Channels are zeroed ONCE on the
    -- way out -- `dirty` is what makes it once rather than every frame --
    -- so switching back on starts from a clear sky rather than from
    -- wherever the last session's storm had got to, and a session spent
    -- at OFF costs one comparison per frame.
    if State.dirty then
      for _, key in ipairs(Types.channels) do State.ch[key] = 0 end
      State.dirty = false
    end
    return
  end

  State.elapsed = State.elapsed + dt

  -- Boot / load: kill any residual 2D fog bank unless weather is fog-family.
  if State._bootSnapFog then
    State._bootSnapFog = false
    if not State.isFogWeather(State.id) then
      State.ch.fog = 0
      State.ch.veil = 0
      State.ch.fogSpeed = 0
    end
  end

  -- ---- Indoor / cave weather gate (overworld) ----
  -- Weather is fully off inside buildings and caves. On exit: resume the
  -- same sky if the stay was under 5 minutes; otherwise allow a new pick.
  local INDOOR_CHANGE_SEC = 5 * 60
  if indoors then
    if not State._wasIndoors then
      State._wasIndoors = true
      State._indoorAccum = 0
      State._pausedWeatherId = State.id
    end
    State._indoorAccum = (State._indoorAccum or 0) + (tonumber(dt) or 0)
    -- No precipitation / residual channels while indoors.
    for _, key in ipairs(Types.channels) do State.ch[key] = 0 end
    State.dirty = true
    -- Still sample map id so exit transition is detected.
    State.lastMapId = mapId
    -- Fronts keep regional state but do not drive visible weather here.
    Fronts.update(dt, Settings.speedScale())
    local L = getLegendary()
    L.speedScale = Settings.speedScale()
    L.tick(dt)
    return
  elseif State._wasIndoors then
    local stayed = State._indoorAccum or 0
    local paused = State._pausedWeatherId
    State._wasIndoors = false
    State._indoorAccum = 0
    State._pausedWeatherId = nil
    -- Channels already 0 from indoor gate; ease back up (no settle jump).
    if stayed >= INDOOR_CHANGE_SEC then
      local exclude = paused
      local nxt = State.pick(mapId, exclude)
      if nxt and nxt ~= paused then
        State.id = nxt
        State.softFrom, State.softTo = nil, nil
        State.softT, State.softDur = 0, 0
        State.mapsTowardCommit = 0
        State.persist()
      elseif paused then
        State.id = paused
        State.persist()
      end
    else
      if paused then
        State.id = paused
        State.softFrom, State.softTo = nil, nil
        State.softT, State.softDur = 0, 0
        State.persist()
      end
    end
    State.markGentleIntro(5.5)
  end

  -- Every region ticks, not just the one underfoot: a front the player
  -- walked out of has to keep running, and the Pokegear card shows skies
  -- over places they are not standing in.
  Fronts.update(dt, Settings.speedScale())
  -- Ticked here beside the front clock because this is where dt exists;
  -- resolveTarget below has no dt, and a tick placed there silently never
  -- expired anything.
  -- the scale is read at ARM time inside Legendary; handing it over here
  -- keeps Legendary free of a Settings dependency
  local L = getLegendary()
  L.speedScale = Settings.speedScale()
  L.tick(dt)
  -- TOD.update is NOT called here.  The clock belongs to the TIME
  -- pipeline, whose update runs whatever the weather ladder is doing --
  -- otherwise turning weather off would stop time, which is exactly the
  -- bug that welding the two together caused in the first place.  Calling
  -- it in both places would also double the cycle rate.

  local mapChanged = (mapId ~= nil and State.lastMapId ~= nil and mapId ~= State.lastMapId)
  if mapChanged and State.softTo then
    State.mapsTowardCommit = (State.mapsTowardCommit or 0) + 1
  end
  State.lastMapId = mapId
  local target, parksClock = resolveTarget(mapId, indoors)

  -- First outdoor moment this session: weather may begin.
  -- Indoor/cave loads keep channels at 0 until this runs.
  if (State._needOutdoorStart or State._sessionStart) and not indoors then
    State._needOutdoorStart = false
    local always = Settings.alwaysWeather and Settings.alwaysWeather()
    local cfgForce = Config.get() and Config.get().force
    -- Gradual start: set weather id, keep channels at 0, ease ramps intensity.
    -- Never settle() here — that caused the visible jump on load/outdoor entry.
    if always or cfgForce then
      local id = cfgForce or always
      State.id = Types.get(id).id
      State.pinnedBy = cfgForce and "force" or "always"
      State.softFrom, State.softTo = nil, nil
      State.softT, State.softDur = 0, 0
      State._sessionStart = false
      State.clearChannels()
      State.markGentleIntro(7.0)
      State.persist()
    elseif State._sessionStart then
      State._sessionStart = false
      local rung = State.LEVEL_IDS[(State.level or 0) + 1]
      if rung == "AUTO" or rung == nil or rung == false then
        local nextId = State.pick(mapId, nil)
        if nextId then
          State.id = nextId
          State.left = dwellFor(Types.get(nextId))
          State.softFrom, State.softTo = nil, nil
          State.softT, State.softDur = 0, 0
          State.pinnedBy = "auto"
          State.clearChannels()
          State.markGentleIntro(7.0)
          State.persist()
        end
      elseif type(rung) == "string" and rung ~= "CYCLE" then
        State.id = Types.get(rung).id
        State.pinnedBy = "menu"
        State.softFrom, State.softTo = nil, nil
        State.clearChannels()
        State.markGentleIntro(7.0)
        State.persist()
      else
        State.clearChannels()
        State.markGentleIntro(7.0)
      end
    else
      State.clearChannels()
      State.markGentleIntro(6.0)
    end
  end


  local function hardSetWeather(id)
    if not id then return end
    State.id = id
    State.softFrom, State.softTo = nil, nil
    State.softT, State.softDur = 0, 0
    State.mapsTowardCommit = 0
    State.persist()
  end

  local function beginSoftWeather(toId)
    if not toId or toId == State.id then
      if toId == State.id then
        State.softFrom, State.softTo = nil, nil
        State.softT, State.softDur = 0, 0
        State.mapsTowardCommit = 0
      end
      return
    end
    if State.softTo == toId then return end
    State.softFrom = State.id
    State.softTo = toId
    State.softT = 0
    State.mapsTowardCommit = 0
    local base = tonumber(Config.get().transitionSeconds) or 3.2
    -- Long overlapping crossfade: outgoing weather stays visible while the
    -- next sky builds in so the world never goes "empty" between spells.
    State.softDur = math.max(32.0, base * 10.0)
  end

  -- Menu pin / force / legend / psystorm: snap. Fronts & soft location: blend.
  local HARD_PIN = {
    force = true, always = true, menu = true,
    pin = true, legend = true, psystorm = true,
  }

  if target then
    if HARD_PIN[State.pinnedBy or ""] then
      if State.id ~= target then
        hardSetWeather(target)
        -- Ease channels toward the new pin (no hard jump)
        State.markGentleIntro(4.0)
      end
    else
      beginSoftWeather(target)
    end
    if not parksClock then State.left = math.max(State.left or 0, 0) end
  elseif State.mode == "CYCLE" then
    -- Soft-rotate: next catalogue weather blends in over the current one.
    if not State.softTo then
      State.left = (State.left or 0) - dt
      if State.left <= 0 then
        local nextId = nextInCycle()
        State.fresh = false
        beginSoftWeather(nextId)
        State.left = dwellFor(Types.get(nextId or State.id))
        State.persist()
      end
    end
  else
    -- AUTO: soft crossfade into the next pick (never hard-cut the sky).
    if not State.softTo then
      State.left = (State.left or 0) - dt
      if State.left <= 0 then
        local nextId = State.pick(mapId, State.fresh and Types.DEFAULT or nil)
        State.fresh = false
        beginSoftWeather(nextId)
        State.left = dwellFor(Types.get(nextId or State.id))
        State.persist()
      end
    end
  end

  -- Soft weather handoff: advance blend; commit after time or a few maps.
  if State.softTo then
    State.softT = (State.softT or 0) + dt
    local dur = State.softDur or 32
    -- Prefer full duration so both weathers overlap; maps only help after most of the blend.
    local maps = State.mapsTowardCommit or 0
    local ready = (State.softT >= dur) or (maps >= 3 and State.softT >= dur * 0.72)
    if ready then
      State.id = State.softTo
      State.softFrom, State.softTo = nil, nil
      State.softT, State.softDur = 0, 0
      State.mapsTowardCommit = 0
      State.left = dwellFor(Types.get(State.id))
      State.persist()
    end
  end

  -- ease every channel toward the active weather (or a blend mid-handoff)
  local def = Types.get(State.id)
  local defTo = State.softTo and Types.get(State.softTo) or nil
  local blendU = 0
  if defTo and State.softDur and State.softDur > 0 then
    blendU = math.min(1, math.max(0, (State.softT or 0) / State.softDur))
    -- Smoothstep so mixes (snow+fog, snow+ash) read as weather, not a cut.
    blendU = blendU * blendU * (3 - 2 * blendU)
  end
  local tuning = Config.tuningFor(def.id)
  local amount = Settings.intensity() * (tuning.intensity or 1)
  local speed = tuning.speed or 1
  -- AUTO intensity multiplies on top, per FAMILY rather than globally, so
  -- the rain, the fog and the lightning breathe on unrelated rhythms
  -- instead of swelling together (which would read as the brightness
  -- being turned up and down).  Computed once per frame per family, not
  -- per channel: five sines a frame, not fifteen.
  local familyScale = nil
  if Settings.get("intensity") == "auto" then
    familyScale = {}
    for family in pairs(Settings.AUTO_FAMILIES) do
      familyScale[family] = Settings.autoScale(family, State.elapsed, Config)
    end
  end
  local tauScale = math.max(0.05, (Config.get().transitionSeconds or 3.2) / 3.2)
  if State._gentleIntro and State._gentleIntro > 0 then
    State._gentleIntro = State._gentleIntro - (tonumber(dt) or 0)
    if State._gentleIntro < 0 then State._gentleIntro = 0 end
    -- Slower approach during intro so weather builds in instead of popping
    tauScale = tauScale * 1.85
  end
  for _, key in ipairs(Types.channels) do
    -- INTENSITY scales the TARGET, not the drawn result, so turning it
    -- down makes a storm genuinely lighter rather than making a full storm
    -- transparent -- and channels that are not amounts (fall speed, lean
    -- angle, strikes per minute) are left alone by it.
    local goal = Types.channel(def, key)
    if defTo and blendU > 0 then
      local goalB = Types.channel(defTo, key)
      -- Overlap weights: outgoing holds through mid-blend; incoming starts early.
      -- Weather never fully stops before the next has begun.
      local u = blendU
      local outW = 1.0 - (u * u)                 -- slow ease-out
      local inW = u * (2.0 - u)                  -- fast ease-in
      if inW > 1 then inW = 1 end
      if outW < 0 then outW = 0 end
      local mixed = goal * outW + goalB * inW
      -- Keep precip/atmosphere from dipping to a dead gap mid-swap
      if AMOUNT[key] then
        local floor = math.max(goal * outW, goalB * inW)
        goal = math.max(mixed, floor)
      else
        goal = mixed
      end
    end
    local family = familyScale and Settings.CHANNEL_FAMILY[key]
    if AMOUNT[key] then
      local scale = amount * (family and familyScale[family] or 1)
      local id = State.id
      local sandMul = 1
      local dustMul = 1
      if Settings.sandIntensity then sandMul = Settings.sandIntensity() or 1 end
      if Settings.dustIntensity then dustMul = Settings.dustIntensity() or 1 end
      local fogMul = 1
      if Settings.fogIntensity then fogMul = Settings.fogIntensity() or 1 end
      if Settings.fogOff and Settings.fogOff() then fogMul = 0 end

      if key == "sand" then
        -- SAND INTENSITY / DUST INTENSITY scale particles; cap unchanged (2.0).
        if id == "SANDSTORM" then
          if sandMul <= 0 then goal = 0
          else goal = math.min(2.0, goal * scale * sandMul) end
        elseif id == "DUSTSTORM" then
          if dustMul <= 0 then goal = 0
          else goal = math.min(2.0, goal * scale * dustMul) end
        else
          goal = math.min(2.0, goal * scale)
        end
      elseif key == "fog" or key == "veil" then
        -- Fog-family: FOG INTENSITY. Sand/dust: haze scaled by sand/dust + fog dials.
        -- Caps unchanged (20.0 max).
        if State.isFogWeather(id) then
          if fogMul <= 0 then goal = 0
          else goal = math.min(20.0, goal * scale * fogMul) end
        elseif id == "SANDSTORM" then
          -- Haze toward 25% visibility at 500% (sandHaze 0..0.75 → strong fog).
          local haze = 0
          if Settings.sandHaze then haze = Settings.sandHaze() or 0 end
          if sandMul <= 0 or haze <= 0 then goal = 0
          else
            local m = (0.4 + haze * 12.0) * (fogMul > 0 and math.max(0.25, fogMul) or 1)
            goal = math.min(20.0, goal * scale * m)
          end
        elseif id == "DUSTSTORM" then
          local haze = 0
          if Settings.dustHaze then haze = Settings.dustHaze() or 0 end
          if dustMul <= 0 or haze <= 0 then goal = 0
          else
            local m = (0.4 + haze * 12.0) * (fogMul > 0 and math.max(0.25, fogMul) or 1)
            goal = math.min(20.0, goal * scale * m)
          end
        else
          goal = 0
        end
      elseif key == "dim" and (id == "SANDSTORM" or id == "DUSTSTORM") then
        -- Sand/dust must not darken the screen; visibility is haze/blur only.
        goal = 0
      else
        goal = math.min(2.0, goal * scale)
      end
    elseif key == "rainSpeed" or key == "snowSpeed" or key == "fogSpeed" then
      goal = goal * speed
    elseif family then
      -- `strike` is a RATE, not an amount, so it is not scaled by
      -- INTENSITY -- but it is exactly the thing that should cluster and
      -- go quiet under AUTO, so the family multiplier reaches it here.
      goal = goal * familyScale[family]
    end
    local tau = (TAU[key] or TAU_DEFAULT) * tauScale
    if goal <= 0.0001 and TAU_CLEAR_OUT[key] then
      tau = TAU_CLEAR_OUT[key] * tauScale
    end
    State.ch[key] = ease(State.ch[key] or 0, goal, dt, tau)
  end
  State.dirty = true
end

-- ------- persistence

function State.persist()
  Fronts.persist()
  local ok = pcall(function()
    mod.save:set("id", State.id)
    mod.save:set("left", math.floor(State.left or 0))
  end)
  if not ok then
    -- A save bucket that will not take a write is not worth a crash inside
    -- a render tick; the weather simply will not survive the session.
    mod.log:warn("could not write weather state to the mod save")
  end
end

function State.restore()
  local ok = pcall(function()
    local id = mod.save:get("id", Types.DEFAULT)
    local left = tonumber(mod.save:get("left", 0)) or 0
    State.id = Types.get(id).id       -- unknown ids degrade to CLEAR
    State.left = math.max(0, left)
  end)
  if not ok then
    State.id = Types.DEFAULT
    State.left = 0
  end
  State.overrideMap = nil
  Fronts.restore()

  -- Start on exactly what the player set:
  --   ALWAYS / config.force → that weather, snapped now
  --   AUTO → random pick on first outdoor tick (_sessionStart)
  --   CYCLE → continues from catalogue
  local forced = nil
  pcall(function()
    local cfg = Config.get()
    if cfg and cfg.force then forced = cfg.force end
  end)
  if not forced and Settings.alwaysWeather then
    forced = Settings.alwaysWeather()
  end
  if forced and Types.get(forced) then
    State.id = Types.get(forced).id
    State.pinnedBy = (Config.get() and Config.get().force) and "force" or "always"
    State.left = 0
    State.softFrom, State.softTo = nil, nil
    State.softT, State.softDur = 0, 0
    State._sessionStart = false
  else
    -- AUTO (or unpinned): pick a random weather on first *outdoor* tick
    State._sessionStart = true
  end

  -- Store intended weather id, but do NOT paint the sky until we know the
  -- player is outdoors. Loading in a cave/building must start with no weather.
  State.settle()
  for _, key in ipairs(Types.channels) do
    State.ch[key] = 0
  end
  State._needOutdoorStart = true
  State._bootSnapFog = true
  State.dirty = true
end

-- ------- for the debug row and the battle layer

function State.describe()
  if State.indoors then return "INDOORS CLEAR" end
  local def = State.current()
  local rung = State.LEVEL_IDS[(State.level or 0) + 1]
  if rung == false then
    -- Say WHY nothing is happening.  A config with `force` set and the
    -- OPTIONS row on OFF is the single most confusing state this mod can
    -- be in, and a readout that just says "OFF" makes the player hunt for
    -- a bug that is one menu row away.
    if Config.get().force then return "OFF (force ignored - row is OFF)" end
    return "OFF (row is OFF)"
  end
  if State.pinnedBy == "front" then
    return ("FRONT %s"):format(Fronts.describe(State.lastMapId))
  end
  if State.pinnedBy == "auto" or State.pinnedBy == "cycle" then
    return ("%s %s %ds"):format(State.pinnedBy:upper(), def.label,
      math.floor(State.left or 0))
  end
  return ("%s %s"):format(State.pinnedBy:upper(), def.label)
end

return State
