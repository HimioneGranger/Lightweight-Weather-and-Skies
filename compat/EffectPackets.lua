-- Weather-owned authored geometry/GLSL, submitted through host-owned resources.
-- Never installs host callbacks or writes to Battle Art modules.
local M={}
local UV={{'VertexPosition','float',3},{'VertexTexCoord','float',2}}
local BOLT={{'VertexPosition','float',3},{'VertexColor','float',4},{'BoltEdge','float',1},{'BoltProgress','float',1}}
local function must(value,err)if not value then error(err or 'host rejected weather resource',2)end;return value end
function M.new(api,modules)
  local self={api=api,resources={},closed=false}
  function self:release()
    if self.closed then return end
    for _,r in pairs(self.resources)do
      if r.mesh then pcall(api.release,api,r.mesh)end
      if r.material then pcall(api.release,api,r.material)end
    end
    self.resources={};self.closed=true
  end
  local function resource(key,source,uniforms,format,vertices,sky)
    assert(not self.closed,'weather resources released')
    local r=self.resources[key]
    if r then return r end
    r={material=must(api:material{source=source,uniforms=uniforms,skyDepth=sky})}
    self.resources[key]=r
    r.mesh=must(api:mesh{format=format,vertices=vertices});r.count=#vertices
    return r
  end
  local function enqueue(r,phase,uniforms)
    must(api:enqueue{phase=phase,material=r.material,mesh=r.mesh,uniforms=uniforms})
  end
  function self:bolt(event)
    if not event or (event.boltAlpha or 0)<=.001 then return false end
    local r=self.resources.bolt
    if not r or r.event~=event.id then
      local vertices=modules.bolt.vertices(event)
      if not r then
        r=resource('bolt',modules.bolt.SHADER,{opacity=1,reveal=1},BOLT,vertices,false)
      elseif r.count==#vertices then must(api:updateMesh(r.mesh,vertices))
      else
        local mesh=must(api:mesh{format=BOLT,vertices=vertices})
        must(api:release(r.mesh));r.mesh=mesh;r.count=#vertices
      end
      r.event=event.id
    end
    enqueue(r,'translucent_after_actors',{opacity=event.boltAlpha,reveal=event.reveal or 1})
    return true
  end
  function self:aurora(state)
    if not state or not state.night or not state.outdoor or (state.alpha or 0)<=0 then return false end
    local r=self.resources.aurora or resource('aurora',modules.aurora.SHADER,
      {clock=0,bearing=0,opacity=0,flourish={0,0,0,0},layer=0,radius=450},UV,modules.aurora.vertices(),true)
    for layer=1,0,-1 do
      enqueue(r,'celestial_before_clouds',{clock=state.clock,bearing=state.bearing or 0,
        opacity=state.alpha,flourish=state.flourish or {0,0,0,state.clock},layer=layer,
        radius=(state.far or 500)*(.90+.01*layer)})
    end
    return true
  end
  function self:rainbow(state)
    if not state or not state.outdoor or (state.alpha or 0)<=.001 then return false end
    local sun=state.sun
    if not sun or not sun.above or sun.dy<=.08 or sun.dy>=.66 then return false end
    local ax,ay,az=-sun.dx,-sun.dy,-sun.dz
    local len=math.sqrt(ax*ax+az*az);if len<.001 then return false end
    local rx,rz=-az/len,ax/len
    local ux,uy,uz=-ay*rz,rz*ax-rx*az,ay*rx
    if uy<0 then ux,uy,uz=-ux,-uy,-uz end
    local r=self.resources.rainbow or resource('rainbow',modules.rainbow.SHADER,
      {antiSun={0,0,1},arcRight={1,0,0},arcUp={0,1,0},radius=450,opacity=0},UV,modules.rainbow.vertices(),true)
    enqueue(r,'celestial_before_clouds',{antiSun={ax,ay,az},arcRight={rx,0,rz},arcUp={ux,uy,uz},radius=(state.far or 500)*.90,opacity=state.alpha})
    return true
  end
  return self
end
return M
