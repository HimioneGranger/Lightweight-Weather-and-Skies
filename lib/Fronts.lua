-- WEATHER FRONTS.
--
-- Until now this mod had ONE weather.  It followed the player: walk out of
-- a blizzard and the blizzard came with you, because there was only ever a
-- single `State.id` and it described "the weather", not "the weather
-- somewhere".  That is fine for an effect and wrong for a world.
--
-- A front belongs to a PLACE.  Snow over Mahogany keeps snowing over
-- Mahogany after you leave, runs its own clock, and is still there when you
-- come back if it has not blown out.  The player is a visitor to whichever
-- front they are standing in.
--
-- =====================================================================
-- WHY REGIONS AND NOT MAPS
-- =====================================================================
--
-- Per-map weather sounds more accurate and is worse in play: crossing a map
-- boundary every twenty steps would mean the sky changing every twenty
-- steps, and a route split into three maps would have three weathers along
-- its length.  Weather systems are bigger than a screen.
--
-- So the world is divided into a few dozen REGIONS -- a town and the routes
-- around it -- and a front covers a whole region.  Walking from Route 30 to
-- Route 31 keeps the same sky because they are the same weather region; the
-- change happens at a boundary that feels like somewhere else.
--
-- Regions are matched by map-id PREFIX rather than an exhaustive list, so a
-- map mod that adds ROUTE_31_NORTH lands in the region its name implies
-- instead of falling through to nothing.
--
-- =====================================================================
-- WHAT MAKES IT A FRONT RATHER THAN A LOOKUP TABLE
-- =====================================================================
--
--   * Each region rolls its own weather on its own clock, using the same
--     weighting the global AUTO used -- so the geography that made snow
--     likelier on the mountain pass still does.
--   * Fronts DRIFT.  When a region's spell ends it does not roll blind:
--     it is twice as likely to inherit what a neighbouring region already
--     has.  That is what turns independent rolls into weather that moves
--     across the map, and it is the whole reason `neighbours` exists.
--   * Everything runs whether or not the player is there.  A region the
--     player has never visited still has a sky, because the Pokegear card
--     needs to show one and because a front that only exists while watched
--     is not a front.
--
-- Cost: one table of ~30 numbers ticked per frame, and a roll per region
-- every few minutes.  Nothing here scales with anything.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local Config = V.require("Config")

local Fronts = {}

-- ------- the map
--
-- `at` is the region's position on the Pokegear's 20x14 panel grid, which
-- is what lets the card draw a weather map rather than a list.  Kanto and
-- Johto are both here: this mod runs on both games, and a region table that
-- only knew one would leave the other with no fronts at all.
--
-- The coordinates are approximate by design -- close enough to read as a
-- map, not a survey.

Fronts.REGIONS = {
  -- ---- Johto  (continent tag drives which map page a marker may draw on)
  { id = "NEW_BARK", land = "johto",   label = "N.BARK",  at = { 16, 9 },
    maps = { "JOHTO_NEW_BARK", "JOHTO_ROUTE_29", "NEW_BARK", "ROUTE_29", "ROUTE_27" } },
  { id = "CHERRYGROVE", land = "johto", label = "CHERRY", at = { 14, 9 },
    maps = { "JOHTO_CHERRYGROVE", "JOHTO_ROUTE_30", "JOHTO_ROUTE_31", "CHERRYGROVE", "ROUTE_30", "ROUTE_31" } },
  { id = "VIOLET", land = "johto",     label = "VIOLET",  at = { 12, 8 },
    maps = { "JOHTO_VIOLET", "JOHTO_ROUTE_32", "JOHTO_ROUTE_36", "VIOLET", "SPROUT_TOWER", "RUINS_OF_ALPH", "ROUTE_32", "ROUTE_36" } },
  { id = "AZALEA", land = "johto",     label = "AZALEA",  at = { 12, 11 },
    maps = { "JOHTO_AZALEA", "JOHTO_ILEX_FOREST", "JOHTO_ROUTE_33", "JOHTO_ROUTE_34", "AZALEA", "SLOWPOKE_WELL", "ILEX_FOREST", "ROUTE_33", "ROUTE_34" } },
  { id = "GOLDENROD", land = "johto",  label = "GOLDEN",  at = { 9, 10 },
    maps = { "JOHTO_GOLDENROD", "JOHTO_NATIONAL_PARK", "JOHTO_ROUTE_35", "JOHTO_ROUTE_37", "GOLDENROD", "NATIONAL_PARK", "ROUTE_35", "ROUTE_37" } },
  { id = "ECRUTEAK", land = "johto",   label = "ECRUTK",  at = { 9, 7 },
    maps = { "JOHTO_ECRUTEAK", "JOHTO_ROUTE_38", "JOHTO_ROUTE_39", "ECRUTEAK", "BURNED_TOWER", "TIN_TOWER", "ROUTE_38", "ROUTE_39" } },
  { id = "OLIVINE", land = "johto",    label = "OLIVIN",  at = { 6, 8 },
    maps = { "JOHTO_OLIVINE", "JOHTO_ROUTE_40", "OLIVINE", "LIGHTHOUSE", "BATTLE_TOWER", "ROUTE_40", "ROUTE_41" } },
  { id = "CIANWOOD", land = "johto",   label = "CIANWD",  at = { 3, 8 },
    maps = { "JOHTO_CIANWOOD", "JOHTO_ROUTE_41", "CIANWOOD", "ROUTE_47", "ROUTE_48" } },
  { id = "MAHOGANY", land = "johto",   label = "MAHOGY",  at = { 13, 5 },
    maps = { "JOHTO_MAHOGANY", "JOHTO_LAKE_RAGE", "JOHTO_ROUTE_42", "JOHTO_ROUTE_43", "JOHTO_ROUTE_44", "MAHOGANY", "LAKE_OF_RAGE", "ROUTE_42", "ROUTE_43", "ROUTE_44" } },
  { id = "BLACKTHORN", land = "johto", label = "BLACKT",  at = { 16, 5 },
    maps = { "JOHTO_BLACKTHORN", "JOHTO_ROUTE_45", "JOHTO_ROUTE_46", "BLACKTHORN", "DRAGONS_DEN", "ICE_PATH", "ROUTE_45", "ROUTE_46" } },
  { id = "MT_SILVER", land = "johto",  label = "MT.SLV",  at = { 18, 7 },
    maps = { "MT_SILVER", "SILVER_CAVE", "ROUTE_28" } },

  -- ---- Kanto
  { id = "PALLET", land = "kanto",     label = "PALLET",  at = { 4, 12 },
    maps = { "PALLET", "ROUTE_1", "ROUTE_21" } },
  { id = "VIRIDIAN", land = "kanto",   label = "VIRIDN",  at = { 4, 10 },
    maps = { "VIRIDIAN", "ROUTE_2", "ROUTE_22" } },
  { id = "PEWTER", land = "kanto",     label = "PEWTER",  at = { 4, 7 },
    maps = { "PEWTER", "MT_MOON", "ROUTE_3" } },
  { id = "CERULEAN", land = "kanto",   label = "CERULN",  at = { 9, 5 },
    maps = { "CERULEAN", "ROUTE_4", "ROUTE_5", "ROUTE_24", "ROUTE_25" } },
  { id = "VERMILION", land = "kanto",  label = "VERMIL",  at = { 9, 10 },
    maps = { "VERMILION", "ROUTE_6", "DIGLETTS_CAVE" } },
  { id = "LAVENDER", land = "kanto",   label = "LAVNDR",  at = { 13, 8 },
    maps = { "LAVENDER", "ROCK_TUNNEL", "ROUTE_10", "ROUTE_8", "ROUTE_12" } },
  { id = "CELADON", land = "kanto",    label = "CELADN",  at = { 7, 8 },
    maps = { "CELADON", "ROUTE_7", "ROUTE_16", "ROUTE_17", "ROUTE_18" } },
  { id = "FUCHSIA", land = "kanto",    label = "FUCHSA",  at = { 8, 12 },
    maps = { "FUCHSIA", "SAFARI", "ROUTE_13", "ROUTE_14", "ROUTE_15", "ROUTE_19" } },
  { id = "SAFFRON", land = "kanto",    label = "SAFFRN",  at = { 9, 8 },
    maps = { "SAFFRON", "ROUTE_9", "ROUTE_11" } },
  { id = "CINNABAR", land = "kanto",   label = "CINNBR",  at = { 4, 13 },
    maps = { "CINNABAR", "POKEMON_MANSION", "SEAFOAM", "ROUTE_20" } },
  { id = "INDIGO", land = "kanto",     label = "INDIGO",  at = { 2, 6 },
    maps = { "INDIGO", "VICTORY_ROAD", "ROUTE_23", "ROUTE_26" } },
}

Fronts.byId = {}
for i, r in ipairs(Fronts.REGIONS) do
  r.index = i
  Fronts.byId[r.id] = r
end

-- Neighbours, computed once from the grid positions rather than typed out.
-- A hand-written adjacency list would be thirty more lines to get subtly
-- wrong, and "near each other on the map" is exactly what neighbouring
-- means for a weather front.
do
  for _, a in ipairs(Fronts.REGIONS) do
    a.neighbours = {}
    for _, b in ipairs(Fronts.REGIONS) do
      if a ~= b then
        local dx = a.at[1] - b.at[1]
        local dy = a.at[2] - b.at[2]
        if (dx * dx + dy * dy) <= 16 then          -- within four cells
          a.neighbours[#a.neighbours + 1] = b.id
        end
      end
    end
  end
end

-- ------- which region a map is in

local cache = {}

function Fronts.regionFor(mapId)
  local id = tostring(mapId or "")
  if id == "" then return nil end
  local hit = cache[id]
  if hit ~= nil then return hit or nil end
  for _, region in ipairs(Fronts.REGIONS) do
    for _, prefix in ipairs(region.maps) do
      if id:find(prefix, 1, true) then
        cache[id] = region
        return region
      end
    end
  end
  cache[id] = false          -- remembered as "no region", not re-scanned
  return nil
end

-- ------- live state
--
-- One entry per region: what it is doing and how long is left.  Kept in the
-- mod's own save so a front survives a reload, which is the difference
-- between weather that lives somewhere and weather that is regenerated
-- whenever you look at it.

Fronts.state = {}

local function rand()
  if love and love.math then return love.math.random() end
  return math.random()
end

-- The picker is WeatherState's, passed in rather than required, because
-- Fronts is loaded by WeatherState and requiring it back would be a cycle.
Fronts.pick = nil          -- set by WeatherState.installFronts

-- True until every region has rolled once.  A fresh save otherwise starts
-- with every front on CLEAR and rolls them independently over the next ten
-- minutes, so a player switching the mod on for the first time -- or
-- recording a video of it -- sees a dry world and reasonably concludes it
-- does nothing.  The GLOBAL AUTO clock has had a never-open-on-clear rule
-- since 2.2.1; the fronts never got it, which is the oversight this fixes.
Fronts.fresh = true

local function rollFor(region, first)
  local picked
  -- DRIFT: a front is twice as likely to inherit a neighbour's weather as
  -- to invent its own.  This is what makes the fronts move across the map
  -- instead of nineteen regions blinking independently.
  --
  -- Skipped on the OPENING roll, because at that moment every neighbour is
  -- still CLEAR -- inheriting from them would hand back the very thing the
  -- opening roll exists to avoid.
  if not first and rand() < (tonumber(Config.get().fronts.drift) or 0.5) then
    local n = region.neighbours
    if n and #n > 0 then
      local from = Fronts.state[n[math.max(1, math.ceil(rand() * #n))]]
      if from and from.id then picked = from.id end
    end
  end
  if not picked and Fronts.pick then
    -- the region's OWN geography, using the same weighted roll the global
    -- AUTO used, so the mountain pass still favours snow
    picked = Fronts.pick(region.maps[1], first and Types.DEFAULT or nil)
  end

  -- The opening roll must not return CLEAR, and asking the weighted picker
  -- to exclude it is not enough on its own: the picker can legitimately
  -- come back with CLEAR when every other weight has been zeroed (a
  -- config that disables types, a `weight = 0`, a time of day that rules
  -- one out).  So the opening roll falls back to an explicit choice from
  -- the natural catalogue -- which is the one place in this mod where
  -- "anything but clear" is the actual requirement rather than a
  -- preference.
  if first and (not picked or picked == Types.DEFAULT) then
    local pool = {}
    for _, def in ipairs(Types.list) do
      if def.natural ~= false and def.id ~= Types.DEFAULT
          and Config.weatherEnabled(def.id) then
        pool[#pool + 1] = def.id
      end
    end
    if #pool > 0 then
      picked = pool[math.max(1, math.ceil(rand() * #pool))]
    end
  end

  return picked or Types.DEFAULT
end

-- How many regions open with weather on a fresh save.  Not all of them: a
-- world where every single region is doing something is as unconvincing as
-- one where none is, and clear skies somewhere are what make the weather
-- elsewhere read as weather.
Fronts.OPENING_FRONTS = 6

local function dwell(def)
  local lo = (def.minMin or 4) * 60
  local hi = (def.maxMin or 10) * 60
  if hi < lo then hi = lo end
  return lo + rand() * (hi - lo)
end

function Fronts.ensure(region)
  local st = Fronts.state[region.id]
  if st then return st end
  st = { id = Types.DEFAULT, left = 0 }
  Fronts.state[region.id] = st
  return st
end

-- Every region ticks, including ones the player has never seen: a front
-- that only exists while watched is not a front, and the Pokegear card has
-- to show a sky over places the player is not standing in.
function Fronts.update(dt, speedScale)
  if not Config.get().fronts.enabled then return end
  dt = tonumber(dt) or 0
  if dt <= 0 or dt > 0.25 then return end
  speedScale = tonumber(speedScale) or 1

  -- The opening roll: a handful of regions start with weather rather than
  -- the whole world starting dry.  Chosen by shuffling rather than by
  -- taking the first six, so it is not always the same corner of the map.
  if Fronts.fresh then
    Fronts.fresh = false

    -- PER CONTINENT, not across the whole world.
    --
    -- Shuffling all 22 regions and taking six could put every one of them
    -- in Johto -- roughly a one in fifty chance, and a certainty for
    -- somebody -- leaving a Gen 2 player who takes the train to Kanto in a
    -- region where nothing has started yet.  Splitting the roll means both
    -- halves of the world are weathered from the first frame, whichever
    -- one the player is standing in.
    --
    -- A continent with no regions (a Gen 1 game has no Johto ones by map
    -- id, though the table carries them) simply contributes none, so this
    -- costs nothing where it does not apply.
    local byLand = {}
    for _, region in ipairs(Fronts.REGIONS) do
      local land = region.land or "other"
      byLand[land] = byLand[land] or {}
      local list = byLand[land]
      list[#list + 1] = region
    end

    local lands = {}
    for land in pairs(byLand) do lands[#lands + 1] = land end
    table.sort(lands)                        -- stable, so runs are reproducible

    local perLand = math.max(1,
      math.floor(Fronts.OPENING_FRONTS / math.max(1, #lands) + 0.5))

    for _, land in ipairs(lands) do
      local list = byLand[land]
      for i = #list, 2, -1 do
        local j = math.max(1, math.ceil(rand() * i))
        list[i], list[j] = list[j], list[i]
      end
      for i = 1, math.min(perLand, #list) do
        local region = list[i]
        local st = Fronts.ensure(region)
        st.id = rollFor(region, true)        -- never CLEAR
        st.left = math.max(4, dwell(Types.get(st.id)) * speedScale)
      end
    end
  end

  for _, region in ipairs(Fronts.REGIONS) do
    local st = Fronts.ensure(region)
    st.left = (st.left or 0) - dt
    if st.left <= 0 then
      st.id = rollFor(region, false)
      st.left = math.max(4, dwell(Types.get(st.id)) * speedScale)
    end
  end
end

-- What is the weather over this map?  nil means "this map is in no region",
-- which is every interior and anywhere the table does not reach -- and the
-- caller falls back to the global weather, so nothing is lost.
function Fronts.weatherFor(mapId)
  if not Config.get().fronts.enabled then return nil end
  local region = Fronts.regionFor(mapId)
  if not region then return nil end
  local st = Fronts.state[region.id]
  return st and st.id or nil, region
end

-- ------- persistence
--
-- Packed into one string rather than a table per region: the save is a flat
-- key/value store, and thirty keys that must be written and read in step is
-- thirty chances to half-save.  One key is atomic.

function Fronts.persist()
  if not Config.get().fronts.enabled then return end
  pcall(function()
    local out = {}
    for _, region in ipairs(Fronts.REGIONS) do
      local st = Fronts.state[region.id]
      if st then
        out[#out + 1] = ("%s=%s:%d"):format(region.id, st.id, math.floor(st.left or 0))
      end
    end
    mod.save:set("fronts", table.concat(out, ";"))
  end)
end

function Fronts.restore()
  Fronts.state = {}
  -- A save that already carries fronts is not fresh; only a world with no
  -- stored weather gets the opening roll.
  Fronts.fresh = true
  pcall(function()
    local packed = mod.save:get("fronts", nil)
    if type(packed) ~= "string" then return end
    for entry in packed:gmatch("[^;]+") do
      local rid, wid, left = entry:match("^(.-)=(.-):(%-?%d+)$")
      if rid and Fronts.byId[rid] then
        -- An unknown weather id degrades to CLEAR rather than being kept:
        -- a save from a version with more weathers must not park a region
        -- on something this build cannot draw.
        Fronts.state[rid] = { id = Types.get(wid).id, left = tonumber(left) or 0 }
        Fronts.fresh = false
      end
    end
  end)
  for _, region in ipairs(Fronts.REGIONS) do Fronts.ensure(region) end
end

-- ------- for the Pokegear card

-- Which continent is this map on?  nil when unknown, which the map
-- overlay treats as "do not draw" rather than "draw everywhere".
function Fronts.landOf(mapId)
  local region = Fronts.regionFor(mapId)
  return region and region.land or nil
end

function Fronts.snapshot()
  local out = {}
  for _, region in ipairs(Fronts.REGIONS) do
    local st = Fronts.state[region.id]
    out[#out + 1] = {
      id = region.id, label = region.label, at = region.at,
      land = region.land,
      weather = st and st.id or Types.DEFAULT,
      left = st and math.floor(st.left or 0) or 0,
    }
  end
  return out
end

function Fronts.describe(mapId)
  local weather, region = Fronts.weatherFor(mapId)
  if not weather then return "-" end
  return ("%s/%s"):format(region.label, Types.get(weather).label)
end

return Fronts
