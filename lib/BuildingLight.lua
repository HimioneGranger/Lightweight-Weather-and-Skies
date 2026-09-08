-- Building-proximity star / ambient modifier (map metadata, not rendered geometry).
--
-- Architecture:
--   map.def / warps / events / TileShape  →  BuildingLocation registry
--   player tile                          →  continuous distance falloff
--   target factor                        →  dt-smoothed current factor
--   factor × day-night visibility        →  starScale / ambientMul
--
-- Building locations are known from map data whether or not the voxel
-- geometry for that building is loaded. Loading geometry must not change
-- brightness.

local V = ...

local BuildingLight = {
  dist = 50,
  factor = 0,          -- smoothed 0 = near building, 1 = far/wild
  _factorRaw = 0,
  ambientMul = 1,
  starMul = 1,
  _cacheKey = nil,
  _buildings = nil,
  _lastDist = nil,
  DEBUG = false,
}

-- Continuous falloff (player steps ≈ map cells)
local NEAR_STEPS = 5     -- max town effect
local FAR_STEPS = 20     -- full wild stars
local AMBIENT_NEAR = 1.0
local AMBIENT_FAR = 0.48
local STAR_NEAR = 0.35   -- dimmer stars near buildings
local STAR_FAR = 1.0     -- full stars in the wild
-- Temporal ease (frame-rate independent). Higher = snappier; keep gentle.
local SMOOTH = 2.2

-- Permanent registry: mapId → { {x,y,w,h}, ... }
-- Survives geometry load/unload; only rebuilt when map identity changes.
local REGISTRY = {}

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function smoothstep(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

local function isTrueNight()
  local ok, TOD = pcall(function() return V.require("TimeOfDay") end)
  if not (ok and TOD) then return false end
  if TOD.pin == "NITE" or TOD.pin == "NIGHT" then return true end
  if TOD.tod == "NITE" or TOD.tod == "NIGHT" then return true end
  if TOD.isNight then
    local ok2, n = pcall(TOD.isNight)
    if ok2 and n then return true end
  end
  return false
end

local function mapIdOf(map)
  if not map then return nil end
  return map.id or (map.def and (map.def.id or map.def.name)) or tostring(map)
end

local function dims(map)
  if not map then return 0, 0 end
  local w = tonumber(map.widthCells) or tonumber(map.width)
  local h = tonumber(map.heightCells) or tonumber(map.height)
  if (not w or w <= 0) and map.def then
    w = tonumber(map.def.widthCells) or tonumber(map.def.width)
  end
  if (not h or h <= 0) and map.def then
    h = tonumber(map.def.heightCells) or tonumber(map.def.height)
  end
  -- Gen1 block maps often store width in blocks; cells ≈ blocks * 2
  if (not w or w <= 0) and map.def and map.def.width then
    w = tonumber(map.def.width) * 2
  end
  if (not h or h <= 0) and map.def and map.def.height then
    h = tonumber(map.def.height) * 2
  end
  return tonumber(w) or 0, tonumber(h) or 0
end

local function pushPoint(list, x, y, footprint)
  if x == nil or y == nil then return end
  x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
  local fp = footprint or 2
  list[#list + 1] = { x = x, y = y, w = fp, h = fp }
end

--- Collect building-like locations from static map data (not rendered voxels).
local function collectFromMapData(map)
  local list = {}
  if not map then return list end
  local w, h = dims(map)
  if w <= 0 or h <= 0 then w, h = 64, 64 end

  local def = map.def or map

  -- 1) Warps / doors / events — present in map definitions without geometry
  local function scanEvents(events)
    if type(events) ~= "table" then return end
    for _, e in pairs(events) do
      if type(e) == "table" then
        local ex = tonumber(e.x or e.tileX or e.tx or e.col or e.cx)
        local ey = tonumber(e.y or e.tileY or e.ty or e.row or e.cy)
        local isDoor = e.warp or e.destination or e.map or e.toMap
            or e.targetMap or e.destMap or e.warpId
            or e.type == "warp" or e.kind == "warp" or e.script == "warp"
            or e.type == "door" or e.kind == "door"
            or e.door or e.entrance
        if isDoor and ex and ey then
          pushPoint(list, ex, ey, 3)
        end
      end
    end
  end
  scanEvents(map.events)
  scanEvents(map.warps)
  scanEvents(def.events)
  scanEvents(def.warps)
  scanEvents(def.warpEvents)
  scanEvents(map.objects)
  scanEvents(def.objects)

  -- Nested event tables (some maps store warps under events.warps)
  if type(def.events) == "table" then
    scanEvents(def.events.warps)
    scanEvents(def.events.doors)
  end

  -- 2) TileShape elevated cells — uses tile definitions for the whole map,
  --    not only currently meshed chunks (forMap returns shape table by tile id)
  pcall(function()
    local TileShape = V.require("TileShape")
    if not (TileShape and TileShape.forMap) then return end
    if not (map.cellTile or (map.def and map.def.cellTile)) then return end
    local shapes = TileShape.forMap(map)
    if not shapes then return end
    local cellTile = map.cellTile
    local inBounds = map.inBounds
    if type(cellTile) ~= "function" then return end
    local step = (w * h > 14000) and 2 or 1
    local seen = {}
    for cy = 0, math.max(0, h - 1), step do
      for cx = 0, math.max(0, w - 1), step do
        local inbound = true
        if type(inBounds) == "function" then
          local okb, ib = pcall(inBounds, map, cx, cy)
          inbound = okb and ib
        end
        if inbound then
          local ok, tile = pcall(cellTile, map, cx, cy)
          if ok and tile ~= nil then
            local sh = shapes[tile]
            if sh then
              local ht = tonumber(sh.h) or 0
              local art = tostring(sh.art or sh.kind or "")
              if ht >= 2.5 or art == "building" or art == "roof"
                  or art == "wall" or art == "house" then
                local key = cx .. "," .. cy
                if not seen[key] then
                  seen[key] = true
                  pushPoint(list, cx, cy, 2)
                end
              end
            end
          end
        end
      end
    end
  end)

  -- 3) Town heuristic only if still empty (avoids false wild mid-town)
  if #list == 0 then
    pcall(function()
      local Scene = V.require("Scene")
      if Scene and Scene.now and Scene.now.isTown then
        pushPoint(list, w * 0.5, h * 0.5, 8)
        pushPoint(list, 8, 8, 4)
        pushPoint(list, math.max(0, w - 8), math.max(0, h - 8), 4)
      end
    end)
  end

  return list
end

local function buildingsFor(map)
  local id = mapIdOf(map)
  if not id then
    local list = collectFromMapData(map)
    BuildingLight._buildings = list
    return list
  end
  local entry = REGISTRY[id]
  if entry and entry.list then
    BuildingLight._buildings = entry.list
    return entry.list
  end
  local list = collectFromMapData(map)
  REGISTRY[id] = { list = list, w = select(1, dims(map)), h = select(2, dims(map)) }
  BuildingLight._buildings = list
  return list
end

--- Distance to nearest building footprint (not a single door pixel).
local function nearestDist(px, py, buildings)
  if not buildings or #buildings == 0 then return nil end
  local best = 1e9
  for i = 1, #buildings do
    local b = buildings[i]
    local hw = (tonumber(b.w) or 2) * 0.5
    local hh = (tonumber(b.h) or 2) * 0.5
    -- Distance to axis-aligned footprint rectangle
    local dx = math.max(math.abs(px - b.x) - hw, 0)
    local dy = math.max(math.abs(py - b.y) - hh, 0)
    local d = math.sqrt(dx * dx + dy * dy)
    if d < best then best = d end
  end
  return best
end

--- Continuous falloff: 0 near building → 1 at FAR_STEPS (smoothstep).
local function distToFactor(d)
  if d == nil then return nil end
  if d <= NEAR_STEPS then return 0 end
  if d >= FAR_STEPS then return 1 end
  local t = (d - NEAR_STEPS) / (FAR_STEPS - NEAR_STEPS)
  return smoothstep(t)
end

local function playerTile()
  local px, py
  pcall(function()
    local game = V.require("Game")
    local g = game and game.current and game.current()
    local world = g and g.level and g.level.world
    if not world then return end
    local p = world.player or world.hero or world.avatar
    if type(p) == "table" then
      px = tonumber(p.x or p.tileX or p.tx)
      py = tonumber(p.y or p.tileY or p.ty)
      if px and py then
        px, py = math.floor(px), math.floor(py)
        return
      end
    end
    local cam = world.camera
    if type(cam) == "table" then
      local cx, cy = tonumber(cam.x), tonumber(cam.y)
      if cx and cy then
        px, py = math.floor(cx / 16), math.floor(cy / 16)
      end
    end
  end)
  if px and py then return px, py end
  pcall(function()
    local Scene = V.require("Scene")
    if Scene and Scene.now then
      local cx, cy = tonumber(Scene.now.camX), tonumber(Scene.now.camY)
      if cx and cy then
        px, py = math.floor(cx / 16), math.floor(cy / 16)
      end
    end
  end)
  return px, py
end

local function resolveMap()
  local map
  pcall(function()
    local Atmos = V.require("DramalessAtmos")
    if Atmos and Atmos._lastMap then map = Atmos._lastMap end
  end)
  if map then return map end
  pcall(function()
    local game = V.require("Game")
    local g = game and game.current and game.current()
    local world = g and g.level and g.level.world
    if world then map = world.map end
  end)
  return map
end

function BuildingLight.update(dt)
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end
  if dt > 0.25 then dt = 0.25 end

  if not isTrueNight() then
    -- Day: no building effect. Ease toward neutral so day/night boundary is soft.
    BuildingLight._factorRaw = 0
    local f = BuildingLight.factor or 0
    local k = 1 - math.exp(-SMOOTH * dt)
    BuildingLight.factor = f + (0 - f) * k
    BuildingLight.dist = 0
    BuildingLight.ambientMul = 1
    BuildingLight.starMul = STAR_FAR
    return
  end

  local map = resolveMap()
  local px, py = playerTile()
  local target

  if not (px and py) then
    -- Unknown player position: keep last factor (do not snap to wild)
    target = BuildingLight._factorRaw
    if target == nil then target = 0.5 end
  else
    local buildings = buildingsFor(map)
    local d = nearestDist(px, py, buildings)
    if d == nil then
      -- No metadata yet: keep previous distance (avoids load-pop)
      d = BuildingLight._lastDist
      if d == nil then d = FAR_STEPS * 0.6 end
    else
      BuildingLight._lastDist = d
    end
    BuildingLight.dist = d
    target = distToFactor(d)
    if target == nil then target = BuildingLight._factorRaw or 0.5 end
  end

  BuildingLight._factorRaw = target

  -- Time-based smooth toward target (no binary near/far switch)
  local f = BuildingLight.factor or target
  if math.abs(target - f) > 0.55 then
    -- Map warp / teleport: blend faster but not instant
    local k = 1 - math.exp(-6.0 * dt)
    f = f + (target - f) * k
  else
    local k = 1 - math.exp(-SMOOTH * dt)
    f = f + (target - f) * k
  end
  BuildingLight.factor = clamp01(f)

  local ff = BuildingLight.factor
  BuildingLight.ambientMul = AMBIENT_NEAR + (AMBIENT_FAR - AMBIENT_NEAR) * ff
  BuildingLight.starMul = STAR_NEAR + (STAR_FAR - STAR_NEAR) * ff
end

function BuildingLight.nightAmbientScale()
  if not isTrueNight() then return 1 end
  return BuildingLight.ambientMul or 1
end

function BuildingLight.starScale()
  -- Day/twilight: do not dim (NightSky multiplies by nightVis separately)
  if not isTrueNight() then
    return STAR_FAR
  end
  local m = BuildingLight.starMul
  if type(m) ~= "number" or m ~= m then m = STAR_FAR end
  if m < STAR_NEAR then m = STAR_NEAR end
  if m > STAR_FAR then m = STAR_FAR end
  return m
end

--- Debug snapshot for AI / HUD tools
function BuildingLight.debugInfo()
  return {
    dist = BuildingLight.dist,
    factor = BuildingLight.factor,
    factorRaw = BuildingLight._factorRaw,
    starMul = BuildingLight.starMul,
    ambientMul = BuildingLight.ambientMul,
    buildings = BuildingLight._buildings and #BuildingLight._buildings or 0,
    registryMaps = (function()
      local n = 0
      for _ in pairs(REGISTRY) do n = n + 1 end
      return n
    end)(),
    night = isTrueNight(),
  }
end

return BuildingLight
