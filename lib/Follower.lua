-- CHIP DAMAGE OUTSIDE BATTLE.
--
-- Sandstorm, ashfall and hail wear down the Pokemon walking behind you --
-- the same weathers that chip HP in a battle, with the same type
-- immunities, so the rule a player learns in one place holds in the other.
--
-- WHICH POKEMON.  The party LEAD, which is what every follower mod walks
-- behind (Followers EX, the PokePC merge, and the rest all render
-- `Game.save.party[1]`).  Reading the party rather than asking a follower
-- mod is deliberate: it needs no integration, it cannot break when one of
-- them changes, and it does the right thing with no follower mod at all --
-- the Pokemon in the storm is still the one at the front of your party.
--
-- WHY IT CANNOT FAINT BY DEFAULT.  A faint outside battle has no message,
-- no animation and nothing the player can respond to; they would simply
-- notice later that a Pokemon was at zero. So the default clamps at 1 HP:
-- the weather is a cost you can feel and manage, not a silent loss.
-- `canFaint = true` is there for anyone who wants the harsher version.
--
-- IT ONLY RUNS OUTDOORS OR WHERE THE CONFIG SAYS WEATHER REACHES INSIDE.
-- The same rule the draw path uses, from the same function, so a cave
-- with a sandstorm override chips and a Poke Mart never does -- and the
-- two can never disagree, because there is one answer.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local Config = V.require("Config")
local Settings = V.require("Settings")
local Scene = V.require("Scene")
local State = V.require("WeatherState")

local Follower = {}

local function tryRequire(path)
  local ok, module = pcall(require, path)
  if ok then return module end
  return nil
end

local Game = tryRequire("src.core.Game")

-- Immunities, matched to the battle layer's so the rule is one rule.
local IMMUNE = {
  sandy = { ROCK = true, GROUND = true, STEEL = true },
  frozen = { ICE = true },
}

Follower.timer = 0
Follower.lastTick = nil     -- for the debug readout

local function typesOf(mon)
  if not (Game and mon) then return nil end
  local ok, list = pcall(function()
    local data = Game.data and Game.data.pokemon
    local def = data and data[mon.species]
    return def and def.types or nil
  end)
  if ok then return list end
  return nil
end

-- Does this weather wear things down out here, and which immunity applies?
local function chipKind(def)
  if not def then return nil end
  -- HAIL chips; plain snow does not, matching the battle layer and the
  -- modern games' split between the two.
  if def.id == "HAIL" then return "frozen" end
  if def.sandy then return "sandy" end
  return nil
end

function Follower.update(dt)
  local cfg = Config.get().followerChip
  if not (cfg and cfg.enabled) then return end
  if (State.level or 0) <= 0 then return end
  dt = tonumber(dt) or 0
  if dt <= 0 or dt > 0.25 then return end

  local kind = chipKind(State.current())
  if not kind then
    Follower.timer = 0
    return
  end

  -- The draw path's own answer: 0 means the weather is not reaching the
  -- player here, so it must not reach their Pokemon either.
  local alpha, precipitation = Scene.drawScale(Settings)
  if alpha <= 0 or not precipitation then
    Follower.timer = 0
    return
  end

  Follower.timer = Follower.timer + dt
  local period = math.max(1, tonumber(cfg.seconds) or 6)
  if Follower.timer < period then return end
  Follower.timer = 0

  pcall(function()
    local party = Game and Game.save and Game.save.party
    local mon = party and party[1]
    if not (mon and mon.hp and mon.hp > 0) then return end
    local maxHp = (mon.stats and mon.stats.hp) or mon.maxHp
    if not (maxHp and maxHp > 0) then return end

    local list = typesOf(mon)
    if list then
      local immune = IMMUNE[kind]
      for i = 1, #list do
        if immune[list[i]] then return end
      end
    end

    local hurt = math.max(1, math.floor(maxHp * (tonumber(cfg.fraction) or 1 / 32)))
    local floor_ = cfg.canFaint and 0 or 1
    local before = mon.hp
    mon.hp = math.max(floor_, mon.hp - hurt)
    Follower.lastTick = before - mon.hp
  end)
end

function Follower.describe()
  local kind = chipKind(State.current())
  if not kind then return "-" end
  return ("%s %ds"):format(kind, math.floor(Follower.timer))
end

return Follower
