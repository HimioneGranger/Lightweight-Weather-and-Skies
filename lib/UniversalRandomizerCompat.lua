-- The World -> Universal Randomizer 1.3.x compatibility.
--
-- Both mods legitimately touch the same shared Pokemon registry, starter gifts,
-- and wild encounters. This bridge gives the Randomizer ownership of choices it
-- explicitly randomizes while retaining The World's WX/weather layer on top.
local Compat = {}

local function find(mod)
  if not mod or not mod.find then return nil end
  local ok, found = pcall(mod.find, mod, "universal_randomizer")
  if ok and found then return found end
  ok, found = pcall(mod.find, "universal_randomizer")
  return ok and found or nil
end

local function active(mod)
  local ur = find(mod)
  local ex = ur and ur.exports
  if not ex or type(ex.active) ~= "function" then return nil, ur end
  local ok, value = pcall(ex.active)
  return ok and value or nil, ur
end

local function cfg(mod)
  local a = active(mod)
  return a and a.cfg or nil
end

function Compat.install(mod)
  local lastFingerprint

  mod.exports.universalRandomizerPresent = function() return find(mod) ~= nil end
  mod.exports.universalRandomizerActive = function() return active(mod) ~= nil end
  mod.exports.universalRandomizerConfig = function() return cfg(mod) end
  mod.exports.universalRandomizerOwnsStarters = function()
    local c = cfg(mod)
    return c ~= nil and c.starters ~= nil and c.starters ~= "UNCHANGED"
  end
  mod.exports.universalRandomizerOwnsWild = function()
    local c = cfg(mod)
    if not c then return false end
    -- Every active UR encounter mode owns the base species roll, including
    -- VANILLA, whose meaning is "stable randomized vanilla slots" in UR 1.3.x.
    return c.area_encounters ~= nil
  end

  local function reconcile(context)
    local a, ur = active(mod)
    if not ur then return false end
    if not a then
      lastFingerprint=nil
      return true
    end
    local fp=tostring(a.fingerprint or a.seed or "active")
    if fp==lastFingerprint and context~="save.loaded" then return true end

    -- UR mutates the base definitions after The World has registered WX clones.
    -- Re-run The World's idempotent WX registration afterwards so each WX form
    -- inherits the randomized base data but keeps its authored WX typing,
    -- ability, sprites, learnset overlays and weather identity.
    if type(mod.exports.refreshWeatherVariants)=="function" then
      local ok, err=pcall(mod.exports.refreshWeatherVariants)
      if not ok and mod.log and mod.log.warn then
        mod.log:warn("Universal Randomizer compatibility: WX refresh failed: %s",tostring(err))
      end
    end
    lastFingerprint=fp
    if mod.log and mod.log.info then
      mod.log:info("Universal Randomizer compatibility active (%s): UR owns randomized base rolls; The World owns WX/weather overlays",tostring(context))
    end
    return true
  end

  -- UR priority is higher than The World and activates/rebuilds its saved seed
  -- at these same lifecycle seams. Run late so reconciliation sees final data.
  if mod.events and mod.events.on then
    mod.events:on("game.ready",function() reconcile("game.ready") end,50000)
    mod.events:on("save.loaded",function() reconcile("save.loaded") end,50000)
    mod.events:on("mods.loaded",function() reconcile("mods.loaded") end,50000)
  end
  pcall(reconcile,"install")
  return {reconcile=reconcile}
end

return Compat
