-- WeatherEncounterAPI
--
-- Read-only public data surface for companion mods such as Kanto Companion
-- Mobile. Weather FX remains the authority for weather, route eligibility,
-- weather-form species, encounter probability and Pokémon metadata.
--
-- Nothing in this module changes an encounter. It only describes what the
-- encounter system can produce RIGHT NOW on a map, including Weather FX's
-- persistent weather variants.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Settings = V.require("Settings")
local State = V.require("WeatherState")
local Scene = V.require("Scene")
local Variants = V.require("WeatherVariants")

local API = { _bound = false }

local function pokemonRegistry()
  return mod.content and mod.content.pokemon
end

local function pokemonData(species)
  local reg = pokemonRegistry()
  if reg and type(reg.get) == "function" then
    local ok, value = pcall(reg.get, reg, species)
    if ok and type(value) == "table" then return value end
  end
  local ok, value = pcall(function()
    local Game = require("src.core.Game")
    return Game and Game.data and Game.data.pokemon and Game.data.pokemon[species]
  end)
  if ok and type(value) == "table" then return value end
  return nil
end

local function weatherRowMatches(row, weatherId)
  if not row then return false end
  local ids = Variants.weatherIds and Variants.weatherIds[row.weather]
  return type(ids) == "table" and ids[weatherId] == true
end

local function configuredChance(row)
  local cfg = Config.get().weatherVariants or {}
  local rarity = row.rarity or "rare"
  if rarity == "legendary" then rarity = "legendary" end
  local chance = tonumber(row.chance)
      or tonumber(cfg[rarity .. "Chance"])
      or tonumber(cfg.encounterChance)
      or 0.03
  return math.max(0, math.min(1, chance))
end

local function typeNames(types)
  local out = {}
  if type(types) ~= "table" then return out end
  for i, t in ipairs(types) do out[i] = t end
  return out
end

local function info(species, extra)
  local def = pokemonData(species)
  if not def then return nil end
  local out = {
    species = species,
    id = species,
    name = def.name or species,
    displayName = def.displayName,
    dex = def.dex,
    types = typeNames(def.types),
    catchRate = def.catchRate,
    baseStats = def.baseStats,
    baseExp = def.baseExp,
    growthRate = def.growthRate,
    level1Moves = def.level1Moves,
    learnset = def.learnset,
    evolutions = def.evolutions,
    dexEntry = def.dexEntry,
    spriteFront = def.spriteFront,
    spriteBack = def.spriteBack,
    icon = def.icon,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do out[k] = v end
  end
  return out
end

local function currentWeatherId()
  if State.indoors then return "CLEAR" end
  return tostring(State.id or "CLEAR"):upper()
end

local function routeBase(mapId)
  local ok, data = pcall(function()
    local Game = require("src.core.Game")
    return Game and Game.data and Game.data.encounters and Game.data.encounters[mapId]
  end)
  if ok and type(data) == "table" then return data end
  return nil
end

local function rawEntries(mapId, kind)
  local ok, Enc = pcall(V.require, "Encounters")
  if ok and Enc and Enc.baseSpeciesOverlay then
    local overlay = Enc.baseSpeciesOverlay(mapId)
    if overlay then
      local which = kind == "water" and overlay.water or overlay.grass
      return which and which.species or {}
    end
  end
  return {}
end

local function existingSpecies(mapId, kind)
  local set = {}
  for _, e in ipairs(rawEntries(mapId, kind)) do set[e.species] = true end
  return set
end

local function variantsForPart(mapId, kind, weatherId)
  if not Settings.weatherVariantsOn() then return {} end
  local bases = existingSpecies(mapId, kind)
  local out = {}
  local rows = Variants.data or {}
  for _, row in ipairs(rows) do
    if Variants.registered[row.id] and bases[row.base]
        and weatherRowMatches(row, weatherId) then
      local variantInfo = info(row.id, {
        baseSpecies = row.base,
        baseName = row.baseName,
        variant = row.variant,
        weather = row.weather,
        weatherId = weatherId,
        rarity = row.rarity or "rare",
        weatherVariant = true,
      })
      if variantInfo then
        for _, baseEntry in ipairs(rawEntries(mapId, kind)) do
          if baseEntry.species == row.base then
            variantInfo.minLevel = baseEntry.minLevel
            variantInfo.maxLevel = baseEntry.maxLevel
            variantInfo.baseEncounterPct = baseEntry.pct
            variantInfo.variantChance = configuredChance(row)
            variantInfo.encounterPct = baseEntry.pct * variantInfo.variantChance
            out[#out + 1] = variantInfo
            break
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return (a.encounterPct or 0) > (b.encounterPct or 0) end)
  return out
end

function API.species(species)
  local def = pokemonData(species)
  if not def then return nil end
  local row = nil
  for _, candidate in ipairs(Variants.data or {}) do
    if candidate.id == species then row = candidate; break end
  end
  if row then
    return info(species, {
      baseSpecies = row.base,
      baseName = row.baseName,
      variant = row.variant,
      weather = row.weather,
      weatherIds = Variants.weatherIds[row.weather],
      rarity = row.rarity or "rare",
      weatherVariant = true,
      encounterChance = configuredChance(row),
    })
  end
  return info(species, { weatherVariant = false })
end

function API.route(mapId)
  mapId = mapId or Scene.now.mapId
  if not mapId then return nil end
  local base = routeBase(mapId)
  local weatherId = currentWeatherId()
  local result = {
    mapId = mapId,
    weather = weatherId,
    weatherVariantsEnabled = Settings.weatherVariantsOn(),
    grass = {}, water = {}, variants = {},
  }
  if base then
    result.variants.grass = variantsForPart(mapId, "grass", weatherId)
    result.variants.water = variantsForPart(mapId, "water", weatherId)
    for _, part in ipairs({ result.variants.grass, result.variants.water }) do
      for _, entry in ipairs(part) do result.variants[#result.variants + 1] = entry end
    end
  end
  -- Include the existing Weather FX encounter forecast too. This keeps one
  -- API call sufficient for Kanto Companion's route panel.
  local Enc = V.require("Encounters")
  local forecast = Enc.currentOverlay(mapId)
  if forecast then
    result.forecast = forecast
  end
  return result
end

function API.bind()
  API._bound = true
  return true
end

function API.public()
  return {
    version = "1",
    route = API.route,
    species = API.species,
    currentWeather = currentWeatherId,
    enabled = function() return Settings.weatherVariantsOn() end,
  }
end

return API
