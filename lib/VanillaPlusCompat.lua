-- The World <-> Vanilla+ compatibility bridge.
-- Vanilla+ deliberately patches a number of engine/UI surfaces directly.  The
-- bridge therefore avoids replacing its functions and coordinates only at
-- public/lifecycle seams, keeping both mods' hook chains intact.
local C = {}

local function findVanillaPlus(mod)
  if not (mod and type(mod.find) == "function") then return nil end
  local ids = { "vanillaplus", "VanillaPlus", "vanilla_plus" }
  for _, id in ipairs(ids) do
    local ok, h = pcall(mod.find, mod, id)
    if ok and h then return h end
    ok, h = pcall(mod.find, id)
    if ok and h then return h end
  end
end

function C.install(mod)
  local state = { active = false, handle = nil }

  local function sync()
    local vp = findVanillaPlus(mod)
    state.handle = vp
    state.active = vp ~= nil

    -- Public handshake for Vanilla+ and other integrations.  No Vanilla+
    -- internals are monkey-patched: its running shoes, field actions, Fly,
    -- Repel prompt, summary page, encounter additions, Chansey/Mime NPCs,
    -- toolkit, TM labels and battle UI therefore retain their own ownership.
    mod.exports.vanillaPlusCompatible = true
    mod.exports.vanillaPlusActive = state.active
    mod.exports.vanillaPlus = {
      compatible = true,
      active = state.active,
      worldOwnsWeather = true,
      worldOwnsWxPokemon = true,
      preservesVanillaPlusEncounters = true,
      preservesVanillaPlusUi = true,
      preservesVanillaPlusFieldTools = true,
    }

    -- The World's SELECT usage is summary-page scoped; Vanilla+'s SELECT
    -- toolkit is overworld scoped.  Export the ownership contract so neither
    -- side needs to globally consume SELECT.
    mod.exports.inputOwnership = mod.exports.inputOwnership or {}
    mod.exports.inputOwnership.select = {
      overworld = state.active and "vanillaplus" or "shared",
      pokemon_summary = "shared",
    }
    return state.active
  end

  pcall(sync)
  if mod.events and mod.events.on then
    -- Vanilla+ priority is higher than The World, so retry after all entries
    -- have loaded and again at save/game lifecycle seams.
    mod.events:on("mods.loaded", function() pcall(sync) end, 30000)
    mod.events:on("game.ready", function() pcall(sync) end, 30000)
    mod.events:on("save.loaded", function() pcall(sync) end, 30000)
  end
  return state
end

return C
