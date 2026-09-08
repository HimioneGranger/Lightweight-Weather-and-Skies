-- WEATHER IN THE GRASS AND ON THE WATER.
--
-- Three effects, all through documented hooks, all generation-agnostic --
-- the Gen 2 migration guide names `encounter.species` as the route to take
-- INSTEAD of engine surgery, so this is the one part of the mod that is
-- more portable than the code around it, not less.
--
--   encounter.roll      weather leans which species you meet in the grass
--   encounter.fishing   rain brings the fish up
--
-- =====================================================================
-- HOW THE BIAS WORKS
-- =====================================================================
--
-- Every weather with a `chipType` (or a fog/sun/ice tag) favours that type
-- in the grass.  On a weather-influenced step the encounter is rolled
-- again through the vanilla chain, and a matching second roll is kept.
-- Several attempts are made for strongly typed storms (Dragonstorm,
-- Psystorm, Swarm, ...) so the bias is felt without editing tables.
--
-- Only species the map ALREADY contains can appear from a reroll, so a
-- route with no Ghost is unaffected by fog and no encounter table is
-- bypassed.  When the map has no matching species, an optional inject
-- step can pull a species of the favoured type from the merged Pokédex
-- (vanilla + any expanded-dex mod registered through mod.content.pokemon)
-- at the rolled level -- rain can surface Water-types, Dragonstorm can
-- surface Dragons, and so on for every typed weather.
--
-- The encounter RATE is deliberately untouched: a reroll only happens
-- when the first draw already produced an encounter.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local Config = V.require("Config")
local Scene = V.require("Scene")
local State = V.require("WeatherState")
local Legendary = V.require("Legendary")
local WeatherVariants = V.require("WeatherVariants")
local Habitats = V.require("HabitatEncounters")

local Enc = {}

-- ------- type affinity
--
-- Primary source is `chipType` on the weather def -- every typed front
-- already declares the damage type it chips, which is exactly the type
-- that should be drawn out in the grass.  Fog/sun/ice tags cover the
-- classic weathers that predate chipType or share one.

-- Chance of taking a second (or further) roll, by favoured type.
local STRENGTH = {
  GHOST = 0.60, FIRE = 0.45, ICE = 0.45, WATER = 0.40,
  ELECTRIC = 0.50, GRASS = 0.45, ROCK = 0.45, GROUND = 0.45,
  POISON = 0.50, BUG = 0.50, FLYING = 0.45, FIGHTING = 0.50,
  DRAGON = 0.65, PSYCHIC = 0.55, NORMAL = 0.35,
  -- Gen 2 types
  DARK = 0.55, STEEL = 0.45,
}

-- Extra reroll attempts for exotic fronts so the bias is felt.
local ATTEMPTS = {
  DRAGON = 4, PSYCHIC = 3, GHOST = 3, FIGHTING = 3,
  POISON = 3, BUG = 3, ELECTRIC = 3,
  DARK = 3, STEEL = 2,
}

local function favouredType(def)
  if not def then return nil end
  if def.chipType then return def.chipType end
  if Types.channel(def, "fog") > 0 then return "GHOST" end
  if def.sunny then return "FIRE" end
  if def.frozen then return "ICE" end
  if def.wet then return "WATER" end
  if def.sandy then return "ROCK" end
  return nil
end
Enc.favouredType = favouredType

-- Hard type bans by weather tag.  Unlike STRENGTH (soft bias), a banned
-- type is never kept when the weather is active outdoors — the roll is
-- replaced until a non-banned species appears (or the encounter is dropped).
-- Keys match weather flags on Types defs (wet/sunny/frozen/sandy) plus fog.
-- Includes Gen 2 types (DARK, STEEL). Steel is *not* banned in sand
-- (matches battle sand immunity). Edit via config.encounters.bans.
local DEFAULT_BANS = {
  wet     = { "FIRE", "STEEL" },           -- rain/storm/sleet: no Fire/Steel
  sunny   = { "WATER", "ICE" },            -- harsh sun: Water/Ice struggle
  frozen  = { "BUG", "GRASS", "FLYING" },-- snow/hail: Bug/Grass/Flying
  sandy   = { "WATER", "BUG" },            -- sand: Water/Bug (not STEEL)
  foggy   = { "FIRE" },                    -- fog: Fire stays away
  ash     = { "BUG", "GRASS", "ICE" },     -- ashfall
  psychic = { "DARK" },                    -- psystorm front: Dark suppressed
}

local function weatherForBans()
  -- Bans follow the sky you see, including ALWAYS / pinned rain.
  if not Config.get().encounters.enabled then return nil end
  if (State.level or 0) <= 0 then return nil end
  if Scene.now.indoors then return nil end
  return State.current()
end

local function bannedSet(def, cfg)
  local set = {}
  if not def then return set end
  local bans = (cfg and cfg.bans) or DEFAULT_BANS
  local function addList(list)
    if type(list) ~= "table" then return end
    for i = 1, #list do
      local ty = list[i]
      if type(ty) == "string" then set[ty:upper()] = true end
    end
  end
  if def.wet then addList(bans.wet) end
  if def.sunny then addList(bans.sunny) end
  if def.frozen then addList(bans.frozen) end
  if def.sandy then addList(bans.sandy) end
  if def.psychic then addList(bans.psychic) end
  if Types.channel(def, "fog") > 0.15 then addList(bans.foggy) end
  if Types.channel(def, "ash") > 0.15 or (def.id and tostring(def.id):find("ASH", 1, true)) then
    addList(bans.ash)
  end
  -- Per-weather-id overrides: cfg.bansById.RAIN_HEAVY = { "FIRE", "GRASS" }
  if cfg and type(cfg.bansById) == "table" and def.id then
    addList(cfg.bansById[def.id] or cfg.bansById[tostring(def.id):upper()])
  end
  return set
end

local function isBanned(species, set)
  if not species or not set then return false end
  local list = (Enc.typesOf or typesOf)(species)
  if type(list) ~= "table" then return false end
  for i = 1, #list do
    if set[list[i]] then return true end
  end
  return false
end


local function typesOf(species)
  local ok, list = pcall(function()
    local Game = require("src.core.Game")
    local data = Game and Game.data and Game.data.pokemon
    local def = data and data[species]
    return def and def.types or nil
  end)
  if ok then return list end
  return nil
end
Enc.typesOf = typesOf

local function isType(species, wanted)
  local list = (Enc.typesOf or typesOf)(species)
  if type(list) ~= "table" then return false end
  for i = 1, #list do
    if list[i] == wanted then return true end
  end
  return false
end
Enc.isType = isType

-- Cache of species ids per type.  Built from the MERGED pokemon registry
-- (mod.content.pokemon) so an expanded-dex mod's species are included;
-- falls back to Game.data.pokemon when the registry is not yet available.
local poolByType = nil
local poolBroken = false
local poolSource = "none"

local function addToPools(pools, id, def)
  if type(id) ~= "string" or type(def) ~= "table" then return end
  -- Weather variants are substitutions of their base species, never members
  -- of the ordinary global injection pool. This makes WX=OFF absolute.
  if id:match("^WX_") then return end
  if type(def.types) ~= "table" then return end
  -- Skip entries explicitly marked non-wild / non-encounter.
  if def.encounter == false or def.wild == false then return end
  if def.inject == false then return end
  for i = 1, #def.types do
    local t = def.types[i]
    if type(t) == "string" then
      local bucket = pools[t]
      if not bucket then bucket = {}; pools[t] = bucket end
      bucket[#bucket + 1] = id
    end
  end
end

local function buildPools()
  local pools = {}
  local source = "none"

  -- 1) Merged content registry -- includes every mod that registered or
  --    patched pokemon (expanded dex, fakemon packs, type edits, …).
  local okReg, regCount = pcall(function()
    local reg = mod.content and mod.content.pokemon
    if not reg or type(reg.each) ~= "function" then return 0 end
    local n = 0
    for id, def in reg:each() do
      addToPools(pools, id, def)
      n = n + 1
    end
    return n
  end)
  if okReg and (regCount or 0) > 0 then
    source = "registry"
  end

  -- 2) Fallback: live Game.data.pokemon (ROM import + whatever merged into
  --    Data.pokemon).  Used when the registry iterator is empty or missing.
  if source == "none" then
    local okData, dataCount = pcall(function()
      local Game = require("src.core.Game")
      local data = Game and Game.data and Game.data.pokemon
      if type(data) ~= "table" then return 0 end
      local n = 0
      for id, def in pairs(data) do
        addToPools(pools, id, def)
        n = n + 1
      end
      return n
    end)
    if okData and (dataCount or 0) > 0 then
      source = "gamedata"
    end
  end

  if source == "none" then return nil, "none" end
  return pools, source
end

local function typePool(wanted)
  if poolBroken then return nil end
  if not poolByType then
    local built, source = buildPools()
    if not built then
      poolBroken = true
      poolSource = "none"
      return nil
    end
    poolByType = built
    poolSource = source or "unknown"
    mod.log:info("encounter type pools from %s", poolSource)
  end
  return poolByType[wanted]
end
Enc.typePool = typePool

-- Drop the cache so a late-loading expanded dex is picked up next inject.
function Enc.invalidatePools()
  poolByType = nil
  poolBroken = false
  poolSource = "none"
end

local function pickFromPool(wanted, rng)
  local pool = typePool(wanted)
  if not pool or #pool == 0 then return nil end
  local roll
  if type(rng) == "function" then
    roll = rng()
  elseif love and love.math then
    roll = love.math.random()
  else
    roll = math.random()
  end
  local idx = math.floor((tonumber(roll) or 0) * #pool) + 1
  if idx < 1 then idx = 1 end
  if idx > #pool then idx = #pool end
  return pool[idx]
end

-- Pinned skies (ALWAYS row, config.force, OPTIONS ladder pin, DEBUG RAIN)
-- are cosmetic/testing choices -- they must not rewrite the grass.  Only
-- weather the world produced on its own (AUTO, CYCLE, fronts, locations,
-- legends, psystorms) leans encounters.
local FORCED_PIN = {
  always = true, config = true, menu = true, debug = true,
}

-- The weather actually being experienced out here.  Indoors and covered
-- frames answer nil, so a cave with no sky does not conjure Ghosts.
-- Forced/pinned weather also answers nil so ALWAYS SNOW does not turn
-- every route into an Ice-type safari.
local function activeWeather()
  if not Config.get().encounters.enabled then return nil end
  if (State.level or 0) <= 0 then return nil end
  if Scene.now.indoors then return nil end
  if FORCED_PIN[State.pinnedBy or ""] then return nil end
  return State.current()
end
Enc.activeWeather = activeWeather

local function chance(rng, p)
  local roll
  if type(rng) == "function" then roll = rng()
  elseif love and love.math then roll = love.math.random()
  else roll = math.random() end
  return (tonumber(roll) or 1) < p
end

local function currentMapId(ctx)
  local id = ctx and (ctx.mapId or ctx.map or ctx.location)
  if type(id) == "table" then id = id.id or id.mapId end
  if id then return id end
  local ok, found = pcall(function()
    local Game = require("src.core.Game")
    return Game and Game.overworld and Game.overworld.map
      and Game.overworld.map.id
  end)
  return ok and found or nil
end

local VALID_CONTENT_SCOPE = {
  gen1=true, gen1_gen2=true, gen1_gen2_gen3=true,
  gen1_gen2_gen3_gen4=true, gen1_gen2_gen3_gen4_gen5=true,
  gen1_gen2_gen3_gen4_gen5_gen6=true,
  gen1_gen2_gen3_gen4_gen5_gen6_gen7=true,
  gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8=true,
}
local SCOPE_RANK = {
  gen1=1, gen1_gen2=2, gen1_gen2_gen3=3, gen1_gen2_gen3_gen4=4,
  gen1_gen2_gen3_gen4_gen5=5, gen1_gen2_gen3_gen4_gen5_gen6=6,
  gen1_gen2_gen3_gen4_gen5_gen6_gen7=7,
  gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8=8,
}
local function contentScope()
  -- v5.16.57: Android can briefly expose a stale option value while the
  -- per-save character-creation mirror already contains the player's choice.
  -- Use the most restrictive valid value when the two disagree. This makes
  -- KANTO ONLY a fail-closed hard boundary instead of allowing a stale ALL
  -- INCLUDED value to leak later species back into encounters.
  local opt, saved
  pcall(function() opt = mod.options:get("worldContentScope") end)
  pcall(function() saved = mod.save:get("world_content_scope") end)
  if VALID_CONTENT_SCOPE[opt] and VALID_CONTENT_SCOPE[saved] then
    return (SCOPE_RANK[opt] <= SCOPE_RANK[saved]) and opt or saved
  end
  if VALID_CONTENT_SCOPE[opt] then return opt end
  if VALID_CONTENT_SCOPE[saved] then return saved end
  return "gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8"
end
Enc.contentScope = contentScope

local function speciesExists(id)
  -- 5.13.9: use the public merged content registry first. This is the same
  -- surface on Red, Blue, Yellow, Gold and Silver and therefore sees native
  -- species plus The World's registered Gen 2/3/WX content on every game.
  local ok, rec = pcall(function()
    return mod.content and mod.content.pokemon and mod.content.pokemon:get(id)
  end)
  if ok and rec ~= nil then return true end

  -- Compatibility fallback for older Gen 1 engine builds only. Never make
  -- Gen 2 availability depend on src.core.Game: Gold/Silver use Game2.
  local function inGame(moduleName)
    local okG, exists = pcall(function()
      local Game = require(moduleName)
      local data = Game and Game.data
      local pokemon = data and (data.pokemon or data.gen2Pokemon)
      return pokemon and pokemon[id] ~= nil
    end)
    return okG and exists == true
  end
  -- Gold/Silver use Game2. Checking only Game made native Kanto species look
  -- nonexistent to the World habitat picker on Gen 2.
  return inGame("src.core.Game2") or inGame("src.core.Game")
end

-- WX=OFF must also reject a WX species supplied by another encounter layer
-- (including an overworld-spawn provider), not only stop our own substitution.
local function stripWxWhenDisabled(encounter)
  if not (encounter and encounter.species) then return encounter end
  if Settings.weatherVariantsOn and Settings.weatherVariantsOn() then return encounter end
  local base = WeatherVariants.baseSpeciesFor and WeatherVariants.baseSpeciesFor(encounter.species)
  if not base then return encounter end
  local out = {}
  for k,v in pairs(encounter) do out[k]=v end
  out.species = base
  out.weatherVariant = nil
  out.rare = nil
  return out
end

-- v6.3.6: encounter ownership. External mode is a true hands-off switch:
-- The World observes the host encounter but does not reroll, filter, replace,
-- WX-transform, ban, bias, or change its rate. AUTO also yields when the
-- All Pokemon Catchable 151 mod is installed, so its authored tables win.
local function externalEncounterOwner()
  local mode = "auto"
  pcall(function()
    local v = mod.options:get("worldEncounterControl")
    if v ~= nil then mode = tostring(v):lower() end
  end)
  if mode == "external" then return true end
  if mode == "world" then return false end
  if mod and mod.find then
    for _,id in ipairs({"all_pokemon_catchable_151_mod","All_Pokemon_Catchable_151_Mod"}) do
      local ok, found = pcall(mod.find, mod, id)
      if not ok then ok, found = pcall(mod.find, id) end
      if ok and found then return true end
    end
  end
  return false
end

function Enc.externalEncounterOwner()
  return externalEncounterOwner()
end

local function expandedHabitatsOn()
  local value
  pcall(function() value = mod.options:get("worldExpandedHabitats") end)
  return value == nil or value == true or value == "on"
end

local function pickHabitatType(mapId, wanted, rng)
  for _ = 1, 12 do
    local species = Habitats.choose(mapId, contentScope(), speciesExists, rng)
    if species and isType(species, wanted) then return species end
  end
  return nil
end

-- Weather multiplies how often grass produces *some* encounter.
-- 1.5 => ~50% more encounters (retry when the first roll is empty).
-- Legendaries use their own smaller boost in Legendary.claimEncounter.
function Enc.rateMultiplier()
  if externalEncounterOwner() then return 1 end
  local cfg = Config.get().encounters
  if not cfg or cfg.enabled == false then return 1 end
  if cfg.rateBoost == false then return 1 end
  local mult = tonumber(cfg.rateBoost) or 1.5
  if mult < 1 then mult = 1 end
  -- Only outdoors with live weather (not CLEAR-only cosmetic).
  if Scene.now.indoors then return 1 end
  if (State.level or 0) <= 0 then return 1 end
  local def = State.current and State.current()
  if not def or def.id == "CLEAR" then return 1 end
  return mult
end


function Enc.install()
  -- ------- typed weather leans the grass
  --
  -- WHY `encounter.roll` AND NOT `encounter.species`.
  --
  -- This hung off `encounter.species` and did nothing at all in a real game.
  -- That hook is a TRANSFORM: its vanilla link is the identity function, so
  -- calling it a second time hands back the same encounter.  `encounter.roll`
  -- is the hook that actually draws with fresh RNG every call.

  mod.hooks:wrap("encounter.roll", function(next_, encDef, ctx)
    local first = next_(encDef, ctx)
    -- External/vanilla authority means exactly that: return the encounter
    -- untouched. This must precede every World filter, including WX and the
    -- generation-scope guard, or a 151 table can still be silently rewritten.
    if externalEncounterOwner() then return first end

    -- ------- Rate boost (~50% more encounters under active weather)
    -- When the engine produced no encounter, retry once with probability
    -- that yields about rateBoost× overall rate for typical step rates.
    if not (first and first.species) then
      local mult = Enc.rateMultiplier()
      if mult > 1 then
        -- P(retry | miss) ≈ (mult - 1) / mult  → overall ≈ mult × base
        local retryP = (mult - 1) / mult
        if chance(ctx and ctx.rng, retryP) then
          first = next_(encDef, ctx)
        end
      end
      if not (first and first.species) then return first end
    end

    first = stripWxWhenDisabled(first)

    -- Legendary bird / beast substitution (roused weather only).
    -- Uses its own +5% chance scale, not the wild 50% rate boost.
    local bird, birdLevel = Legendary.claimEncounter()
    if bird then
      local out = {}
      for k, v in pairs(first) do out[k] = v end
      out.species = bird
      out.level = birdLevel or out.level
      return out
    end

    -- 5.16.4: evolved species are evolution rewards, not ordinary wild rolls.
    -- If the host ROM/table returns one, reroll through the same encounter
    -- chain a few times and keep the first unevolved result. Static/gift/event
    -- Pokemon do not pass through this encounter hook and are unaffected.
    if first and first.species and Habitats.isEvolved(first.species) then
      for _ = 1, 12 do
        local candidate = next_(encDef, ctx)
        if candidate and candidate.species and not Habitats.isEvolved(candidate.species) then
          first = candidate
          break
        end
      end
      if first and first.species and Habitats.isEvolved(first.species) then return nil end
    end

    -- v5.16.44: generation scope is a hard filter, not merely a filter on
    -- optional expanded substitutions. This is what makes GEN 1 ONLY actually
    -- mean Gen 1 on Gold/Silver and after another mod has rewritten tables.
    if first and first.species and not Habitats.allows(tostring(first.species):upper(), contentScope()) then
      local replacement = Habitats.choose(currentMapId(ctx), contentScope(), speciesExists, ctx and ctx.rng)
      if replacement then
        local out={} for k,v in pairs(first) do out[k]=v end
        out.species=replacement; first=out
      else
        return nil
      end
    end

    -- A registered Delta may substitute for the normal species only under
    -- its mapped live weather. The normal roll is preserved on every miss.
    if Settings.weatherVariantsOn and Settings.weatherVariantsOn() then
      local variant = WeatherVariants.tryEncounter(first, ctx, activeWeather())
      if variant ~= first then return variant end
    end

    local cfg = Config.get().encounters

    -- Stable regional distribution for expanded-dex species. The native roll
    -- still owns rate and level; this only substitutes a registered Gen 2/3
    -- species assigned to the current route's habitat. It runs before weather
    -- bias so weather can still favour or ban types without drawing from the
    -- old global anything-goes pool.
    local randomizerOwnsWild = type(mod.exports.universalRandomizerOwnsWild) == "function"
      and mod.exports.universalRandomizerOwnsWild()
    if not randomizerOwnsWild and cfg.expandedHabitats ~= false and expandedHabitatsOn()
       and chance(ctx and ctx.rng, tonumber(cfg.expandedChance) or 0.35) then
      local species = Habitats.choose(currentMapId(ctx), contentScope(),
        speciesExists, ctx and ctx.rng)
      if species then
        local out = {}
        for k, v in pairs(first) do out[k] = v end
        out.species = species
        first = out
      end
    end

    -- ------- Hard type bans (e.g. no Fire in rain)
    -- Runs even when soft species bias is off, and follows pinned weather.
    if cfg.bans ~= false then
      local banDef = weatherForBans()
      local banned = bannedSet(banDef, cfg)
      if next(banned) ~= nil and isBanned(first.species, banned) then
        local rng = ctx and ctx.rng
        local replacement = nil
        for _ = 1, 10 do
          local second = next_(encDef, ctx)
          if second and second.species and not isBanned(second.species, banned) then
            replacement = second
            break
          end
        end
        if not replacement and cfg.inject ~= false then
          -- Prefer a non-banned type from the soft-bias favourite, else WATER/NORMAL
          local prefer = favouredType(banDef) or "NORMAL"
          if banned[prefer] then prefer = "WATER" end
          if banned[prefer] then prefer = "NORMAL" end
          if banned[prefer] then prefer = "GRASS" end
          if not banned[prefer] then
            local species = pickHabitatType(currentMapId(ctx), prefer, rng)
            if species and not isBanned(species, banned) then
              replacement = {}
              for k, v in pairs(first) do replacement[k] = v end
              replacement.species = species
            end
          end
        end
        if replacement then
          first = replacement
        else
          -- Could not find a legal species — drop this encounter rather than
          -- force a banned type (100% exclusion).
          return nil
        end
      end
    end

    if not cfg.species then return first end

    local def = activeWeather()
    local wanted = favouredType(def)
    if not wanted then return first end
    if isType(first.species, wanted) then return first end

    local strength = (STRENGTH[wanted] or 0.4) * (tonumber(cfg.strength) or 1)
    if strength <= 0 then return first end

    -- Soft bias must not reintroduce a hard-banned type.
    local bannedSoft = bannedSet(weatherForBans(), cfg)
    if bannedSoft[wanted] then return first end

    local attempts = ATTEMPTS[wanted] or 2
    local rng = ctx and ctx.rng
    for _ = 1, attempts do
      if not chance(rng, strength) then break end
      local second = next_(encDef, ctx)
      if second and second.species and isType(second.species, wanted)
          and not isBanned(second.species, bannedSoft) then
        return second
      end
    end

    -- Inject: any favoured type, when enabled, after the map table failed
    -- to produce a match.  Pool is the merged Pokédex (expanded dex mods
    -- included).  Level comes from the original roll so Route 1 does not
    -- hand out Lv50 legends.
    local allowInject = cfg.inject
    if allowInject == nil then allowInject = true end
    if allowInject then
      local injectChance = (tonumber(cfg.injectChance) or 0.35) * (tonumber(cfg.strength) or 1)
      if injectChance > 0 and chance(rng, injectChance) then
        local species = pickHabitatType(currentMapId(ctx), wanted, rng)
        if species and not isBanned(species, bannedSoft) then
          local out = {}
          for k, v in pairs(first) do out[k] = v end
          out.species = species
          return out
        end
      end
    end

    return first
  end)

  -- ------- rain brings the fish up

  mod.hooks:wrap("encounter.fishing", function(next_, rod, mapId, candidates)
    local first = next_(rod, mapId, candidates)
    if externalEncounterOwner() then return first end
    local cfg = Config.get().encounters
    if not cfg.fishing then return first end

    local def = activeWeather()
    if not (def and def.wet) then return first end
    if not chance(nil, (tonumber(cfg.fishingBonus) or 0.5)) then return first end

    local second = next_(rod, mapId, candidates)
    if not first then return second end
    if not second then return first end
    local a = tonumber(first.level) or 0
    local b = tonumber(second.level) or 0
    if b > a then return second end
    return first
  end)

  return true
end

function Enc.describe()
  local wanted = favouredType(activeWeather())
  return wanted or "-"
end

-- =====================================================================
-- LIVE REPORTING (read-only -- changes nothing about the real roll)
-- =====================================================================
--
-- encounter.roll (above) decides species per-step, live, on request --
-- there has never been a data structure anywhere that says "here is
-- what's currently biased." Enc.currentOverlay(mapId) computes one, for
-- display, reusing the same bannedSet/favouredType/pickFromPool this
-- file already uses for real rolls -- so a companion mod can render
-- "what's likely right now" without reimplementing any bias/ban rule of
-- its own, and without this function or its caller ever touching what
-- encounter.roll actually returns.
--
-- This is an EXACT closed-form model of the bias chain above, not a
-- simulation and not a rough approximation. It works because every
-- reroll in encounter.roll draws fresh from the same base distribution,
-- independently -- which makes the whole "keep trying, maybe give up
-- early, maybe inject" process a bounded geometric series with a known
-- sum, not something that has to be sampled to find out the answer.
--
-- The chain, and how each step maps onto real numbers:
--  1. Hard bans: a banned species' weight is redistributed proportionally
--     across the surviving species (weight / (1 - bannedMass)). The real
--     path retries up to 10 times before giving up; the gap between that
--     and true proportional redistribution is bannedMass^10, negligible
--     unless the table is almost entirely banned.
--  2. Favoured-type bias: each reroll attempt only continues if a "keep
--     trying" roll (chance = strength) succeeds, AND that attempt's own
--     fresh draw only ends the loop if it lands on the favoured type. Over
--     `attempts` tries this is geometric: r = strength * (1 - pi), where
--     pi is the chance a single fresh draw is already favoured-and-legal.
--     G = sum(r^k, k=0..attempts-1) = (1 - r^attempts) / (1 - r). The total
--     chance ANY non-favoured roll gets redirected to a favoured species is
--     strength * G * pi -- NOT strength * G alone; dropping the pi factor
--     was an early bug in this file, caught by re-deriving it by hand
--     rather than trusting the first draft, worth mentioning since it's
--     an easy place to get subtly wrong.
--  3. Inject: whatever's left after (2) has its own separate injectChance
--     shot at pulling a species from the merged-dex favoured-type pool,
--     split evenly across every member of that pool.
--  4. Whatever's left after both (2) and (3) just stays the original
--     species, unchanged.
--
-- The one real simplification, not a probability shortcut: an injected
-- (off-route) species has no level range of its own on this route -- the
-- real roll actually inherits the STARTING roll's level, which is
-- path-specific and would need per-pathway tracking to reproduce exactly.
-- Here it's shown using the route's own overall min/max level instead.
-- Doesn't affect any of the odds above, only the level range shown for a
-- species that only ever arrives via injection.
--
-- Not modelled at all, deliberately: the legendary-bird substitution and
-- the WeatherVariants delta substitution that can each override the roll
-- before this bias logic even runs. Both are separate, rarer systems --
-- folding them in would blur what this is actually answering ("what does
-- the weather bias do"), not sharpen it.

local DEFAULT_BUCKETS = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 }

local function encounterBuckets(part)
  if part.buckets then return part.buckets end
  local ok, b = pcall(function()
    local Game = require("src.core.Game")
    return Game and Game.data and Game.data.constants and Game.data.constants.encounterBuckets
  end)
  return (ok and b) or DEFAULT_BUCKETS
end

-- Aggregates a part's slots into one weight per species (weights sum to
-- ~1), using the exact same bucket-gap-sum kanto's own route panel (and
-- the base game) already use to turn slots into percentages -- so our
-- numbers agree with how this same data is interpreted everywhere else.
local function speciesWeights(part)
  if not part or not part.slots or (part.rate or 0) == 0 then return nil end
  local bk = encounterBuckets(part)
  local byId, order, prev = {}, {}, 0
  for i, slot in ipairs(part.slots) do
    local top = bk[i] or 256
    local w = (top - prev) / 256
    prev = top
    if slot and slot.species then
      local e = byId[slot.species]
      if not e then
        e = { species = slot.species, weight = 0, minL = slot.level, maxL = slot.level }
        byId[slot.species] = e; order[#order + 1] = e
      end
      e.weight = e.weight + w
      e.minL = math.min(e.minL, slot.level); e.maxL = math.max(e.maxL, slot.level)
    end
  end
  return order
end

local function addWeight(byId, order, species, weight, minL, maxL)
  if weight <= 0 then return end
  local e = byId[species]
  if not e then
    e = { species = species, weight = 0, minL = minL, maxL = maxL }
    byId[species] = e; order[#order + 1] = e
  end
  e.weight = e.weight + weight
  e.minL = math.min(e.minL, minL); e.maxL = math.max(e.maxL, maxL)
end

-- Runs the four-step model above over one aggregated species list.
local function biasedWeights(base, banned, wanted, cfg)
  if not base then return nil end

  -- step 1: hard bans, exact proportional redistribution.
  local bannedMass = 0
  for _, e in ipairs(base) do
    if isBanned(e.species, banned) then bannedMass = bannedMass + e.weight end
  end
  local survivors, overallMinL, overallMaxL = {}, nil, nil
  for _, e in ipairs(base) do
    if not isBanned(e.species, banned) then
      local w = (bannedMass < 1) and (e.weight / (1 - bannedMass)) or e.weight
      survivors[#survivors + 1] = { species = e.species, weight = w, minL = e.minL, maxL = e.maxL }
      overallMinL = overallMinL and math.min(overallMinL, e.minL) or e.minL
      overallMaxL = overallMaxL and math.max(overallMaxL, e.maxL) or e.maxL
    end
  end
  if not wanted or banned[wanted] then return survivors end

  -- step 2 setup: pi is the chance a single completely fresh vanilla
  -- draw is already favoured-and-legal -- this is what every reroll
  -- attempt inside encounter.roll actually draws against (the raw base
  -- table, not the renormalized survivors list).
  local strength = math.min(1, (STRENGTH[wanted] or 0.4) * (tonumber(cfg.strength) or 1))
  local attempts = ATTEMPTS[wanted] or 2
  local pi = 0
  for _, e in ipairs(base) do
    if not isBanned(e.species, banned) and isType(e.species, wanted) then pi = pi + e.weight end
  end

  local byId, out = {}, {}
  local nonFavouredMass, redirectShare = 0, 0
  if strength > 0 and pi > 0 then
    local r = strength * (1 - pi)
    local G = (r ~= 1) and ((1 - r ^ attempts) / (1 - r)) or attempts
    redirectShare = math.min(1, strength * G * pi)

    for _, s in ipairs(survivors) do
      if not isType(s.species, wanted) then nonFavouredMass = nonFavouredMass + s.weight end
    end

    -- redirected mass, split across favoured species proportional to
    -- their own raw base odds (the strength * G * p_j term -- note
    -- redirectShare/pi already equals strength*G, so it's used directly
    -- here, not multiplied by strength again).
    if nonFavouredMass > 0 then
      local strengthG = redirectShare / pi
      for _, e in ipairs(base) do
        if not isBanned(e.species, banned) and isType(e.species, wanted) then
          addWeight(byId, out, e.species, nonFavouredMass * strengthG * e.weight, e.minL, e.maxL)
        end
      end
    end
  end

  -- everything already favoured stays in full, plus whatever landed on
  -- it above; everything non-favoured keeps whatever wasn't redirected
  -- or injected away.
  local injectChance = (tonumber(cfg.injectChance) or 0.35) * (tonumber(cfg.strength) or 1)
  local allowInject = cfg.inject ~= false
  local injectMass = 0
  for _, s in ipairs(survivors) do
    if isType(s.species, wanted) then
      addWeight(byId, out, s.species, s.weight, s.minL, s.maxL)
    else
      local remaining = s.weight * (1 - redirectShare)
      local stay = allowInject and (remaining * (1 - injectChance)) or remaining
      injectMass = injectMass + (allowInject and (remaining * injectChance) or 0)
      addWeight(byId, out, s.species, stay, s.minL, s.maxL)
    end
  end

  -- inject pool, split evenly, using the route's overall level range
  -- (see the simplification note above).
  if allowInject and injectMass > 0 then
    local pool = typePool(wanted)
    if pool and #pool > 0 then
      local each = injectMass / #pool
      for _, species in ipairs(pool) do
        addWeight(byId, out, species, each, overallMinL or 1, overallMaxL or 1)
      end
    end
  end

  return out
end

local function toDisplay(list)
  if not list then return nil end
  local result = {}
  for _, e in ipairs(list) do
    result[#result + 1] = { species = e.species, pct = e.weight * 100, minLevel = e.minL, maxLevel = e.maxL }
  end
  table.sort(result, function(a, b) return a.pct > b.pct end)
  return result
end

-- Returns nil when weather-driven bias is off/inactive right now
-- (disabled, indoors, pinned) -- callers should fall back to plain
-- Data.encounters[mapId], exactly as if this mod were absent. Each part's
-- `species` list is already in display form (species, pct, minLevel,
-- maxLevel, sorted highest-first) -- no bucket/slot math needed downstream.
function Enc.baseSpeciesOverlay(mapId)
  if not mapId then return nil end
  local ok, base = pcall(function()
    local Game = require("src.core.Game")
    local data = Game and Game.data and Game.data.encounters
    return data and data[mapId]
  end)
  if not (ok and base) then return nil end
  local out = {
    grass = base.grass and { rate = base.grass.rate, species = toDisplay(speciesWeights(base.grass)) } or nil,
    water = base.water and { rate = base.water.rate, species = toDisplay(speciesWeights(base.water)) } or nil,
  }
  return out
end

function Enc.currentOverlay(mapId)
  if not mapId then return nil end
  local wanted = favouredType(activeWeather())
  local cfg = Config.get().encounters
  local banned = bannedSet(weatherForBans(), cfg)
  if not wanted and next(banned) == nil then return nil end

  local ok, base = pcall(function()
    local Game = require("src.core.Game")
    local data = Game and Game.data and Game.data.encounters
    return data and data[mapId]
  end)
  if not (ok and base) then return nil end

  local grassW = base.grass and speciesWeights(base.grass)
  local waterW = base.water and speciesWeights(base.water)

  local weatherId = State.id and tostring(State.id):upper() or ""
  local function variantForecast(partW)
    if not Settings.weatherVariantsOn or not Settings.weatherVariantsOn() then return {} end
    if not partW then return {} end
    local seen = {}
    for _, e in ipairs(partW) do seen[e.species] = e end
    local out = {}
    for _, row in ipairs(WeatherVariants.data or {}) do
      local ids = WeatherVariants.weatherIds and WeatherVariants.weatherIds[row.weather]
      if WeatherVariants.registered[row.id] and seen[row.base] and ids and ids[weatherId] then
        local cfgv = Config.get().weatherVariants or {}
        local chance = tonumber(row.chance) or tonumber(cfgv[(row.rarity or "rare") .. "Chance"])
          or tonumber(cfgv.encounterChance) or 0.03
        chance = math.max(0, math.min(1, chance))
        local e = seen[row.base]
        out[#out + 1] = {
          species = row.id, pct = e.weight * 100 * chance,
          minLevel = e.minL, maxLevel = e.maxL,
          baseSpecies = row.base, baseName = row.baseName, variant = row.variant,
          weather = row.weather, weatherId = weatherId,
          variantChance = chance, weatherVariant = true, rarity = row.rarity or "rare",
        }
      end
    end
    table.sort(out, function(a, b) return a.pct > b.pct end)
    return out
  end

  return {
    weather = wanted,
    weatherId = weatherId,
    bannedTypes = banned,
    grass = grassW and { rate = base.grass.rate, species = toDisplay(biasedWeights(grassW, banned, wanted, cfg)) } or nil,
    water = waterW and { rate = base.water.rate, species = toDisplay(biasedWeights(waterW, banned, wanted, cfg)) } or nil,
    variants = { grass = variantForecast(grassW), water = variantForecast(waterW) },
  }
end

return Enc
