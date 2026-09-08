-- The World -> Anime Realism 4.x compatibility bridge.
-- Anime Realism owns battle presentation/REACT/FIELD combat when installed.
-- The World keeps simulation, Pokemon/WX data, weather rules and rival identity.
-- Never edits Anime Realism files.
local Compat = {}

local IDS = { "anime_realism", "Anime_Realism", "ANIME_REALISM" }

local function find(mod)
  if not mod or type(mod.find) ~= "function" then return nil end
  for i=1,#IDS do
    local ok,h = pcall(mod.find, mod, IDS[i])
    if not ok or not h then ok,h = pcall(mod.find, IDS[i]) end
    if ok and h then return h end
  end
  return nil
end

function Compat.install(mod)
  local present = false
  local version = nil

  local function refresh(context)
    local h = find(mod)
    present = h ~= nil
    version = h and (h.version or (h.manifest and h.manifest.version)) or nil

    -- Compat.lua is intentionally queried dynamically by battle drawing. Force
    -- it to forget any pre-mods.loaded result because AR priority 200 loads
    -- after The World (60).
    local ok,C = pcall(require, "mods.the_world.lib.Compat")
    if ok and type(C)=="table" and type(C.refresh)=="function" then pcall(C.refresh) end

    if present and mod.log and mod.log.info then
      mod.log:info("Anime Realism compatibility active%s (%s): AR owns FIELD/REACT battle presentation; The World keeps WX/weather/gameplay data",
        version and (" v"..tostring(version)) or "", tostring(context or "refresh"))
    end
    return present
  end

  mod.exports.animeRealismPresent = function() return find(mod) ~= nil end
  mod.exports.animeRealismCompatible = true
  mod.exports.animeRealismOwnership = function()
    return {
      battlePresentation = "anime_realism",
      fieldCombat = "anime_realism",
      reactSystem = "anime_realism",
      weatherVisuals = "the_world_under_ui",
      weatherRules = "the_world",
      wxPokemon = "the_world",
      rivalSimulation = "the_world",
      rivalIdentity = "the_world",
      doubleBattleLogic = "the_world",
      doubleBattlePresentation = "classic_anime_realism",
    }
  end

  -- Refresh only at safe lifecycle seams. We deliberately do not wrap AR's
  -- BattleState methods: both projects already chain engine hooks and another
  -- wrapper would make load order brittle.
  if mod.events and type(mod.events.on)=="function" then
    mod.events:on("mods.loaded", function() refresh("mods.loaded") end, 60000)
    mod.events:on("game.ready", function() refresh("game.ready") end, 60000)
    mod.events:on("save.loaded", function() refresh("save.loaded") end, 60000)
    mod.events:on("battle.started", function(ev)
      -- Late detection protects hot reload / reordered optional mods.
      if not present then refresh("battle.started") end
      local b = ev and ev.battle
      if present and b and b.__double then
        -- Anime Realism 4.0.2 supportsBattle() explicitly excludes these
        -- public flags. World doubles use __double internally, so publish the
        -- aliases before AR decides whether to create its 1v1 FIELD scene.
        b.double, b.isDouble, b.doubleBattle = true, true, true
        b._worldAnimeRealismDoubleCompat = true
      end
    end, 100000)
  end
  pcall(refresh, "install")
  return { refresh=refresh, present=function() return present end }
end

return Compat
