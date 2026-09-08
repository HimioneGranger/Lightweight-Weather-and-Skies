-- The World 5.19.1: one authoritative capability gate for every subsystem.
-- Content stays registered for save compatibility; these gates decide what may
-- actually enter a live world.  Live option + save mirror use the most
-- restrictive answer when both exist, preventing stale saves from widening a
-- player's rules during boot on Android/Gen 2.
local mod = ...
local C={}

local SAVE={
  worldContentScope="world_content_scope", worldAbilities="world_abilities_enabled",
  worldHeldItems="world_held_items_enabled", worldShark="world_shark_enabled",
  weatherVariants="world_wx_pokemon_enabled", johto_postgame="johto_postgame_enabled",
}
local LIMIT={gen1=151,gen1_gen2=251,gen1_gen2_gen3=386,gen1_gen2_gen3_gen4=493,
 gen1_gen2_gen3_gen4_gen5=649,gen1_gen2_gen3_gen4_gen5_gen6=721,
 gen1_gen2_gen3_gen4_gen5_gen6_gen7=809,gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8=1025}
local function live(k) local ok,v=pcall(function() return mod.options:get(k) end); return ok and v or nil end
local function saved(k) local sk=SAVE[k]; if not sk or not mod.save then return nil end; local ok,v=pcall(function() return mod.save:get(sk) end); return ok and v or nil end
-- Saves created by earlier Weather FX/The World builds have used booleans,
-- numbers, and textual true values for the same menu rows. Treat all positive
-- encodings alike so a valid caught WX form never becomes unavailable merely
-- because an update reads its old save representation.
local function yes(v)
  return v == true or v == 1 or v == "on" or v == "true" or v == "yes" or v == "enabled"
end
local function restrictiveBool(k,default)
  local a,b=live(k),saved(k)
  if a~=nil and b~=nil then return yes(a) and yes(b) end
  if a~=nil then return yes(a) end; if b~=nil then return yes(b) end
  return default==true
end
function C.scopeLimit()
  local a,b=LIMIT[live("worldContentScope")],LIMIT[saved("worldContentScope")]
  if a and b then return math.min(a,b) end
  return a or b or 1025
end
function C.scope() local n=C.scopeLimit(); for k,v in pairs(LIMIT) do if v==n then return k end end; return "gen1" end
function C.speciesAllowed(species,data)
  if species==nil then return false end
  local seen={}; local function dexOf(s)
    if seen[s] then return nil end; seen[s]=true
    local row=data and data.pokemon and data.pokemon[s]
    local base=row and (row.baseSpecies or row.base)
    if base and base~=s then local d=dexOf(base); if d then return d end end
    return row and tonumber(row.dex) or nil
  end
  local d=dexOf(species); return d==nil or d<=C.scopeLimit()
end
function C.wxEnabled()
  -- Settings owns the richer compatibility rules; the central gate additionally
  -- applies the restrictive saved/live contract.
  if not restrictiveBool("weatherVariants",true) then return false end
  local ok,S=pcall(require,"mods.the_world.lib.Settings")
  return ok and S and type(S.weatherVariantsOn)=="function" and S.weatherVariantsOn() or false
end
function C.heldItemsEnabled() return restrictiveBool("worldHeldItems",false) end
function C.abilitiesEnabled() return restrictiveBool("worldAbilities",true) end
function C.worldSharkEnabled() return restrictiveBool("worldShark",false) end
function C.johtoEnabled()
  -- Native Gen 2 always has Johto. Imported Johto in Gen 1 remains opt-in.
  local game=mod.activeGame; local id=game and (game.id or game.gameId or game.version)
  if tostring(id or ""):lower():find("gold") or tostring(id or ""):lower():find("silver") or tostring(id or ""):lower():find("crystal") then return true end
  return restrictiveBool("johto_postgame",false)
end
function C.snapshot()
  return {scope=C.scope(),maxDex=C.scopeLimit(),wx=C.wxEnabled(),heldItems=C.heldItemsEnabled(),abilities=C.abilitiesEnabled(),johto=C.johtoEnabled(),worldShark=C.worldSharkEnabled()}
end
return C
