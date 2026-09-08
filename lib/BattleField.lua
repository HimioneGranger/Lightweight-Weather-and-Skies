-- ART BEHIND THE POKEMON.
--
-- =====================================================================
-- READ THIS BEFORE CHANGING ANYTHING HERE
-- =====================================================================
--
-- This is the ONLY part of weather_fx that patches engine internals.
-- Everything else is hooks and registries, which is why the rest of the
-- mod survives engine updates and never contends with another mod.  This
-- file gives that up deliberately, because there is no seam:
--
--   * `battle.overlay` runs at the END of the battle's draw -- anything
--     drawn there covers the Pokemon.
--   * `battleBg = "world"` exposes the letterbox voids only.  The
--     engine's own comment (BattleState:82): "The battle screen itself is
--     untouched: it keeps its white paper field in every mode."
--   * `render.compose` would work but demands taking over the ENTIRE
--     window composite -- SGB zones, palette pass, letterbox, GBC FX --
--     to place one image.
--
-- So the field fill is intercepted instead.  Both draw paths do the same
-- thing (BattleState:drawClassic and WideBattle.draw): set the paper
-- colour, then `g.rectangle("fill", 0, 0, W, H)` across the whole battle
-- surface.  For the duration of one battle draw, `love.graphics.rectangle`
-- is replaced with a function that spots THAT call -- the first full-
-- surface fill of the frame -- and draws the backdrop in its place.
-- Everything else passes straight through, and the original is restored
-- before the call returns, in every path including an error.
--
-- WHY INTERCEPTION RATHER THAN REIMPLEMENTING THE DRAW.  Copying
-- `drawClassic` into this mod would mean copying four hundred lines of
-- HUD, text, shake, slide and SGB handling, and re-copying them at every
-- engine update.  Intercepting one call depends on one line staying
-- shaped the way it is, and degrades to "no backdrop" when it changes
-- rather than to a broken battle.
--
-- =====================================================================
-- WHEN IT STANDS DOWN, AND WHY
-- =====================================================================
--
--   * SGB / colour mode.  That path draws into `bgCanvas` and then
--     recolours it by zone, as if it were Game Boy tiles.  A photographic
--     backdrop through a zone recolour looks like a fault, so this stays
--     out of its way unless the player insists.
--   * StadiumBattleFX, DRAMATIC_SHAPE, DRAMALESS_SHAPE.  They stage
--     battles their own way, and two mods patching the same draw means
--     the last one loaded wins.  Detected, not guessed.
--   * The nickname screen (`blankForAskName`), which clears the field on
--     purpose and would otherwise get scenery behind the naming box.
--
-- All three are overridable, because a player who can see their own
-- screen is better placed to judge than a guess in a config file.

local V = ...
local mod = V.mod
local Settings = V.require("Settings")
local Config = V.require("Config")
local Interop = V.require("Interop")
local Backgrounds = V.require("Backgrounds")

-- LuaJIT (what LOVE 11 runs) exposes `unpack`; 5.3+ moved it to
-- `table.unpack`.  Resolved once so the draw path does no version test.
local unpackAny = unpack or table.unpack

local BF = {}

BF.installed = false
BF.active = false        -- true while a battle draw is being intercepted
BF.lastReason = "not installed"

-- ------- should we?

function BF.wanted()
  if not Settings.is("backdrops", "behind") then
    BF.lastReason = "BATTLE ART is not set to BEHIND"
    return false
  end
  if Config.get().battleFieldArt == "off" then
    BF.lastReason = "battleFieldArt = off"
    return false
  end
  if Config.get().battleFieldArt == "on" then return true end
  -- AUTO: stand down for full UI overhauls that own battle presentation.
  -- gen3_battle_ui redraws HUD/frames; intercepting the paper fill can
  -- leave a double field or a missing chrome edge. Force ON still works.
  local uiClash = false
  pcall(function()
    if mod.find and mod:find("gen3_battle_ui") then uiClash = true end
    if mod.find and mod:find("colosseum_ui_overhaul") then uiClash = true end
  end)
  if uiClash then
    BF.lastReason = "gen3/colosseum UI owns battle presentation"
    return false
  end
  return true
end

local function okForBattle(battle)
  -- The nickname screen clears its field on purpose; scenery behind the
  -- naming box would be a bug, not a feature.
  if battle.blankForAskName then
    BF.lastReason = "naming screen"
    return false
  end

  -- COLOUR MODE USED TO STAND DOWN HERE, AND THAT WAS WRONG.
  --
  -- The reasoning was that the SGB/GBC path draws the field into
  -- `bgCanvas` and then recolours it by zone, so a painted backdrop would
  -- come out tinted.  That may well be true -- but it meant that on any
  -- device running in colour, which is most of them, BEHIND silently did
  -- nothing at all.  A guess about how something might look was
  -- overriding what the player could see for themselves, and "no backdrop"
  -- is a worse outcome than "a backdrop I can switch off".
  --
  -- So it draws, and `battleFieldArt = "off"` is there for anyone who
  -- looks at it and disagrees.
  if Config.get().battleFieldArt == "mono" then
    if type(battle.colorMode) == "function" then
      local ok, colour = pcall(battle.colorMode, battle)
      if ok and colour then
        BF.lastReason = "colour mode (battleFieldArt = mono)"
        return false
      end
    end
  end
  return true
end

-- ------- the interception

local function surfaceOf(battle)
  if type(battle.uiSize) == "function" then
    local ok, w, h = pcall(battle.uiSize, battle)
    if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      return w, h
    end
  end
  return 160, 144
end

-- Wraps one battle draw.  `origDraw` is the engine's; `battle` is self.
local function wrappedDraw(origDraw, battle, ...)
  do
    local okC, Compat = pcall(function() return V.require("Compat") end)
    if okC and Compat and Compat.battleProfile then
      local p = Compat.battleProfile()
      if p and p.skipFieldArtHijack then
        return origDraw(battle, ...)
      end
    end
  end
  if not (BF.wanted() and okForBattle(battle)) then
    return origDraw(battle, ...)
  end

  local g = love.graphics
  local origRect = g.rectangle
  local sw, sh = surfaceOf(battle)
  local done = false

  g.rectangle = function(mode, x, y, w, h, ...)
    -- The field fill, and only it: a filled rectangle covering the whole
    -- battle surface from its origin, before any other has been seen this
    -- frame.  The screen-flash overlay later in the draw is the same
    -- shape, which is exactly why `done` latches on the first one.
    -- MATCH EITHER SURFACE.  `drawClassic` fills a LITERAL 160x144
    -- (BattleState.lua) while `uiSize()` reports whatever the current
    -- layout is -- so on any build where those two disagree, the match
    -- failed and the substitution silently did nothing.  That is the
    -- shape of "battle backgrounds do not work on Gen 2": no error, no
    -- backdrop, nothing to see.  Both are accepted now, since either is a
    -- full-surface fill and nothing else in the draw is.
    local fullSurface = (w == sw and h == sh) or (w == 160 and h == 144)
    if not done and mode == "fill" and x == 0 and y == 0 and fullSurface then
      done = true
      local okDraw = pcall(Backgrounds.drawField, sw, sh)
      if not okDraw then
        -- a backdrop that failed to draw must not leave the field
        -- transparent, or the battle composites over whatever was behind
        return origRect(mode, x, y, w, h, ...)
      end
      return
    end
    return origRect(mode, x, y, w, h, ...)
  end

  BF.active = true
  -- table.pack records `n`, so a draw that returns nil among its results
  -- keeps them instead of having the array length truncate at the gap.
  -- LuaJIT has no table.pack; there the array length is used, which is
  -- correct for every return shape BattleState:draw actually has (one
  -- value or none) and would only lose a trailing nil.
  local results
  if table.pack then
    results = table.pack(pcall(origDraw, battle, ...))
  else
    results = { pcall(origDraw, battle, ...) }
  end
  g.rectangle = origRect          -- restored on every path, including error
  BF.active = false

  if not results[1] then error(results[2], 0) end
  -- LuaJIT has the global `unpack`, 5.3+ only `table.unpack`; picked once
  -- at load rather than per call, and via a local so neither lookup
  -- happens on the draw path.
  return unpackAny(results, 2, results.n or #results)
end

-- The wrapper install() applies, exposed so the test suite drives THIS
-- code rather than a copy of it.  A replica in a test proves the replica
-- works.
function BF.wrap(origDraw)
  return function(self, ...)
    return wrappedDraw(origDraw, self, ...)
  end
end

-- ------- install

-- Installed ONCE, regardless of the current setting, because the wrapper
-- asks BF.wanted() on every draw.  Version 2.9.0 installed only when the
-- row already read BEHIND at game.ready, so switching the row mid-session
-- did nothing until a restart, silently -- the same class of bug as a
-- switch that lives in a file the player cannot open.
function BF.install()
  if BF.installed then return true end
  local ok, BattleState = pcall(require, "src.battle.BattleState")
  if not ok or type(BattleState) ~= "table" or type(BattleState.draw) ~= "function" then
    BF.lastReason = "BattleState.draw not found"
    mod.log:warn("battle field art: %s; art will draw around the battle only",
      BF.lastReason)
    return false
  end

  if BattleState._wxBFWrapped then
    BF.installed = true
    BF.lastReason = "already-wrapped"
    return true
  end
  BF._prevDraw = BattleState.draw
  BattleState.draw = BF.wrap(BattleState.draw)
  BattleState._wxBFWrapped = true
  BF._battleState = BattleState

  BF.installed = true
  BF.lastReason = "installed"
  mod.log:info("battle field art: chain-wrapped BattleState.draw")
  return true
end

function BF.uninstall()
  if not BF.installed then return end
  local BattleState = BF._battleState
  if BattleState and BF._prevDraw and BattleState._wxBFWrapped then
    BattleState.draw = BF._prevDraw
    BattleState._wxBFWrapped = nil
  end
  BF.installed = false
  BF._prevDraw = nil
  BF._battleState = nil
end

return BF
