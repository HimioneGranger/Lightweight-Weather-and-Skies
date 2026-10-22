-- Bounded world-cell fireflies; no lights, textures, collisions or global RNG.
local V,B=...
local M={active=0,groundSamples=0,habitatSamples=0,eyePasses=0,lastVertices=0}
local env=V.mod and V.mod.exports and V.mod.exports.lib or V
local function get(name)local ok,v=pcall(env.require,name);return ok and v or {} end
local Scene,TOD,State=get('Scene'),get('TimeOfDay'),get('WeatherState')
local precipitationKeys={'rainIntensity','snowIntensity','sandIntensity','ashIntensity','debrisIntensity'}
local rows,bugs={},{}
for i=1,108 do rows[i]={0,0,0,0,0,0,0} end
for i=1,18 do bugs[i]={x=0,y=0,z=0,a=0,hue=0} end
local buf={v=rows,n=0,cap=108,reserve=function(self,n)
 for i=self.cap+1,n do self.v[i]={0,0,0,0,0,0,0} end;self.cap=n end}
local fmt={{'VertexPosition','float',3},{'RainTint','float',4}}
local mesh,shader,time=nil,nil,0
local halfSize=.60 -- 33% larger, same six-vertex billboard and bounded pool.
local uv={0,0,1,0,1,1,0,0,1,1,0,1}
local function hash(x,z,k)local n=math.sin(x*127.1+z*311.7+k*74.7)*43758.5453;return n-math.floor(n)end
local world,nextWorld=nil,0
local Habitat=assert(load(V.mod:read('lib/voxel_atmos/FireflyHabitat.lua'),'@FireflyHabitat.lua'))()
local ecology=Habitat.new()
local function refreshWorld()
 if time<nextWorld then return end;nextWorld=time+2
 if V.mod and V.mod.find then
  local ok,m=pcall(V.mod.find,'FRLG_VOXEL')
  world=ok and m and m.exports and m.exports.vrHost and m.exports.vrHost.world or nil
 end
end
function M.update(dt,focus,weather)
 time=time+math.max(0,math.min(.1,tonumber(dt) or 0));M.active=0
 local scene=Scene.now or {};local wx=weather or {}
 if type(focus)~='table' then return end
 for i=1,3 do local n=focus[i];if type(n)~='number' or n~=n or math.abs(n)>1e7 then return end end
 if not focus or wx.fireflies==false or scene.outdoor~=true or scene.indoors or scene.visible=='battle' or scene.visible=='hidden'
 or not(TOD.isNight and TOD.isNight()) or (tonumber(State.level) or 0)<=0 then return end
 local id=tostring(wx.wxId or ''):upper()
 if id~='CLEAR' and id~='PARTLY_CLOUDY' and id~='MOSTLY_CLOUDY' then return end
 for _,key in ipairs(precipitationKeys)do
 if (tonumber(wx[key]) or 0)>.02 then return end end
 refreshWorld()
 local density=Habitat.update(ecology,time,focus,scene,world,wx.surfaceRevision)
 if density<=0 then return end
 local changed=false
 local cx,cz=math.floor(focus[1]/48),math.floor(focus[3]/48)
 local index=0
 for dz=-1,1 do for dx=-1,1 do for k=1,2 do
 index=index+1;local b=bugs[index];local gx,gz=cx+dx,cz+dz
 local moved=b.gx~=gx or b.gz~=gz or b.mapId~=scene.mapId
 if moved then
   b.gx,b.gz,b.mapId=gx,gz,scene.mapId
   b.seed=hash(gx,gz,k);b.homeX=(gx+hash(gx,gz,k+3))*48;b.homeZ=(gz+hash(gx,gz,k+6))*48
 end
 -- Wrappers recreate surfaceAt closures and focusY follows the eye. Neither
 -- changes terrain at a fixed world X/Z. Refresh by map/cell/revision and a
 -- staggered bounded TTL; sampler availability transitions remain immediate.
 local hasSampler=type(wx.surfaceAt)=='function'
 if moved or b.hasSampler~=hasSampler or b.revision~=wx.surfaceRevision or time>=(b.refreshAt or 0)then
   b.hasSampler,b.revision=hasSampler,wx.surfaceRevision
   b.refreshAt=time+.9+b.seed*1.2
   local ok,ground=false,nil
   if hasSampler then ok,ground=pcall(wx.surfaceAt,b.homeX,b.homeZ);M.groundSamples=M.groundSamples+1 end
   b.valid=ok and type(ground)=='number' and ground==ground and math.abs(ground)<=10000
   b.ground=b.valid and ground or 0
   if b.valid and world and world.isWater then
     local waterOk,water=pcall(world.isWater,b.homeX/16,b.homeZ/16);M.habitatSamples=M.habitatSamples+1
     if not waterOk or water~=false then b.valid=false end
   end
   if b.valid and world and type(world.behavior)=='function'then
     local materialOk,material=pcall(world.behavior,b.homeX/16,b.homeZ/16)
     M.habitatSamples=M.habitatSamples+1
     if materialOk and material==0x06 then b.valid=false end
   end
 end
 local seed=b.seed;local period=6.0+seed*3.0
 local phase=(time+seed*period)%period
 -- Gentle independent breaths, with a dark interval rather than a sharp flash.
 local rise,hold,fall=1.4,.6,2.2
 local pulse=0
 if phase<rise then
   local t=phase/rise;pulse=t*t*(3-2*t)
 elseif phase<rise+hold then pulse=1
 elseif phase<rise+hold+fall then
   local t=(phase-rise-hold)/fall;pulse=1-t*t*(3-2*t)
 end
 pulse=pulse*.85
 b.x=b.homeX+math.sin(time*.43+seed*30)*3
 b.z=b.homeZ+math.sin(time*.31+seed*17)*3
 b.y=b.ground+2+seed*8+math.sin(time*.67+seed*13)*1.2
 local eligible=b.valid and hash(gx,gz,k+91)<density
 if b.eligible~=eligible then changed=true;b.eligible=eligible end
 b.a=eligible and pulse or 0;b.hue=seed
 if b.eligible then M.active=M.active+1 end
 end end end
 if changed and B.changed then B.changed()end
end
local source=[[
#ifdef VERTEX
extern mat4 vp;attribute vec4 RainTint;varying vec4 vBug;
vec4 position(mat4 t,vec4 v){vBug=RainTint;return vp*vec4(v.xyz,1.0);}
#endif
#ifdef PIXEL
varying vec4 vBug;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
 vec2 p=vBug.rg*2.0-1.0;float d=dot(p,p);
 float core=(1.0-smoothstep(0.0,0.12,d))*.78;
 float halo=1.0-smoothstep(0.0,1.0,d);halo=halo*halo*.22;
 return vec4(0.80+vBug.b*.20,0.92,0.16,vBug.a*(core+halo))*color;
}
#endif
]]
function M.draw(view,beginPass,endPass)
 if M.active==0 or not(view and view.vp and view.eye) then return end
 if shader==nil then local ok,s=pcall(love.graphics.newShader,source);shader=ok and s or false end
 if not shader then return end
 local functionShader=M.getShader
 local hit,n=B.cachedDraw(buf,M.active,view,functionShader,beginPass,endPass)
 if hit then M.lastVertices=n or 0;if (n or 0)>=3 then M.eyePasses=M.eyePasses+1 end;return end
 buf.n=0
 for i=1,18 do local b=bugs[i]
 if b.a>.01 then
 local dx,dz=view.eye[1]-b.x,view.eye[3]-b.z;local len=math.sqrt(dx*dx+dz*dz)
 local distance2=dx*dx+(view.eye[2]-b.y)^2+dz*dz
 if len>.001 and distance2>1 and distance2<14400 then
 local distance=math.sqrt(distance2)
 local rx,rz=-dz/len*halfSize,dx/len*halfSize
 local fade=math.min(1,(distance-1)/3)*math.min(1,(120-distance)/24)
 for j=1,6 do local u,v=uv[j*2-1],uv[j*2];buf.n=buf.n+1;local row=rows[buf.n]
 row[1],row[2],row[3]=b.x+(u*2-1)*rx,b.y+(1-v*2)*halfSize,b.z+(u*2-1)*rz
 row[4],row[5],row[6],row[7]=u,v,b.hue,b.a*fade
 end
 end end end
 mesh=B.upload(mesh,fmt,buf)
 M.lastVertices=buf.n
 if mesh then beginPass(view,shader);love.graphics.setColor(1,1,1,1);love.graphics.draw(mesh);endPass(view);M.eyePasses=M.eyePasses+1 end
end
function M.getShader()return shader end
function M.invalidate()
 M.active=0;mesh=nil;shader=nil
 world=nil;nextWorld=0;ecology=Habitat.new()
 for i=1,18 do bugs[i].gx=nil end
end
-- Read-only diagnostics; does not expose mutable particle storage.
function M.sample(i)local b=bugs[i or 1];return b.x,b.y,b.z,b.a end
function M.status()return {active=M.active,groundSamples=M.groundSamples,habitatSamples=M.habitatSamples,
 density=ecology.density,habitat=ecology.kind,treeDensity=ecology.trees,shoreFraction=ecology.water,sandFraction=ecology.sand,desertFraction=ecology.desert,ecologyProbes=ecology.probes,
 eyePasses=M.eyePasses,lastVertices=M.lastVertices,shaderReady=shader~=nil and shader~=false}end
if V.mod and V.mod.exports then V.mod.exports.gen3Fireflies={status=M.status}end
return M
