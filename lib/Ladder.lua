-- THE LADDER PUSH.
--
-- WHY THIS EXISTS, which is a mistake worth recording.
--
-- Version 2.0.1's `debugRain` set an INTERNAL level of 1 and assumed that
-- was enough to switch the mod on.  It was not, and could never have
-- been, because the engine gates a pipeline before it ever asks the mod
-- anything:
--
--     function Pipelines.eligible(id)
--       ...
--       if Pipelines.level(id) <= 0 then return false end   -- <-- here
--       if def.available and guard(id, def.available) ~= true then ... end
--
-- `available` is not consulted at level 0.  Neither stage is called.  So
-- an internal override could pin the weather, ease every channel and
-- report a healthy state on the debug readout while drawing precisely
-- nothing -- which is exactly what it did.  The particle pools were not
-- even ticked, because `Draw.update` is handed the same engine level.
--
-- THE LESSON, generalised: this mod does not own the ladder.  The engine
-- does, it persists it in save.options.pipelines, and it is the single
-- gate on every stage.  Anything that wants the mod switched on has to
-- move THAT number.  A shadow copy of somebody else's state is not a
-- switch, it is a second opinion.
--
-- So `debugRain` now genuinely turns the OPTIONS row on, and the player
-- can see it has: the row reads HEAVY while debug rain is on.  Nothing
-- downstream needs a special case, which is the real win -- the debug path
-- and the normal path are now the same path.
--
-- WHERE IT LANDS WHEN DEBUG GOES OFF, which is a fix for a real trap.
-- 2.1.x put the row back to OFF, on the reasoning that it should leave
-- things as it found them.  In practice that meant the ONLY thing that
-- ever switched the weather on was debug mode, and turning debug off
-- turned the whole mod off -- so it looked like weather only worked in
-- debug.  Landing on AUTO instead is the useful answer: someone who just
-- confirmed the mod works wants to play with weather, not to switch it
-- off.  A rung the player chose themselves is still never touched.

local V = ...
local Types = V.require("Types")
local WeatherState = V.require("WeatherState")

local Ladder = {}

Ladder.PIPELINE = "weather"

-- The rung debug rain parks on.  Resolved from the catalogue rather than
-- hardcoded, so adding a weather type ahead of RAIN_HEAVY in Types.PINNED
-- cannot silently point this at the wrong sky.
-- Resolved from the ladder itself rather than from an offset into
-- Types.PINNED: the automatic rungs ahead of the pinned list have changed
-- twice now (AUTO, then AUTO+CYCLE), and an arithmetic offset silently
-- pointed at the wrong sky each time.  Searching the built ladder cannot
-- drift.
Ladder.DEBUG_RUNG = 1                                        -- AUTO, if not found
for i, id in ipairs(WeatherState.LEVEL_IDS) do
  if id == "RAIN_HEAVY" then Ladder.DEBUG_RUNG = i - 1 end
end

-- Where the ladder is left when debug rain is switched off and we were the
-- one that raised it.  1 is AUTO.
Ladder.RELEASE_RUNG = 1

-- Whether WE were the one that raised the ladder, so turning debug rain
-- off puts it back where the player had it instead of leaving a
-- downpour pinned forever.
local raisedByUs = false

-- `P` is the engine's Pipelines module, injected so the test suite can
-- drive this against a stub.  `opts` is save.options, for persistence; nil
-- is fine and simply means the change is live-only this session.
function Ladder.enforce(P, wantDebugRain, opts)
  if not P or type(P.level) ~= "function" or type(P.setLevel) ~= "function" then
    return nil
  end
  local current = P.level(Ladder.PIPELINE) or 0

  if wantDebugRain then
    if current <= 0 then
      P.setLevel(Ladder.PIPELINE, Ladder.DEBUG_RUNG)
      raisedByUs = true
      if opts and type(P.syncOptions) == "function" then
        pcall(P.syncOptions, opts)
      end
      return Ladder.DEBUG_RUNG
    end
    -- Already on at some rung the player chose: leave their choice alone.
    -- The weather is pinned to heavy rain anyway (WeatherState.resolveTarget),
    -- so raising the rung as well would only lose their setting.
    return current
  end

  -- debug rain is off; undo our own push, and only our own
  if raisedByUs then
    raisedByUs = false
    if current == Ladder.DEBUG_RUNG then
      P.setLevel(Ladder.PIPELINE, Ladder.RELEASE_RUNG)
      if opts and type(P.syncOptions) == "function" then
        pcall(P.syncOptions, opts)
      end
      return Ladder.RELEASE_RUNG
    end
  end
  return current
end

function Ladder.raisedByUs()
  return raisedByUs
end

function Ladder.reset()
  raisedByUs = false
end

return Ladder
