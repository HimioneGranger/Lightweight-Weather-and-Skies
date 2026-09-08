-- The World <-> QoL Toggles compatibility bridge.
-- QoL Toggles 1.30+ is intentionally allowed to own its QoL seams while The
-- World owns world simulation, species/content, weather/WX and regional data.
local M = {}

local function find(mod, id)
  if not (mod and mod.find) then return nil end
  local ok, found = pcall(mod.find, mod, id)
  if ok and found then return found end
  ok, found = pcall(mod.find, id)
  return ok and found or nil
end

function M.install(mod)
  local qol = find(mod, "qol_toggles") or find(mod, "QoL Toggles")
  local present = qol ~= nil
  mod.exports.qolTogglesPresent = function() return present end
  mod.exports.qolTogglesCompatibility = present
  mod.exports.qolToggles = qol and qol.exports or nil
  mod.exports.qolTogglesMod = qol
  if not present then return false end

  -- Deliberately do not replace QoL's hooks. Runtime hook chains compose, so
  -- encounter de-duping, EXP/money multipliers, field-move eligibility,
  -- running, fishing, capture healing, battle cursor/animation helpers and
  -- map toasts remain QoL-owned. The World continues to transform encounters
  -- only when its own encounter-control setting gives it authority.
  --
  -- Likewise, QoL's MODERN TYPES switch is allowed to reload the live engine
  -- TypeChart. World battle AI asks that same live chart for effectiveness,
  -- so trainer decisions follow the player's selected chart rather than a
  -- stale private copy.
  mod.exports.qolTogglesOwnership = {
    encounterPostProcess = true,
    expMultiplier = true,
    moneyMultiplier = true,
    fieldMoveConvenience = true,
    movementConvenience = true,
    battleConvenience = true,
    typeChartToggle = true,
    optionsSubmenu = true,
  }

  -- Public handshake for diagnostics and future QoL releases. No dependency
  -- on private QoL internals is required, which keeps 1.30.x+ forward-safe.
  if qol.exports then
    qol.exports.theWorldPresent = function() return true end
    qol.exports.theWorldCompatibility = true
  end
  if mod.log and mod.log.info then
    mod.log:info("QoL Toggles compatibility active; QoL seams will compose with World systems")
  end
  return true
end

return M
