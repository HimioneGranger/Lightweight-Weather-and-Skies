local M={}
local FORMAT={{'VertexPosition','float',3},{'VertexTexCoord','float',2},{'VertexShade','float',1}}
local function must(v,e)assert(v,e);return v end
local function loadSource(source,ns,proxy)
 local f=assert((loadstring or load)("local _, love = ...;\n"..source,'@weather/cloud-source'))
 return f(ns,proxy)
end
function M.new(api,sources,realLove,clock)
 local self={};local vx={};local motion,fog,start,haze,cut
 local light=assert((loadstring or load)(sources.light))()
 local space=assert((loadstring or load)(sources.space))()
 local ns={require=function(name)
  return assert(({Mat4={translate=function(x,y,z)return {x,y,z}end},Voxel3D=vx,
    CloudLight=light,CloudSpace=space,DayNight={time=clock},Sky={haze=function()return self.haze or {1,1,1}end}})[name],name)
 end}
 local proxy={image=realLove.image,graphics={newImage=function(data)
  return {data=data,setFilter=function()end,setWrap=function()end}
 end}}
 function vx.newMesh(vertices,indices)return {vertices=vertices,indices=indices}end
 function vx.glass()end;function vx.seams()end
 function vx.skyDeck(on,d,s,h,c,m)if on then fog,start,haze,cut,motion=d,s,h,c,m end end
 local reflect=realLove.graphics.newShader(sources.shader)
 local allowed={}
 for name in sources.shader:gmatch('uniform%s+[^;]-([%w_]+)%s*;')do
  if reflect:hasUniform(name)then allowed[name]=true end
 end
 reflect:release()
 assert(allowed.cloudMorph,'cloud motion uniform missing')
 function vx.draw(mesh,img,position)
  local rows={}
  for _,i in ipairs(mesh.indices)do local v=mesh.vertices[i];rows[#rows+1]={v[1]+position[1],v[2]+position[2],v[3]+position[3],v[4],v[5],v[6]}end
  if self.mesh then must(api:updateMesh(self.mesh,rows))else self.mesh=must(api:mesh{format=FORMAT,vertices=rows})end
  if not self.image then local d=img.data;self.image=must(api:image{width=d:getWidth(),height=d:getHeight(),rgba=d:getString(),wrap='repeat'})end
  local m=motion;local sf=m.stormFront or {0,0,0,0}
  local u={fogInfo={fog or 0,start or 0,0,0},fogColor=haze or {1,1,1},alphaCut=cut,
   cloudMorph={m.phase,m.warp,0,1},cloudShape={m.shapeA,m.shapeB,m.density,m.steps},
   cloudMaterial={1-m.coverage,m.softness},cloudColor=m.color,cloudLight=m.light,
   cloudFade=1-m.opacity,cloudOvercast=m.overcast,cloudLightning=m.lightning or {0,0,0,0},
   stormFront={sf[1],sf[2],sf[3],sf[4]},stormAxis=sf.axis or {1,0},stormCanopy=sf.canopy or 0,
   stormFinish={sf.fill or 0,sf.ready or 0},dayTint=self.dayTint or {1,1,1}}
  local filtered={}
  for k,v in pairs(u)do if allowed[k]then filtered[k]=v end end
  for k in pairs(allowed)do assert(k=='vp'or k=='eye'or filtered[k]~=nil,'unbound cloud uniform '..k)end
  self.material=self.material or must(api:material{source=sources.shader,uniforms=filtered,skyDepth=true})
  must(api:enqueue{phase='sky_deck',material=self.material,mesh=self.mesh,image=self.image,uniforms=filtered})
 end
 self.clouds=loadSource(sources.clouds,ns,proxy)
 -- Packet-rendered rain needs a broad cloud bank, but must not alter the
 -- approved direct Quest cloud source or the actual rain particle budget.
 function self:ceilingAt(x,z)
  local sf=self.clouds.stormFrontProvider and self.clouds.stormFrontProvider()
  local altitude=self.clouds.ALT or 1920
  if not sf or (sf[4] or 0)<=0 then return altitude end
  -- Keep authored lightning just below the same moving shelf as the shader.
  local function smooth(a,b,v)local t=math.max(0,math.min(1,(v-a)/(b-a)));return t*t*(3-2*t)end
  local dx,dz=(x-sf[1])*sf[3],(z-sf[2])*sf[3]
  local axis=sf.axis or {1,0}
  local along=dx*axis[1]+dz*axis[2]
  local across=(-dx*axis[2]+dz*axis[1])/2.6
  local edge=along+.05*math.sin(across*7)
  local leading=1-smooth(.65,1,edge)
  local lateral=1-smooth(.7,1,math.abs(across))
  local front=math.max(leading*smooth(-1.4,-.6,along)*lateral*sf[4],sf.canopy or 0)
  local shelf=leading*smooth(.25,.65,edge)*lateral*sf[4]
  return altitude-65*front-110*shelf
 end
 function self:draw(camera,dt,tint,haze)
  self.dayTint=tint;self.haze=haze;self.clouds.update(dt)
  if camera.overhead then assert(self.clouds.draw(camera.eye),'original cloud source declined')end
 end
 function self:release()
  for _,name in ipairs({'image','mesh','material'})do if self[name]then api:release(self[name]);self[name]=nil end end
 end
 return self
end
return M
