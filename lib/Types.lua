-- THE WEATHER CATALOGUE.
--
-- This file is the extension point of the whole mod.  Adding a weather type
-- is adding one entry to `Types.list` -- nothing else in the mod knows the
-- name of any weather, and no draw code branches on one.
--
-- THE CHANNEL MODEL is what buys that.  A weather is not a thing with its
-- own renderer; it is a set of numbers, one per visual channel (how much
-- rain, how fast, how dark, how many strikes a minute).  Every draw system
-- reads its own channels and nothing else, and WeatherState eases every
-- channel toward the active type's value at a fixed rate.
--
--   * TRANSITIONS ARE FREE.  No cross-fade code, no "previous weather" kept
--     alive, no blend of two renderers.  Rain stopping and fog rolling in is
--     the rain channel easing to 0 while the fog channel eases to 1.
--   * A NEW CHANNEL IS BACKWARD COMPATIBLE.  Channels absent from a def read
--     as 0 (Types.channel), so adding one to a single type does not require
--     touching the other thirteen.
--   * NOTHING CAN DESYNC.  One authority for "how much rain is falling", and
--     it is a number, so an unknown weather id degrades to CLEAR rather than
--     to a half-drawn frame.
--
-- ---------------------------------------------------------------------
-- CHANNEL REFERENCE (all plain numbers, all 0 when omitted)
-- ---------------------------------------------------------------------
--
--   rain       0..1  liquid precipitation density
--   rainSpeed  0..2  fall speed multiplier
--   rainAngle  rad   lean off vertical, positive = blown right
--   rainLen    0..2  streak length multiplier
--   splash     0..1  fraction of drops that burst where they land
--   snow       0..1  soft frozen precipitation density
--   snowSpeed  0..2  fall speed multiplier
--   snowDrift  0..1  how much flakes wander sideways
--   hail       0..1  hard frozen grains -- fast, straight, they bounce
--   sand       0..1  wind-driven grit, near-horizontal
--   ash        0..1  volcanic fall -- grey, slow, near-vertical
--   psy        0..1  psychic violet -- an additive wash, not a multiply,
--                    because the sky under a psystorm glows rather than
--                    darkens, and a multiply cannot make a colour brighter
--   debris     0..1  leaves and litter carried on a gale
--   fog        0..1  scrolling noise-bank opacity
--   fogSpeed   0..2  how fast the banks drift
--   veil       0..1  flat achromatic haze (whiteout / murk)
--   dim        0..1  multiply-darken the frame
--   cool       0..1  push the multiply tint toward blue
--   warm       0..1  push it toward amber instead
--   glare      0..1  additive bloom -- sunlight on the lens
--   gust       0..1  strength of the slow wind oscillation
--   strike     n/min lightning strikes per minute, 0 = never
--
-- The four GRAIN channels (hail, sand, ash, debris) share one particle pool
-- and differ by colour, speed and bounce.  They stay separate channels
-- rather than one because they have to cross-fade independently during a
-- transition.
--
-- ---------------------------------------------------------------------
-- SCHEDULING FIELDS (AUTO only; ignored when a type is pinned or forced)
-- ---------------------------------------------------------------------
--
--   weight       relative chance of being picked next
--   dayWeight    multiplier while the sun is up
--   nightWeight  multiplier while it is down
--   minMin/maxMin  spell length in minutes
--   follows      ids this type likes to arrive after, which doubles its
--                weight -- how a storm grows out of a downpour rather than
--                out of a clear sky
--   natural      false = never picked by AUTO.  The primal weathers and
--                Strong Winds are legendary-tier: they exist so a config
--                or a location override can force them, and so a battle
--                can be fought in one, but Kanto's sky does not produce
--                them on its own.
--
-- ---------------------------------------------------------------------
-- BATTLE FIELDS
-- ---------------------------------------------------------------------
--
--   battle   the id written into `battle.field.weather`.
--
--     THIS VOCABULARY IS NOT OURS.  Kanto-Reforged already implements
--     battle weather -- Weather Ball, Forecast/Castform, Sand Veil,
--     Chlorophyll and Swift Swim all read `battle.field.weather` and
--     expect the strings SUNNY / RAINY / SANDSTORM / HAIL / SNOWY.  So
--     those are the strings this mod writes, and the two systems drive
--     one field instead of fighting over two.  With that mod absent the
--     field is ours alone and the same strings still apply.
--
--     HARSH_SUN, HEAVY_RAIN, STRONG_WINDS and FOG extend the vocabulary.
--     Reforged passes a value it does not recognise straight through, so
--     extending is safe; lib/Battle.lua handles the extensions.
--
--   wet / frozen / sunny / sandy   capability tags.  The battle layer and
--     the region bias read these instead of ids, so A NEW TYPE IS
--     AUTOMATICALLY COVERED by both without being added to a second list.

local V = ...
local Types = {}

Types.list = {
  {
    id = "CLEAR", label = "CLEAR",
    weight = 30, dayWeight = 1.25, nightWeight = 0.9,
    minMin = 6, maxMin = 16,
    -- Leaving almost any spell into clear is natural.
    follows = {
      RAIN_LIGHT = true, RAIN_HEAVY = true, STORM = true, MIST = true, FOG = true,
      SNOW_LIGHT = true, SUNNY = true, GALE = true, STRONG_WINDS = true,
      SLEET = true, SMOG = true, SANDSTORM = true, ASHFALL = true,
    },
    ch = {},
  },

  -- ------- sun

  {
    id = "SUNNY", label = "SUN", chipType = "FIRE", sunny = true, battle = "SUNNY",
    weight = 14, dayWeight = 2.0, nightWeight = 0.0,
    minMin = 5, maxMin = 12,
    follows = { CLEAR = true, HEATWAVE = true, FOG = true, MIST = true },
    ch = { warm = 0.28, glare = 0.30, veil = 0.04 },
  },
  {
    -- Primal Groudon's weather.  Never scheduled; force it and the sky
    -- bleaches out.
    id = "HARSH_SUN", label = "H.SUN", chipType = "FIRE", sunny = true, battle = "HARSH_SUN",
    natural = false, minMin = 3, maxMin = 6,
    ch = { warm = 0.55, glare = 0.85, veil = 0.14 },
  },

  -- ------- water

  {
    id = "RAIN_LIGHT", label = "RAIN", chipType = "WATER", wet = true, battle = "RAINY",
    weight = 16, minMin = 4, maxMin = 10,
    follows = { CLEAR = true, MIST = true, FOG = true, RAIN_HEAVY = true, STORM = true, SLEET = true, VERDANT_RAIN = true },
    ch = {
      rain = 0.34, rainSpeed = 0.92, rainAngle = 0.17, rainLen = 1.0,
      splash = 0.45, dim = 0.11, cool = 0.18, gust = 0.25,
    },
  },
  {
    id = "RAIN_HEAVY", label = "HEAVY", chipType = "WATER", wet = true, battle = "RAINY",
    weight = 9, minMin = 3, maxMin = 7,
    follows = { RAIN_LIGHT = true, STORM = true, GALE = true, VERDANT_RAIN = true, HEAVY_RAIN = true },
    ch = {
      rain = 1.0, rainSpeed = 1.22, rainAngle = 0.27, rainLen = 1.35,
      splash = 1.0, dim = 0.21, cool = 0.26, gust = 0.55, veil = 0.05,
    },
  },
  {
    -- Primal Kyogre's weather.  Never scheduled.
    id = "HEAVY_RAIN", label = "PRIML", chipType = "WATER", wet = true, battle = "HEAVY_RAIN",
    natural = false, minMin = 3, maxMin = 6,
    ch = {
      rain = 1.3, rainSpeed = 1.5, rainAngle = 0.30, rainLen = 1.7,
      splash = 1.0, dim = 0.34, cool = 0.42, gust = 0.70, veil = 0.14,
      strike = 3,
    },
  },
  {
    id = "STORM", label = "STORM", chipType = "ELECTRIC", wet = true, battle = "RAINY",
    weight = 6, nightWeight = 1.4, minMin = 2, maxMin = 6,
    follows = { RAIN_HEAVY = true, RAIN_LIGHT = true, GALE = true, THUNDERSNOW = true, DRAGONSTORM = true },
    ch = {
      rain = 1.0, rainSpeed = 1.35, rainAngle = 0.36, rainLen = 1.5,
      splash = 1.0, dim = 0.30, cool = 0.30, gust = 0.85, veil = 0.07,
      strike = 9,
    },
  },

  -- ------- frozen

  {
    id = "SNOW_LIGHT", label = "SNOW", chipType = "ICE", frozen = true, battle = "SNOWY",
    -- Kanto is temperate, so snow is rare by weight and pushed upward by
    -- altitude in WeatherState.BIAS (and by winter when SEASONS is ON)
    -- not have.
    weight = 5, minMin = 5, maxMin = 12,
    follows = { CLEAR = true, MIST = true, FOG = true, SLEET = true, HAIL = true, BLIZZARD = true, RAIN_LIGHT = true },
    ch = { snow = 1.08, snowSpeed = 0.34, snowDrift = 0.5, dim = 0.05, veil = 0.06 },
  },
  {
    id = "BLIZZARD", label = "BLIZZ", chipType = "ICE", frozen = true, battle = "SNOWY",
    weight = 2, minMin = 2, maxMin = 5,
    follows = { SNOW_LIGHT = true, HAIL = true, THUNDERSNOW = true, GALE = true },
    ch = {
      snow = 3, snowSpeed = 0.8, snowDrift = 1.0,
      dim = 0.16, veil = 0.32, gust = 1.0, cool = 0.10,
    },
  },
  {
    -- Hail is not heavy snow: the grains are small, hard, fast and nearly
    -- vertical, and they bounce.  Its own channel, its own look, and the
    -- only frozen weather that chips HP in battle.
    id = "HAIL", label = "HAIL", chipType = "ICE", frozen = true, battle = "HAIL",
    weight = 3, minMin = 2, maxMin = 6,
    follows = { SNOW_LIGHT = true, STORM = true, BLIZZARD = true, SLEET = true },
    ch = {
      hail = 0.9, snow = 0.36, snowSpeed = 0.6,
      dim = 0.18, cool = 0.22, veil = 0.14, gust = 0.5,
    },
  },

  -- ------- earth and air

  {
    id = "SANDSTORM", label = "SAND", chipType = "ROCK", sandy = true, battle = "SANDSTORM",
    -- Kanto has no desert, so this is rare by weight and lives on the
    -- config's location overrides more than on the schedule.
    weight = 2, dayWeight = 1.3, nightWeight = 0.7,
    minMin = 3, maxMin = 8,
    follows = { CLEAR = true, STRONG_WINDS = true, DUSTSTORM = true, HEATWAVE = true, SUNNY = true },
    ch = {
      sand = 1.0, debris = 0.15,
      veil = 0.30, warm = 0.30, dim = 0.14, gust = 1.0,
    },
  },
  {
    -- Mega Rayquaza's weather.  Never scheduled.
    id = "STRONG_WINDS", label = "WINDS", chipType = "FLYING", battle = "STRONG_WINDS",
    natural = false, minMin = 3, maxMin = 7,
    ch = { debris = 1.0, gust = 1.0, veil = 0.10, dim = 0.10, cool = 0.08 },
  },


  -- ------- typed weather fronts
  --
  -- These are deliberately weather, not moves.  Each one has a distinct
  -- field id and a visual recipe, and each carries one Gen-1 damage type
  -- for the residual chip system.  The existing weather families are reused
  -- where they already express the type naturally; these fill the remaining
  -- types.

  {
    -- `battle` was missing here while every other type-storm in this family
    -- carries one. Without it PLAIN_FRONT seeds no battle weather, resolves
    -- no look, and draws nothing on the battle screen -- a pinned weather
    -- that silently does nothing in a fight. It is in Types.PINNED, so the
    -- player can select it; NORMAL is simply the member of the set that was
    -- left half-wired.
    id = "PLAIN_FRONT", label = "PLAIN", chipType = "NORMAL",
    battle = "PLAIN_FRONT", weight = 3, minMin = 3, maxMin = 8,
    follows = { CLEAR = true, SUNNY = true, MIST = true },
    ch = { debris = 0.22, gust = 0.35, veil = 0.04, dim = 0.02 },
  },
  {
    id = "VERDANT_RAIN", label = "VRAIN", chipType = "GRASS", wet = true,
    battle = "VERDANT_RAIN", weight = 3, dayWeight = 1.3, nightWeight = 0.8,
    minMin = 3, maxMin = 8,
    follows = { RAIN_LIGHT = true, MIST = true, FOG = true, RAIN_HEAVY = true },
    ch = {
      rain = 0.42, rainSpeed = 0.88, rainAngle = 0.12, rainLen = 0.8,
      splash = 0.35, fog = 0.16, veil = 0.05, cool = 0.08, gust = 0.2,
    },
  },
  {
    id = "BRAWL_WIND", label = "BRAWL", chipType = "FIGHTING",
    battle = "BRAWL_WIND", weight = 2, minMin = 2, maxMin = 6,
    follows = { GALE = true, STRONG_WINDS = true, CLEAR = true },
    ch = { debris = 0.85, gust = 1.0, veil = 0.08, dim = 0.05, warm = 0.12 },
  },
  {
    id = "SMOG", label = "SMOG", chipType = "POISON", battle = "SMOG",
    weight = 4, dayWeight = 0.8, nightWeight = 1.8, minMin = 3, maxMin = 8,
    follows = { FOG = true, MIST = true, HAUNTED_MIST = true, CLEAR = true },
    ch = { fog = 1.0, fogSpeed = 0.7, ash = 0.45, veil = 0.30,
           dim = 0.18, warm = 0.05, gust = 0.18 },
  },
  {
    id = "DUSTSTORM", label = "DUST", chipType = "GROUND", sandy = true,
    battle = "DUSTSTORM", weight = 2, dayWeight = 1.25, nightWeight = 0.8,
    minMin = 3, maxMin = 8,
    follows = { SANDSTORM = true, STRONG_WINDS = true, ASHFALL = true, CLEAR = true },
    ch = { sand = 1.5, debris = 0.28, fog = 0.55, fogSpeed = 0.9,
           veil = 0.62, warm = 0.12, dim = 0.0, gust = 0.9 },
  },
  {
    id = "FLOCKSTORM", label = "FLOCK", chipType = "FLYING",
    battle = "FLOCKSTORM", weight = 2, minMin = 2, maxMin = 6,
    follows = { GALE = true, STRONG_WINDS = true, CLEAR = true },
    ch = { debris = 1.0, gust = 1.0, veil = 0.05, cool = 0.05 },
  },
  {
    id = "SWARM", label = "SWARM", chipType = "BUG", battle = "SWARM",
    weight = 2, dayWeight = 1.1, nightWeight = 1.1, minMin = 2, maxMin = 6,
    follows = { MIST = true, FOG = true, CLEAR = true },
    ch = { debris = 0.95, fog = 0.28, fogSpeed = 1.2, veil = 0.08,
           gust = 0.35, warm = 0.04 },
  },
  {
    id = "HAUNTED_MIST", label = "HAUNT", chipType = "GHOST",
    battle = "HAUNTED_MIST", weight = 2, dayWeight = 0.45, nightWeight = 2.4,
    minMin = 3, maxMin = 8,
    follows = { MIST = true, FOG = true, SMOG = true },
    ch = { fog = 1.0, fogSpeed = 0.22, veil = 0.22, dim = 0.20,
           cool = 0.32, debris = 0.12 },
  },
  {
    id = "DRAGONSTORM", label = "DRAGON", chipType = "DRAGON",
    battle = "DRAGONSTORM", weight = 1, nightWeight = 1.7, minMin = 2, maxMin = 5,
    follows = { STORM = true, RAIN_HEAVY = true, GALE = true },
    ch = {
      rain = 0.72, rainSpeed = 1.25, rainAngle = 0.42, rainLen = 1.55,
      snow = 0.85, snowSpeed = 0.7, snowDrift = 0.9,
      sand = 0.75,
      splash = 0.7, debris = 0.45, gust = 0.9, strike = 7,
      dim = 0.26, cool = 0.22, veil = 0.10,
    },
  },
  -- ------- mixed and volcanic
  --
  -- Five types added in 2.5, all built from channels that already existed
  -- except `ash` -- which is the point of the channel model: a new weather
  -- is a table entry, and a new LOOK is one new channel plus one branch in
  -- the particle pool.

  {
    -- Rain and snow falling together, with a little ice in it.  The one
    -- weather that genuinely needs three precipitation channels at once,
    -- and the clearest demonstration that they compose.
    id = "SLEET", label = "SLEET", chipType = "ICE", frozen = true, wet = true, battle = "SNOWY",
    weight = 4, minMin = 3, maxMin = 8,
    follows = { RAIN_LIGHT = true, SNOW_LIGHT = true, HAIL = true, RAIN_HEAVY = true, MIST = true },
    ch = {
      rain = 0.45, rainSpeed = 1.0, rainAngle = 0.22, rainLen = 0.9,
      snow = 1.35, snowSpeed = 0.7, snowDrift = 0.6, hail = 0.18,
      splash = 0.35, dim = 0.20, cool = 0.32, veil = 0.12, gust = 0.5,
    },
  },
  {
    -- Rare and worth the rarity: a blizzard with lightning in it.
    id = "THUNDERSNOW", label = "TSNOW", chipType = "ELECTRIC", frozen = true, battle = "SNOWY",
    weight = 1, nightWeight = 1.6, minMin = 2, maxMin = 4,
    follows = { BLIZZARD = true, HAIL = true, STORM = true, SNOW_LIGHT = true },
    ch = {
      -- Snow only (no rain streaks); lightning via strike
      snow = 9, snowSpeed = 0.95, snowDrift = 1.0,
      dim = 0.26, cool = 0.26, veil = 0.28, gust = 0.9, strike = 5,
    },
  },
  {
    -- Cinnabar's volcano.  Ash is not sand: it is grey, it falls slowly
    -- and almost straight down, and it settles rather than blows.
    id = "ASHFALL", label = "ASH", chipType = "FIRE", sandy = true, battle = "SANDSTORM",
    weight = 2, minMin = 3, maxMin = 8,
    follows = { CLEAR = true, SUNNY = true, DUSTSTORM = true, HEATWAVE = true },
    ch = {
      ash = 0.95, fog = 0.35, fogSpeed = 0.55, veil = 0.28,
      dim = 0.0, warm = 0.08, gust = 0.35,
    },
  },
  {
    -- Sun with weight behind it: the air itself goes pale.
    id = "HEATWAVE", label = "HEAT", chipType = "FIRE", sunny = true, battle = "SUNNY",
    weight = 5, dayWeight = 2.2, nightWeight = 0.0, minMin = 4, maxMin = 10,
    follows = { SUNNY = true, CLEAR = true, SANDSTORM = true, ASHFALL = true },
    ch = { warm = 0.45, glare = 0.58, veil = 0.14 },
  },
  {
    -- A blustery front: hard slanting rain with things blown through it.
    id = "GALE", label = "GALE", chipType = "FLYING", wet = true, battle = "RAINY",
    weight = 5, minMin = 2, maxMin = 6,
    follows = { RAIN_LIGHT = true, RAIN_HEAVY = true, STORM = true, STRONG_WINDS = true, BRAWL_WIND = true },
    ch = {
      rain = 0.7, rainSpeed = 1.3, rainAngle = 0.52, rainLen = 1.4,
      splash = 0, debris = 0.55, gust = 1.0,
      dim = 0.20, cool = 0.22, veil = 0.08,
      strike = 4,
    },
  },

  {
    -- PSYSTORM.  Not weather so much as a place reacting to what is
    -- standing in it: violet cloud, hard wind and lightning, and it wears
    -- down anything that is not Psychic.
    --
    -- `natural = false` keeps it out of the AUTO roll entirely.  It is
    -- summoned instead, by lib/Psystorm.lua, and only where the conditions
    -- allow -- which is what stops it turning up over Pallet Town.
    id = "PSYSTORM", label = "PSY", chipType = "PSYCHIC", battle = "PSYSTORM", psychic = true,
    natural = false, minMin = 3, maxMin = 8,
    ch = {
      psy = 1.0, rain = 1.5, rainSpeed = 1.4, rainAngle = 0.45, rainLen = 1.6,
      debris = 0.6, gust = 1.0, strike = 42,
      dim = 0.22, cool = 0.30, veil = 0.16,
    },
  },

  -- ------- suspended water

  {
    id = "MIST", label = "MIST", battle = "FOG",
    weight = 8, dayWeight = 0.7, nightWeight = 1.6, minMin = 4, maxMin = 10,
    follows = { CLEAR = true, RAIN_LIGHT = true, FOG = true, SMOG = true },
    ch = { fog = 0.45, fogSpeed = 0.4, veil = 0.06, dim = 0.05 },
  },
  {
    id = "FOG", label = "FOG", battle = "FOG",
    weight = 5, dayWeight = 0.6, nightWeight = 1.8, minMin = 3, maxMin = 8,
    follows = { MIST = true, CLEAR = true, RAIN_LIGHT = true, SMOG = true, HAUNTED_MIST = true },
    ch = { fog = 1.0, fogSpeed = 0.55, veil = 0.12, dim = 0.09, cool = 0.06 },
  },
}

-- The standalone Quest adapter intentionally carries only supported effects.
-- Filtering the catalogue here also keeps AUTO, config validation, and
-- the ALWAYS menu on the same small vocabulary instead of merely hiding rows.
if V.questLitePrivate then
  local keep = {
    CLEAR = true,
    RAIN_LIGHT = true,
    RAIN_HEAVY = true,
    HEAVY_RAIN = true,
    STORM = true,
    SNOW_LIGHT = true,
    STRONG_WINDS = true,
    GALE = true,
    ASHFALL = true,
  }
  local filtered = {}
  for _, def in ipairs(Types.list) do
    if keep[def.id] then
      if type(def.follows) == "table" then
        local follows = {}
        for id, enabled in pairs(def.follows) do
          if keep[id] and enabled then follows[id] = true end
        end
        def.follows = follows
      end
      filtered[#filtered + 1] = def
    end
  end
  Types.list = filtered
  -- Append: existing numeric weather picker/save meanings must not shift.
  Types.list[#Types.list+1]={id='PARTLY_CLOUDY',label='PARTLY CLOUDY',natural=false,
    weight=0,minMin=6,maxMin=16,ch={dim=.04}}
  Types.list[#Types.list+1]={id='MOSTLY_CLOUDY',label='MOSTLY CLOUDY',natural=false,
    weight=0,minMin=6,maxMin=16,ch={dim=.10}}
  Types.list[#Types.list+1]={id='PARTLY_SNOW',label='PARTLY / LIGHT SNOW',natural=false,
    weight=0,minMin=6,maxMin=16,ch={snow=.18,gust=.08,dim=.04}}
end

Types.byId = {}
for i, def in ipairs(Types.list) do
  def.index = i
  Types.byId[def.id] = def
end

Types.DEFAULT = "CLEAR"

-- Every channel any def mentions, so WeatherState eases the union of them
-- without a hardcoded list (a new channel in one def is eased for all).
Types.channels = {}
do
  local seen = {}
  for _, def in ipairs(Types.list) do
    for key in pairs(def.ch) do
      if not seen[key] then
        seen[key] = true
        Types.channels[#Types.channels + 1] = key
      end
    end
  end
  table.sort(Types.channels)     -- stable order, so tests and logs are stable
end

function Types.get(id)
  return Types.byId[id or ""] or Types.byId[Types.DEFAULT]
end

-- A def's value for one channel.  Absent = 0, which is what makes a new
-- channel safe to add to a single def.  `v ~= v` catches NaN.
function Types.channel(def, key)
  local v = def and def.ch and def.ch[key]
  if type(v) ~= "number" or v ~= v then return 0 end
  return v
end

-- The ids the OPTIONS ladder can pin, in rung order.  MIST is absent: it
-- is a shade of FOG and would spend a rung the player cycles by hand,
-- while AUTO still uses it for variety.  The three unnatural weathers ARE
-- here -- a player who wants to stand in Primal rain should be able to,
-- and there is otherwise no way to reach them without editing config.lua.
Types.PINNED = {
  "CLEAR", "SUNNY", "HEATWAVE", "HARSH_SUN",
  "RAIN_LIGHT", "RAIN_HEAVY", "HEAVY_RAIN", "STORM", "GALE",
  "SNOW_LIGHT", "BLIZZARD", "HAIL", "SLEET", "THUNDERSNOW",
  "SANDSTORM", "DUSTSTORM", "ASHFALL", "STRONG_WINDS", "FLOCKSTORM",
  "SWARM", "HAUNTED_MIST", "DRAGONSTORM", "BRAWL_WIND", "PLAIN_FRONT",
  "VERDANT_RAIN", "SMOG", "FOG", "PSYSTORM",
}

if V.questLitePrivate then
  Types.PINNED = {
    "CLEAR", "RAIN_LIGHT", "RAIN_HEAVY", "HEAVY_RAIN",
    "SNOW_LIGHT", "STRONG_WINDS", "GALE", "ASHFALL", "STORM",
    "PARTLY_CLOUDY", "MOSTLY_CLOUDY", "PARTLY_SNOW",
  }
end

-- Every id, for config validation messages.
function Types.ids()
  local out = {}
  for _, def in ipairs(Types.list) do out[#out + 1] = def.id end
  return out
end

-- The battle-field string a weather writes, or nil for none.
function Types.battleWeather(id)
  return Types.get(id).battle
end

-- The REVERSE mapping: given a `battle.field.weather` string, which
-- catalogue entry should the battle screen LOOK like?
--
-- Several overworld types share one battle string -- light rain, heavy
-- rain and a thunderstorm are all RAINY -- so the reverse is a choice
-- rather than a lookup.  It is made explicitly rather than by taking the
-- first match, because the first match is the weakest one: a Rain Dance
-- should put real rain on the screen rather than a drizzle, and FOG should
-- be fog rather than the mist that happens to be listed above it.
Types.BATTLE_LOOK = {
  SUNNY        = "SUNNY",
  HARSH_SUN    = "HARSH_SUN",
  RAINY        = "RAIN_HEAVY",
  HEAVY_RAIN   = "HEAVY_RAIN",
  SNOWY        = "SNOW_LIGHT",
  HAIL         = "HAIL",
  SANDSTORM    = "SANDSTORM",
  STRONG_WINDS = "STRONG_WINDS",
  FOG          = "FOG",
  PSYSTORM     = "PSYSTORM",
  ELECTRIC_STORM = "STORM",
  VERDANT_RAIN = "VERDANT_RAIN",
  BRAWL_WIND = "BRAWL_WIND",
  SMOG = "SMOG",
  DUSTSTORM = "DUSTSTORM",
  FLOCKSTORM = "FLOCKSTORM",
  SWARM = "SWARM",
  HAUNTED_MIST = "HAUNTED_MIST",
  DRAGONSTORM = "DRAGONSTORM",
  PLAIN_FRONT = "PLAIN_FRONT",
}

function Types.forBattleWeather(weather)
  local id = Types.BATTLE_LOOK[weather or ""]
  if not id then return nil end
  return Types.get(id)
end

return Types
