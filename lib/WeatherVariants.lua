-- Persistent weather-dependent Delta Pokémon.
-- Species are cloned from the merged Pokémon registry and registered under
-- unique string IDs. Wild substitution happens only after a normal encounter
-- succeeds, so this system never changes encounter rates or tables.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Settings = V.require("Settings")
local Scene = V.require("Scene")
local State = V.require("WeatherState")
local BaseData = V.require("WeatherVariantsData")
local Dex = V.require("WeatherVariantDex")

local function kantoReforgedInstalled()
  -- v6.50.0: Kanto Reforged 1.4.0 is embedded in The World.
  return true
end

local function gen9DexInstalled()
  if not mod or type(mod.find) ~= "function" then return false end
  -- Gen9Dex ships as "g9-battle-engine" (manifest id). Also accept common aliases.
  local candidates = { "g9-battle-engine", "Gen9Dex", "gen9dex", "G9-Battle-Engine" }
  for _, id in ipairs(candidates) do
    local ok, handle = pcall(function() return mod.find(id) end)
    if ok and handle ~= nil and handle ~= false then return true end
  end
  return false
end

-- gen1recomp-national-dex (sanjinpepic). Provides species 1–1025 and treats
-- records with baseSpecies + form as alternate forms of the base (never new
-- dex rows). Critical for keeping the Pokédex clean with hundreds of weather
-- variants.
local function nationalDexInstalled()
  if not mod or type(mod.find) ~= "function" then return false end
  local candidates = { "national_dex", "National-Dex", "national-dex", "gen1recomp-national-dex" }
  for _, id in ipairs(candidates) do
    local ok, handle = pcall(function() return mod.find(id) end)
    if ok and handle ~= nil and handle ~= false then return true end
  end
  return false
end

local Data = {}
for _, row in ipairs(BaseData) do Data[#Data + 1] = row end
-- 5.16.0: guarantee a recoloured WX art form for every species represented
-- by the bundled Battlers collection. Existing authored WX forms remain intact.
do
  local okA,A=pcall(require,"mods.the_world.reforged.pokemon.battler_art_import")
  local okP,P=pcall(require,"mods.the_world.reforged.pokemon_data")
  if okA and okP then A.apply(P); for _,row in ipairs(A.wxRows(P)) do Data[#Data+1]=row end end
end

-- The World 5.15.1: native expanded starter forms. These are deliberately
-- unconditional and therefore available without any external content mod.
do
  local ok, extra = pcall(function() return V.require("StarterWeatherVariantsData") end)
  if ok and type(extra) == "table" then
    for _, row in ipairs(extra) do Data[#Data + 1] = row end
  end
end
-- 5.16.52: The World owns the complete National Dex and four WX forms per canonical species.
do
  local ok, extra = pcall(function() return V.require("NationalDexWxVariantsData") end)
  if ok and type(extra) == "table" then
    for _, row in ipairs(extra) do Data[#Data + 1] = row end
    mod.log:info("weather variants: loaded four native National Dex WX forms (%d rows)", #extra)
  end
end

local STARTER_BASES = {
  BULBASAUR=true, CHARMANDER=true, SQUIRTLE=true, PIKACHU=true,
  CHIKORITA=true, CYNDAQUIL=true, TOTODILE=true,
  TREECKO=true, TORCHIC=true, MUDKIP=true,
}
local kantoPack
do
  -- The regional Johto starter trio belongs to The World itself and must not
  -- depend on Kanto-Reforged being installed. 5.13.0 accidentally placed the
  -- trio at the head of KantoWeatherVariantsData, while this whole file was
  -- gated behind Kanto-Reforged. That made WX appear enabled but left the
  -- Pewter breeder with no registered species on ordinary installs.
  local extra = V.require("KantoWeatherVariantsData")
  local hasKanto = kantoReforgedInstalled()
  for _, row in ipairs(extra) do
    if row.starterRegional or STARTER_BASES[row.base] or hasKanto then Data[#Data + 1] = row end
  end
  if hasKanto then
    local ok, pack = pcall(require, "mods.the_world.reforged.pokemon_data")
    if ok and type(pack) == "table" then kantoPack = pack end
  end
end

-- 5.13.7: Yellow/RB do not expose Johto species in the vanilla registry.
-- The World already ships complete Gen 2/3 species records in its own
-- reforged data pack, so use those records as registration templates for the
-- three regional starter families. This happens during content registration,
-- before the registry is frozen; attempting registry:register() later from
-- the Pewter NPC cannot work reliably on API 2 hosts.
local bundledSpecies
do
  local ok, pack = pcall(require, "mods.the_world.reforged.pokemon_data")
  if ok and type(pack) == "table" and type(pack.species) == "table" then
    bundledSpecies = pack.species
  end
end

-- Gen9Dex path (often paired with national_dex). Load the Gen 9 weather-variant
-- cohort when either Gen9Dex or national_dex is present so the full modern
-- roster can receive weather forms.
if gen9DexInstalled() or nationalDexInstalled() then
  local ok, extra = pcall(function() return V.require("Gen9WeatherVariantsData") end)
  if ok and type(extra) == "table" then
    for _, row in ipairs(extra) do Data[#Data + 1] = row end
    mod.log:info("weather variants: Gen9/national_dex detected — loading Gen9 weather variants (%d rows)", #extra)
  else
    mod.log:info("weather variants: Gen9/national_dex detected but Gen9WeatherVariantsData.lua not present")
  end
end

-- Holiday-only Primalweather forms from Weather FX 4.3.1. They are real
-- species records so they save safely, but are excluded from wild pools.
do
  local ok, extra = pcall(function() return V.require("PrimalWeatherVariantsData") end)
  if ok and type(extra) == "table" then
    for _, row in ipairs(extra) do Data[#Data + 1] = row end
    mod.log:info("weather variants: loaded Primalweather gifts (%d rows)", #extra)
  end
end

local NATIONAL_DEX = nationalDexInstalled()
-- Synthetic form dex numbers start well above national 1025 and national_dex's
-- own FORM_DEX_BASE (~20000) range used for megas/gigantamax. Weather variants
-- claim 30000+ so they never collide and never appear as their own list rows.
local FORM_DEX_BASE = 30000

local Variants = {
  data = Data, registered = {}, skipped = {}, forced = nil,
  kantoReforged = kantoReforgedInstalled(),
  gen9Dex = gen9DexInstalled(),
  nationalDex = NATIONAL_DEX,
}

-- Requested labels mapped to real IDs defined by lib/Types.lua. A label may
-- intentionally name a family (for example Rain or Seasonal).
local WEATHER_IDS = {
  ["Rain"] = { RAIN_LIGHT=true, VERDANT_RAIN=true },
  ["Heavy Rain"] = { RAIN_HEAVY=true, HEAVY_RAIN=true },
  ["Storm"] = { STORM=true, RAIN_HEAVY=true },
  ["Thunderstorm"] = { STORM=true, THUNDERSNOW=true },
  ["Snow"] = { SNOW_LIGHT=true }, ["Hail"] = { HAIL=true },
  ["Blizzard"] = { BLIZZARD=true }, ["Wind"] = { GALE=true, STRONG_WINDS=true },
  ["Sandstorm"] = { SANDSTORM=true }, ["Dust Storm"] = { DUSTSTORM=true },
  ["Ashfall"] = { ASHFALL=true }, ["Heatwave"] = { HEATWAVE=true, HARSH_SUN=true },
  ["Sunny"] = { SUNNY=true }, ["Fog"] = { FOG=true, MIST=true },
  ["Moonlit Fog"] = { HAUNTED_MIST=true }, ["Smog"] = { SMOG=true },
  ["Acid Rain"] = { SMOG=true, HEAVY_RAIN=true },
  ["Static Storm"] = { STORM=true, THUNDERSNOW=true },
  ["Flood"] = { HEAVY_RAIN=true }, ["Typhoon"] = { GALE=true, STORM=true },
  ["Aurora"] = { SNOW_LIGHT=true, THUNDERSNOW=true },
  ["Eclipse"] = { HAUNTED_MIST=true, PSYSTORM=true },
  ["Heat Haze"] = { HEATWAVE=true, SUNNY=true },
  ["Spring Rain"] = { VERDANT_RAIN=true, RAIN_LIGHT=true },
  ["Autumn Rain"] = { VERDANT_RAIN=true, RAIN_LIGHT=true },
  ["Moonlit Rain"] = { HAUNTED_MIST=true },
  ["Seasonal"] = { SUNNY=true, VERDANT_RAIN=true, SNOW_LIGHT=true },
  ["Any seasonal weather"] = { SUNNY=true, VERDANT_RAIN=true, SNOW_LIGHT=true, BLIZZARD=true },
  ["Any rare weather"] = { ASHFALL=true, BLIZZARD=true, THUNDERSNOW=true,
    HAUNTED_MIST=true, DRAGONSTORM=true, PSYSTORM=true, SMOG=true, HEAVY_RAIN=true },
}
Variants.weatherIds = WEATHER_IDS

-- 5.16.1: every WX Pokemon has an explicit, usable weather affinity.
local TYPE_WEATHER={FIRE="Heatwave",WATER="Rain",GRASS="Sunny",ELECTRIC="Thunderstorm",ICE="Hail",GROUND="Sandstorm",ROCK="Sandstorm",POISON="Smog",GHOST="Fog",DARK="Moonlit Fog",FAIRY="Aurora",FLYING="Wind",DRAGON="Storm",STEEL="Ashfall",BUG="Spring Rain",PSYCHIC_TYPE="Eclipse",FIGHTING="Wind",NORMAL="Seasonal"}
for _,row in ipairs(Data) do
  if not row.weather or not WEATHER_IDS[row.weather] then
    row.weather=TYPE_WEATHER[row.types and row.types[1]] or TYPE_WEATHER[row.types and row.types[2]] or "Seasonal"
  end
end

local AFFINITIES = {
  RAIN_LIGHT={ WATER=true, GRASS=true }, RAIN_HEAVY={ WATER=true, GRASS=true },
  HEAVY_RAIN={ WATER=true, GROUND=true }, FOG={ GHOST=true, PSYCHIC_TYPE=true, POISON=true },
  HAUNTED_MIST={ GHOST=true, FAIRY=true, DARK=true }, SMOG={ POISON=true, FIRE=true },
  SNOW_LIGHT={ ICE=true }, HAIL={ ICE=true }, BLIZZARD={ ICE=true },
  STORM={ ELECTRIC=true, FLYING=true }, THUNDERSNOW={ ELECTRIC=true, ICE=true },
  SANDSTORM={ GROUND=true, ROCK=true }, DUSTSTORM={ GROUND=true, ROCK=true },
  ASHFALL={ FIRE=true, GHOST=true }, HEATWAVE={ FIRE=true, GROUND=true },
}
Variants.affinities = AFFINITIES

-- These are names already used by Weather FX config/game data. Variants also
-- remain eligible wherever their base species was just rolled, which is the
-- strongest habitat signal and avoids inventing encounter-table map IDs.
local HABITAT = {
  ASHFALL={ "CINNABAR", "POKEMON_MANSION", "POWER_PLANT" },
  SMOG={ "CELADON", "SAFFRON", "POKEMON_MANSION", "POWER_PLANT" },
  FOG={ "POKEMON_TOWER", "ROCK_TUNNEL", "MT_MOON", "SEAFOAM" },
  HAUNTED_MIST={ "POKEMON_TOWER", "LAVENDER", "ROCK_TUNNEL" },
  SANDSTORM={ "ROUTE_3", "ROUTE_4", "MT_MOON", "ROCK_TUNNEL", "VICTORY_ROAD", "DIGLETTS_CAVE" },
  DUSTSTORM={ "ROUTE_3", "ROUTE_4", "MT_MOON", "ROCK_TUNNEL", "VICTORY_ROAD" },
  SNOW_LIGHT={ "ROUTE_23", "INDIGO_PLATEAU", "SEAFOAM", "VICTORY_ROAD" },
  BLIZZARD={ "ROUTE_23", "INDIGO_PLATEAU", "SEAFOAM", "VICTORY_ROAD" },
  HAIL={ "ROUTE_23", "INDIGO_PLATEAU", "SEAFOAM" },
  STORM={ "ROUTE_", "POWER_PLANT", "CINNABAR", "SEA_ROUTE" },
  RAIN_LIGHT={ "ROUTE_", "FOREST", "CINNABAR", "SEAFOAM" },
  RAIN_HEAVY={ "ROUTE_", "FOREST", "CINNABAR", "SEAFOAM" },
  HEAVY_RAIN={ "ROUTE_", "CINNABAR", "SEAFOAM" },
}
Variants.habitats = HABITAT

local function deepCopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do out[deepCopy(k, seen)] = deepCopy(v, seen) end
  return out
end

local byCohortBase = {}
local byId = {}
for i, row in ipairs(Data) do
  -- Imported/generated WX rows did not historically require a cohort. Lua
  -- cannot use nil as a table key, so normalise those rows before building
  -- the evolution lookup. Keeping the fallback stable also lets all CHROMA
  -- forms evolve into the matching CHROMA form of the next species.
  local cohort = row.cohort
  if cohort == nil then
    cohort = row.variant == "CHROMA" and "chroma" or ("uncategorised:" .. tostring(i))
    row.cohort = cohort
  end
  if row.base ~= nil and row.id ~= nil then
    byCohortBase[cohort] = byCohortBase[cohort] or {}
    byCohortBase[cohort][row.base] = row.id
    byId[row.id] = row
  end
end

local function rewriteEvolution(value, cohort, inEvolution, seen)
  if type(value) == "string" then
    if inEvolution then return byCohortBase[cohort][value] or value end
    return value
  end
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do
    local key = tostring(k):lower()
    local evo = inEvolution or key:find("evol", 1, true) ~= nil
    out[k] = rewriteEvolution(v, cohort, evo, seen)
  end
  return out
end

local function typeAvailable(typeId)
  local chart = mod.content and mod.content.type_chart
  return not chart or type(chart.get) ~= "function" or chart:get(typeId) ~= nil
end

-- ---------------------------------------------------------------------------
-- Learnset adaptation for new typings
-- ---------------------------------------------------------------------------
-- Weather variants change types (e.g. Bulbasaur Bloom: Grass/Poison → Grass/Fairy).
-- The base learnset is kept where it still makes sense; offensive moves of a
-- dropped type are swapped for thematic moves of an added type, and each new
-- type is guaranteed a few STAB options across the level curve.
-- Move ids that are not registered by the engine are skipped at swap time.

-- Static fallback type map for common Gen 1–3 / modern moves. Registry lookup
-- is preferred when available; this covers the case where content.moves is
-- thin or the move is only known by id string.
local MOVE_TYPES = {
  -- Normal
  TACKLE="NORMAL", SCRATCH="NORMAL", POUND="NORMAL", QUICK_ATTACK="NORMAL",
  BODY_SLAM="NORMAL", TAKE_DOWN="NORMAL", DOUBLE_EDGE="NORMAL", HYPER_BEAM="NORMAL",
  SWIFT="NORMAL", SLAM="NORMAL", STRENGTH="NORMAL", CUT="NORMAL", HEADBUTT="NORMAL",
  -- Fire
  EMBER="FIRE", FLAMETHROWER="FIRE", FIRE_BLAST="FIRE", FIRE_PUNCH="FIRE",
  FIRE_SPIN="FIRE", FLAME_WHEEL="FIRE", HEAT_WAVE="FIRE", OVERHEAT="FIRE",
  FLARE_BLITZ="FIRE", LAVA_PLUME="FIRE", INCINERATE="FIRE",
  -- Water
  WATER_GUN="WATER", BUBBLE="WATER", BUBBLEBEAM="WATER", SURF="WATER",
  HYDRO_PUMP="WATER", WATERFALL="WATER", WHIRLPOOL="WATER", AQUA_JET="WATER",
  AQUA_TAIL="WATER", SCALD="WATER", WATER_PULSE="WATER",
  -- Grass
  VINE_WHIP="GRASS", RAZOR_LEAF="GRASS", SOLARBEAM="GRASS", PETAL_DANCE="GRASS",
  MEGA_DRAIN="GRASS", GIGA_DRAIN="GRASS", SEED_BOMB="GRASS", LEAF_BLADE="GRASS",
  ENERGY_BALL="GRASS", MAGICAL_LEAF="GRASS", LEAF_STORM="GRASS", POWER_WHIP="GRASS",
  -- Electric
  THUNDER_SHOCK="ELECTRIC", THUNDERBOLT="ELECTRIC", THUNDER="ELECTRIC",
  THUNDER_WAVE="ELECTRIC", SPARK="ELECTRIC", THUNDER_PUNCH="ELECTRIC",
  WILD_CHARGE="ELECTRIC", DISCHARGE="ELECTRIC", VOLT_TACKLE="ELECTRIC",
  -- Ice
  ICE_BEAM="ICE", BLIZZARD="ICE", AURORA_BEAM="ICE", ICE_PUNCH="ICE",
  POWDER_SNOW="ICE", ICY_WIND="ICE", ICE_SHARD="ICE", AVALANCHE="ICE",
  -- Fighting
  KARATE_CHOP="FIGHTING", SUBMISSION="FIGHTING", LOW_KICK="FIGHTING",
  SEISMIC_TOSS="FIGHTING", CROSS_CHOP="FIGHTING", BRICK_BREAK="FIGHTING",
  CLOSE_COMBAT="FIGHTING", AURA_SPHERE="FIGHTING", DRAIN_PUNCH="FIGHTING",
  -- Poison
  POISON_STING="POISON", ACID="POISON", SLUDGE="POISON", TOXIC="POISON",
  POISON_POWDER="POISON", SLUDGE_BOMB="POISON", POISON_JAB="POISON",
  VENOSHOCK="POISON", GUNK_SHOT="POISON",
  -- Ground
  EARTHQUAKE="GROUND", DIG="GROUND", BONE_CLUB="GROUND", MUD_SLAP="GROUND",
  BULLDOZE="GROUND", EARTH_POWER="GROUND", MUD_SHOT="GROUND",
  -- Flying
  GUST="FLYING", WING_ATTACK="FLYING", FLY="FLYING", PECK="FLYING",
  DRILL_PECK="FLYING", AERIAL_ACE="FLYING", AIR_SLASH="FLYING", BRAVE_BIRD="FLYING",
  HURRICANE="FLYING",
  -- Psychic
  CONFUSION="PSYCHIC_TYPE", PSYCHIC="PSYCHIC_TYPE", PSYBEAM="PSYCHIC_TYPE",
  PSYWAVE="PSYCHIC_TYPE", FUTURE_SIGHT="PSYCHIC_TYPE", EXTRASENSORY="PSYCHIC_TYPE",
  ZEN_HEADBUTT="PSYCHIC_TYPE", STORED_POWER="PSYCHIC_TYPE",
  -- Bug
  LEECH_LIFE="BUG", PIN_MISSILE="BUG", TWINEEDLE="BUG", MEGAHORN="BUG",
  SIGNAL_BEAM="BUG", X_SCISSOR="BUG", BUG_BUZZ="BUG", U_TURN="BUG",
  -- Rock
  ROCK_THROW="ROCK", ROCK_SLIDE="ROCK", ANCIENTPOWER="ROCK", STONE_EDGE="ROCK",
  ROCK_TOMB="ROCK", POWER_GEM="ROCK",
  -- Ghost
  LICK="GHOST", NIGHT_SHADE="GHOST", CONFUSE_RAY="GHOST", SHADOW_BALL="GHOST",
  SHADOW_CLAW="GHOST", HEX="GHOST", SHADOW_SNEAK="GHOST", PHANTOM_FORCE="GHOST",
  -- Dragon
  DRAGON_RAGE="DRAGON", OUTRAGE="DRAGON", DRAGON_CLAW="DRAGON",
  DRAGON_PULSE="DRAGON", DRACO_METEOR="DRAGON", DRAGON_BREATH="DRAGON",
  -- Dark
  BITE="DARK", CRUNCH="DARK", PURSUIT="DARK", FAINT_ATTACK="DARK",
  THIEF="DARK", NIGHT_SLASH="DARK", DARK_PULSE="DARK", FOUL_PLAY="DARK",
  -- Steel
  METAL_CLAW="STEEL", IRON_TAIL="STEEL", STEEL_WING="STEEL", FLASH_CANNON="STEEL",
  IRON_HEAD="STEEL", METEOR_MASH="STEEL",
  -- Fairy
  MOONBLAST="FAIRY", DAZZLING_GLEAM="FAIRY", PLAY_ROUGH="FAIRY",
  FAIRY_WIND="FAIRY", DRAINING_KISS="FAIRY", DISARMING_VOICE="FAIRY",
  CHARM="FAIRY", SWEET_KISS="FAIRY", MOONLIGHT="FAIRY",
}

-- Preferred STAB / thematic moves per type, ordered early → late game.
-- Only ids that exist in the move registry are actually written.
local TYPE_MOVE_POOL = {
  -- v5.16.27: cross-generation early STAB catalogue.  Entries are ordered
  -- weakest/earliest first and are filtered through the live move registry,
  -- so RBY uses moves it actually exposes while Gold/Silver and the embedded
  -- expanded dex can use Gen 2+ attacks.  Every damaging type has a real STAB
  -- option now; Steel/Fairy no longer fall back to Normal/status moves.
  FIRE     = { "EMBER", "FIRE_FANG", "FLAME_WHEEL", "FIRE_PUNCH", "FLAMETHROWER" },
  WATER    = { "WATER_GUN", "BUBBLE", "AQUA_JET", "WATER_PULSE", "BUBBLEBEAM" },
  GRASS    = { "ABSORB", "VINE_WHIP", "MAGICAL_LEAF", "MEGA_DRAIN", "RAZOR_LEAF" },
  ELECTRIC = { "THUNDERSHOCK", "SPARK", "ELECTRO_BALL", "THUNDERPUNCH", "THUNDERBOLT" },
  ICE      = { "POWDER_SNOW", "ICE_SHARD", "ICY_WIND", "AURORA_BEAM", "ICE_PUNCH" },
  FIGHTING = { "ROCK_SMASH", "KARATE_CHOP", "ARM_THRUST", "LOW_KICK", "MACH_PUNCH" },
  POISON   = { "POISON_STING", "ACID", "SMOG", "SLUDGE", "VENOSHOCK" },
  GROUND   = { "MUD_SLAP", "MUD_SHOT", "BONE_CLUB", "BULLDOZE", "DIG" },
  FLYING   = { "GUST", "PECK", "WING_ATTACK", "AERIAL_ACE", "AIR_CUTTER" },
  PSYCHIC_TYPE = { "CONFUSION", "PSYBEAM", "ZEN_HEADBUTT", "PSYCHIC" },
  BUG      = { "FURY_CUTTER", "LEECH_LIFE", "TWINEEDLE", "PIN_MISSILE", "BUG_BITE" },
  ROCK     = { "ROCK_THROW", "ROCK_TOMB", "SMACK_DOWN", "ANCIENT_POWER", "ROCK_SLIDE" },
  GHOST    = { "LICK", "ASTONISH", "SHADOW_SNEAK", "HEX", "SHADOW_CLAW" },
  DRAGON   = { "TWISTER", "DRAGON_RAGE", "DRAGON_BREATH", "DRAGON_CLAW" },
  DARK     = { "PURSUIT", "BITE", "THIEF", "FAINT_ATTACK", "SNARL" },
  STEEL    = { "METAL_CLAW", "BULLET_PUNCH", "STEEL_WING", "IRON_HEAD" },
  FAIRY    = { "FAIRY_WIND", "DISARMING_VOICE", "DRAINING_KISS", "DAZZLING_GLEAM" },
  NORMAL   = { "TACKLE", "SCRATCH", "POUND", "QUICK_ATTACK", "BODY_SLAM" },
}


-- Gen1Recomp uses a handful of historical compact move ids.  Never let a
-- pretty/underscored alias leak into a Pokemon record: the summary screen
-- resolves PP from the canonical move registry and an alias can become a
-- zero-PP/invalid slot until the save is reconstructed.
local MOVE_ID_ALIASES = {
  BUBBLE_BEAM = "BUBBLEBEAM",
  THUNDER_SHOCK = "THUNDERSHOCK",
  THUNDER_PUNCH = "THUNDERPUNCH",
  POISON_POWDER = "POISONPOWDER",
}

local function canonicalMoveId(moveId)
  if type(moveId) == "table" then
    moveId = moveId.move or moveId.id or moveId[2]
  end
  if not moveId then return nil end
  local id = tostring(moveId):upper():gsub(" ", "_"):gsub("-", "_")
  return MOVE_ID_ALIASES[id] or id
end

local function moveTypeOf(moveId)
  if not moveId then return nil end
  local id = canonicalMoveId(moveId)
  -- Prefer live registry
  local moves = mod.content and mod.content.moves
  if moves and type(moves.get) == "function" then
    local ok, def = pcall(function() return moves:get(id) end)
    if ok and type(def) == "table" and def.type then
      return tostring(def.type):upper()
    end
  end
  return MOVE_TYPES[id]
end

local function moveExists(moveId)
  if not moveId then return false end
  local id = canonicalMoveId(moveId)
  local moves = mod.content and mod.content.moves
  if moves and type(moves.get) == "function" then
    local ok, def = pcall(function() return moves:get(id) end)
    if ok and type(def) == "table" then return true end
    -- Also try without underscores / with spaces for host registries
    local alt = id:gsub("_", "")
    ok, def = pcall(function() return moves:get(alt) end)
    if ok and type(def) == "table" then return true end
    -- A live registry is authoritative. Falling through to a static allowlist
    -- here previously admitted aliases/nonexistent ids and produced PP=0.
    return false
  end
  -- Gen 1 safe static set only (no Gen2+ exclusive moves like POWDER_SNOW)
  -- Prefer live registry; static allowlist is Gen 1 RBY only.
  local GEN1_SAFE = {
    EMBER=true, FIRE_PUNCH=true, FLAMETHROWER=true, FIRE_BLAST=true,
    WATER_GUN=true, BUBBLEBEAM=true, SURF=true, HYDRO_PUMP=true,
    VINE_WHIP=true, MEGA_DRAIN=true, RAZOR_LEAF=true, SOLARBEAM=true,
    THUNDERSHOCK=true, THUNDERPUNCH=true, THUNDERBOLT=true, THUNDER=true,
    ICE_PUNCH=true, ICE_BEAM=true, BLIZZARD=true, AURORA_BEAM=true,
    KARATE_CHOP=true, SUBMISSION=true, SEISMIC_TOSS=true, COUNTER=true,
    POISON_STING=true, ACID=true, SLUDGE=true, POISON_GAS=true,
    BONE_CLUB=true, DIG=true, EARTHQUAKE=true, FISSURE=true,
    GUST=true, WING_ATTACK=true, PECK=true, DRILL_PECK=true,
    CONFUSION=true, PSYBEAM=true, PSYCHIC=true, DREAM_EATER=true,
    LEECH_LIFE=true, TWINEEDLE=true, PIN_MISSILE=true, STRING_SHOT=true,
    ROCK_THROW=true, ROCK_SLIDE=true,
    LICK=true, NIGHT_SHADE=true, CONFUSE_RAY=true,
    DRAGON_RAGE=true, BITE=true,
    TACKLE=true, BODY_SLAM=true, HYPER_BEAM=true, QUICK_ATTACK=true,
    DOUBLESLAP=true, SING=true, PETAL_DANCE=true,
  }
  return GEN1_SAFE[id] == true
end

local function typeSet(types)
  local s = {}
  for _, t in ipairs(types or {}) do
    s[tostring(t):upper()] = true
  end
  return s
end

local function pickReplacement(newTypes, used, tier)
  -- tier 1=early, 2=mid, 3=late
  for _, t in ipairs(newTypes) do
    local pool = TYPE_MOVE_POOL[t]
    if pool then
      local idx = math.min(math.max(tier or 2, 1), #pool)
      -- Prefer unused moves of this type
      for step = 0, #pool - 1 do
        local candidate = pool[((idx - 1 + step) % #pool) + 1]
        if moveExists(candidate) and not used[candidate] then
          return candidate
        end
      end
    end
  end
  return nil
end

-- Normalize every host learnset shape before a WX species reaches UI/battle
-- code. Gen 1 commonly uses {level=, move=}; Gen 2 integrations may expose
-- {level, move} or levelMoves. Leaving positional rows unsanitized was the
-- source of low-level WX summary crashes: invalid move ids survived species
-- registration, then save validation removed them after reload.
local function sanitizeLevelRows(rows)
  if type(rows) ~= "table" then return rows end
  local out = {}
  for _, entry in ipairs(rows) do
    if type(entry) == "table" then
      local id = canonicalMoveId(entry.move or entry.id or entry[2])
      local level = tonumber(entry.level or entry.at or entry[1])
      if id and moveExists(id) then
        if entry.move ~= nil or entry.level ~= nil or entry.at ~= nil or entry.id ~= nil then
          local copy = {}
          for k,v in pairs(entry) do copy[k]=v end
          if copy.move ~= nil then copy.move=id
          elseif copy.id ~= nil then copy.id=id
          else copy[2]=id end
          out[#out+1]=copy
        elseif level then
          out[#out+1]={level,id}
        end
      end
    elseif type(entry) == "string" then
      local id=canonicalMoveId(entry)
      if moveExists(id) then out[#out+1]=id end
    end
  end
  return out
end

local function adaptLearnset(clone, baseTypes, newTypes)
  if type(clone) ~= "table" then return end
  local oldSet = typeSet(baseTypes)
  local newSet = typeSet(newTypes)
  local added, removed = {}, {}
  for t in pairs(newSet) do
    if not oldSet[t] then added[#added + 1] = t end
  end
  for t in pairs(oldSet) do
    if not newSet[t] then removed[t] = true end
  end
  -- Even with unchanged types, strip moves the host cannot resolve.
  if #added == 0 and next(removed) == nil then
    if type(clone.level1Moves) == "table" then
      local out = {}
      for _, mv in ipairs(clone.level1Moves) do
        local id = canonicalMoveId(mv)
        if moveExists(id) then out[#out + 1] = id end
      end
      clone.level1Moves = out
    end
    if type(clone.learnset) == "table" then
      local out = {}
      for _, entry in ipairs(clone.learnset) do
        if type(entry) == "table" and entry.move then
          local mv = tostring(entry.move):upper():gsub(" ", "_"):gsub("-", "_")
          if moveExists(mv) then
            entry.move = mv
            out[#out + 1] = entry
          end
        elseif type(entry) == "table" then
          out[#out + 1] = entry
        end
      end
      clone.learnset = out
    end
    return
  end

  local used = {}
  local function mark(id)
    if id then used[tostring(id):upper()] = true end
  end

  -- Rewrite level-up learnset entries
  if type(clone.learnset) == "table" then
    local out = {}
    for _, entry in ipairs(clone.learnset) do
      if type(entry) == "table" and entry.move then
        local mv = canonicalMoveId(entry.move)
        local mt = moveTypeOf(mv)
        local level = tonumber(entry.level) or 1
        local keep = entry
        if not moveExists(mv) then
          keep = nil  -- drop unresolved move ids
        elseif mt and removed[mt] then
          local tier = level <= 15 and 1 or (level <= 30 and 2 or 3)
          local rep = pickReplacement(added, used, tier)
          if rep then
            keep = { level = level, move = rep }
            mark(rep)
          else
            keep = nil
          end
        else
          entry.move = mv
          mark(mv)
        end
        if keep then out[#out + 1] = keep end
      elseif type(entry) == "table" then
        out[#out + 1] = entry
      end
    end
    -- Inject STAB moves for each added type if still missing
    local levels = { 12, 22, 32, 42 }
    for i, t in ipairs(added) do
      local pool = TYPE_MOVE_POOL[t]
      if pool then
        local hasStab = false
        for _, e in ipairs(out) do
          if type(e) == "table" and moveTypeOf(e.move) == t then
            hasStab = true; break
          end
        end
        if not hasStab then
          for _, mv in ipairs(pool) do
            if moveExists(mv) and not used[mv] then
              local lvl = levels[math.min(i, #levels)] or 28
              out[#out + 1] = { level = lvl, move = mv }
              mark(mv)
              break
            end
          end
        end
      end
    end
    table.sort(out, function(a, b)
      return (tonumber(a.level) or 0) < (tonumber(b.level) or 0)
    end)
    clone.learnset = out
  end

  -- Rewrite level-1 moves similarly.
  -- ALWAYS drop moves the host does not know (prevents:
  --   pokemon.WX_*_*.level1Moves[n]: unresolved reference to ...)
  if type(clone.level1Moves) == "table" then
    local out = {}
    for _, mv in ipairs(clone.level1Moves) do
      local id = canonicalMoveId(mv)
      if not moveExists(id) then
        -- skip unresolved host move
      else
        local mt = moveTypeOf(id)
        if mt and removed[mt] then
          local rep = pickReplacement(added, used, 1)
          if rep then
            out[#out + 1] = rep
            mark(rep)
          end
        else
          out[#out + 1] = id
          mark(id)
        end
      end
    end
    -- Do NOT inject new STAB directly into level1Moves. Variant catches must
    -- have the same number of starting moves as their base species at that
    -- level. Added-type STAB belongs on the level-up curve above, otherwise
    -- low-level catches can acquire phantom/zero-PP moves.
    clone.level1Moves = out
  end

  -- Optional modern full learnset field used by national_dex consumers
  if type(clone.movesFull) == "table" then
    local out = {}
    for _, entry in ipairs(clone.movesFull) do
      if type(entry) == "table" and entry.move then
        local mv = tostring(entry.move):upper():gsub(" ", "_"):gsub("-", "_")
        if not moveExists(mv) then
          -- drop unresolved
        else
          local mt = moveTypeOf(mv)
          if mt and removed[mt] then
            local tier = (tonumber(entry.level) or 1) <= 15 and 1 or 2
            local rep = pickReplacement(added, used, tier)
            if rep then
              out[#out + 1] = { level = entry.level, move = rep, name = entry.name }
              mark(rep)
            end
          else
            entry.move = mv
            out[#out + 1] = entry
            mark(mv)
          end
        end
      else
        out[#out + 1] = entry
      end
    end
    clone.movesFull = out
  end
end

function Variants.install()
  local registry = mod.content and mod.content.pokemon
  if not registry or type(registry.get) ~= "function" or type(registry.register) ~= "function" then
    mod.log:warn("weather variants disabled: pokemon registry cannot register species")
    return false
  end
  local registered, skipped = 0, 0
  for _, row in ipairs(Data) do
    if Variants.registered[row.id] then
      registered = registered + 1
    else
      local base = registry:get(row.base)
    -- Regional Johto starters must work on vanilla Yellow/RB. Resolve their
    -- real Johto base record from The World's bundled species data rather than
    -- cloning an unrelated Kanto starter or waiting until NPC interaction.
    if type(base) ~= "table" and (row.starterRegional or STARTER_BASES[row.base]) and bundledSpecies then
      base = bundledSpecies[row.base]
    end
    if type(base) ~= "table" and row.kantoReforged and kantoPack and kantoPack.species then
      base = kantoPack.species[row.base]
    end
    local typesOk = true
    for _, typeId in ipairs(row.types) do
      if not typeAvailable(typeId) then typesOk = false break end
    end
    if type(base) ~= "table" or not typesOk then
      Variants.skipped[row.id] = type(base) ~= "table" and "base missing" or "type missing"
      skipped = skipped + 1
    else
      local clone = rewriteEvolution(deepCopy(base), row.cohort, false)
      -- `index` is the imported ROM species number, not reusable identity.
      -- Duplicating it across hundreds of registered records makes engine
      -- paths that index auxiliary species tables resolve the vanilla base
      -- unpredictably. Registered species use their string id; dex may remain
      -- shared so the legal base Pokédex entry is retained.
      clone.index = nil
      clone.id = row.id
      clone.name = row.variant .. " " .. row.baseName:upper()
      clone.types = deepCopy(row.types)

      -- Always point visual / follower systems at the original species so
      -- overworld-spawn-mod (Wilds of Kanto) and similar mods can resolve
      -- HGSS / follower sprites by base id instead of the WX_ form id.
      clone.baseSpecies = row.base
      clone.spriteSpecies = row.base
      clone.overworldSpecies = row.base
      clone.followerSpecies = row.base

      -- national_dex compatibility: register as an alternate *form* of the
      -- base species, never as a new numbered Pokédex row.
      -- national_dex's dex UI builds form lists from records that carry
      -- baseSpecies + form, and ignores synthetic dex numbers >= FORM_DEX_BASE
      -- when drawing the main 1..1025 list. Without this, hundreds of weather
      -- variants would appear as extra species and break sorting / seen-only
      -- / page jumps.
      if NATIONAL_DEX then
        if (row.variant or ""):upper() == "PRIMALWEATHER" then
          clone.form = "PRIMALWEATHER"
        else
          clone.form = "WX_" .. (row.variant or "VARIANT"):gsub("%s+", "_")
        end
        -- Synthetic dex number well above national 1025 and national_dex's
        -- own form range (~20000). Unique per variant so byDex lookups stay
        -- unambiguous while remaining invisible on the main list.
        clone.dex = FORM_DEX_BASE + (tonumber(row.n) or 0)
        -- Keep a pointer to the real national number for any UI that wants
        -- to show "No. XXX" of the base while browsing the form.
        clone.baseDex = (type(base.dex) == "number" and base.dex)
          or (type(base.baseDex) == "number" and base.baseDex)
          or nil
      else
        -- Without national_dex, share the base's dex number so legacy
        -- PokedexMenu paths still resolve something sensible and we never
        -- invent a new 1–151/251 slot.
        if type(base.dex) == "number" then
          clone.dex = base.dex
        end
      end

      -- Ability assignment (expanded + type-aware):
      -- 1. Explicit row.ability wins, then thematic weather/typing pick.
      -- 2. Gen 9-only abilities are rewritten to Gen 3-safe alternatives
      --    unless Gen9Dex / g9-battle-engine is installed.
      local HAS_GEN9 = Variants.gen9Dex == true
      local GEN9_ONLY = {
        BEADS_OF_RUIN = true, WIND_RIDER = true, ORICHALCUM_PULSE = true,
        HADRON_ENGINE = true, PROTOSYNTHESIS = true, QUARK_DRIVE = true,
        SUPREME_OVERLORD = true, ANGERSHELL = true, GOOD_AS_GOLD = true,
        TOXIC_DEBRIS = true, ARMOR_TAIL = true, ROCKY_PAYLOAD = true,
        SHARPNESS = true, SUPERSWEET_SYRUP = true, MINDSEYE = true,
        EMBODY_ASPECT = true, TERA_SHIFT = true, TERA_SHELL = true,
        TERAFORM_ZERO = true, POISON_PUPPETEER = true,
      }
      -- Fallback when Gen9 is absent (Gen 3 / common ability set).
      local GEN9_FALLBACK = {
        BEADS_OF_RUIN = "PRESSURE",
        WIND_RIDER = "GALE_WINGS",
        ORICHALCUM_PULSE = "DROUGHT",
        HADRON_ENGINE = "ELECTRIC_SURGE",
        PROTOSYNTHESIS = "CHLOROPHYLL",
        QUARK_DRIVE = "MOTOR_DRIVE",
        SUPREME_OVERLORD = "PRESSURE",
        ANGERSHELL = "GUTS",
        GOOD_AS_GOLD = "CLEAR_BODY",
        TOXIC_DEBRIS = "POISON_POINT",
        ARMOR_TAIL = "INNER_FOCUS",
        ROCKY_PAYLOAD = "STURDY",
        SHARPNESS = "HYPER_CUTTER",
        SUPERSWEET_SYRUP = "CUTE_CHARM",
        MINDSEYE = "KEEN_EYE",
        EMBODY_ASPECT = "PRESSURE",
        TERA_SHIFT = "PROTEAN",
        TERA_SHELL = "MULTISCALE",
        TERAFORM_ZERO = "CLOUD_NINE",
        POISON_PUPPETEER = "POISON_TOUCH",
        -- Also treat some Gen 6–8 weather abilities as optional if missing
        GALE_WINGS = "SPEED_BOOST",
        ELECTRIC_SURGE = "STATIC",
        PROTEAN = "ADAPTABILITY",
        MULTISCALE = "STURDY",
        POISON_TOUCH = "POISON_POINT",
      }
      local function abilityExists(id)
        if not id then return false end
        id = tostring(id):upper()
        local ab = mod.content and mod.content.abilities
        if ab and type(ab.get) == "function" then
          local ok, def = pcall(function() return ab:get(id) end)
          if ok and def ~= nil then return true end
        end
        if ab and type(ab) == "table" and ab[id] then return true end
        return false
      end
      -- Abilities safe when the host has no ability registry (vanilla Gen 1
      -- often has none — returning nil is better than an unresolved id).
      local VANILLA_OK = {
        -- Prefer nil on pure Gen 1; only keep widely-modded ability names
        -- if the registry confirms them via abilityExists.
      }
      local function sanitizeAbility(id, row)
        if not id or id == "" then return nil end
        id = tostring(id):upper()
        if id == "ICE_SCALES" or id == "THICK_FAT" or id == "SHADOW_SHIELD" or id == "MEGA_SOL" then return id end
        if row and row.starterRegional and (id == "HUGE_POWER" or id == "PURE_POWER" or id == "CORROSION") then return id end
        if not HAS_GEN9 and GEN9_ONLY[id] then
          id = GEN9_FALLBACK[id] or "PRESSURE"
        end
        -- Chain fallbacks until registry accepts or we give up
        local guard = 0
        while id and guard < 6 do
          guard = guard + 1
          if abilityExists(id) then return id end
          local fb = GEN9_FALLBACK[id]
          if fb and fb ~= id then id = fb
          else
            -- The World ships its own battle-ability implementation, so WX
            -- species must keep an ability even when the host exposes no
            -- content.abilities registry (notably vanilla Gen 1). Prefer a
            -- registered ability when possible, otherwise fall back to an
            -- ability implemented by The World's battle layer.
            for _, cand in ipairs({ "STATIC", "CHLOROPHYLL", "SWIFT_SWIM", "FLASH_FIRE", "INTIMIDATE" }) do
              if abilityExists(cand) then return cand end
            end
            local WORLD_ABILITY_FALLBACK = {
              PRESSURE="INTIMIDATE", STATIC="STATIC", CHLOROPHYLL="CHLOROPHYLL",
              SWIFT_SWIM="SWIFT_SWIM", FLASH_FIRE="FLASH_FIRE", SNOW_CLOAK="MAGMA_ARMOR",
              SAND_VEIL="INTIMIDATE", POISON_POINT="POISON_POINT", STENCH="INTIMIDATE",
              SPEED_BOOST="VITAL_SPIRIT", COMPOUND_EYES="ILLUMINATE", CLOUD_NINE="AIR_LOCK",
              STURDY="VITAL_SPIRIT", GUTS="VITAL_SPIRIT", CLEAR_BODY="OWN_TEMPO",
              INNER_FOCUS="OWN_TEMPO", HYPER_CUTTER="INTIMIDATE", CUTE_CHARM="OWN_TEMPO",
              KEEN_EYE="ILLUMINATE", MOTOR_DRIVE="LIGHTNING_ROD", ADAPTABILITY="INTIMIDATE",
              DROUGHT="DROUGHT", DRIZZLE="DRIZZLE", WATER_ABSORB="WATER_VEIL",
              VOLT_ABSORB="LIGHTNING_ROD", HUGE_POWER="INTIMIDATE", PURE_POWER="INTIMIDATE", THICK_FAT="THICK_FAT",
            }
            return WORLD_ABILITY_FALLBACK[id] or "INTIMIDATE"
          end
        end
        return nil
      end
      local function hasType(types, ...)
        if not types then return false end
        local want = {...}
        for _, t in ipairs(types) do
          for _, w in ipairs(want) do
            if t == w then return true end
          end
        end
        return false
      end
      local function thematicAbility(r)
        if r.ability and r.ability ~= "" then return r.ability end
        local w = (r.weather or ""):upper()
        local types = r.types or {}
        local variant = (r.variant or ""):upper()

        -- Signature / legendary-tier specials
        if variant == "PRIMALWEATHER" then
          if HAS_GEN9 then return "AIR_LOCK" end
          return "CLOUD_NINE"
        end
        if w:find("ECLIPSE") then
          return HAS_GEN9 and "BEADS_OF_RUIN" or "PRESSURE"
        end
        if variant:find("VOID") or variant:find("SHADOW") then
          return "PRESSURE"
        end
        if variant:find("INFERNO") or variant:find("SOLAR") then
          return "DROUGHT"
        end
        if variant:find("MAELSTROM") or variant:find("TEMPEST") then
          return hasType(types, "WATER") and "DRIZZLE" or "SWIFT_SWIM"
        end

        -- Rain family
        if w:find("RAIN") or w:find("FLOOD") or w == "STORM" then
          if hasType(types, "WATER") then return "DRIZZLE" end
          if hasType(types, "BUG", "GRASS") then return "SWIFT_SWIM" end
          if hasType(types, "ELECTRIC") then return "MOTOR_DRIVE" end
          return "HYDRATION"
        end

        -- Sun / heat
        if w:find("SUN") or w:find("HEAT") or w:find("HARSH") then
          if hasType(types, "FIRE") then return "DROUGHT" end
          if hasType(types, "GRASS") then return "CHLOROPHYLL" end
          if hasType(types, "FIRE", "GROUND") then return "FLASH_FIRE" end
          return "SOLAR_POWER"
        end

        -- Sand / dust
        if w:find("SAND") or w:find("DUST") then
          if hasType(types, "ROCK", "GROUND", "STEEL") then return "SAND_STREAM" end
          if hasType(types, "GROUND") then return "SAND_FORCE" end
          return "SAND_VEIL"
        end

        -- Cold weather
        if w:find("SNOW") or w:find("HAIL") or w:find("BLIZZARD") or w:find("SLEET") then
          if hasType(types, "ICE") then return "SNOW_WARNING" end
          if hasType(types, "WATER", "ICE") then return "ICE_BODY" end
          return "SNOW_CLOAK"
        end

        -- Thunder / electric storms
        if w:find("THUNDER") or w:find("STATIC") then
          if hasType(types, "ELECTRIC") then return "STATIC" end
          if hasType(types, "FLYING", "ELECTRIC") then return "LIGHTNING_ROD" end
          return "MOTOR_DRIVE"
        end

        -- Fog / mist / haunted
        if w:find("FOG") or w:find("MIST") or w:find("HAUNTED") then
          if hasType(types, "GHOST", "DARK", "PSYCHIC_TYPE") then return "PRESSURE" end
          if hasType(types, "FAIRY") then return "MAGIC_BOUNCE" end
          return "FORECAST"
        end

        -- Ash / volcanic
        if w:find("ASH") then
          if hasType(types, "FIRE", "GHOST") then return "FLASH_FIRE" end
          return "WHITE_SMOKE"
        end

        -- Wind / gale
        if w:find("WIND") or w:find("GALE") or w:find("TYPHOON") then
          if hasType(types, "FLYING") then
            return HAS_GEN9 and "WIND_RIDER" or "SPEED_BOOST"
          end
          if hasType(types, "BUG", "FLYING") then return "COMPOUND_EYES" end
          return HAS_GEN9 and "GALE_WINGS" or "SPEED_BOOST"
        end

        -- Smog / poison weather
        if w:find("SMOG") or w:find("ACID") then
          if hasType(types, "POISON") then return "POISON_POINT" end
          return "STENCH"
        end

        -- Fallback by dominant type when weather is ambiguous
        if hasType(types, "WATER") then return "SWIFT_SWIM" end
        if hasType(types, "FIRE") then return "FLASH_FIRE" end
        if hasType(types, "GRASS") then return "CHLOROPHYLL" end
        if hasType(types, "ICE") then return "SNOW_CLOAK" end
        if hasType(types, "ELECTRIC") then return "STATIC" end
        if hasType(types, "GROUND", "ROCK") then return "SAND_VEIL" end
        if hasType(types, "GHOST") then return "PRESSURE" end

        return nil
      end
      local chosen = sanitizeAbility(row.ability or thematicAbility(row), row)

      -- v5.16.19 WX ability suitability audit.  Do not assign an ability whose
      -- only battle effect is already supplied by the variant's own typing.
      -- This is deliberately conservative: abilities such as FLASH_FIRE on a
      -- Fire type are retained because The World's implementation still grants
      -- their offensive/trigger benefit, while IMMUNITY on a Poison type is a
      -- genuinely dead slot.
      local function wxAbilityUseful(id, types)
        id = tostring(id or ""):upper()
        if id == "IMMUNITY" and hasType(types, "POISON") then return false end
        if id == "LIMBER" and hasType(types, "ELECTRIC") then return false end
        if id == "MAGMA_ARMOR" and hasType(types, "ICE") then return false end
        if id == "WATER_VEIL" and hasType(types, "FIRE") then return false end
        if id == "LEVITATE" and hasType(types, "FLYING") then return false end
        return true
      end
      if chosen and not wxAbilityUseful(chosen, row.types or clone.types) then
        if hasType(row.types or clone.types, "POISON") then chosen = "POISON_POINT"
        elseif hasType(row.types or clone.types, "ELECTRIC") then chosen = "STATIC"
        elseif hasType(row.types or clone.types, "ICE") then chosen = "ICE_BODY"
        elseif hasType(row.types or clone.types, "FIRE") then chosen = "FLASH_FIRE"
        elseif hasType(row.types or clone.types, "FLYING") then chosen = "SPEED_BOOST"
        else chosen = "INTIMIDATE" end
        chosen = sanitizeAbility(chosen, row) or "INTIMIDATE"
      end
      clone.ability = chosen or "INTIMIDATE"
      Dex.attach(row, clone)
      clone.level1Moves = clone.level1Moves or {}
      clone.learnset = clone.learnset or {}
      clone.evolutions = clone.evolutions or {}

      -- Normalize both Gen 1 and Gen 2 curve schemas before adaptation.
      clone.learnset = sanitizeLevelRows(clone.learnset) or {}
      clone.levelMoves = sanitizeLevelRows(clone.levelMoves)
      -- Adapt learnsets to the variant's new typing: swap offensive moves of
      -- dropped types for thematic STAB of added types, and ensure each new
      -- type has at least one learnable move on the curve.
      adaptLearnset(clone, base.types, row.types)
      -- 5.12.9 regional Johto starter curves. These intentionally favour physical
      -- STAB so Huge/Pure Power is meaningful, while moveExists keeps RBY/GS
      -- and optional dex hosts safe from unresolved move references.
      if row.starterRegional then
        local curves = {
          DUSKJAW = { {1,"SCRATCH"},{6,"WATER_GUN"},{10,"BITE"},{17,"HEADBUTT"},{24,"SURF"},{31,"SLASH"},{38,"CRUNCH"},{46,"HYDRO_PUMP"} },
          THORNHEART = { {1,"TACKLE"},{6,"VINE_WHIP"},{10,"RAZOR_LEAF"},{17,"KARATE_CHOP"},{24,"BODY_SLAM"},{31,"SUBMISSION"},{38,"SOLARBEAM"},{46,"EARTHQUAKE"} },
          ASHEN = { {1,"TACKLE"},{6,"EMBER"},{10,"QUICK_ATTACK"},{17,"LICK"},{24,"FIRE_PUNCH"},{31,"BODY_SLAM"},{38,"FLAMETHROWER"},{46,"SHADOW_BALL"} },
        }
        local curve = curves[tostring(row.variant or ""):upper()]
        if curve then
          local rebuilt = {}
          for _, e in ipairs(curve) do
            local id = canonicalMoveId(e[2])
            if moveExists(id) then rebuilt[#rebuilt+1] = { level=e[1], move=id } end
          end
          clone.learnset = rebuilt
        end
      end
      -- v5.16.27 all-WX level-5 STAB guarantee.  This is intentionally applied
      -- to every WX form, not only the three regional starter rows.  For each
      -- current WX type, add the first damaging move that exists on this host
      -- to the level-up curve at level 5.  Existing <=5 STAB is preserved.
      do
        clone.learnset = clone.learnset or {}
        for _, t in ipairs(row.types or clone.types or {}) do
          local typeId = tostring(t):upper()
          local hasEarly = false
          for _, e in ipairs(clone.learnset) do
            if type(e) == "table" and (tonumber(e.level or e[1]) or 99) <= 5 then
              local mid = canonicalMoveId(e.move or e.id or e[2])
              if moveTypeOf(mid) == typeId then hasEarly = true; break end
            end
          end
          if not hasEarly then
            local pool = TYPE_MOVE_POOL[typeId] or {}
            for _, mid in ipairs(pool) do
              mid = canonicalMoveId(mid)
              if moveExists(mid) and moveTypeOf(mid) == typeId then
                table.insert(clone.learnset, { level=5, move=mid })
                break
              end
            end
          end
        end
        table.sort(clone.learnset, function(a,b)
          return (tonumber(a.level or a[1]) or 99) < (tonumber(b.level or b[1]) or 99)
        end)
      end

      -- 5.15.5 starter acquisition guarantee.  Starter WX forms must be battle-ready
      -- at level 5, not merely learn their new STAB later.  Inject one resolvable
      -- damaging move for EACH registered type into both constructor paths.
      -- Pikachu also keeps Normal coverage so Ground opponents cannot hard-wall it.
      if row.starterRegional then
        local usedStart = {}
        local start = {}
        local function addStart(id)
          id = canonicalMoveId(id)
          if id and moveExists(id) and not usedStart[id] then
            usedStart[id] = true
            start[#start+1] = id
          end
        end
        for _, mv in ipairs(clone.level1Moves or {}) do addStart(mv) end
        for _, t in ipairs(row.types or {}) do
          local pool = TYPE_MOVE_POOL[tostring(t):upper()]
          if pool then
            for _, mv in ipairs(pool) do
              if moveExists(mv) then addStart(mv); break end
            end
          end
        end
        if tostring(row.base or ''):upper() == 'PIKACHU' then
          if moveExists('QUICK_ATTACK') then addStart('QUICK_ATTACK') else addStart('TACKLE') end
        end
        while #start > 4 do table.remove(start, 1) end
        clone.level1Moves = start
        clone.learnset = clone.learnset or {}
        for _, mv in ipairs(start) do
          local found = false
          for _, e in ipairs(clone.learnset) do
            if type(e)=='table' and canonicalMoveId(e.move or e.id or e[2]) == mv and (tonumber(e.level or e[1]) or 99) <= 5 then found=true; break end
          end
          if not found then table.insert(clone.learnset, 1, {level=1, move=mv}) end
        end
      end

      -- Final unresolved-move scrub (level1Moves + learnset + movesFull)
      if type(clone.level1Moves) == "table" then
        local scrub = {}
        for _, mv in ipairs(clone.level1Moves) do
          local id = canonicalMoveId(mv)
          if moveExists(id) then scrub[#scrub + 1] = id end
        end
        clone.level1Moves = scrub
      end
      if type(clone.learnset) == "table" then
        local scrub = {}
        for _, entry in ipairs(clone.learnset) do
          if type(entry) == "table" and entry.move then
            local id = tostring(entry.move):upper():gsub(" ", "_"):gsub("-", "_")
            if moveExists(id) then
              entry.move = id
              scrub[#scrub + 1] = entry
            end
          elseif type(entry) == "table" then
            local id = canonicalMoveId(entry[2])
            if id and moveExists(id) then
              local copy = {}
              for k,v in pairs(entry) do copy[k]=v end
              copy[2]=id
              scrub[#scrub + 1] = copy
            end
          end
        end
        clone.learnset = scrub
      end
      clone.levelMoves = sanitizeLevelRows(clone.levelMoves)
      if type(clone.movesFull) == "table" then
        local scrub = {}
        for _, entry in ipairs(clone.movesFull) do
          if type(entry) == "table" and entry.move then
            local id = tostring(entry.move):upper():gsub(" ", "_"):gsub("-", "_")
            if moveExists(id) then
              entry.move = id
              scrub[#scrub + 1] = entry
            end
          elseif type(entry) == "table" then
            scrub[#scrub + 1] = entry
          end
        end
        clone.movesFull = scrub
      end

      -- Cries always come from the original species. deepCopy inherits most
      -- fields, but audio systems often resolve cry by registered id or by
      -- explicit cry/cryId/crySpecies keys. Pin those to the base so a
      -- weather variant never plays silence or a missing-asset stub.
      local function copyFromBase(key)
        if base[key] ~= nil then clone[key] = base[key] end
      end
      copyFromBase("cry")
      copyFromBase("cryId")
      copyFromBase("cryPath")
      copyFromBase("cryIndex")
      copyFromBase("sound")
      copyFromBase("soundId")
      clone.crySpecies = row.base
      if clone.cryId == nil or clone.cryId == row.id then
        clone.cryId = row.base
      end
      -- Same idea for sprites: keep base art unless a variant-specific path
      -- was already supplied (none are today).
      copyFromBase("spriteFront")
      copyFromBase("spriteBack")
      -- 5.16.17: authored WX forms now have per-variant, type-themed art.
      -- Previously every WX form of a species fell back to the same single
      -- species-level recolour, making Cinder/Abyssal/etc visually identical.
      local okVA, VA = pcall(require, "mods.the_world.reforged.pokemon.wx_variant_art_registry")
      local variantArt = okVA and VA and VA.battle and VA.battle[row.id] or nil
      if variantArt then
        clone.spriteFront = variantArt.front or clone.spriteFront
        clone.spriteBack = variantArt.back or clone.spriteBack
        -- 5.16.20: these are baked RGB/RGBA recolours, not 4-shade Game Boy
        -- art. Without trueColor the Gen 3 UI/palette renderer quantises them
        -- again, producing corrupted-looking battlers, especially on Silver.
        clone.trueColor = true
      end
      if row.spriteFront then clone.spriteFront=row.spriteFront end
      if row.spriteBack then clone.spriteBack=row.spriteBack end
      copyFromBase("sprite")
      copyFromBase("pic")
      copyFromBase("icon")
      copyFromBase("menuIcon")
      copyFromBase("iconIndex")
      if (row.variant or ""):upper() == "PRIMALWEATHER" or row.immuneToWeather then
        clone.icon = base.icon or clone.icon
        clone.menuIcon = base.menuIcon or base.icon or clone.menuIcon
        clone.spriteFront = base.spriteFront or base.sprite or clone.spriteFront
        clone.spriteBack = base.spriteBack or clone.spriteBack
        clone.sprite = base.sprite or clone.sprite
        clone.pic = base.pic or clone.pic
        clone.immuneToWeather = true
        clone.ability = row.ability or clone.ability or "AIR_LOCK"
      end

      -- Intentional fallback: inherited sprites/cry/stats/moves/dex are legal
      -- references to the already-loaded base data, not redistributed assets.
      local ok, err = pcall(function() registry:register(row.id, clone) end)
      if ok then Variants.registered[row.id] = row; registered = registered + 1
      else Variants.skipped[row.id] = tostring(err); skipped = skipped + 1 end
    end
    end
  end
  mod.log:info("weather variants: %d registered, %d skipped", registered, skipped)
  -- 5.16.30: PokeSurvive-style type-aware native palette assignment.
  -- Primary type owns the dominant editable colour; secondary owns detail.
  do
    local okPal, WXPal = pcall(require, "mods.the_world.reforged.pokemon.wx_type_palettes")
    if okPal and WXPal and WXPal.applyGen2 then
      pcall(WXPal.applyGen2, mod, Data, Variants.registered)
    end
  end
  return registered > 0
end

function Variants.bindPokedex()
  return Dex.bindLive(Data, Variants.registered)
end

local poolByWeatherBase = {}
for _, row in ipairs(Data) do
  if not row.giftOnly and (row.variant or ""):upper() ~= "PRIMALWEATHER" then
    local ids = WEATHER_IDS[row.weather] or {}
    for weatherId in pairs(ids) do
      local byBase = poolByWeatherBase[weatherId]
      if not byBase then byBase = {}; poolByWeatherBase[weatherId] = byBase end
      local pool = byBase[row.base]
      if not pool then pool = {}; byBase[row.base] = pool end
      pool[#pool + 1] = row
    end
  end
end

local LEGENDARY = { ARTICUNO=true, ZAPDOS=true, MOLTRES=true, MEWTWO=true, MEW=true }
local VERY_RARE = { DITTO=true, EEVEE=true, SNORLAX=true, DRAGONITE=true }
local function rarityOf(row)
  if row.rarity == "primal" or (row.variant or ""):upper() == "PRIMALWEATHER" then
    return "primal"
  end
  if LEGENDARY[row.base] then return "legendary" end
  if VERY_RARE[row.base] then return "veryRare" end
  return row.rarity or "rare"
end

local function random(rng)
  if type(rng) == "function" then return tonumber(rng()) or 1 end
  if love and love.math then return love.math.random() end
  return math.random()
end

local function configuredChance(row)
  local cfg = Config.get().weatherVariants or {}
  local rarity = rarityOf(row)
  local chance = tonumber(row.chance) or tonumber(cfg[rarity .. "Chance"])
    or tonumber(cfg.encounterChance) or 0.03
  return math.max(0, math.min(1, chance))
end

local function mapSuitable(weatherId, mapId)
  if not mapId then return false end
  local patterns = HABITAT[weatherId]
  if not patterns then return true end
  local id = tostring(mapId):upper()
  for _, pattern in ipairs(patterns) do
    if id:find(pattern, 1, true) then return true end
  end
  -- The normal roll itself proves this base species inhabits this map. Keep
  -- that authoritative instead of rejecting real tables with guessed IDs.
  return true
end
Variants.mapSuitable = mapSuitable

function Variants.forceNext(query)
  query = tostring(query or ""):upper()
  for _, row in ipairs(Data) do
    if row.id == query or row.variant == query or row.base == query
        or (row.variant .. " " .. row.baseName:upper()) == query then
      Variants.forced = row.id
      return row
    end
  end
  return nil
end

function Variants.tryEncounter(first, ctx, weatherDef)
  local cfg = Config.get().weatherVariants or {}
  if cfg.enabled == false or not Settings.weatherVariantsOn() then
    -- Do not leave a developer-forced variant queued to surprise the player
    -- after they turn the feature back on.
    Variants.forced = nil
    return first
  end
  if not (first and first.species) then return first end

  if Variants.forced then
    local row = byId[Variants.forced]
    Variants.forced = nil
    if row and Variants.registered[row.id] then
      local out = {}; for k, v in pairs(first) do out[k] = v end
      out.species, out.weatherVariant, out.rare = row.id, true, true
      return out
    end
  end

  if not weatherDef or not weatherDef.id then return first end
  local byBase = poolByWeatherBase[weatherDef.id]
  local pool = byBase and byBase[first.species]
  if not pool or #pool == 0 or not mapSuitable(weatherDef.id, Scene.now.mapId) then return first end
  local rng = ctx and ctx.rng
  local candidates = {}
  for _, row in ipairs(pool) do
    if Variants.registered[row.id] then candidates[#candidates + 1] = row end
  end
  if #candidates == 0 then return first end
  local row = candidates[math.min(#candidates, math.floor(random(rng) * #candidates) + 1)]
  if random(rng) >= configuredChance(row) then return first end
  local out = {}; for k, v in pairs(first) do out[k] = v end
  out.species, out.weatherVariant, out.rare = row.id, true, true
  return out
end

function Variants.describe()
  local n = 0; for _ in pairs(Variants.registered) do n = n + 1 end
  return ("%d/%d registered"):format(n, #Data)
end

-- Map any weather-variant id (or display name) back to the base species id.
-- Return a stable registered WX form for a base species. Character creation
-- uses this after Oak/Elm grants the normal starter, so the native starter
-- choice UI remains untouched while the actual party member becomes WX.
function Variants.variantsForBase(baseSpecies)
  if not baseSpecies then return {} end
  local base = tostring(baseSpecies):upper()
  local matches = {}
  for id, row in pairs(Variants.registered) do
    if row and tostring(row.base or ""):upper() == base then
      matches[#matches + 1] = { id=id, base=row.base, variant=row.variant, weather=row.weather }
    end
  end
  table.sort(matches, function(a,b) return tostring(a.id) < tostring(b.id) end)
  return matches
end

function Variants.variantForBase(baseSpecies)
  if not baseSpecies then return nil end
  local base = tostring(baseSpecies):upper()
  local matches = {}
  for id, row in pairs(Variants.registered) do
    if row and tostring(row.base or ""):upper() == base then
      matches[#matches + 1] = id
    end
  end
  table.sort(matches)
  return matches[1]
end

function Variants.baseSpeciesFor(speciesId)
  if not speciesId then return nil end
  local id = tostring(speciesId):upper()
  local row = byId[id]
  if row and row.base then return row.base end
  if Variants.registered[id] and Variants.registered[id].base then
    return Variants.registered[id].base
  end
  -- Prefix pattern WX_###_BASE_VARIANT
  local base = id:match("^WX_%d+_(%w+)_")
  if base and base ~= "" then return base end
  return nil
end

-- overworld-spawn-mod (Wilds of Kanto) resolves follower/overworld sprites via
-- SpeciesAssets.idFor(mon.species). Weather variants use WX_* ids that are
-- not in that table, so followers would show the missing-sprite fallback.
-- After Wilds loads we wrap its spriteProviders:resolve / resolveWater so any
-- WX_* species is remapped to the original base before asset lookup.
function Variants.installWildsCompat()
  if not mod or type(mod.find) ~= "function" then return false end
  local ok, wilds = pcall(function() return mod:find("overworld_wild_spawns") end)
  if not ok or not wilds or not wilds.exports then return false end

  -- Wilds 2.1.9 ships follow-sprite art/mapping well beyond Johto (through
  -- #649), but its SpeciesAssets string-key table stops at Celebi (#251).
  -- Extended species such as TREECKO therefore reach the provider by name,
  -- fail SpeciesAssets.idFor(), and materialise without their Pokemon art.
  -- Wilds deliberately accepts numeric canonical asset ids >251, so bridge
  -- only those extended species names to their NATIONAL dex id.  Gen1/Gen2
  -- names are left untouched and WX forms first collapse to their base.
  local function extendedWildsAssetId(speciesId, game)
    if type(speciesId) == "number" then return speciesId end
    local key = tostring(speciesId or "")
    local def = nil
    if game and game.data and game.data.pokemon then
      def = game.data.pokemon[key]
    end
    if not def and mod.content and mod.content.pokemon then
      local okGet, got = pcall(function() return mod.content.pokemon:get(key) end)
      if okGet then def = got end
    end
    local dex = def and tonumber(def.dex) or nil
    if dex and dex >= 252 and dex <= 649 and math.floor(dex) == dex then
      return math.floor(dex)
    end
    return nil
  end

  local function remap(speciesId, game)
    local base = Variants.baseSpeciesFor(speciesId) or speciesId
    return extendedWildsAssetId(base, game) or base
  end

  local function worldFollowerSprite(speciesId)
    local okF,F=pcall(require,"mods.the_world.reforged.pokemon.follower_art")
    if not okF then return nil end
    local okD,D=pcall(require,"mods.the_world.reforged.pokemon_data")
    if not okD then return nil end
    local okP,p=pcall(F.resolve,speciesId,D)
    return okP and p or nil
  end

  local function remapOpts(opts)
    opts = opts or {}
    local copy = {}
    for k, v in pairs(opts) do copy[k] = v end
    if copy.species then
      -- Exact WX walker art is registered in our provider chain. Do not collapse
      -- those ids to the base species or followers/overworld entities lose the
      -- same per-form recolour used by the battle sprite. Only borrow base art
      -- when this WX form has no authored walker sheet.
      local own = worldFollowerSprite(copy.species)
      if not own then copy.species = remap(copy.species, copy.game) end
    end
    return copy
  end

  -- 0) Visible encounter bridge. Wilds builds its roaming entities from its
  -- own GameCompat.pickEncounter() path, so The World's encounter.roll hook
  -- never sees those picks. Run the same WX substitution here, preserving the
  -- WX species id in the entity/battle while the sprite resolver below borrows
  -- the base species artwork when a dedicated WX walker sheet is unavailable.
  local wildsLib = wilds.exports.lib
  local wildsGameCompat = nil
  if type(wildsLib) == "table" and type(wildsLib.require) == "function" then
    local okGC, gc = pcall(wildsLib.require, "game_compat")
    if okGC and type(gc) == "table" then wildsGameCompat = gc end
  end
  if type(wildsGameCompat) == "table"
      and type(wildsGameCompat.pickEncounter) == "function"
      and not wildsGameCompat._theWorldWxPickWrapped then
    local origPick = wildsGameCompat.pickEncounter
    local forcedPins = { always=true, config=true, menu=true, debug=true }
    local function liveEncounterWeather()
      local ecfg = Config.get().encounters or {}
      if ecfg.enabled == false then return nil end
      if (State.level or 0) <= 0 then return nil end
      if Scene.now and Scene.now.indoors then return nil end
      if forcedPins[State.pinnedBy or ""] then return nil end
      return State.current and State.current() or nil
    end
    wildsGameCompat.pickEncounter = function(...)
      local args={...}
      local pick = origPick(...)
      if not (pick and pick.species) then return pick end
      -- v6.3.6: when another mod owns wild encounters, Wilds must display
      -- that owner's result verbatim rather than becoming a back door for
      -- The World's habitat/scope/WX substitution.
      local EncOwner = V.require("Encounters")
      if EncOwner.externalEncounterOwner and EncOwner.externalEncounterOwner() then return pick end
      -- 5.16.4: Wilds has its own visible encounter picker and bypasses the
      -- normal encounter hook. Reject evolved forms here as well.
      if Habitats.isEvolved(pick.species) then
        for _ = 1, 12 do
          local candidate = origPick(...)
          if candidate and candidate.species and not Habitats.isEvolved(candidate.species) then
            pick = candidate
            break
          end
        end
        if Habitats.isEvolved(pick.species) then return nil end
      end
      -- Wilds bypasses encounter.roll, so mirror The World's expanded habitat
      -- substitution here. This makes every registered World species capable
      -- of materialising as a visible/catchable Wilds entity.
      local ecfg = Config.get().encounters or {}
      local mapId = Scene.now and Scene.now.mapId
      local Encounters = V.require("Encounters")
      local scope = (Encounters.contentScope and Encounters.contentScope()) or Habitats.scope()
      local function exists(id)
        local ok,rec=pcall(function() return mod.content and mod.content.pokemon and mod.content.pokemon:get(id) end)
        if ok and rec~=nil then return true end
        for _,m in ipairs({"src.core.Game2","src.core.Game"}) do
          local okG,G=pcall(require,m)
          if okG and G and G.data then
            local mons=G.data.pokemon or G.data.gen2Pokemon
            if mons and mons[id]~=nil then return true end
          end
        end
        return false
      end
      -- v5.16.44: Wilds is presentation, not a second encounter authority.
      -- Enforce the World's generation scope on every visible entity, then
      -- use the shared balanced habitat ecology frequently enough that Johto/
      -- Hoenn do not disappear behind Wilds' native-Kanto-heavy picker.
      local allowed = pick.species and Habitats.allows(tostring(pick.species):upper(), scope)
      local substitute = (not allowed) or (ecfg.expandedHabitats ~= false and math.random() < 0.60)
      if substitute then
        local species = Habitats.choose(mapId, scope, exists, random)
        if species then
          local cp={} for k,v in pairs(pick) do cp[k]=v end
          cp.species=species; pick=cp
        elseif not allowed then
          return nil
        end
      end
      -- Then apply the live-weather WX substitution to the visible species.
      return Variants.tryEncounter(pick, { rng = random }, liveEncounterWeather())
    end
    wildsGameCompat._theWorldWxPickWrapped = true
  end

  -- 1) Sprite provider chain (ambient / wild overworld)
  local sp = wilds.exports.spriteProviders
  if type(sp) == "table" then
    if type(sp.resolve) == "function" and not sp._wxResolveWrapped then
      local orig = sp.resolve
      sp.resolve = function(self, style, speciesId, variant, game)
        -- 5.16.43: Wilds owns the overworld presentation when it has art.
        -- Ask Wilds first using the canonical/base species (or National Dex id
        -- for its extended sheets). The World's authored walker is now only a
        -- fallback for species/forms Wilds genuinely cannot resolve.
        local wildsSpecies = remap(speciesId, game)
        local okWilds, resolved = pcall(orig, self, style, wildsSpecies, variant, game)
        if okWilds and resolved and resolved.def and resolved.def.image then
          return resolved
        end
        local own = worldFollowerSprite(speciesId)
        if own then
          return { def={ image=own, frames=6, trueColor=true, walker=true, id="SPRITE_THE_WORLD_"..tostring(speciesId) }, meta={ providerId="the_world", usedVariant=tostring(speciesId):find("^WX_") and "wx" or "normal", loadPath=own, frames=6, walker=true, bodyRenderer="NATIVE_SPRITE_RENDERER" }, providerId="the_world", fallbackStep=1, steps={} }
        end
        if okWilds then return resolved end
        return nil
      end
      sp._wxResolveWrapped = true
    end
    if type(sp.resolveWater) == "function" and not sp._wxResolveWaterWrapped then
      local origW = sp.resolveWater
      sp.resolveWater = function(self, style, speciesId, variant, game)
        return origW(self, style, remap(speciesId, game), variant, game)
      end
      sp._wxResolveWaterWrapped = true
    end
  end

  -- 2) Follower sprite service (party followers) — uses SpeciesAssets.idFor
  --    on opts.species; remap before that lookup.
  local follower = wilds.exports.follower
  if type(follower) == "table" and type(follower.spriteService) == "table" then
    local svc = follower.spriteService
    if type(svc.resolveFollowerSprite) == "function" and not svc._wxFollowerWrapped then
      local origF = svc.resolveFollowerSprite
      svc.resolveFollowerSprite = function(self, opts)
        return origF(self, remapOpts(opts))
      end
      svc._wxFollowerWrapped = true
    end
  end
  if type(wilds.exports.resolveFollowerSprite) == "function"
      and not wilds.exports._wxResolveFollowerWrapped then
    local origRF = wilds.exports.resolveFollowerSprite
    wilds.exports.resolveFollowerSprite = function(opts)
      return origRF(remapOpts(opts))
    end
    wilds.exports._wxResolveFollowerWrapped = true
  end

  -- 3) Control engine path (when exported on follower module)
  if type(follower) == "table" and type(follower.engine) == "table" then
    local eng = follower.engine
    if type(eng.resolveFollowerSprite) == "function" and not eng._wxEngineWrapped then
      local origE = eng.resolveFollowerSprite
      eng.resolveFollowerSprite = function(self, opts)
        return origE(self, remapOpts(opts))
      end
      eng._wxEngineWrapped = true
    end
  end

  wilds.exports.wxBaseSpeciesFor = Variants.baseSpeciesFor
  wilds.exports.theWorldFollowerSprite = worldFollowerSprite
  if mod.exports then
    mod.exports.baseSpeciesFor = Variants.baseSpeciesFor
    mod.exports.resolvePokemonOverworldSprite = worldFollowerSprite
  end
  mod.log:info("weather variants: Wilds of Kanto bridge installed (visible WX encounter substitution + base sprite remap + Gen3 extended asset ids)")
  return true
end

-- Battle Art Voxel (and Dramatic Shape-family renderers) choose their animated
-- Gen 2 art from mon.species inside OverworldBattle.sideTexture. WX forms are
-- real registered species, so their WX_* id misses the host's base-species
-- override. Borrow the base id for the texture call only, then restore it
-- before the HUD or battle logic can observe the substitution.
function Variants.installBattleArtCompat()
  local okG, Game = pcall(require, "src.core.Game")
  local exports = okG and type(Game) == "table" and Game.mods and Game.mods.exports
  if type(exports) ~= "table" then return false end

  local installed = false
  for _, entry in pairs(exports) do
    local lib = type(entry) == "table" and entry.lib
    if type(lib) == "table" and type(lib.require) == "function" then
      local okO, ov = pcall(lib.require, "OverworldBattle")
      if okO and type(ov) == "table" and type(ov.sideTexture) == "function" then
        if not ov.__wxBaseSpeciesOrigSideTexture then
          ov.__wxBaseSpeciesOrigSideTexture = ov.sideTexture
          ov.sideTexture = function(battle, side, ...)
            local changed = {}
            local function borrow(battler)
              local mon = battler and battler.mon
              if not (mon and mon.species) then return end
              local base = Variants.baseSpeciesFor(mon.species)
              if base then
                changed[#changed + 1] = { mon = mon, species = mon.species }
                mon.species = base
              end
            end
            if battle then
              borrow(battle.player); borrow(battle.player2)
              borrow(battle.enemy); borrow(battle.enemy2)
            end
            local result = { pcall(ov.__wxBaseSpeciesOrigSideTexture,
              battle, side, ...) }
            for i = #changed, 1, -1 do
              changed[i].mon.species = changed[i].species
            end
            if not result[1] then error(result[2]) end
            return unpack(result, 2)
          end
        end
        installed = true
      end
    end
  end
  if installed then
    mod.log:info("weather variants: Battle Art base-species sprite remap installed")
  end
  return installed
end

return Variants
