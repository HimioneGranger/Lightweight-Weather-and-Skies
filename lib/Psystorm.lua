-- THE PSYSTORM.
--
-- The one weather that is not weather.  It does not roll on the AUTO clock
-- and no front can drift it in; it is SUMMONED, by a place or by what is
-- walking through it, and everywhere else the sky simply cannot produce it.
--
-- Two triggers, either of which is enough:
--
--   1. A MAP WHERE MEWTWO LIVES.  Cerulean Cave and its floors.  The
--      innermost chamber is always storming -- that is its weather, not a
--      chance -- and the approach floors are a strong chance, so walking in
--      feels like walking toward something.
--
--   2. MEW OR MEWTWO AT THE FRONT OF THE PARTY.  Carrying one anywhere
--      makes the sky occasionally answer, which is the version of this a
--      player will actually notice, because most players will never stand
--      in the cave twice.
--
-- WHY IT IS ROLLED PER ARRIVAL, NOT PER FRAME.  A 70% chance evaluated
-- every frame is a certainty within a second, and a chance evaluated per
-- step would flicker.  It is rolled ONCE each time the player enters a
-- qualifying map, and the answer stands until they leave -- the same
-- treatment lib/Config.lua gives a chance-based location override, for the
-- same reason.
--
-- WHY IT OUTRANKS FRONTS.  A front is the region's own weather; a psystorm
-- is a reaction to what is standing there. When Mewtwo's cave is storming
-- and a front says fog, the cave wins -- the front resumes the moment the
-- player leaves, because the front was never overwritten, only overruled.

local V = ...
local mod = V.mod
local Config = V.require("Config")

local Psystorm = {}

Psystorm.ID = "PSYSTORM"

-- Maps where it may occur, by prefix, and how likely.  `always` is the
-- innermost chamber: a chance there would mean a player could stand in
-- front of Mewtwo under a clear sky, which would be worse than no feature.
Psystorm.PLACES = {
  { prefix = "CERULEAN_CAVE_B1F", chance = 1.00 },   -- Mewtwo's chamber
  { prefix = "CERULEAN_CAVE_2F",  chance = 0.70 },
  { prefix = "CERULEAN_CAVE_1F",  chance = 0.70 },
  { prefix = "CERULEAN_CAVE",     chance = 0.70 },   -- any other floor
  -- Gen 2 keeps Mewtwo out of the story, but a mod that puts him back
  -- usually puts him here; harmless when the map does not exist.
  { prefix = "CAVE_OF_ORIGIN",    chance = 0.70 },
}

-- The species that call it up when they lead the party.
Psystorm.CARRIERS = { MEWTWO = true, MEW = true }

local function tryRequire(path)
  local ok, m = pcall(require, path)
  if ok then return m end
  return nil
end

local Game = tryRequire("src.core.Game")

-- What the map allows, or nil.
function Psystorm.placeChance(mapId)
  local id = tostring(mapId or "")
  if id == "" then return nil end
  for _, place in ipairs(Psystorm.PLACES) do
    if id:find(place.prefix, 1, true) then return place.chance end
  end
  return nil
end

-- Is the party lead one of the carriers?
function Psystorm.leadIsCarrier()
  local ok, yes = pcall(function()
    local party = Game and Game.save and Game.save.party
    local lead = party and party[1]
    if not (lead and lead.species and lead.hp and lead.hp > 0) then return false end
    return Psystorm.CARRIERS[tostring(lead.species):upper()] and true or false
  end)
  return ok and yes or false
end

-- ------- the per-arrival roll

Psystorm.rolledMap = nil     -- the map the current answer belongs to
Psystorm.active = false

local function rand()
  if love and love.math then return love.math.random() end
  return math.random()
end

-- Called once per frame with the current map.  Returns the weather id to
-- force, or nil.
function Psystorm.weatherFor(mapId)
  local cfg = Config.get().psystorm
  if not (cfg and cfg.enabled) then return nil end

  local chance = Psystorm.placeChance(mapId)
  if not chance and Psystorm.leadIsCarrier() then
    chance = tonumber(cfg.carrierChance) or 0.7
  end
  if not chance then
    Psystorm.rolledMap, Psystorm.active = nil, false
    return nil
  end

  chance = chance * (tonumber(cfg.scale) or 1)

  -- Rolled once per arrival: a chance evaluated every frame is a certainty
  -- within a second.
  if Psystorm.rolledMap ~= mapId then
    Psystorm.rolledMap = mapId
    Psystorm.active = (chance >= 1) or (rand() < chance)
  end
  return Psystorm.active and Psystorm.ID or nil
end

function Psystorm.describe()
  if not Psystorm.active then return "-" end
  return "ACTIVE"
end

return Psystorm
