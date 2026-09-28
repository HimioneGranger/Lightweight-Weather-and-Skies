local root = assert(arg[1])
local draws, ends = 0, 0

love = { graphics = {
  getCanvas = function() return "eye" end,
  push = function() end, pop = function() end,
  getBlendMode = function() return "alpha", "alphamultiply" end,
  setBlendMode = function() end,
  getColor = function() return 1, 1, 1, 1 end,
  setColor = function() end, setShader = function() end,
  setDepthMode = function() end,
} }

local voxel = {
  vp = {}, eye = { 0, 40, 0 }, focus = { 0, 0, -1 },
  endScene = function() ends = ends + 1; return "eye-result" end,
}
local sky = {
  paint = function() return "sky-result" end,
  discImage = function() return "native-body" end,
}
local hostLib = { require = function(name)
  if name == "Voxel3D" then return voxel end
  if name == "Sky" then return sky end
  if name == "VoxelScene" then return {} end
  if name == "DayNight" or name == "ShadowMap" or name == "TileShape" then return {} end
  -- Battle Art 1.11.0 does not contain Clouds.lua.
  if name == "Clouds" then error("host Clouds.lua absent") end
  error(name)
end }
local host = { exports = { lib = hostLib } }
local mod = {
  path = "weather",
  exports = {
    rendererReady = function() return true end,
    activeWeatherHost = function() return host, "BATTLE_ART_VOXEL_FORK" end,
  },
  read = function(_, path)
    if path:find("CinematicAtmos", 1, true) then
      return "return {frame=function() return {weather={}} end, update=function() end}"
    end
    if path:find("WorldPrecip", 1, true) then
      return "return {update=function() end,draw=function() end}"
    end
    if path:find("ForestAtmos", 1, true) then
      return "return {time=0,update=function() end}"
    end
    return "return {}"
  end,
  log = { warn = function() end },
}
local namespace = { mod = mod, path = mod.path, questLitePrivate = true }
function namespace.require(name)
  if name == "Gen2VoxelClouds" then return { new = function(_, _, opts)
    assert(opts and opts.depthTest == true)
    return { update = function() end, draw = function()
      draws = draws + 1
      return true
    end }
  end } end
  if name == "TimeOfDay" then return { hour = 12, isNight = function() return false end } end
  if name == "WeatherState" then return { channel = function() return 1 end } end
  if name == "QuestStorm" then return { attach = function() end, flash = function() return 0 end, strength = 1 } end
  if name == "QuestStormFront" then return { managed = false } end
  if name == "QuestAfterStorm" then return { rain = 0 } end
  if name == "QuestRainSurface" then return { sampler = function() return function() return 0 end end } end
  if name == "QuestAurora" or name == "QuestRainbow" or name == "QuestStormBolt" then
    return { drawWorld = function() return true end }
  end
  if name == "NightSky" then return { drawWorld = function() return true end } end
  if name == "CelestialBodies" then return { drawWorld = function() return true end } end
  return {}
end

local atmosphere = assert(loadfile(root .. "/lib/DramalessAtmos.lua"))(namespace)
assert(atmosphere.install(), atmosphere.reason())
atmosphere.update(1 / 90)
assert(voxel.endScene() == "eye-result")
assert(ends == 1, "host eye did not close exactly once")
assert(draws == 1, "stock Gen 1 host did not draw weather's cloud deck")
print("Gen 1 stock host cloud fallback: PASS")
