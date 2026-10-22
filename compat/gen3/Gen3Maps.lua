-- FRLG map tables: the outdoor mapType set (shared with Gen3World and
-- Gen3Host) and region aliases through OutdoorWeatherAreas.identity.
-- DESIGN.md §4.3 Gen3Maps, citing lib\QuestRegional.lua:54-58. Loaded from
-- Gen3Compat's mods.loaded@50 listener.

local mod, loadModule, hostLib, shared = ...

local Gen3Maps = {}

-- pokefirered map_types.h, also RTC's own Core.OUTDOOR and ENG
-- field_moves.lua's FieldMoves.MAP_TYPES: Town=1 City=2 Route=3
-- Underground=4 Underwater=5 OceanRoute=6.
Gen3Maps.OUTDOOR_MAP_TYPES = { [1] = true, [2] = true, [3] = true, [6] = true }

-- QuestRegional.profile(mapId) calls OutdoorWeatherAreas.identity(mapId)
-- first, then uppercases and strips everything but [A-Z0-9] before
-- matching its own Gen 1/2 map-name table (lib/QuestRegional.lua:54-58).
-- Aliasing here to an id that survives that strip and lands on an
-- existing entry is enough; nothing in QuestRegional's own tables needs
-- to change.
local ALIASES = {
  -- FRLG splits Route 21 into a north (Cinnabar-side) and south
  -- (Pallet-side) half; both should read the one Route 21 weather profile.
  ROUTE_21_NORTH = "ROUTE_21",
  ROUTE_21_SOUTH = "ROUTE_21",
  -- FRLG's exterior-of-the-plateau map is not INDIGO_PLATEAU itself.
  INDIGO_PLATEAU_EXTERIOR = "INDIGO_PLATEAU",
}

-- Sevii Islands are FRLG/LeafGreen-only and have no entry at all in
-- QuestRegional's Gen 1/2 table; alias every Sevii outdoor map to
-- CINNABARISLAND (QuestRegional's 'island' / coastal profile), the
-- closest existing Kanto analogue, rather than inventing a new profile
-- entry this file cannot add (QuestRegional's `profiles`/`maps` tables
-- are file-local upvalues, not exposed for extension).
local function isSevii(id)
  return type(id) == "string" and id:upper():find("SEVII", 1, true) ~= nil
end

local OutdoorWeatherAreas = hostLib.require("OutdoorWeatherAreas")
if OutdoorWeatherAreas and type(OutdoorWeatherAreas.identity) == "function" then
  local origIdentity = OutdoorWeatherAreas.identity
  OutdoorWeatherAreas.identity = function(id)
    local aliased = ALIASES[id]
    if aliased then return origIdentity(aliased) end
    if isSevii(id) then return origIdentity("CINNABARISLAND") end
    return origIdentity(id)
  end
else
  mod.log:warn("gen3: OutdoorWeatherAreas.identity not found; region aliases not installed")
end

-- Gen3Compat assigns shared.maps = (this file's return value), so
-- Gen3Maps.OUTDOOR_MAP_TYPES above is already shared.maps.OUTDOOR_MAP_TYPES
-- once this returns; nothing further to publish here.
return Gen3Maps
