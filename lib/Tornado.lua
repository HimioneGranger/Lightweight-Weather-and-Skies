-- TORNADOES.
--
-- The one thing in this mod that moves the player.  Everything else draws
-- pixels or nudges a number; this picks you up in a gale and puts you
-- somewhere else, and that is a different kind of change, so it is built
-- with a different amount of suspicion.
--
-- =====================================================================
-- WHY IT IS OFF BY DEFAULT AND FLAGGED FOR POST-GAME
-- =====================================================================
--
-- A story-mode Pokemon game is a sequence of gates: badges, HMs, a Snorlax,
-- a guard who wants tea.  A warp does not know about any of that.  Even
-- restricted to places you have already been, being moved mid-errand can
-- strand you without the HM you walked out with, break a fetch quest's
-- assumption about where you are, or drop you the wrong side of a gate you
-- have not opened from that direction.  None of that is a bug this mod can
-- fix, because "where the player is supposed to be right now" is a fact
-- only the story knows.
--
-- So: off unless asked for, and the row says post-game rather than leaving
-- the player to find out.
--
-- =====================================================================
-- THREE RESTRICTIONS THAT MAKE IT SURVIVABLE
-- =====================================================================
--
-- 1. ONLY WHERE YOU HAVE BEEN.  Destinations come from `save.visited`,
--    the engine's own record of towns the player has entered -- the same
--    table the Town Map and the Fly menu read.  A tornado can therefore
--    never show you a place the story has not, never skip a gate, and
--    never land you somewhere with no way home.  This is why the
--    destination list is not a table in this file: a curated list would
--    have to guess at progression, and `save.visited` already knows.
--
-- 2. ONLY OUTDOORS, ONLY IN A GALE.  It needs `STRONG_WINDS` (or a
--    sandstorm, which is the same wind carrying grit) and a sky overhead.
--
-- 3. ALWAYS REVERSIBLE.  Where you were is written to the mod's save
--    before the warp, and `weather return` in the developer console puts
--    you back.  A feature that can move you should be able to unmove you.
--
-- The cooldown is long by design.  A tornado is an event; one every few
-- minutes would be a mechanic, and a fast-travel mechanic at that.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Settings = V.require("Settings")
local Scene = V.require("Scene")
local Funnel = V.require("Funnel")
local State = V.require("WeatherState")

local Tornado = {}

local function tryRequire(path)
  local ok, module = pcall(require, path)
  if ok then return module end
  return nil
end

local Game = tryRequire("src.core.Game")

Tornado.timer = 0
Tornado.lastReason = "idle"

local function enabled()
  if not Settings.is("tornado", "on") then
    Tornado.lastReason = "row off"
    return false
  end
  if not Config.get().tornado.enabled then
    Tornado.lastReason = "config off"
    return false
  end
  return true
end

-- The weathers that can carry you: a gale, and a sandstorm, which is the
-- same wind with grit in it.  Read by tag so a new windy weather counts.
local function windy(def)
  if not def then return false end
  if def.id == "STRONG_WINDS" then return true end
  if def.sandy and Config.get().tornado.sandstorms then return true end
  return false
end
Tornado.windy = windy

-- Every map the player has actually been to, minus where they are now.
-- `save.visited` is the engine's own record -- the table the Town Map and
-- the Fly menu read -- so this cannot reach anywhere the story has not.
function Tornado.destinations(here)
  local out = {}
  local ok = pcall(function()
    local visited = Game and Game.save and Game.save.visited
    if type(visited) ~= "table" then return end
    for mapId, seen in pairs(visited) do
      if seen and mapId ~= here and type(mapId) == "string" then
        out[#out + 1] = mapId
      end
    end
  end)
  if not ok then return {} end
  table.sort(out)          -- stable order, so a seeded run is reproducible
  return out
end

local function rand(n)
  if love and love.math then return love.math.random(n) end
  return math.random(n)
end

-- Remember where we took them from, so it can be undone.
function Tornado.remember(mapId, x, y)
  pcall(function()
    mod.save:set("tornadoFrom", mapId)
    mod.save:set("tornadoFromX", x)
    mod.save:set("tornadoFromY", y)
  end)
end

function Tornado.origin()
  local ok, mapId, x, y = pcall(function()
    return mod.save:get("tornadoFrom", nil),
           mod.save:get("tornadoFromX", nil),
           mod.save:get("tornadoFromY", nil)
  end)
  if ok then return mapId, x, y end
  return nil
end

-- The warp itself.  Guarded end to end: a tornado that throws must cost a
-- log line, not the player's session.
function Tornado.carry(destination)
  local ow = Scene.overworld and Scene.overworld() or nil
  if not ow then
    local okOw = pcall(function()
      local stack = Game and Game.stack
      local states = stack and stack.states
      if type(states) == "table" then
        for i = #states, 1, -1 do
          if type(states[i]) == "table" and states[i].isOverworld then
            ow = states[i]
            return
          end
        end
      end
    end)
    if not okOw then return false end
  end
  if not (ow and type(ow.startWarpTo) == "function") then
    Tornado.lastReason = "no warp entry point"
    return false
  end

  local here = ow.map and ow.map.id
  local px = ow.player and ow.player.cellX
  local py = ow.player and ow.player.cellY
  Tornado.remember(here, px, py)

  local ok = pcall(function() ow:startWarpTo(destination) end)
  if not ok then
    Tornado.lastReason = "warp refused"
    return false
  end
  mod.log:info("tornado carried the player from %s to %s (weather return undoes it)",
    tostring(here), tostring(destination))
  Tornado.lastReason = "carried"
  return true
end

function Tornado.update(dt)
  if not enabled() then
    Tornado.timer = 0
    return
  end
  if (State.level or 0) <= 0 then return end
  dt = tonumber(dt) or 0
  if dt <= 0 or dt > 0.25 then return end

  -- a gale, outdoors, with the world actually on screen
  if not windy(State.current()) then
    Tornado.timer = 0
    Tornado.lastReason = "no gale"
    return
  end
  if Scene.now.visible ~= "world" or Scene.now.indoors then
    Tornado.lastReason = "not outdoors"
    return
  end

  local cfg = Config.get().tornado
  Tornado.timer = Tornado.timer + dt
  local wait = math.max(30, tonumber(cfg.everySeconds) or 240)
  if Tornado.timer < wait then return end
  Tornado.timer = 0

  local here = Scene.now.mapId
  local places = Tornado.destinations(here)
  -- Fewer than two places visited means the player is early in the game,
  -- which is exactly who this is not for.
  if #places < (tonumber(cfg.minVisited) or 4) then
    Tornado.lastReason = ("only %d places visited"):format(#places)
    return
  end
  -- THE FUNNEL FIRST, then the warp.  An event that moves the player
  -- against their will should announce itself, and the announcement is
  -- also the fairness: a couple of seconds in which it is obvious what is
  -- coming.  The warp is the funnel's completion callback, so the two
  -- cannot get out of step -- and if the funnel is switched off the warp
  -- fires immediately, exactly as before.
  local destination = places[rand(#places)]
  local seconds = tonumber(Config.get().tornado.funnelSeconds) or 2.5
  if seconds > 0 and Config.get().tornado.funnel ~= false then
    Tornado.lastReason = "funnel"
    Funnel.start(seconds, function() Tornado.carry(destination) end)
  else
    Tornado.carry(destination)
  end
end

function Tornado.describe()
  if not Settings.is("tornado", "on") then return "off" end
  return ("%s %ds"):format(Tornado.lastReason, math.floor(Tornado.timer))
end

return Tornado
