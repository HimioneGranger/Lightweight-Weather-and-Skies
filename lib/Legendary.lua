-- THE BIRDS.
--
-- Three weathers that mean something is nearby: a thunderstorm for Zapdos,
-- ashfall for Moltres, hail for Articuno.  Each has a small chance on any
-- outdoor map, and while one is running the bird itself may turn up in the
-- grass.
--
-- =====================================================================
-- WHY THE EXISTING WEATHERS RATHER THAN THREE NEW ONES
-- =====================================================================
--
-- A ZAPDOS_STORM would look exactly like a STORM, need its own catalogue
-- entry, its own battle mapping and its own audio bed, and would then have
-- to be excluded from the AUTO roll so it did not turn up without a bird
-- behind it.  All of that to draw the same rain.
--
-- So a rousing is a FLAG over an ordinary weather, not a weather.  The sky
-- is a real thunderstorm; what makes it Zapdos's thunderstorm is that
-- `Legendary.roused` says so, and that is the only thing the encounter
-- hook needs to know.  Nothing in the draw path, the battle layer or the
-- audio changes at all.
--
-- =====================================================================
-- THE ENCOUNTER IS A SUBSTITUTION, AND THAT IS DELIBERATE
-- =====================================================================
--
-- Everywhere else in this mod an encounter effect REROLLS -- fog draws out
-- a Ghost only if the map already has one, so no table is bypassed.  That
-- rule cannot work here: the whole point is a bird appearing where it
-- normally would not, and no route's table contains Zapdos.
--
-- So this is the one place that substitutes, and it is fenced accordingly:
--
--   * only while that bird's weather is roused, which is itself a 5% roll
--     per map arrival;
--   * once per rousing -- after the bird appears the rousing is spent, so
--     a single storm cannot produce two Zapdos;
--   * never indoors, never in a battle already in progress;
--   * and the level comes from the config rather than from the roll, since
--     a level-3 Zapdos on Route 1 would be worse than none.
--
-- Catching it is the player's business; this mod only decides that it is
-- there.  If they run or faint, the rousing is spent either way -- the
-- storm blew over and the bird moved on, which is the honest reading.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Scene = V.require("Scene")

local Legendary = {}

-- The three, and what each brings with it.  `weather` is an ordinary
-- catalogue id: the sky really is a thunderstorm, it just happens to have
-- something in it.
-- `bolt` tints the lightning and `thunder` names its own sound: a Zapdos
-- storm should not merely be a storm that happens to contain a Zapdos.
-- Both are optional, so a bird with neither behaves exactly as before.
-- Gen 1 birds + Gen 2 legendaries. Weather follows type identity the same
-- way the birds do: the sky is a normal catalogue weather with a flag.
-- Gen 2-only species are skipped on Gen 1 games via Legendary.available().

-- True when this legend can appear in the running game.
local Battle = nil
local function getBattle()
  if not Battle then Battle = V.require("Battle") end
  return Battle
end

function Legendary.available(entry)
  if not entry then return false end
  local need = tonumber(entry.gen) or 1
  if need <= 1 then return true end
  -- Gen 2+: prefer engine probe, fall back to Game.data.pokemon presence.
  local ok, is2 = pcall(function()
    local B = getBattle()
    if B and B.isGen2 then return B.isGen2() end
  end)
  if ok and is2 then return true end
  local ok2, has = pcall(function()
    local Game = require("src.core.Game")
    local data = Game and Game.data and Game.data.pokemon
    return data and data[entry.species] ~= nil
  end)
  if ok2 and has then return true end
  return false
end

local function pickableBirds()
  local out = {}
  for i = 1, #Legendary.BIRDS do
    local e = Legendary.BIRDS[i]
    -- skip HO-OH alias duplicate if both forms listed
    if e.species == "HO-OH" then
      -- prefer HO_OH if both exist in table; still allow single HO-OH
    end
    if Legendary.available(e) then out[#out + 1] = e end
  end
  -- Dedup Ho-Oh aliases
  local seen, dedup = {}, {}
  for i = 1, #out do
    local key = out[i].species:gsub("-", "_")
    if not seen[key] then seen[key] = true; dedup[#dedup + 1] = out[i] end
  end
  return dedup
end

Legendary.BIRDS = {
  -- Gen 1
  { species = "ZAPDOS",   weather = "STORM",        label = "ZAPDOS",
    gen = 1, bolt = { 1.00, 0.94, 0.35 }, thunder = "thunder_zapdos" },
  { species = "MOLTRES",  weather = "ASHFALL",      label = "MOLTRES", gen = 1 },
  { species = "ARTICUNO", weather = "HAIL",         label = "ARTICUNO", gen = 1 },
  -- Gen 2 beasts (Electric / Fire / Water)
  { species = "RAIKOU",   weather = "STORM",        label = "RAIKOU",
    gen = 2, bolt = { 0.95, 0.90, 0.40 }, thunder = "thunder_zapdos" },
  { species = "ENTEI",    weather = "ASHFALL",      label = "ENTEI", gen = 2 },
  { species = "SUICUNE",  weather = "RAIN_HEAVY",   label = "SUICUNE", gen = 2 },
  -- Gen 2 duo + Celebi
  { species = "LUGIA",    weather = "PSYSTORM",     label = "LUGIA", gen = 2 },
  { species = "HO_OH",    weather = "HARSH_SUN",    label = "HO-OH", gen = 2 },
  { species = "CELEBI",   weather = "VERDANT_RAIN", label = "CELEBI", gen = 2 },
}

-- The colour a roused bird lends the lightning, or nil for the ordinary
-- near-white.  Read by lib/Draw.lua each frame; nil costs one comparison.
function Legendary.boltTint()
  local b = Legendary.roused
  return b and b.bolt or nil
end

-- The one-shot a roused bird lends the thunder, or nil for the usual pair.
function Legendary.thunderSound()
  local b = Legendary.roused
  return b and b.thunder or nil
end

-- Live state: which bird, on which map, and whether it has already shown.
Legendary.roused = nil        -- a BIRDS entry, or nil
Legendary.rousedMap = nil
Legendary.spent = false
Legendary.rolledMap = nil

local function rand()
  if love and love.math then return love.math.random() end
  return math.random()
end

-- Rolled ONCE per arrival, like every other chance in this mod: a 5%
-- chance evaluated per frame is a certainty within a second, and per step
-- would flicker.
-- ------- a rousing has to END
--
-- It did not. The only thing that cleared `roused` was LEAVING the map, so a
-- bird that stirred over a route held that sky for as long as the player
-- stood there -- and because the encounter is spent after one claim, the
-- storm then just persisted with nothing left to happen. From the player's
-- side that is "the weather is stuck and never changes again", which is
-- exactly how it was reported.
--
-- `minutes` is in the same units as an ordinary spell so the two are
-- comparable, and it runs on the same speed scale, so TEST speed shortens a
-- rousing the way it shortens everything else. When it expires the bird is
-- released AND `rolledMap` is cleared, so standing still can roll another
-- one later rather than being permanently barren.
function Legendary.tick(dt, scale)
  if not Legendary.roused then return end
  -- `scale` is applied to the DURATION when the bird rouses, exactly as
  -- ordinary spell lengths do it (WeatherState: seconds * speedScale). It is
  -- NOT a multiplier on the countdown: TEST speed is 0.02, so used that way
  -- it made a rousing fifty times longer instead of shorter -- which is what
  -- left the sky pinned for the whole run.
  local left = (Legendary.left or 0) - (tonumber(dt) or 0)
  Legendary.left = left
  if left <= 0 then
    Legendary.roused, Legendary.rousedMap = nil, nil
    Legendary.rolledMap, Legendary.spent = nil, false
    Legendary.left = 0
  end
end

function Legendary.update(mapId, indoors)
  local cfg = Config.get().legendary
  if not (cfg and cfg.enabled) then
    -- switched off mid-session: any rousing ends, and the per-map roll is
    -- forgotten so turning it back on rolls afresh rather than resuming a
    -- bird the player was never told about
    Legendary.roused, Legendary.rousedMap = nil, nil
    Legendary.rolledMap, Legendary.spent = nil, false
    return nil
  end

  -- Indoors has no sky for a bird to arrive out of, and a cave is not
  -- where any of the three live.
  if indoors or not mapId then
    Legendary.rolledMap = nil
    Legendary.roused, Legendary.rousedMap = nil, nil
    return nil
  end

  -- Leaving the map ends the rousing: the bird belongs to that sky, not to
  -- the player, and carrying it around would make it a following weather
  -- rather than an event.
  if Legendary.rousedMap and Legendary.rousedMap ~= mapId then
    Legendary.roused, Legendary.rousedMap, Legendary.spent = nil, nil, false
  end

  if Legendary.rolledMap ~= mapId then
    Legendary.rolledMap = mapId
    local chance = tonumber(cfg.chance) or 0.05
    if rand() < chance then
      local pool = pickableBirds and pickableBirds() or Legendary.BIRDS
      if #pool == 0 then pool = Legendary.BIRDS end
      local pick = pool[math.max(1, math.ceil(rand() * #pool))]
      Legendary.roused = pick
      Legendary.rousedMap = mapId
      Legendary.spent = false
      local mins = tonumber(Config.get().legendary.minutes) or 6
      Legendary.left = math.max(2, mins * 60 * (tonumber(Legendary.speedScale) or 1))
      mod.log:info("a %s stirs over %s", pick.label, tostring(mapId))
    end
  end

  return Legendary.roused and Legendary.roused.weather or nil
end

-- Should this encounter become the bird?  Answers the species or nil, and
-- spends the rousing when it says yes -- so one storm cannot produce two.
function Legendary.claimEncounter()
  local cfg = Config.get().legendary
  if not (cfg and cfg.enabled and cfg.encounters) then return nil end
  local bird = Legendary.roused
  if not bird or Legendary.spent then return nil end
  if Scene.now.indoors then return nil end
  -- The map must still be the one that was roused; a rousing does not
  -- travel.
  if Legendary.rousedMap and Scene.now.mapId ~= Legendary.rousedMap then
    return nil
  end
  local base = tonumber(cfg.encounterChance) or 0.005
  -- This is an exact 0.5% default while the matching legendary weather is
  -- roused. It does not inherit the normal wild-weather encounter boost.
  local boost = tonumber(cfg.rateBoost) or 1.0
  if boost < 1 then boost = 1 end
  local chance = math.min(0.95, base * boost)
  if rand() >= chance then return nil end
  Legendary.spent = true
  return bird.species, tonumber(cfg.level) or 50
end

function Legendary.describe()
  if not Legendary.roused then return "-" end
  return ("%s%s"):format(Legendary.roused.label, Legendary.spent and " (seen)" or "")
end

return Legendary
