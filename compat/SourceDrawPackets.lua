-- Execute authored draw code against a private command recorder. No global
-- graphics state or host function is replaced.
local M={}
local function copy(v)
  if type(v)~='table' then return v end
  local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t
end
local function must(v,e)assert(v,e);return v end
-- Authored modules may cache these objects across map/recorder lifetimes.
-- Their methods must retire through the CURRENT owner, never a captured one.
local function retireObject(o)
  if o.token then o.owner:retire(o.token);o.token=nil end
end
function M.new(api,phase,skyDepth)
  local self={objects={},retired={},phase=phase,draws=0}
  local shader,blend,tint=nil,'alpha',{1,1,1,1}
  local g={}
  local function retire(token)if token then self.retired[#self.retired+1]=token end end
  function self:retire(token)retire(token)end
  function self:detach(o)
    if o.owner~=self then return end
    if o.token then api:release(o.token);o.token=nil end
    o.owner=nil;o.lastDraw=nil
    for i=#self.objects,1,-1 do
      if self.objects[i]==o then table.remove(self.objects,i)end
    end
  end
  local function adopt(o)
    assert(not self.released,'packet recorder is released')
    if o.owner==self then return end
    if o.owner then o.owner:detach(o)end
    o.owner=self;o.lastDraw=nil
    self.objects[#self.objects+1]=o
  end
  function self:begin()
    assert(not self.released,'packet recorder is released')
    for _,t in ipairs(self.retired)do api:release(t)end
    self.retired={}
    self.serial=(self.serial or 0)+1
    -- Original stream meshes can grow and be replaced without release().
    -- Reclaim only resources absent from the previous completed packet frame.
    local retained={}
    for _,o in ipairs(self.objects)do
      if o.format and o.lastDraw and o.lastDraw<self.serial-1 then
        if o.token then api:release(o.token);o.token=nil end
        o.owner=nil;o.lastDraw=nil
      else retained[#retained+1]=o end
    end
    self.objects=retained
    self.draws=0;shader=nil;blend='alpha';tint={1,1,1,1}
  end
  function g.newShader(source)
    local recenter=false
    if skyDepth and source:find('vp*vertex_position',1,true) then
      -- Recorded sky vertices use the last completed camera; VP belongs to
      -- the current render. Translate only their origin to the current eye.
      source=source:gsub('uniform mat4 vp;', 'uniform mat4 vp;\n uniform vec3 eye;\n uniform vec3 packetEye;')
      source=source:gsub('vp%*vertex_position','vp*vec4(vertex_position.xyz-packetEye+eye,1.0)')
      recenter=true
    end
    local s={source=source,uniforms={}}
    s.recenter=recenter
    function s:send(name,a,b)
      if name=='vp' or name=='eye' then return end
      if self.token and self.uniforms[name]==nil then retireObject(self)end
      self.uniforms[name]=copy(b or a)
    end
    function s:hasUniform(name)return self.source:find(name,1,true)~=nil end
    function s:release()retireObject(self)end
    adopt(s);return s
  end
  function g.newMesh(format,vertices,mode)
    assert(mode=='triangles','only authored triangle effects supported')
    local m={format=copy(format),vertices=type(vertices)=='table' and copy(vertices)or {},capacity=type(vertices)=='number' and vertices or #vertices}
    function m:setVertices(v,start,count)
      start=start or 1;count=count or #v
      assert(start+count-1<=self.capacity,'mesh capacity exceeded')
      for i=1,count do self.vertices[start+i-1]=copy(v[i])end
      self.dirty=true
    end
    function m:setDrawRange(first,count)self.first=first;self.count=count;self.dirty=true end
    function m:release()retireObject(self)end
    adopt(m);return m
  end
  function g.setShader(s)shader=s end
  function g.getShader()return shader end
  function g.setBlendMode(b,a)assert((b=='alpha'or b=='add')and (not a or a=='alphamultiply'));blend=b end
  function g.getBlendMode()return blend,'alphamultiply'end
  function g.setColor(r,gc,b,a)tint=type(r)=='table' and copy(r)or {r,gc,b,a or 1}end
  function g.getColor()return unpack(tint)end
  function g.setDepthMode()end
  function g.draw(mesh)
    assert(shader,'authored effect requires a shader')
    if shader.recenter then shader.uniforms.packetEye=copy(assert(self.eye,'sky camera required'))end
    adopt(mesh);adopt(shader)
    mesh.lastDraw=self.serial or 0
    local rows={};local first=mesh.first or 1
    for i=first,first+(mesh.count or #mesh.vertices)-1 do rows[#rows+1]=mesh.vertices[i]end
    if #rows==0 then return end
    if mesh.uploaded~=#rows then retire(mesh.token);mesh.token=nil end
    if mesh.token then must(api:updateMesh(mesh.token,rows))
    else mesh.token=must(api:mesh{format=mesh.format,vertices=rows});mesh.uploaded=#rows end
    shader.token=shader.token or must(api:material{source=shader.source,uniforms=copy(shader.uniforms),skyDepth=skyDepth})
    must(api:enqueue{phase=self.phase,material=shader.token,mesh=mesh.token,uniforms=copy(shader.uniforms),blend=blend,tint=copy(tint)})
    self.draws=self.draws+1
  end
  self.graphics=g
  function self:load(source,namespace,realLove,label)
    local proxy=setmetatable({graphics=g},{__index=realLove})
    local chunk=assert((loadstring or load)("local _, love = ...;\n"..source,label))
    return chunk(namespace,proxy)
  end
  function self:camera(c)
    self.eye=copy(c.eye)
    local viewportHeight=c.viewportHeight
    if not viewportHeight and love and love.graphics and love.graphics.getHeight then
      local ok,height=pcall(love.graphics.getHeight)
      if ok then viewportHeight=height end
    end
    return {eye=copy(c.eye),focus=copy(c.focus),far=c.far,camera={far=c.far},
      stableStarBillboards=skyDepth==true,fov=c.fov,viewportHeight=viewportHeight,
      vp={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},
      beginEffect=function(s)shader=s;return true end,endEffect=function()shader=nil end}
  end
  function self:release()
    for _,o in ipairs(self.objects)do
      if o.owner==self then
        if o.token then api:release(o.token);o.token=nil end
        o.owner=nil;o.lastDraw=nil
      end
    end
    for _,t in ipairs(self.retired)do api:release(t)end
    self.objects={};self.retired={}
    self.released=true
  end
  return self
end
return M
