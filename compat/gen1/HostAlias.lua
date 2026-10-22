-- Lab Gen 1 compat for the_world_weather_quest_lite_private (TWS-L).
--
-- The user's Gen1 Battle Art Quest host now ships under a lab-only id,
-- BATTLE_ART_QUEST_COMPAT_GEN1 (the Gen2 host keeps BATTLE_ART_QUEST_COMPAT
-- -- two mods cannot share an id in one multi-generation app). TWS's own
-- Gen1 code still looks its host up by the OLD id in six places
-- (compat/Bootstrap.lua:86, compat/QuestAdapter.lua:5,
-- lib/DesktopWeatherProfile.lua:8, lib/DramalessAtmos.lua:280,
-- lib/NightSky.lua:28, lib/QuestStorm.lua:91) -- none of them edited by
-- this file or by anything else in this lab copy. Instead, this wraps the
-- ONE function all six calls resolve to (`mod.find`) so a lookup for the
-- old id transparently falls back to the new one, on Gen 1 only.
--
-- Loaded only when mod.generation == 1, by the same one-line seam in
-- main.lua that loads compat/gen3/Gen3Compat.lua on Gen 3 (a small
-- {[1]=...,[3]=...}[mod.generation] table keyed by generation, still one
-- inserted line). Gen 2 and Gen 3 never read this file.

local mod, loadModule = ...

local ALIAS_FROM = "BATTLE_ART_QUEST_COMPAT"
local ALIAS_TO = "BATTLE_ART_QUEST_COMPAT_GEN1"

-- ENG mods\Loader.lua's own `find` already handles BOTH call styles in one
-- function: `local otherId = second == nil and first or second`, so
-- `mod.find(id)` (first=id, second=nil) and `mod:find(id)` (first=mod,
-- second=id, from the implicit self argument) both resolve to the same
-- `otherId`. Wrapping that one function is therefore also enough for
-- V.mod.find(...) -- V.mod IS the same `mod` table (weather_main.lua sets
-- `local V = { mod = mod, ... }`), not a separate object with its own
-- `find` to wrap.
local origFind = mod.find
if type(origFind) == "function" then
  mod.find = function(first, second)
    local result = origFind(first, second)
    if result then return result end
    local otherId = (second == nil) and first or second
    if otherId == ALIAS_FROM then
      -- A fresh, unambiguous dot-style retry: correct regardless of
      -- whether the FAILED lookup above was itself dot- or colon-style.
      return origFind(ALIAS_TO)
    end
    return nil
  end
else
  mod.log:warn("gen1: mod.find is not a function; BATTLE_ART_QUEST_COMPAT_GEN1 alias not installed")
end

return true
