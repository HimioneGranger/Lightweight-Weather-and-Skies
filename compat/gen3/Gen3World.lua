-- Gen 3 world rules: the outdoor test, the storm-front map graph, and
-- nature ambience. DESIGN.md §4.3 Gen3World. Loaded from Gen3Compat's
-- mods.loaded@50 listener, so TWS's own cached modules (via hostLib) are
-- available.

local mod, loadModule, hostLib, shared = ...

local Gen3World = {}

local OUTDOOR_MAP_TYPES = (shared.maps and shared.maps.OUTDOOR_MAP_TYPES)
  or { [1] = true, [2] = true, [3] = true, [6] = true } -- fallback if Gen3Maps failed to load

local function tryRequire(path)
  local ok, m = pcall(require, path)
  if ok then return m end
  return nil
end

local FieldMoves = tryRequire("src.core.game3.field_moves")
local Game3 = tryRequire("src.core.Game")
local Connections = tryRequire("src.core.game3.connections")
local Game3Map = tryRequire("src.core.game3.map")

local function isOutdoorMapType(mapType)
  if FieldMoves and type(FieldMoves.isOutdoors) == "function" then
    local ok, out = pcall(FieldMoves.isOutdoors, mapType)
    if ok then return out end
  end
  return OUTDOOR_MAP_TYPES[tonumber(mapType) or 0] == true
end

local function mapDefFor(mapId)
  local maps = Game3 and Game3.data and Game3.data.maps
  return maps and mapId and maps[mapId]
end

-- ------- 1. Outdoor rule: AND our reliable mapType check onto TWS's -----
--
-- Scene.lua's outdoorOf() reads def.environment first (a Gen 2 field:
-- ROUTE/TOWN strings) and falls through to Map.isOutdoor/def.outdoor/
-- def.tileset=="OVERWORLD" -- none of which is FRLG's schema, and the
-- fallthrough marks most FRLG interiors "outdoor" (T1 §7.4). We AND our
-- own mapType-based answer onto whatever TWS's own test already produced,
-- rather than replacing it outright: a false positive from TWS's heuristic
-- is corrected (mapType says indoors), but if the mapType read itself
-- fails we do not downgrade a TWS "outdoor" answer to false -- an
-- unreadable mapType is more likely our own probe failing than the map
-- actually being indoors, and understating "outdoor" costs a session its
-- weather where overstating it draws rain through a roof.
local Scene = hostLib.require("Scene")
if Scene and type(Scene.sample) == "function" then
  local origSample = Scene.sample
  Scene.sample = function(...)
    local now = origSample(...)
    if now and now.mapId then
      local def = mapDefFor(now.mapId)
      if def then
        local outdoorByType = isOutdoorMapType(def.mapType)
        now.outdoor = (now.outdoor and outdoorByType) and true or false
        now.indoors = not now.outdoor
      end
    end
    return now
  end
else
  mod.log:warn("gen3: Scene.sample not found; FRLG outdoor rule not installed")
end

-- ------- 2. Storm-front context: FRLG connections in TWS's shape --------
--
-- QuestStormFront.buildGraph(maps, root) walks maps[id].connections[dir]
-- = {mapId=, offset=} with width/height and offsets in 32-px blocks
-- (lib/QuestStormFront.lua comment: "blocks are 32 world pixels"). FRLG's
-- own def.width/def.height are already block counts (ENG connections.lua
-- Connections.sizeOf doubles them only to get 16-px *cell* counts for
-- midLayout, i.e. the raw fields are block counts already); FRLG's
-- connection `offset` is in 16-px cells, so ours must be halved to match
-- TWS's block unit (DESIGN.md §4.3: "offsets in 32-px blocks = cells/2").
--
-- "Gen 1 spelling ids": FRLG ids are FR_SOME_NAME; QuestRegional's own
-- lookup uppercases and strips everything but [A-Z0-9] before matching
-- its Gen 1/2 map-name table, so stripping the FR_ prefix and the
-- underscores here (rather than just uppercasing) gets an id that also
-- matches Gen3Maps' aliases and QuestRegional's profile table for the
-- routes/towns whose short name is unchanged from Gen 1 (PALLETTOWN,
-- ROUTE1, VIRIDIANCITY, ...); everything else falls through to
-- QuestRegional's own 'neutral' profile, which is a correct default, not
-- an error.
local function gen1Spelling(id)
  if type(id) ~= "string" then return id end
  return (id:gsub("^FR_", ""):gsub("_", ""))
end

local function connectionsOf(def)
  if Connections and type(Connections.each) == "function" then
    local ok, list = pcall(Connections.each, def)
    if ok and type(list) == "table" then return list end
  end
  -- Fallback: read def.connections directly in the same shape ENG's own
  -- Connections.each documents (array of {dir|direction, map|mapId, offset}).
  local out, conns = {}, def and def.connections
  if type(conns) == "table" then
    for _, c in ipairs(conns) do
      local dir = c.dir or c.direction
      local m = c.map or c.mapId
      if dir and m then out[#out + 1] = { dir = dir, map = m, offset = tonumber(c.offset) or 0 } end
    end
  end
  return out
end

-- Builds a TWS-shaped `maps` table covering just the current map and its
-- immediate connections -- enough for one buildGraph() call rooted there.
-- Deliberately NOT a full precomputed map (there is no single Gen 3
-- equivalent of Gen 1/2's flat game.data.maps kept entirely in memory in
-- the shape buildGraph wants); rebuilt each time context() is asked, which
-- QuestStormFront.lua does only when its graph is missing or its root
-- changed (lib/QuestStormFront.lua:101,140), i.e. on map transitions, not
-- every frame.
local function buildFrlgMaps(rootId)
  local rootDef = mapDefFor(rootId)
  if not rootDef then return nil end
  local out = {}
  local rootGen1 = gen1Spelling(rootId)
  local rootConns = {}
  for _, c in ipairs(connectionsOf(rootDef)) do
    local d = ({ north = "north", south = "south", west = "west", east = "east",
      up = "north", down = "south", left = "west", right = "east" })[c.dir]
    if d then
      rootConns[d] = { mapId = gen1Spelling(c.map), offset = (tonumber(c.offset) or 0) / 2 }
      -- Also give the neighbor a minimal entry so buildGraph's BFS has a
      -- destination `def` to read width/height from (it stops there: this
      -- function does not recurse past one hop, which is what a storm
      -- cell needs to cross a map edge without jumping, DESIGN.md §7.1 P3).
      local neighborDef = mapDefFor(c.map)
      if neighborDef and not out[gen1Spelling(c.map)] then
        out[gen1Spelling(c.map)] = {
          width = tonumber(neighborDef.width) or 0,
          height = tonumber(neighborDef.height) or 0,
          connections = {},
        }
      end
    end
  end
  out[rootGen1] = {
    width = tonumber(rootDef.width) or 0,
    height = tonumber(rootDef.height) or 0,
    connections = rootConns,
  }
  return out, rootGen1
end

local QuestStormFront = hostLib.require("QuestStormFront")
if QuestStormFront then
  QuestStormFront.contextProvider = function()
    local Scene2 = hostLib.require("Scene")
    local s = (Scene2 and Scene2.now) or {}
    if not s.mapId then return nil end
    local ok, maps, rootGen1 = pcall(buildFrlgMaps, s.mapId)
    if not ok or not maps then return nil end
    return {
      maps = maps, mapId = rootGen1, climateMapId = s.mapId,
      x = s.playerX or s.camX or 0, z = s.playerZ or s.camY or 0,
      offsetX = 0, offsetZ = 0,
      outdoor = s.outdoor, indoors = s.indoors, visible = s.visible,
    }
  end
else
  mod.log:warn("gen3: QuestStormFront not found; storm fronts stay unmanaged on Gen 3")
end

-- ------- 3. Nature ambience: beds on, local cries off ------------------
--
-- QuestNature's cry pool reads Gen 1/2-shaped species data and finds
-- nothing useful on game3 (R4 (b) [I/H]); v1 keeps it off unconditionally,
-- runtime-only (never a save write). The play gate is #N.pool==0
-- (QuestNature.lua:97).
local QuestNature = hostLib.require("QuestNature")
if QuestNature then
  QuestNature.pool = {}
else
  mod.log:warn("gen3: QuestNature not found; local cries not clearable (should already be empty)")
end

-- Mirror the NATURE AMBIENCE row into Game.save.options.qNatureAudio /
-- qNatureCalls -- the only keys QuestNature itself reads (QuestNature.lua
-- :46,85-97) -- but only if that table exists on game3 (open probe,
-- DESIGN.md §7.1 P0 (10)). If it does not, nature plays at its default
-- level, which DESIGN.md accepts.
local function mirrorNatureOption()
  local on = shared.options and shared.options.natureOn and shared.options.natureOn()
  if on == nil then on = true end
  local ok = pcall(function()
    local g = Game3 or tryRequire("src.core.Game")
    local opts = g and g.save and g.save.options
    if type(opts) ~= "table" then return end
    opts.qNatureAudio = on and "on" or "off"
    -- qNatureCalls stays whatever the player set for individual cry
    -- playback; v1 forces the pool empty regardless (see above), so this
    -- key currently has no effect on Gen 3, but is left untouched rather
    -- than overwritten, in case a later game3 pool (§5.1) reads it.
  end)
  return ok
end
shared.mirrorNatureOption = mirrorNatureOption
mirrorNatureOption()

return Gen3World
