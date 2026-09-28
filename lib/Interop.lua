-- COMPANION MODS.
--
-- Every "is that other mod installed" question in one file, asked once,
-- so the answers cannot drift apart and there is a single list to edit
-- when a new fork appears.
--
-- TWO RULES THIS FOLLOWS, both learned the hard way:
--
--  1. ASK LAZILY.  A handle taken at load time can be taken before the
--     other mod's entry chunk has assigned its exports, and a nil cached
--     then is a nil forever.  Everything here resolves on first use and
--     caches only a POSITIVE answer.
--
--  2. ASK BY CAPABILITY, NOT BY NAME, wherever the capability is
--     detectable.  Names are listed because some of these have no probe
--     -- but where a mod publishes something we can test for, the test
--     wins, so a rename or a new fork does not silently turn a feature off.

local V = ...
local mod = V.mod

local Interop = {}

-- ------- the voxel diorama family
--
-- DRAMATIC_SHAPE and its fork DRAMALESS_SHAPE (which declares a conflict
-- with the original, so only one is ever loaded).  Both publish their
-- whole module namespace as `mod.exports.lib` and both ship a DayNight
-- module, so one probe covers both and any future fork that keeps the
-- convention.
Interop.VOXEL_IDS = { "BATTLE_ART_VOXEL_FORK", "BATTLE_ART_VOXEL_GEN2", "DRAMATIC_SHAPE", "DRAMALESS_SHAPE", "STADIUM2_OVERWORLD_MODELS", "potato_voxel", "POTATO_VOXEL" }

-- ------- mods that render a battle WIDER than the classic 160x144
--
-- The `battle.overlay` hook draws inside the engine's 160x144 battle
-- canvas -- the engine fills exactly that rectangle immediately before
-- calling it.  That is the right place for battle weather normally,
-- because it scales with the battle and passes through the palette
-- handling.  It is the WRONG place when another mod has drawn a
-- widescreen battle behind it, because then the overlay covers only the
-- classic box sitting in the middle of a much larger scene.
Interop.WIDE_BATTLE_IDS = {
  "STADIUM_BATTLE_FX",   -- Stadium-style battle cinematics
  "BATTLE_ART_VOXEL_FORK", -- Dramatic Shape 1.9.x battle/voxel fork
  "BATTLE_ART_VOXEL_GEN2", -- Battle Art port for Gold/Silver/Crystal
  "DRAMATIC_SHAPE",      -- 3D battle arenas
  "DRAMALESS_SHAPE",
  "STADIUM2_OVERWORLD_MODELS",  -- Gen2 Stadium 2 overworld/battle
}

local cache = {}

local function handleFor(id)
  if cache[id] then return cache[id] end
  local ok, handle = pcall(function() return mod.find(id) end)
  if ok and handle then
    cache[id] = handle
    return handle
  end
  return nil
end

-- The first installed mod from a list, with its id, or nil.
local function firstOf(ids)
  for i = 1, #ids do
    local handle = handleFor(ids[i])
    if handle then return handle, ids[i] end
  end
  return nil, nil
end

function Interop.voxel()
  return firstOf(Interop.VOXEL_IDS)
end

-- The voxel family's DayNight module, whichever fork is installed.
-- Shape-checked rather than trusted: a fork that renamed or dropped it
-- costs this mod a lighting nuance, not a crash.
function Interop.dayNight()
  local handle, id = Interop.voxel()
  if not handle then return nil end
  local ok, module = pcall(function()
    local lib = handle.exports and handle.exports.lib
    if not (lib and type(lib.require) == "function") then return nil end
    local dn = lib.require("DayNight")
    if type(dn) ~= "table" or type(dn.time) ~= "function" then return nil end
    return dn
  end)
  if not ok or not module then return nil, id end
  return module, id
end

-- Is anything installed that draws a battle wider than 160x144?
function Interop.wideBattle()
  local _, id = firstOf(Interop.WIDE_BATTLE_IDS)
  return id ~= nil, id
end

function Interop.installed(id)
  return handleFor(id) ~= nil
end

-- A short list for the log line and the debug readout.
function Interop.describe()
  local names = {}
  for _, id in ipairs(Interop.VOXEL_IDS) do
    if handleFor(id) then names[#names + 1] = id end
  end
  for _, id in ipairs(Interop.WIDE_BATTLE_IDS) do
    if handleFor(id) and id ~= "BATTLE_ART_VOXEL_FORK" and id ~= "DRAMATIC_SHAPE" and id ~= "DRAMALESS_SHAPE" then
      names[#names + 1] = id
    end
  end
  if handleFor("Kanto-Reforged") then names[#names + 1] = "Kanto-Reforged" end
  if #names == 0 then return "standalone" end
  return table.concat(names, "+")
end

-- Forget every cached handle.  Called on hot reload, so a mod removed
-- between runs does not stay "installed" for the session.
function Interop.reset()
  cache = {}
end

return Interop
