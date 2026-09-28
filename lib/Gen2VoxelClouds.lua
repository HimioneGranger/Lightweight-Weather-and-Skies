-- Gen2 Quest transport for the approved, world-anchored voxel cloud deck.
-- Geometry, density field, weather response, motion, and shading come from
-- compat/CloudsSource.lua and compat/CloudShader.glsl without visual edits.
local V = ...
local M = {}
local FORMAT = {
  { 'VertexPosition', 'float', 3 },
  { 'VertexTexCoord', 'float', 2 },
  { 'VertexShade', 'float', 1 },
}

local function source(path)
  return assert(V.mod:read(path), 'missing original cloud asset: ' .. path)
end

local function derivedShader()
  local shader = source('compat/CloudShader.glsl')
  local a, n = shader:gsub('const mat4 model = mat4%(1%.0%);', 'uniform vec3 cloudOrigin;')
  assert(n == 1, 'cloud model declaration changed')
  local b, m = a:gsub('vec4 w = model %* vertex_position;',
    'vec4 w = vec4(vertex_position.xyz + cloudOrigin, 1.0);')
  assert(m == 1, 'cloud model translation changed')
  return b
end

function M.new(hostLib, voxel, options)
  local g = love.graphics
  local self = { voxel = voxel }
  options = options or {}
  local motion, fog, start, haze, cut
  local light = assert((loadstring or load)(source('compat/CloudLightSource.lua'),
    '@weather/CloudLightSource'))()
  local space = assert((loadstring or load)(source('compat/CloudSpace.lua'),
    '@weather/CloudSpace'))()
  local bridge = {}
  local namespace = { require = function(name)
    if name == 'Voxel3D' then return bridge end
    if name == 'Mat4' then return { translate = function(x, y, z) return {x,y,z} end } end
    if name == 'CloudLight' then return light end
    if name == 'CloudSpace' then return space end
    if name == 'DayNight' or name == 'Sky' then return hostLib.require(name) end
    return V.require(name)
  end }

  function bridge.newMesh(vertices, indices)
    local mesh = g.newMesh(FORMAT, vertices, 'triangles', 'static')
    mesh:setVertexMap(indices)
    return mesh
  end
  function bridge.glass() end
  function bridge.seams() end
  function bridge.skyDeck(on, density, first, color, alpha, params)
    if on then fog, start, haze, cut, motion = density, first, color, alpha, params end
  end
  function bridge.draw(mesh, image, origin)
    if not self.shader then self.shader = g.newShader(derivedShader()) end
    local shader = self.shader
    local eye = assert(voxel.eye, 'Gen2 cloud eye unavailable')
    local vp = assert(voxel.vp, 'Gen2 cloud camera unavailable')
    local sf = motion.stormFront or {0,0,0,0}
    local tint = {1,1,1}
    pcall(function()
      local day = hostLib.require('DayNight').tint(true)
      if day then tint = day end
    end)
    local uniforms = {
      eye = eye, cloudOrigin = origin, fogInfo = {fog or 0,start or 0,0,0},
      fogColor = haze or {1,1,1}, alphaCut = cut,
      cloudMorph = {motion.phase,motion.warp,0,1},
      cloudShape = {motion.shapeA,motion.shapeB,motion.density,motion.steps},
      cloudMaterial = {1-motion.coverage,motion.softness},
      cloudColor = motion.color, cloudLight = motion.light,
      cloudFade = 1-motion.opacity, cloudOvercast = motion.overcast,
      cloudLightning = motion.lightning or {0,0,0,0},
      stormFront = {sf[1],sf[2],sf[3],sf[4]},
      stormAxis = sf.axis or {1,0}, stormCanopy = sf.canopy or 0,
      stormFinish = {sf.fill or 0,sf.ready or 0}, dayTint = tint,
    }
    g.push('all')
    local ok, err = pcall(function()
      -- Gen 2 paints clouds before terrain. Gen 1's host seam is after
      -- opaque terrain, so it must depth-test the same approved deck.
      g.setDepthMode(options.depthTest and 'lequal' or 'always', false)
      g.setBlendMode('alpha', 'alphamultiply')
      g.setColor(1,1,1,1)
      g.setShader(shader)
      shader:send('vp', 'row', vp)
      for name, value in pairs(uniforms) do
        if shader:hasUniform(name) then shader:send(name, value) end
      end
      mesh:setTexture(image)
      g.draw(mesh)
    end)
    g.pop()
    if not ok then error(err) end
  end

  self.clouds = assert((loadstring or load)(source('compat/CloudsSource.lua'),
    '@weather/CloudsSource'))(namespace)
  self.clouds.setWeatherProvider(function()
    local state = V.require('WeatherState')
    local recovery = V.require('QuestAfterStorm')
    return state.channel('rain'), state.channel('snow'),
      state.channel('dim'), state.channel('gust'), state.channel('ash'),
      state.id, recovery.cloud
  end)
  self.clouds.lightningProvider = function()
    return V.require('QuestStorm').cloudLightning()
  end
  self.clouds.stormFrontProvider = function()
    return V.require('QuestStormFront').cloudField()
  end
  function self:update(dt)
    self.clouds.update(dt)
  end
  function self:draw(map, neighbors, outdoor)
    if not outdoor then return true end
    self.clouds.observeMap(map, neighbors)
    return self.clouds.draw(voxel.eye)
  end
  return self
end
return M
