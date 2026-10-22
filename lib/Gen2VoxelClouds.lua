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

-- Runtime-only performance state, shared with the other weather files through
-- mod.exports.questPerf (see main.lua). hoist: per-eye allocation and repeated
-- uniform sends are removed (default ON; OFF runs the original per-eye code).
-- tier: "off" | "lite" | "full" (default "full"). Nothing here is ever saved.
local function perfState()
  local m = V.mod
  local e = m and m.exports
  if type(e) ~= 'table' then return { hoist = true, tier = 'full' } end
  local p = e.questPerf
  if type(p) ~= 'table' then p = { hoist = true, tier = 'full' }; e.questPerf = p end
  return p
end

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
  -- Only the clean native host opts in. Other hosts retain the original
  -- cloud fog/color/alpha behavior with this uniform zero.
  local function replaceOnce(text,needle,value)
    local i=assert(text:find(needle,1,true),'native cloud shader seam missing')
    assert(not text:find(needle,i+1,true),'ambiguous native cloud shader seam')
    return text:sub(1,i-1)..value..text:sub(i+#needle)
  end
  b=replaceOnce(b,'  uniform vec3 fogColor;','  uniform vec3 fogColor;\n  uniform float nativeCloudFade;')
  b=replaceOnce(b,'    vec4 p = Texel(tex, tc);','    if(nativeCloudFade>0.5 && vFog>=0.995)discard;\n    vec4 p = Texel(tex, tc);')
  b=replaceOnce(b,'    return vec4(rgb, p.a) * color;','    float nativeAlpha=nativeCloudFade>0.5 ? 1.0-smoothstep(0.85,0.995,vFog) : 1.0;\n    return vec4(rgb, p.a*nativeAlpha) * color;')
  return b
end

-- ---------------------------------------------------------------------------
-- Frame-hoist helpers. A shader's uniforms live in the shader object, so a
-- value this code already sent does not need to be sent again. The record is
-- weak-keyed by shader object: a rebuilt shader starts with no history.
-- ---------------------------------------------------------------------------
local records = setmetatable({}, { __mode = 'k' })

local function recordFor(shader)
  local r = records[shader]
  if not r then r = { has = {}, val = {} }; records[shader] = r end
  return r
end

local function known(shader, r, name)
  local h = r.has[name]
  if h == nil then h = shader:hasUniform(name) and true or false; r.has[name] = h end
  return h
end

-- scalar (or any non-table) value
local function sendScalar(shader, r, name, v)
  if v == nil or not known(shader, r, name) then return end
  local last = r.val[name]
  if last ~= nil and last == v then return end
  shader:send(name, v)
  r.val[name] = v
end

-- vector uniform given as a table; n components are compared and remembered
local function sendVector(shader, r, name, v, n)
  if v == nil or not known(shader, r, name) then return end
  n = n or #v
  local last = r.val[name]
  if last and last.n == n then
    local same = true
    for i = 1, n do
      local x = v[i]
      if x == nil or last[i] ~= x then same = false; break end
    end
    if same then return end
  end
  shader:send(name, v)
  if not last then last = {}; r.val[name] = last end
  for i = 1, n do last[i] = v[i] end
  last.n = n
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
  local perf = perfState()
  local originT = {0, 0, 0}
  local matStub = { translate = function(x, y, z)
    if perf.hoist then
      originT[1], originT[2], originT[3] = x, y, z
      return originT
    end
    return {x,y,z}
  end }
  local namespace = { require = function(name)
    if name == 'Voxel3D' then return bridge end
    if name == 'Mat4' then return matStub end
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

  -- ---- original per-eye path (hoist OFF): the Lab 52 behaviour, plus the
  -- native-fade seam that stays inert unless a host publishes
  -- voxel.nativeCloudAtmos.
  local function drawLegacy(mesh, image, origin)
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
    local native=voxel.nativeCloudAtmos
    local density,first,color=fog,start,haze
    if native then
      local altitude=self.clouds.ALT or 1920 -- source uses world pixels (16/cell)
      density=-math.log(.02)/(altitude*native.runAltitudes)
      first=altitude*native.startAltitudes;color=native.color
    end
    local uniforms = {
      eye = eye, cloudOrigin = origin, fogInfo = {density or 0,first or 0,0,0},
      fogColor = color or {1,1,1}, alphaCut = cut,nativeCloudFade=native and 1 or 0,
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

  -- ---- hoisted per-eye path: no per-eye tables or closures; a uniform is sent
  -- only when it differs from the last value sent to this shader object. The
  -- value every draw sees is the value the original path would have sent.
  local fogInfoT, morphT, shapeT, materialT = {0,0,0,0}, {0,0,0,1}, {0,0,0,0}, {0,0}
  local stormFrontT, finishT = {0,0,0,0}, {0,0}
  local ZERO4, AXIS0, WHITE3, ONE3 = {0,0,0,0}, {1,0}, {1,1,1}, {1,1,1}
  local tintV, day = ONE3, nil
  local function readTint()
    day = hostLib.require('DayNight').tint(true)
  end
  local dEye, dVp, dOrigin, dNative, dSf
  local function drawBody(shader, mesh, image)
    local r = recordFor(shader)
    g.setDepthMode(options.depthTest and 'lequal' or 'always', false)
    g.setBlendMode('alpha', 'alphamultiply')
    g.setColor(1,1,1,1)
    g.setShader(shader)
    shader:send('vp', 'row', dVp)
    local native, sf = dNative, dSf
    local density, first, color = fog, start, haze
    if native then
      local altitude = self.clouds.ALT or 1920
      density = self.nativeK / (altitude * native.runAltitudes)
      first = altitude * native.startAltitudes; color = native.color
    end
    sendVector(shader, r, 'eye', dEye)
    sendVector(shader, r, 'cloudOrigin', dOrigin)
    fogInfoT[1], fogInfoT[2] = density or 0, first or 0
    sendVector(shader, r, 'fogInfo', fogInfoT, 4)
    sendVector(shader, r, 'fogColor', color or WHITE3)
    sendScalar(shader, r, 'alphaCut', cut)
    sendScalar(shader, r, 'nativeCloudFade', native and 1 or 0)
    morphT[1], morphT[2] = motion.phase, motion.warp
    sendVector(shader, r, 'cloudMorph', morphT, 4)
    shapeT[1], shapeT[2], shapeT[3], shapeT[4] = motion.shapeA, motion.shapeB, motion.density, motion.steps
    sendVector(shader, r, 'cloudShape', shapeT, 4)
    materialT[1], materialT[2] = 1 - motion.coverage, motion.softness
    sendVector(shader, r, 'cloudMaterial', materialT, 2)
    sendVector(shader, r, 'cloudColor', motion.color)
    sendVector(shader, r, 'cloudLight', motion.light)
    sendScalar(shader, r, 'cloudFade', 1 - motion.opacity)
    sendScalar(shader, r, 'cloudOvercast', motion.overcast)
    sendVector(shader, r, 'cloudLightning', motion.lightning or ZERO4)
    if sf then
      stormFrontT[1], stormFrontT[2], stormFrontT[3], stormFrontT[4] = sf[1], sf[2], sf[3], sf[4]
    else
      stormFrontT[1], stormFrontT[2], stormFrontT[3], stormFrontT[4] = 0, 0, 0, 0
    end
    sendVector(shader, r, 'stormFront', stormFrontT, 4)
    sendVector(shader, r, 'stormAxis', sf and sf.axis or AXIS0)
    sendScalar(shader, r, 'stormCanopy', sf and sf.canopy or 0)
    finishT[1], finishT[2] = sf and sf.fill or 0, sf and sf.ready or 0
    sendVector(shader, r, 'stormFinish', finishT, 2)
    sendVector(shader, r, 'dayTint', tintV)
    if r.texture ~= image or r.mesh ~= mesh then
      mesh:setTexture(image)
      r.texture, r.mesh = image, mesh
    end
    g.draw(mesh)
  end
  local function drawHoisted(mesh, image, origin)
    if not self.shader then self.shader = g.newShader(derivedShader()) end
    local shader = self.shader
    local eye = assert(voxel.eye, 'Gen2 cloud eye unavailable')
    local vp = assert(voxel.vp, 'Gen2 cloud camera unavailable')
    dSf = motion.stormFront
    tintV, day = ONE3, nil
    pcall(readTint)
    if day then tintV = day end
    dEye, dVp, dOrigin, dNative = eye, vp, origin, voxel.nativeCloudAtmos
    g.push('all')
    local ok, err = pcall(drawBody, shader, mesh, image)
    g.pop()
    dEye, dVp, dOrigin, dNative, dSf, day = nil, nil, nil, nil, nil, nil
    if not ok then error(err) end
  end
  self.nativeK = -math.log(.02)

  function bridge.draw(mesh, image, origin)
    if perf.hoist then return drawHoisted(mesh, image, origin) end
    -- Lab 55 review D2: the legacy path sends straight to the shader, so the
    -- hoisted path's last-sent record is no longer the shader's state; drop it
    -- (a later ON frame resends every uniform and the texture).
    if self.shader then records[self.shader] = nil end
    return drawLegacy(mesh, image, origin)
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
    -- OFF tier: no sky-deck clouds at all (rain, snow and the day/night grade
    -- come from other passes). Reports success so callers do not fault.
    if perf.tier == 'off' then return true end
    self.clouds.hoist = perf.hoist
    self.clouds.observeMap(map, neighbors)
    return self.clouds.draw(voxel.eye)
  end
  return self
end
return M
