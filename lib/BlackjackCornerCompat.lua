-- The World -> Blackjack Corner compatibility.
-- Blackjack Corner intentionally builds its starter roulette from every
-- base-stage species currently registered in game.data.pokemon. The World
-- registers later-generation species even when its generation scope hides
-- them from encounters, so without this bridge Gamble Mode can bypass the
-- player's POKEMON GENERATIONS setting.
local Compat = {}

local function scope(mod)
  local value
  pcall(function() value = mod.save:get("world_content_scope") end)
  if value == "gen1" or value == "gen1_gen2" then return value end
  pcall(function() value = mod.options:get("worldContentScope") end)
  if value == "gen1" or value == "gen1_gen2" then return value end
  return "gen1_gen2_gen3"
end

local function maxDex(mod)
  local value = scope(mod)
  if value == "gen1" then return 151 end
  if value == "gen1_gen2" then return 251 end
  return 386
end

local function allowed(mod, pokemonData, species)
  local limit = maxDex(mod)
  if limit >= 386 then return true end
  local def = pokemonData and pokemonData[species]
  local dex = def and tonumber(def.dex)
  -- A roulette starter must have a known National Dex position when the
  -- player selected a restricted scope. This prevents injected/custom
  -- later-generation records with missing metadata leaking through.
  return dex ~= nil and dex <= limit
end

function Compat.install(mod)
  local patchedRules

  local function patch()
    if not mod.find then return false end
    local ok, blackjack = pcall(mod.find, mod, "blackjack_corner")
    if not ok or not blackjack then
      ok, blackjack = pcall(mod.find, "blackjack_corner")
    end
    local exports = blackjack and blackjack.exports
    local rules = exports and exports.roulette_rules
    if type(rules) ~= "table" or type(rules.pool) ~= "function" then return false end
    if rules == patchedRules or rules._theWorldGenerationScopePatched then return true end

    local originalPool = rules.pool
    rules.pool = function(pokemonData)
      local pool = originalPool(pokemonData)
      local filtered = {}
      for _, species in ipairs(pool or {}) do
        if allowed(mod, pokemonData, species) then
          filtered[#filtered + 1] = species
        end
      end
      -- Never hand Blackjack Corner an empty pool. Stock RBY data always has
      -- legal Gen-1 base stages, but this guard keeps unusual content stacks
      -- from turning a compatibility filter into a startup/gameplay crash.
      return #filtered > 0 and filtered or pool
    end
    rules._theWorldGenerationScopePatched = true
    rules._theWorldOriginalPool = originalPool
    patchedRules = rules
    if mod.log and mod.log.info then
      pcall(mod.log.info, mod.log, "The World: Blackjack Corner starter roulette now follows POKEMON GENERATIONS")
    end
    return true
  end

  -- Blackjack Corner has a higher priority and may not have exported its
  -- roulette table while The World's entry point is executing. Retry at the
  -- lifecycle seams that occur before Oak's roulette can be used.
  pcall(patch)
  if mod.events and mod.events.on then
    mod.events:on("game.ready", function() patch() end, -20000)
    mod.events:on("save.loaded", function() patch() end, -20000)
    mod.events:on("intro.oak_speech.finished", function() patch() end, 20000)
  end

  return { patch = patch }
end

return Compat
