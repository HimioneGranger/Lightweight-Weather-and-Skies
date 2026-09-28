local root = assert(arg[1])
local draws, sends, sourceReads = 0, {}, {}
local shaderSource
local shader = {
  hasUniform = function() return true end,
  send = function(_, name, value, matrix)
    sends[name] = matrix or value
  end,
}
local mesh = {
  setVertexMap = function(_, indices)
    assert(#indices == 40 * 40 * 6, 'approved cloud mesh changed')
  end,
  setTexture = function() end,
}
love = {
  image = { newImageData = function(width, height)
    assert(width == 512 and height == 512, 'approved cloud field changed')
    return { setPixel = function() end }
  end },
  graphics = {
    newImage = function() return {setFilter=function() end,setWrap=function() end} end,
    newMesh = function(format, vertices)
      assert(#format == 3 and #vertices == 41 * 41, 'approved cloud vertices changed')
      return mesh
    end,
    newShader = function(text) shaderSource=text; return shader end,
    push=function() end, pop=function() end, setDepthMode=function() end,
    setBlendMode=function() end, setColor=function() end,
    setShader=function() end, draw=function() draws=draws+1 end,
  },
}
local channels={}
local weather = {id='MOSTLY_CLOUDY',channel=function(key) return channels[key] or 0 end}
local V = {
  mod = {read=function(_,path)
    sourceReads[path]=true
    local f=assert(io.open(root..'/'..path,'rb'))
    local content=f:read('*a');f:close();return content
  end},
  require=function(name)
    if name=='WeatherState' then return weather end
    if name=='QuestAfterStorm' then return {} end
    if name=='QuestStorm' then return {cloudLightning=function() return nil end} end
    if name=='QuestStormFront' then return {cloudField=function() return nil end} end
    error(name)
  end,
}
local host={require=function(name)
  if name=='DayNight' then return {time=function() return 300 end,
    tint=function() return {1,1,1} end} end
  if name=='Sky' then return {haze=function() return {.2,.3,.4} end} end
  error(name)
end}
local voxel={vp={},eye={0,40,0}}
local adapter=assert(loadfile(root..'/lib/Gen2VoxelClouds.lua'))(V).new(host,voxel)
adapter:update(1/90)
assert(adapter:draw({id='PALLET'},nil,true), 'original deck declined draw')
assert(draws==1, 'original deck did not reach Love draw')
assert(sourceReads['compat/CloudsSource.lua'] and sourceReads['compat/CloudShader.glsl'],
  'adapter did not load approved cloud source/shader')
assert(shaderSource:find('uniform vec3 cloudOrigin;',1,true)
  and shaderSource:find('vec4(vertex_position.xyz + cloudOrigin, 1.0)',1,true),
  'world anchored shader translation missing')
assert(sends.cloudOrigin and sends.cloudMorph and sends.cloudShape and sends.stormFront,
  'original cloud uniforms were not sent')
assert(adapter:draw({id='PALLET'},nil,false) and draws==1,
  'indoor cloud draw was not suppressed')
local function settledCoverage(id, values)
  weather.id,channels=id,values
  for _=1,600 do adapter:update(.1) end
  return adapter.clouds.weatherVisuals().coverage
end
local mostly=settledCoverage('MOSTLY_CLOUDY',{})
local light=settledCoverage('RAIN_LIGHT',{rain=.34,dim=.11})
local heavy=settledCoverage('RAIN_HEAVY',{rain=1,dim=.21})
assert(mostly>.50 and mostly<.60 and light>mostly+.12
  and heavy>light+.10 and heavy>=.84,
  ('Quest cloud ordering wrong: mostly %.3f light %.3f heavy %.3f'):
    format(mostly,light,heavy))
print('Gen2 original voxel cloud adapter: PASS')
