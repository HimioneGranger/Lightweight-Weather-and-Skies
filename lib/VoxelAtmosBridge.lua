-- VoxelAtmosBridge
--
-- Routes optional 3D overworld weather for Weather FX.
-- Target hosts: DRAMATIC_SHAPE, DRAMALESS_SHAPE, potato_voxel,
-- POTATO_VOXEL, and STADIUM2_OVERWORLD_MODELS (Gen2).
-- The current Dramatic Shape 1.9.x fork uses the same exports.lib/Voxel3D
-- contract as the multi-host atmosphere bridge, so it is handled in-memory
-- rather than through the old 1.7 patch path.
--
-- Weather FX remains authority for weather state. This only upgrades
-- overworld drawing and tells Draw.lua when to skip 2D rain/fog.

local V = ...

local Bridge = {
  _impl = nil,
  _reason = "not-initialised",
}

local function loadDramaless()
  local ok, mod = pcall(V.require, "DramalessAtmos")
  if not ok or not mod then
    return nil, "DramalessAtmos-load-failed: " .. tostring(mod)
  end
  local iok, err = pcall(mod.install)
  if not iok then
    return nil, "DramalessAtmos-install-error: " .. tostring(err)
  end
  if not mod.active or not mod.active() then
    return nil, (mod.reason and mod.reason()) or "dramaless-inactive"
  end
  return mod, nil
end

function Bridge.init()
  if Bridge._impl and Bridge._impl.active and Bridge._impl.active() then
    return true
  end
  local impl, err = loadDramaless()
  if impl then
    Bridge._impl = impl
    Bridge._reason = impl.reason and impl.reason() or "voxel-host-3d"
    return true
  end
  Bridge._reason = tostring(err or "no-3d-host")
  Bridge._impl = nil
  return false
end

function Bridge.active()
  return Bridge._impl and Bridge._impl.active and Bridge._impl.active() or false
end

function Bridge.reason()
  if Bridge._impl and Bridge._impl.reason then
    return Bridge._impl.reason()
  end
  return Bridge._reason
end

function Bridge.handlesPrecipitation()
  return Bridge._impl and Bridge._impl.handlesPrecipitation
      and Bridge._impl.handlesPrecipitation() or false
end

function Bridge.handlesSnow()
  return Bridge._impl and Bridge._impl.handlesSnow
      and Bridge._impl.handlesSnow() or false
end

function Bridge.handlesGrains()
  return Bridge._impl and Bridge._impl.handlesGrains
      and Bridge._impl.handlesGrains() or false
end

function Bridge.handlesFog()
  return Bridge._impl and Bridge._impl.handlesFog
      and Bridge._impl.handlesFog() or false
end

function Bridge.handlesClouds()
  return false
end

function Bridge.syncFromWeatherFx(state, settings)
  if not Bridge.active() then return end
  if Bridge._impl.syncFromWeatherFx then
    pcall(Bridge._impl.syncFromWeatherFx, state, settings)
  end
end

function Bridge.update(dt)
  if not Bridge.active() then
    Bridge.init()
  end
  if Bridge._impl and Bridge._impl.update then
    pcall(Bridge._impl.update, dt)
  end
end

function Bridge.invalidate()
  if Bridge._impl and Bridge._impl.invalidate then
    pcall(Bridge._impl.invalidate)
  end
end

return Bridge
