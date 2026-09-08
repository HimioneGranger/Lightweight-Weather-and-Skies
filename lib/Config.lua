-- CONFIGURATION: loading config.lua, checking it, and deciding what wins.
--
-- WHY A FILE AND A MENU, NOT ONE OR THE OTHER.  They answer different
-- questions.  The menu answers "what do I want to see right now" and has
-- to be reachable on a handheld with no keyboard, so it is short.  The
-- file answers "how should this mod behave in my playthrough" -- per-map
-- overrides, per-weather density, which battle effects exist -- and none
-- of that belongs on a row the player cycles with a d-pad.  So both, with
-- one documented precedence order and no third place for a value to hide:
--
--   1. config.force        -- the file pins one weather everywhere
--   2. config.locations    -- the file pins one weather on this map
--   3. the OPTIONS row     -- OFF / AUTO / a pinned weather
--   4. the AUTO clock
--
-- WHY IT CANNOT BREAK THE MOD.  The file is loaded with `load`, called in
-- a pcall, and then walked against the default table: every key is
-- checked for type and range, and anything wrong is replaced by the
-- default and reported by name through mod.log (which the mod manager's
-- error feed shows).  A missing file, an empty file, a syntax error, a
-- table of nonsense -- all of them end with a usable config and a running
-- mod, because a player editing a config file is the single most likely
-- way this mod ever sees malformed input.
--
-- WHAT IS NOT VALIDATED is map ids in `locations`.  There is no list of
-- them to check against that would still be right after a map mod loads,
-- and a typo'd map id is self-diagnosing (the weather does not appear
-- there).  Weather ids inside those entries ARE checked, because those
-- fail silently otherwise.

local V = ...
local mod = V.mod
local Types = V.require("Types")

local Config = {}

Config.FILE = "config.lua"

-- ------- defaults
--
-- The shape below is authoritative: the validator walks THIS table and
-- copies matching keys out of the user's, so a key the defaults do not
-- have is reported as unknown rather than silently carried.  That makes a
-- typo ("lightingMode") a message instead of a mystery.

local DEFAULTS = {
  force = nil,
  locations = {},
  bias = {},
  tuning = { ALL = { density = 1, intensity = 1, speed = 1, duration = 1, weight = 1 } },
  weathers = {},
  indoorMaps = {
    OAKS_LAB=true, OAKSLAB=true, OAK_LAB=true, ELMS_LAB=true,
    SSAnne1F=true, SSAnne2F=true, SSAnne3F=true, SSAnneB1F=true,
    SSAnneBow=true, SSAnneKitchen=true, SSAnneCaptainsRoom=true,
    SSAnne1FRooms=true, SSAnne2FRooms=true,
    SSANNE1F=true, SSANNE2F=true, SSANNE3F=true, SSANNEB1F=true,
    SSANNEBOW=true, SSANNEKITCHEN=true, SSANNECAPTAINSROOM=true,
    SSANNE1FROOMS=true, SSANNE2FROOMS=true,
  },
  visuals = {
    precipitation = true, splashes = true, fog = true, veil = true,
    tint = true, glare = true, lightning = true, battleWeather = true,
    textBoxClear = true,
    puddles = true,
  },
  coverage = "screen",
  battleView = "auto",
  battleBackdrops = true,
  battleFieldArt = "auto",
  encounters = { enabled = true, species = true, fishing = true,
                 strength = 1.0, fishingBonus = 0.5,
                 expandedHabitats = true, expandedChance = 0.22,
                 -- When the map's table has no matching type, inject a dex
                 -- species of the favoured type at the rolled level.  Pool
                 -- is the merged pokemon registry (expanded dex included).
                 inject = false, injectChance = 0.35 },
  weatherVariants = {
    enabled = true, encounterChance = 0.03,
    commonChance = 0.05, rareChance = 0.03,
    veryRareChance = 0.01, legendaryChance = 0.005,
  },
  -- : how long a roused bird holds the sky. Without it a rousing
  -- only ended by leaving the map, so standing still froze the weather.
  legendary = { enabled = true, chance = 0.05, encounters = true,
                rateBoost = 1.0, encounterChance = 0.005,
                level = 50, minutes = 6 },
  psystorm = { enabled = true, carrierChance = 0.7, scale = 1.0 },
  fronts = { enabled = true, drift = 0.5 },
  pokegear = { enabled = true },
  audio = { enabled = true, volume = 1.0, indoors = 0, battle = 0.35,
            fadeSeconds = 2.5, thunder = true, thunderGain = 0.8,
            wind = true },
  tornado = { enabled = true, everySeconds = 240, minVisited = 4,
              sandstorms = true, funnel = true, funnelSeconds = 2.5 },
  followerChip = { enabled = true, seconds = 6, fraction = 1/32, canFaint = false },
  battleBackdropDim = 0.25,
  autoIntensity = { min = 0.5, max = 1.4, seconds = 1.0 },
  splashSpread = 1.0,
  lightningMode = "full",
  time = {
    source = "system", cycleMinutes = 24, fixedPhase = "DAY",
    grade = true, gradeStrength = 1.0, publishTod = true, indoors = 0.35,
  },
  -- Seasons sit on top of the day/night clock.  enabled/notify can also be
  -- flipped from the mod options page; the file is the set-once default.
  seasons = {
    enabled = true,
    notify = true,
    notifySeconds = 3.5,
    daysPerSeason = 28,   -- in-game days per season when not on SYSTEM time
    placeBanner = true,   -- location + season on map entry / game entry
  },
  battle = {
    enabled = true,
    seedFromOverworld = true,
    requireRuleset = true,
    seededTurns = nil,
    effects = {
      typePower = true, accuracy = true, solarBeam = true,
      weatherBall = true, residual = true, defenseBoost = true,
      speed = true, evasion = true, healing = true, forms = true,
      heldItems = true,
      -- Both are house rules rather than reference behaviour, so they
      -- carry their own switches instead of riding on typePower.
      --
      -- They default differently on purpose. `amplified` CONTRADICTS
      -- reference multipliers this mod already implements and tests
      -- ("...but physical damage is untouched" asserts a sandstorm does
      -- not power up ROCK), so switching it on by default would mean the
      -- mod quietly stopped doing what its own suite says it does --
      -- opt-in. `terrain` ADDS something the reference has no opinion on
      -- at all and only fires on named maps, so it contradicts nothing --
      -- on by default.
      amplified = false, terrain = true,
      -- the opening lines naming what the weather is doing to the fight
      announce = true,
    },
    -- Per-map type multipliers, applied whatever the weather.  Keys are
    -- map ids; a map with no entry gets nothing.  These ids are verified
    -- against tools/rom_manifest.json; ids the player adds are not checked
    -- at runtime and fail silently if wrong, which is what the DEBUG HUD's
    -- `map:`/`terr:` readout is for.
    terrain = {
      VIRIDIAN_FOREST = { BUG = 1.5, GRASS = 1.5 },
      POWER_PLANT     = { ELECTRIC = 1.5 },
      POKEMON_TOWER_1F = { GHOST = 1.5 },
      POKEMON_TOWER_2F = { GHOST = 1.5 },
      POKEMON_TOWER_3F = { GHOST = 1.5 },
      POKEMON_TOWER_4F = { GHOST = 1.5 },
      POKEMON_TOWER_5F = { GHOST = 1.5 },
      POKEMON_TOWER_6F = { GHOST = 1.5 },
      POKEMON_TOWER_7F = { GHOST = 1.5 },
      -- ------- Johto (Gold), verified against tools/rom_manifest_gold.json
      --
      -- The Kanto ids above mostly do NOT exist on Gold: only 76 of Gen 1's
      -- 222 maps survive into it, and Pokemon Tower (a Radio Tower by then)
      -- and Viridian Forest are not among them. Left alone, eight of the ten
      -- entries above would have been silently dead on a Gold boot -- the
      -- same failure that killed them once already under a misspelt id.
      --
      -- Both sets ship together because the table is keyed by MAP ID: an id
      -- that does not exist in the running game simply never matches, so the
      -- Johto rows cost a Kanto game nothing and vice versa.
      ILEX_FOREST      = { BUG = 1.5, GRASS = 1.5 },   -- Johto's Viridian Forest
      SPROUT_TOWER_1F  = { GHOST = 1.5 },
      SPROUT_TOWER_2F  = { GHOST = 1.5 },
      SPROUT_TOWER_3F  = { GHOST = 1.5 },
      BURNED_TOWER_1F  = { GHOST = 1.5 },              -- the Johto ghost site
      BURNED_TOWER_B1F = { GHOST = 1.5 },
      -- POWER_PLANT is in both games under the same id, so it needs no twin.
    },
    residualDamage = {
      fraction = 1 / 16, canFaint = true,
      sandImmune = { "ROCK", "GROUND", "STEEL" },
      psyImmune = { "PSYCHIC" },
      hailImmune = { "ICE" },
    },
    suppressAbilities = { "CLOUD_NINE" },
    items = {
      extenders = {
        DAMP_ROCK = "RAINY", HEAT_ROCK = "SUNNY",
        ICY_ROCK = "HAIL", SMOOTH_ROCK = "SANDSTORM",
      },
      extendBy = 3,
      umbrella = "UTILITY_UMBRELLA",
    },
  },
  quality = "auto",
  maxParticles = nil,
  transitionSeconds = 4.8,
  debug = false,
  debugRain = false,
}

-- Ranges for the numeric keys, by dotted path.  Anything outside is
-- clamped and reported rather than rejected: a player who wrote
-- `density = 50` wants "a lot", and clamping to 3 gives them that.
local RANGES = {
  ["tuning.*.density"] = { 0, 3 },
  ["tuning.*.intensity"] = { 0, 3 },
  ["tuning.*.speed"] = { 0.25, 3 },
  ["tuning.*.duration"] = { 0.1, 10 },
  ["tuning.*.weight"] = { 0, 20 },
  ["time.cycleMinutes"] = { 0.5, 1440 },
  ["time.gradeStrength"] = { 0, 2 },
  ["time.indoors"] = { 0, 1 },
  ["battle.residualDamage.fraction"] = { 0, 0.5 },
  ["battle.items.extendBy"] = { 0, 20 },
  ["transitionSeconds"] = { 0.1, 60 },
  ["autoIntensity.min"] = { 0, 2 },
  ["autoIntensity.max"] = { 0, 3 },
  ["autoIntensity.seconds"] = { 0.05, 20 },
  ["splashSpread"] = { 0, 1 },
  ["legendary.chance"] = { 0, 1 },
  ["legendary.encounterChance"] = { 0, 1 },
  ["legendary.level"] = { 1, 100 },
  ["psystorm.carrierChance"] = { 0, 1 },
  ["psystorm.scale"] = { 0, 1 },
  ["fronts.drift"] = { 0, 1 },
  ["audio.volume"] = { 0, 2 },
  ["audio.indoors"] = { 0, 1 },
  ["audio.battle"] = { 0, 1 },
  ["audio.fadeSeconds"] = { 0.2, 20 },
  ["audio.thunderGain"] = { 0, 2 },
  ["tornado.everySeconds"] = { 30, 3600 },
  ["tornado.minVisited"] = { 2, 60 },
  ["tornado.funnelSeconds"] = { 0, 10 },
  ["encounters.strength"] = { 0, 3 },
  ["encounters.fishingBonus"] = { 0, 1 },
  ["encounters.injectChance"] = { 0, 1 },
  ["encounters.expandedChance"] = { 0, 1 },
  ["weatherVariants.encounterChance"] = { 0, 1 },
  ["weatherVariants.commonChance"] = { 0, 1 },
  ["weatherVariants.rareChance"] = { 0, 1 },
  ["weatherVariants.veryRareChance"] = { 0, 1 },
  ["weatherVariants.legendaryChance"] = { 0, 1 },
  ["followerChip.seconds"] = { 1, 600 },
  ["followerChip.fraction"] = { 0, 0.25 },
  ["battleBackdropDim"] = { 0, 1 },
  ["maxParticles"] = { 0, 20000 },
}

-- Keys whose DEFAULT is nil, so the merge cannot infer their type from the
-- default table.  Without this list every one of them would be reported as
-- an unknown key -- which is exactly what "no default" looks like to a
-- table walk.  Listing them keeps the typo detection strict everywhere
-- else: a key that is neither in the defaults nor here really is a typo.
local OPTIONAL = {
  force = "string",
  maxParticles = "number",
  ["battle.seededTurns"] = "number",
}

local ENUMS = {
  ["coverage"] = { screen = true, playfield = true },
  ["battleView"] = { auto = true, canvas = true, screen = true },
  ["battleFieldArt"] = { auto = true, on = true, off = true, mono = true },
  ["lightningMode"] = { full = true, soft = true, off = true },
  ["quality"] = { auto = true, high = true, medium = true, low = true },
  ["time.source"] = { auto = true, system = true, cycle = true,
                      fixed = true, off = true },
  ["time.fixedPhase"] = { MORN = true, DAY = true, EVE = true, NITE = true },
}

-- ------- the live config, and the problems found loading it

Config.data = nil
Config.problems = {}
-- Whether config.lua was found and read at all.  Reported on the debug
-- readout, because "my edits do nothing" and "there is no file to edit"
-- look identical from the player's side -- and a .modpkg install has no
-- editable file at all.
Config.found = false

local function problem(fmt, ...)
  local line = select("#", ...) > 0 and fmt:format(...) or fmt
  Config.problems[#Config.problems + 1] = line
  mod.log:warn("config.lua: %s", line)
end

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopy(v) end
  return out
end

local function isWeatherId(id)
  return type(id) == "string" and Types.byId[id] ~= nil
end

-- Enum keys fall back to the default rather than being stored, so a
-- typo'd `coverage = "playfeild"` behaves like the default instead of
-- silently disabling a feature.  This table existed since 2.0.0 and was
-- never actually consulted -- a test asserting the hole is what found it.
local function checkEnum(path, value, default)
  local allowed = ENUMS[path]
  if not allowed then return value end
  if allowed[value] then return value end
  problem("%s = %s is not one of its allowed values; using %s",
    path, tostring(value), tostring(default))
  return default
end

local function clampPath(path, value)
  local range = RANGES[path]
  if not range or type(value) ~= "number" or value ~= value then return value end
  if value < range[1] then
    problem("%s = %s is below %s; clamped", path, tostring(value), tostring(range[1]))
    return range[1]
  end
  if value > range[2] then
    problem("%s = %s is above %s; clamped", path, tostring(value), tostring(range[2]))
    return range[2]
  end
  return value
end

-- Merge `user` over `base` in place, type-checking against `base`.
-- `wildcard` marks a level whose keys are user-chosen (tuning ids, map
-- ids), where an unknown key is data rather than a typo.
local function merge(base, user, path, wildcard)
  if type(user) ~= "table" then
    problem("%s should be a table; ignored", path ~= "" and path or "config")
    return base
  end
  for key, value in pairs(user) do
    local sub = (path == "" and tostring(key)) or (path .. "." .. tostring(key))
    local default = base[key]
    local optional = OPTIONAL[sub]
    if default == nil and optional then
      if type(value) ~= optional then
        problem("%s should be a %s, got %s; ignored", sub, optional, type(value))
      else
        base[key] = clampPath(sub, value)
      end
    elseif default == nil and not wildcard then
      problem("unknown key %s; ignored", sub)
    elseif type(default) == "table" and type(value) == "table" then
      -- one level of wildcard: the CHILDREN of tuning/locations/bias are
      -- user-named, their contents are not
      merge(default, value, sub, false)
    elseif type(default) == "table" and type(value) ~= "table" then
      problem("%s should be a table; ignored", sub)
    elseif default ~= nil and type(value) ~= type(default) then
      problem("%s should be a %s, got %s; ignored", sub, type(default), type(value))
    else
      base[key] = checkEnum(sub, clampPath(sub, value), default)
    end
  end
  return base
end

-- ------- entry-shape checks for the two user-keyed tables

local function normaliseLocation(mapId, entry)
  if type(entry) == "string" then
    entry = { weather = entry }
  elseif type(entry) ~= "table" then
    problem("locations.%s should be a weather id or a table; ignored", tostring(mapId))
    return nil
  end
  if not isWeatherId(entry.weather) then
    problem("locations.%s has unknown weather %q; ignored",
      tostring(mapId), tostring(entry.weather))
    return nil
  end
  local chance = tonumber(entry.chance)
  if chance == nil then chance = 1 end
  if chance < 0 then chance = 0 elseif chance > 1 then chance = 1 end
  return { weather = entry.weather, chance = chance,
           indoors = entry.indoors and true or false }
end

local function normaliseTuning(id, entry)
  if id ~= "ALL" and not isWeatherId(id) then
    problem("tuning.%s is not a weather id; ignored", tostring(id))
    return nil
  end
  if type(entry) ~= "table" then
    problem("tuning.%s should be a table; ignored", tostring(id))
    return nil
  end
  -- Clamped HERE rather than in the generic merge: these keys live under a
  -- user-chosen weather id, so their dotted path is not knowable in advance
  -- and the RANGES table addresses them through a `*` wildcard.
  local function one(key)
    local v = tonumber(entry[key])
    if v == nil then return 1 end
    return clampPath("tuning.*." .. key, v)
  end
  return { density = one("density"), intensity = one("intensity"),
           speed = one("speed"), duration = one("duration"),
           weight = one("weight") }
end

-- ------- load

function Config.load()
  Config.problems = {}
  local data = deepCopy(DEFAULTS)

  local source = nil
  local okRead = pcall(function() source = mod:read(Config.FILE) end)
  Config.found = (okRead and source ~= nil) and true or false
  if not okRead or not source then
    -- No config file is the normal case for a fresh install, not an error.
    Config.data = data
    Config.finalise(data)
    return data
  end

  local loadChunk = loadstring or load
  local chunk, err = loadChunk(source, "@" .. Config.FILE)
  if not chunk then
    problem("did not compile (%s); using defaults", tostring(err))
    Config.data = data
    Config.finalise(data)
    return data
  end

  -- The file is data, so it is run with no arguments and its return value
  -- is all that is kept.  A file that throws costs its own contents and
  -- nothing else.
  local okRun, user = pcall(chunk)
  if not okRun or type(user) ~= "table" then
    problem("did not return a table (%s); using defaults",
      tostring(okRun and type(user) or user))
    Config.data = data
    Config.finalise(data)
    return data
  end

  -- the user-keyed tables come out before the type-checked merge, because
  -- their keys are data and would every one be reported as unknown
  local locations, bias, tuning = user.locations, user.bias, user.tuning
  local weathers, indoorMaps = user.weathers, user.indoorMaps
  user.locations, user.bias, user.tuning = nil, nil, nil
  user.weathers, user.indoorMaps = nil, nil

  -- battle.terrain is keyed by MAP ID, so it comes out too: left in, the
  -- strict merge would report every map the player added as an unknown
  -- key and drop it.  Its own table, not `locations`, because a map can
  -- reasonably have both a weather override and a terrain bonus.
  local terrain = nil
  if type(user.battle) == "table" then
    terrain = user.battle.terrain
    user.battle.terrain = nil
  end

  merge(data, user, "", false)

  if locations ~= nil then
    data.locations = {}
    if type(locations) == "table" then
      for mapId, entry in pairs(locations) do
        local norm = normaliseLocation(mapId, entry)
        if norm then data.locations[mapId] = norm end
      end
    else
      problem("locations should be a table; ignored")
    end
  end

  if bias ~= nil then
    if type(bias) == "table" then data.bias = bias
    else problem("bias should be a table; ignored") end
  end

  if tuning ~= nil then
    data.tuning = { ALL = { density = 1, intensity = 1, speed = 1, duration = 1 } }
    if type(tuning) == "table" then
      for id, entry in pairs(tuning) do
        local norm = normaliseTuning(id, entry)
        if norm then data.tuning[id] = norm end
      end
    else
      problem("tuning should be a table; ignored")
    end
  end

  if weathers ~= nil then
    data.weathers = {}
    if type(weathers) == "table" then
      for id, on in pairs(weathers) do
        if not isWeatherId(id) then
          problem("weathers.%s is not a weather id; ignored", tostring(id))
        else
          data.weathers[id] = on and true or false
        end
      end
    else
      problem("weathers should be a table; ignored")
    end
  end

  if indoorMaps ~= nil then
    data.indoorMaps = {}
    if type(indoorMaps) == "table" then
      -- accepts either { "MAP_ID", ... } or { MAP_ID = true }
      for k, v in pairs(indoorMaps) do
        if type(k) == "number" and type(v) == "string" then
          data.indoorMaps[v] = true
        elseif type(k) == "string" then
          data.indoorMaps[k] = v and true or false
        end
      end
    else
      problem("indoorMaps should be a table; ignored")
    end
  end

  if terrain ~= nil then
    data.battle.terrain = {}
    if type(terrain) == "table" then
      for mapId, row in pairs(terrain) do
        if type(mapId) ~= "string" then
          problem("battle.terrain keys should be map ids; ignored")
        elseif type(row) ~= "table" then
          problem("battle.terrain.%s should be a table of TYPE = multiplier; ignored",
            tostring(mapId))
        else
          local clean = nil
          for typeName, mult in pairs(row) do
            local n = tonumber(mult)
            if type(typeName) ~= "string" or n == nil then
              problem("battle.terrain.%s.%s should be TYPE = number; ignored",
                tostring(mapId), tostring(typeName))
            else
              -- Same spirit as clampPath elsewhere: a player who wrote 50
              -- wants "a lot", and a hard clamp gives them that without
              -- letting a typo one-shot the whole game.
              if n < 0 then n = 0 elseif n > 4 then n = 4 end
              clean = clean or {}
              clean[typeName:upper()] = n
            end
          end
          if clean then data.battle.terrain[mapId] = clean end
        end
      end
    else
      problem("battle.terrain should be a table; ignored")
    end
  end

  if data.force ~= nil and not isWeatherId(data.force) then
    problem("force = %q is not a weather id; ignored", tostring(data.force))
    data.force = nil
  end

  Config.data = data
  Config.finalise(data)
  return data
end

-- Normalise the shapes the hot paths read every frame, so those paths do
-- no defaulting of their own.
function Config.finalise(data)
  if V.questLitePrivate then
    -- Hard performance envelope for the first Quest study. These values are
    -- applied after config parsing so a stale upstream config cannot silently
    -- re-enable systems that this package deliberately omitted.
    data.force = nil
    data.locations = {}
    data.bias = {}
    data.weathers = {}
    data.visuals = {
      precipitation = true, splashes = false, fog = false, veil = true,
      tint = true, glare = true, lightning = false, battleWeather = false,
      textBoxClear = true, puddles = false,
    }
    data.coverage = "screen"
    data.battleBackdrops = false
    data.encounters.enabled = false
    data.encounters.inject = false
    data.weatherVariants.enabled = false
    data.legendary.enabled = false
    data.psystorm.enabled = false
    data.fronts.enabled = false
    data.pokegear.enabled = false
    data.tornado.enabled = false
    data.followerChip.enabled = false
    data.battle.enabled = false
    data.battle.seedFromOverworld = false
    data.seasons.enabled = false
    data.seasons.notify = false
    data.seasons.placeBanner = false
    data.audio.enabled = true
    data.audio.volume = 0.70
    data.audio.indoors = 0
    data.audio.battle = 0
    data.audio.fadeSeconds = 1.5
    -- QuestStorm owns scheduling; its FULL/SOFT/OFF and WEATHER SFX rows
    -- govern playback. Disabling this legacy gate muted every queued roll.
    data.audio.thunder = true
    data.audio.wind = true
    data.lightningMode = "off"
    -- Battle Art's DayNight module remains the one clock authority in q90.
    -- AUTO reads that effective clock (including its DAY/NIGHT/DUSK/DAWN/CYCLE
    -- option), while the 20-minute value is only a standalone fallback.
    data.time.source = "auto"
    data.time.cycleMinutes = 20
    data.time.grade = true
    data.time.gradeStrength = 1.0
    data.time.publishTod = true
    data.time.indoors = 0.20
    data.quality = "potato"
    data.maxParticles = 240
    data.transitionSeconds = 3.0
  end
  data.tuning = data.tuning or {}
  data.tuning.ALL = data.tuning.ALL
    or { density = 1, intensity = 1, speed = 1, duration = 1, weight = 1 }
  data.weathers = data.weathers or {}
  data.indoorMaps = data.indoorMaps or {}
  data.locations = data.locations or {}
  data.bias = data.bias or {}
  -- immunity lists become sets, once, rather than a linear scan per turn
  local rd = data.battle.residualDamage
  rd.sandImmuneSet, rd.hailImmuneSet, rd.psyImmuneSet = {}, {}, {}
  for _, t in ipairs(rd.psyImmune or { "PSYCHIC" }) do rd.psyImmuneSet[t] = true end
  for _, t in ipairs(rd.sandImmune or {}) do rd.sandImmuneSet[t] = true end
  for _, t in ipairs(rd.hailImmune or {}) do rd.hailImmuneSet[t] = true end
  local suppress = {}
  for _, a in ipairs(data.battle.suppressAbilities or {}) do suppress[a] = true end
  data.battle.suppressSet = suppress
  if #Config.problems > 0 then
    mod.log:warn("config.lua loaded with %d problem(s); defaults used for those",
      #Config.problems)
  end
end

function Config.get()
  if not Config.data then Config.load() end
  return Config.data
end

-- ------- accessors the rest of the mod uses
--
-- Every one of these is total: it answers even with no config file, and
-- never returns nil for something a caller would then have to default.

function Config.tuningFor(weatherId)
  local t = Config.get().tuning
  local all = t.ALL
  local one = t[weatherId or ""]
  if not one then return all end
  return {
    density = all.density * one.density,
    intensity = all.intensity * one.intensity,
    speed = all.speed * one.speed,
    duration = all.duration * one.duration,
    weight = (all.weight or 1) * (one.weight or 1),
  }
end

-- Is this weather allowed to be rolled by AUTO at all?  `weathers` in
-- config.lua is a plain on/off list, checked before any weighting, so
-- switching one off is absolute rather than merely unlikely.
function Config.weatherEnabled(id)
  local v = Config.get().weathers[id or ""]
  if v == nil then return true end
  return v and true or false
end

-- The location override for an outdoor map, or nil. Indoor maps are
-- always clear; legacy `indoors = true` fields are accepted but ignored.
function Config.locationFor(mapId, isIndoors)
  if isIndoors then return nil end
  local entry = Config.get().locations[mapId or ""]
  if not entry then return nil end
  return entry
end

function Config.visual(name)
  local v = Config.get().visuals[name]
  if v == nil then return true end
  return v and true or false
end

-- NOTE: the master on/off is Battle.effectsEnabled(), which folds in the
-- mod-manager row as well; this only answers "is this individual effect
-- switched on", and every caller is already behind that master gate.
-- The map ids this mod ships, gathered from the DEFAULTS rather than a
-- hand-kept list, so adding a row above cannot leave this behind. Used by
-- the map-id check to tell "the author shipped a Johto id and this is a
-- Kanto game" apart from "the player mistyped something".
function Config.bundledMapIds()
  local out = {}
  local d = DEFAULTS or {}
  local t = d.battle and d.battle.terrain
  if type(t) == "table" then
    for mapId in pairs(t) do out[mapId] = true end
  end
  if type(d.locations) == "table" then
    for mapId in pairs(d.locations) do out[mapId] = true end
  end
  return out
end

function Config.battleEffect(name)
  local b = Config.get().battle
  if not b.enabled then return false end
  local v = b.effects[name]
  if v == nil then return true end
  return v and true or false
end

return Config
