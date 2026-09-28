local root = assert(arg[1], 'mod root required')
local function source(path)
  local file = assert(io.open(root .. '/' .. path, 'rb'))
  local data = assert(file:read('*a'))
  file:close()
  return data
end

local recorder = assert(loadfile(root .. '/compat/SourceDrawPackets.lua'))()
local skyCamera = recorder.new({}, 'celestial_before_clouds', true):camera({
  eye = {0, 0, 0}, focus = {0, 0, 1}, far = 840,
  fov = math.rad(70), viewportHeight = 1080,
})
assert(skyCamera.stableStarBillboards == true, 'PC sky packet lacks stable star geometry')
assert(skyCamera.fov == math.rad(70) and skyCamera.viewportHeight == 1080,
  'packet star pixel scale lacks camera dimensions')
local rainCamera = recorder.new({}, 'translucent_after_actors', false):camera({
  eye = {0, 0, 0}, focus = {0, 0, 1}, far = 840,
})
assert(rainCamera.stableStarBillboards == false, 'star geometry flag leaked to rain packets')

local night = assert(loadfile(root .. '/lib/NightSky.lua'))({
  questLitePrivate = true,
  require = function(name)
    if name == 'DesktopWeatherProfile' then return {current = function() return nil end} end
    error(name)
  end,
})
local right, up = night.skyTangentAxes(.6, .8, 0)
assert(math.abs(right[1] * .6 + right[2] * .8) < 1e-6)
assert(math.abs(up[1] * .6 + up[2] * .8) < 1e-6)
assert(math.abs(right[1]^2 + right[2]^2 + right[3]^2 - 1) < 1e-6)
assert(math.abs(up[1]^2 + up[2]^2 + up[3]^2 - 1) < 1e-6)
local halfNear = night.packetStarHalf(.5, 420, skyCamera)
local halfFar = night.packetStarHalf(.5, 3360, skyCamera)
assert(math.abs(halfFar / halfNear - 8) < 1e-6,
  'packet stars change apparent size with the far plane')
local pixels = halfFar * skyCamera.viewportHeight /
  (2 * 3360 * math.tan(skyCamera.fov * .5))
assert(pixels >= 1.1 - 1e-6, 'packet stars are subpixel')
assert(night.packetStarHalf(.5, 3360, {}) == .5,
  'packet pixel floor leaked into the Quest direct renderer')

local celestial = assert(loadfile(root .. '/compat/CelestialPackets.lua'))()
local lastVertices
local api = {
  material = function() return {} end,
  image = function() return {} end,
  mesh = function(_, spec) lastVertices = spec.vertices; return {} end,
  updateMesh = function(_, _, vertices) lastVertices = vertices; return true end,
  enqueue = function() return true end,
}
local data = {getWidth = function() return 16 end,
  getHeight = function() return 16 end, getString = function() return string.rep('\255', 16*16*4) end}
local disc = {image = function() return {data = data} end,
  axes = function() return {1, 0, 0}, {0, 1, 0} end}
local bodies = {sun = {kind = 'sun', dx = 0, dy = 0, dz = 1, alpha = 1}}
local packet = celestial.new(api, disc)
assert(packet:draw(bodies, 420, {0, 0, 1}))
local nearWidth = lastVertices[2][1] - lastVertices[1][1]
assert(packet:draw(bodies, 840, {0, 0, 1}))
local farWidth = lastVertices[2][1] - lastVertices[1][1]
assert(math.abs(farWidth / nearWidth - 2) < .001,
  'PC sun lost angular size as sky distance increased')

local cloudPackets = assert(loadfile(root .. '/compat/CloudPackets.lua'))()
local realLove = {image = {}, graphics = {newShader = function()
  return {hasUniform = function() return true end, release = function() end}
end}}
local clouds = cloudPackets.new({}, {
  shader = source('compat/CloudShader.glsl'),
  clouds = source('compat/CloudsSource.lua'),
  light = source('compat/CloudLightSource.lua'),
  space = source('compat/CloudSpace.lua'),
}, realLove, function() return 300 end).clouds
local weather = 'CLEAR'
clouds.setWeatherProvider(function()
  if weather == 'RAIN_LIGHT' then return .34, 0, .11, 0, 0, weather end
  if weather == 'RAIN_HEAVY' then return 1, 0, .21, 0, 0, weather end
  return 0, 0, 0, 0, 0, weather
end)
local function settle(id)
  weather = id
  for _ = 1, 600 do clouds.update(.1) end
  return clouds.weatherVisuals().coverage
end
local clear = settle('CLEAR')
local mostly = settle('MOSTLY_CLOUDY')
local light = settle('RAIN_LIGHT')
local heavy = settle('RAIN_HEAVY')
assert(clear < .35 and mostly > .50 and mostly < .60
  and light > mostly + .12 and heavy > light + .10 and heavy >= .84,
  ('PC rain cloud cover wrong: %.3f %.3f %.3f %.3f'):
    format(clear, mostly, light, heavy))
local heavyColor = clouds.weatherVisuals().color[1]
settle('STORM')
assert(clouds.weatherVisuals().color[1] < heavyColor - .10,
  'heavy rain became as dark as storm clouds')
local drift = clouds.driftPx()
for _ = 1, 100 do clouds.update(.1) end
assert(clouds.driftPx() > drift, 'PC cloud animation clock did not advance')
print('PC packet sky: PASS')
