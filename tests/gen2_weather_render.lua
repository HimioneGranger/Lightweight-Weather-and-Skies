local root = assert(arg[1])
local sceneEnds = 0
local skyPaints = 0
TEST_SELECTED_WEATHER = nil
TEST_SKY_FILL = nil
GEN2_CLOUD_DRAWS = 0
GEN2_BILLBOARD_DRAWS = 0

love = {
  graphics = {
    getCanvas = function() return "eye" end,
    push = function() end,
    pop = function() end,
    getBlendMode = function() return "alpha", "alphamultiply" end,
    setBlendMode = function() end,
    getColor = function() return 1, 1, 1, 1 end,
    setColor = function(r, g, b) TEST_DRAW_COLOR = { r, g, b } end,
    rectangle = function(mode, x, y, w, h)
      if mode == "fill" then TEST_SKY_FILL = { x, y, w, h, TEST_DRAW_COLOR } end
    end,
    setShader = function() end,
    setDepthMode = function() end,
  },
}

local voxel = {
  vp = {},
  eye = { 0, 40, 0 },
  focus = { 0, 0, -1 },
  endScene = function()
    sceneEnds = sceneEnds + 1
    return "eye-result"
  end,
}

local sky = {
  paint = function()
    skyPaints = skyPaints + 1
    return "sky-result"
  end,
}

local hostLib = {}
function hostLib.require(name)
  if name == "Voxel3D" then return voxel end
  if name == "Sky" then return sky end
  if name == "VoxelScene" then return {} end
  if name == "DayNight" or name == "ShadowMap" or name == "TileShape" then return {} end
  error(name)
end

local host = { exports = { lib = hostLib } }
local mod = {
  path = "weather",
  exports = {
    rendererReady = function() return true, "standalone-renderer-selected" end,
    activeWeatherHost = function() return host, "BATTLE_ART_VOXEL_GEN2" end,
  },
  read = function(_, path)
    if path:find("CinematicAtmos", 1, true) then
      return [[return {
        frame=function() return { weather={} } end,
        update=function() end,
        drawQuestClouds=function()
          GEN2_BILLBOARD_DRAWS=GEN2_BILLBOARD_DRAWS+1
          return true
        end,
        setQuestWeather=function(key) TEST_SELECTED_WEATHER=key end,
        skyWeather=function() return { color={0.4,0.5,0.6}, blend=0.7 } end,
      }]]
    end
    if path:find("WorldPrecip", 1, true) then
      return "return {update=function()end,draw=function()end}"
    end
    if path:find("ForestAtmos", 1, true) then
      return "return {time=0,update=function()end}"
    end
    return "return {}"
  end,
  log = { warn = function() end },
}

local namespace = { mod = mod, path = mod.path, questLitePrivate = true }
function namespace.require(name)
  if name == "Gen2VoxelClouds" then return { new=function()
    return { update=function() end, draw=function()
      GEN2_CLOUD_DRAWS=GEN2_CLOUD_DRAWS+1
      return true
    end }
  end } end
  if name == "Settings" then return {} end
  if name == "TimeOfDay" then return { hour=12, isNight=function() return false end } end
  if name == "WeatherState" then
    return { channel=function() return 1 end }
  end
  if name == "QuestStorm" then
    return { attach=function() end, flash=function() return 0 end, strength=1 }
  end
  if name == "QuestStormFront" then return { managed=false } end
  if name == "QuestAfterStorm" then return { rain=0 } end
  if name == "QuestRainSurface" then
    return { sampler=function() return function() return 0 end end }
  end
  if name == "QuestAurora" or name == "QuestRainbow" or name == "QuestStormBolt" then
    return { drawWorld=function() return true end }
  end
  if name == "NightSky" then return {
    drawWorld=function() return true end,
    applyWeatherBands=function() return { {0.2,0.3,0.4}, {0.4,0.5,0.6} } end,
  } end
  if name == "CelestialBodies" then return { drawWorld=function() return true end } end
  return {}
end

local atmosphere = assert(loadfile(
  root .. "/lib/DramalessAtmos.lua"))(namespace)
assert(atmosphere.install(), atmosphere.reason())
atmosphere.syncFromWeatherFx({ id="STORM", level=1 })
assert(TEST_SELECTED_WEATHER == "thunderstorm", "Gen2 storm profile not selected")
atmosphere.syncFromWeatherFx({ id="PARTLY_CLOUDY", level=1 })
assert(TEST_SELECTED_WEATHER == "partly", "Gen2 partly-cloudy menu fell back to clear")
atmosphere.syncFromWeatherFx({ id="MOSTLY_CLOUDY", level=1 })
assert(TEST_SELECTED_WEATHER == "mostly", "Gen2 mostly-cloudy menu fell back to clear")
atmosphere.syncFromWeatherFx({ id="STORM", level=1 })
atmosphere.update(1/90)
assert(sky.paint(100, 100, { bands={{0,0,0},{1,1,1}} }) == "sky-result")
assert(voxel.endScene() == "eye-result")
assert(skyPaints == 1, "Gen2 Quest sky replacement did not run")
assert(not TEST_SKY_FILL, "Gen2 substitute screen-space weather veil returned")
assert(sceneEnds == 1, "Gen2 scene did not close exactly once")
assert(GEN2_CLOUD_DRAWS == 1, "Gen2 Quest scene skipped the original voxel cloud deck")
assert(GEN2_BILLBOARD_DRAWS == 0, "Gen2 Quest rendered substitute billboard clouds")

-- Gen 2 Battle Art has no host Clouds.lua.  QuestStorm must still attach its
-- sky tint, haze, and Weather FX cloud flash without requiring that Gen 1
-- host module.
local stormV = {
  mod = { events = { on = function() end } },
  require = function() return {} end,
}
local realStorm = assert(loadfile(root .. "/lib/QuestStorm.lua"))(stormV)
local stormDayNight = { tint = function() return {1,1,1} end }
local stormSky = { haze = function() return {0,0,0} end }
local stormHost = { require = function(name)
  if name == "DayNight" then return stormDayNight end
  if name == "Sky" then return stormSky end
  if name == "Voxel3D" then return {} end
  if name == "Clouds" then error("Clouds.lua missing") end
  error(name)
end }
assert(pcall(realStorm.attach, stormHost, voxel),
  "Gen2 storm attach still requires host Clouds.lua")
assert(pcall(realStorm.detach), "Gen2 storm detach failed without host Clouds.lua")
print("Gen 2 weather render hook: PASS")
