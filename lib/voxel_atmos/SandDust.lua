-- Bounded wind-blown dust wisps complement existing sand grains. No lights,
-- textures, global RNG, collision probes or camera-parented particle motion.
local V,B=...
local M={active=0,maxParticles=18,stats={updates=0,respawns=0,surfaceCalls=0,draws=0,vertices=0}}
local env=V.mod and V.mod.exports and V.mod.exports.lib or V
local function get(name)local ok,v=pcall(env.require,name);return ok and v or {}end
local Scene,State=get('Scene'),get('WeatherState')
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<1e8 end
local function hash(i,k)local n=math.sin(i*127.1+k*311.7)*43758.5453;return n-math.floor(n)end
local particles,rows={},{}
for i=1,18 do particles[i]={life=0,maxLife=0,serial=0}end
for i=1,108 do rows[i]={0,0,0,0,0,0,0}end
local buf={v=rows,n=0,cap=108,reserve=function(self,n)
 for i=self.cap+1,n do self.v[i]={0,0,0,0,0,0,0}end;self.cap=n
end}
local fmt={{'VertexPosition','float',3},{'RainTint','float',4}}
local uv={0,0,1,0,1,1,0,0,1,1,0,1}
local mesh,shader,time=nil,nil,0
local targetCount=0
local function spawn(p,i,focus,wx,windX,windZ)
 p.serial=p.serial+1;local seed=hash(i,p.serial);local angle=seed*math.pi*2
 local radius=24+hash(i+13,p.serial)*88
 p.x=focus[1]+math.cos(angle)*radius;p.z=focus[3]+math.sin(angle)*radius
 p.valid=false;p.maxLife=0
 p.ground=nil
 if type(wx.surfaceAt)=='function'then
  M.stats.surfaceCalls=M.stats.surfaceCalls+1
  local ok,y=pcall(wx.surfaceAt,p.x,p.z)
  if ok and finite(y)then p.ground=y end
 end
 if p.ground==nil then
  -- Unknown terrain is not a frame-rate-driven collision query loop.
  p.retryAt=time+.5+hash(i+37,p.serial)*.5
  return false
 end
 p.retryAt=nil
 p.valid=true
 p.y=p.ground+1+seed*8;p.seed=seed;p.life=0;p.maxLife=2.5+seed*2
 p.speed=14+seed*18;p.halfWidth=3+seed*3;p.halfHeight=.6+seed*.7
 p.vx,p.vz=windX*p.speed,windZ*p.speed
 M.stats.respawns=M.stats.respawns+1
 return true
end
function M.update(dt,focus,weather)
 M.stats.updates=M.stats.updates+1;M.active=0;targetCount=0
 local wx=weather or {};local scene=Scene.now or {};local id=tostring(wx.wxId or ''):upper()
 local strength=tonumber(wx.sandIntensity)
 local level=tonumber(State.level)
 if not(focus and finite(focus[1])and finite(focus[2])and finite(focus[3]))
  or scene.outdoor~=true or scene.indoors or scene.visible=='hidden'
  or not finite(level)or level<=0 or wx.sandDust==false
  or (id~='SANDSTORM'and id~='DUSTSTORM')or not finite(strength)or strength<=.02 then
  for i=1,18 do particles[i].maxLife=0 end
  return
 end
 dt=math.max(0,math.min(.1,tonumber(dt)or 0));time=time+dt
 local windX,windZ=tonumber(wx.windX),tonumber(wx.windZ)
 if not finite(windX)or not finite(windZ)then windX,windZ=.55,.25 end
 local length=math.sqrt(windX*windX+windZ*windZ)
 if length<.001 then windX,windZ=.91,.414 else windX,windZ=windX/length,windZ/length end
 local windScale=tonumber(wx.rainWind)or 1
 if not finite(windScale)then windScale=1 end
 windScale=math.max(.3,math.min(2,windScale))
 local count=math.min(18,math.max(1,math.floor(18*math.min(1,strength)+.5)))
 targetCount=count
 local gust=.78+.22*math.sin(time*.9)
 for i=1,count do local p=particles[i]
  local dx,dz=(p.x or focus[1])-focus[1],(p.z or focus[3])-focus[3]
  if (p.valid and (p.life>=p.maxLife or dx*dx+dz*dz>160*160))
    or (not p.valid and time>=(p.retryAt or 0))then spawn(p,i,focus,wx,windX,windZ)end
  if p.valid then
  M.active=M.active+1
  p.life=p.life+dt;p.vx=windX*p.speed*windScale*gust;p.vz=windZ*p.speed*windScale*gust
  p.x=p.x+p.vx*dt;p.z=p.z+p.vz*dt
  p.y=p.ground+1+p.seed*8+math.sin(time*1.3+p.seed*21)*.45
  local fade=math.min(1,p.life/.4)*math.min(1,math.max(0,(p.maxLife-p.life)/.6))
  p.alpha=(.055+p.seed*.025)*math.min(1,strength)*fade
  end
 end
end
local source=[[
#ifdef VERTEX
extern mat4 vp;attribute vec4 RainTint;varying vec4 vDust;
vec4 position(mat4 transform,vec4 vertex){vDust=RainTint;return vp*vec4(vertex.xyz,1.0);}
#endif
#ifdef PIXEL
varying vec4 vDust;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
 vec2 p=vDust.rg*2.0-1.0;
 float edge=1.0-smoothstep(.05,1.0,dot(p,p));
 float curl=.72+.28*sin(p.x*6.0+p.y*3.0+vDust.b*17.0);
 return vec4(.78,.65,.43,vDust.a*edge*edge*curl)*color;
}
#endif
]]
function M.getShader()return shader end
function M.draw(view,beginPass,endPass)
 if M.active==0 or not(view and view.vp and view.eye and B)then return false end
 local g=love.graphics
 if shader==nil then local ok,s=pcall(g.newShader,source);shader=ok and s or false end
 if not shader then return false end
 g.push('all')
 local ok,err=pcall(function()
  g.setMeshCullMode('none')
  if B.cachedDraw(buf,M.active,view,M.getShader,beginPass,endPass)then return end
  B.prepareCull(view.vp,buf);buf.n=0
  local eye=view.eye
  for i=1,targetCount do local p=particles[i]
   if p.valid then
   local dx,dy,dz=eye[1]-p.x,eye[2]-p.y,eye[3]-p.z
   local horizontal=math.sqrt(dx*dx+dz*dz);local distance=math.sqrt(horizontal*horizontal+dy*dy)
   if distance>12 and distance<160 and horizontal>.001 and p.alpha>.001
     and B.visibleSphere(p.x,p.y,p.z,p.halfWidth+1.5)then
    -- A <=.08 angular half-width cap prevents a nearby wisp filling an eye.
    local width=math.min(p.halfWidth,distance*.08);local height=math.min(p.halfHeight,distance*.025)
    local rx,rz=-dz/horizontal*width,dx/horizontal*width
    local fade=math.min(1,(distance-12)/16)*math.min(1,(160-distance)/32)
    for j=1,6 do local u,v=uv[j*2-1],uv[j*2];buf.n=buf.n+1;local row=rows[buf.n]
     row[1],row[2],row[3]=p.x+(u*2-1)*rx,p.y+(1-v*2)*height,p.z+(u*2-1)*rz
     row[4],row[5],row[6],row[7]=u,v,p.seed,p.alpha*fade
    end
   end
   end
  end
  M.stats.vertices=buf.n;mesh=B.upload(mesh,fmt,buf)
  if mesh then beginPass(view,shader);g.setColor(1,1,1,1);g.draw(mesh);endPass(view)end
 end)
 g.pop();M.error=not ok and tostring(err)or nil
 if ok then M.stats.draws=M.stats.draws+1 end
 return ok
end
function M.invalidate()
 M.active=0;targetCount=0;mesh=nil;shader=nil
 for i=1,18 do particles[i].maxLife=0;particles[i].valid=false;particles[i].retryAt=nil end
end
function M.sample(i)
 local p=particles[i or 1];return p.x,p.y,p.z,p.alpha,p.vx,p.vz
end
return M
