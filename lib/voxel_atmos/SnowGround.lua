-- Snow-only ground frost for 1.2.0. Puddles and ripple rings are excluded.
-- Numeric native surface heights cannot classify water/materials or roofs; five
-- matching footprint samples only prove a locally flat native-rendered surface.
local V,B=...
local M={};local floor,min,max=math.floor,math.min,math.max
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<10000 end
local function get(name)local ok,value=pcall(V.require,name);return ok and value or {}end
local Scene,State=get('Scene'),get('WeatherState')
local patches={}
for i=1,25 do patches[i]={ready=false,snow=0,nextProbe=0}end
local buf={v={},n=0,cap=150}
for i=1,150 do buf.v[i]={0,0,0,0,0,0,0}end
function buf:reserve(n)
 for i=self.cap+1,n do self.v[i]={0,0,0,0,0,0,0}end
 self.cap=max(self.cap,n)
end
local stats={enabled=false,available=false,probes=0,surfaceCalls=0,rejected=0,patches=0,rings=0,
 drawCalls=0,uploads=0,vertices=0,revisionResets=0,
 waterQueries=0,waterUnknown=0,waterCells=0,materialAPI=false}
local now,cursor,mesh,shader=0,0,nil,nil
local mapKey,revision,samplerPresent,cx,cz,enabled=nil,nil,false,nil,nil,false
local world,worldCached=nil,false
local function seed(x,z)local v=math.sin(x*127.1+z*311.7)*43758.5453;return v-floor(v)end
local function slot(x,z)return(x%5)*5+(z%5)+1 end
function M.available()
 return type(Scene.now)=='table'and finite(State.level)
end
local function reset()
 for i=1,25 do local p=patches[i];p.ready=false;p.snow=0;p.nextProbe=0;p.cellX=nil;p.cellZ=nil end
 cx,cz=nil,nil;cursor=0
 world,worldCached=nil,false
 if B and B.changed then B.changed()end
end
local function waterAt(p)
 if not worldCached then
  worldCached=true
  if V.mod and type(V.mod.find)=='function'then
   local ok,h=pcall(V.mod.find,'FRLG_VOXEL')
   world=ok and h and h.exports and h.exports.vrHost and h.exports.vrHost.world or nil
  end
 end
 stats.materialAPI=world and type(world.isWater)=='function'or false
 if not stats.materialAPI then return false,true end -- height-only older host
 stats.waterQueries=stats.waterQueries+1
 local ok,value=pcall(world.isWater,p.x/16,p.z/16)
 if not ok or type(value)~='boolean'then stats.waterUnknown=stats.waterUnknown+1;return nil,false end
 if value then stats.waterCells=stats.waterCells+1 end
 return value,true
end
local function approach(value,target,delta)
 return value+max(-delta,min(delta,target-value))
end
local function probe(p,sampler)
 stats.probes=stats.probes+1
 local water,known=waterAt(p)
 if not known then p.ready=false;p.snow=0;p.nextProbe=now+2+p.seed*2;stats.rejected=stats.rejected+1;return end
 p.water=water
 local ok,y=pcall(sampler,p.x,p.z);stats.surfaceCalls=stats.surfaceCalls+1
 local valid=ok and finite(y)
 if valid then
  for i=1,4 do
   local dx=i<=2 and -6 or 6;local dz=i%2==1 and -6 or 6
   local good,h=pcall(sampler,p.x+dx,p.z+dz);stats.surfaceCalls=stats.surfaceCalls+1
   if not good or not finite(h)or math.abs(h-y)>.01 then valid=false;break end
  end
 end
 p.ready=valid and true or false
 if valid then p.y=y+.055;p.nextProbe=now+2.5+p.seed
 else p.snow=0;p.nextProbe=now+2+p.seed*2;stats.rejected=stats.rejected+1 end
end
function M.update(dt,focus,wx)
 local delta=finite(dt)and max(0,min(.1,dt))or 0;now=now+delta
 stats.available=M.available();local s=Scene.now
 local currentMap=type(s)=='table'and s.mapId
 local currentRevision=wx and wx.surfaceRevision or(type(s)=='table'and(s.surfaceRevision or s.mapRevision))
 local present=wx and type(wx.surfaceAt)=='function'or false
 if currentMap~=mapKey or currentRevision~=revision or present~=samplerPresent then
  reset();mapKey,revision,samplerPresent=currentMap,currentRevision,present;stats.revisionResets=stats.revisionResets+1
 end
 enabled=stats.available and State.level>0 and s.visible=='world'and s.outdoor==true and not s.indoors
  and currentMap~=nil and present and type(focus)=='table'and finite(focus[1])and finite(focus[3])
 stats.enabled=enabled and true or false
 if not enabled then
  for i=1,25 do patches[i].snow=0 end
  stats.patches,stats.rings,stats.vertices=0,0,0
  return
 end
 local nx,nz=floor(focus[1]/16),floor(focus[3]/16)
 if nx~=cx or nz~=cz then
  cx,cz=nx,nz
  for x=nx-2,nx+2 do for z=nz-2,nz+2 do
   local p=patches[slot(x,z)]
   if p.cellX~=x or p.cellZ~=z then
    p.cellX,p.cellZ=x,z;p.x,p.z=x*16+8,z*16+8;p.seed=seed(x,z)
    -- Sparse, stable scatter inside the verified +/-6 footprint. Terrain
    -- cache keeps the full grid; only visual finishes are thinned.
    p.finish=seed(x+17,z-29)>.48
    p.offsetX=(seed(x+43,z+11)*2-1)*1.8
    p.offsetZ=(seed(x-13,z+71)*2-1)*1.8
    p.radius=1.6+seed(x+101,z-57)*2.6
    p.ready=false;p.snow=0;p.nextProbe=now
   end
  end end
 end
 local snow=finite(wx.snowIntensity)and max(0,min(1,wx.snowIntensity))or 0
 local active=0
 for i=1,25 do local p=patches[i]
  if p.ready then
   local snowTarget=p.water and 0 or snow
   p.snow=approach(p.snow,snowTarget,delta/(snowTarget>p.snow and 4 or 7))
   if p.finish and now<=p.nextProbe and p.snow>.015 then active=active+1 end
  end
 end
 -- Exactly one due cell per update; dry/faded empty grids do not probe.
 for attempt=1,25 do
  cursor=cursor%25+1;local p=patches[cursor]
  if p.cellX and now>=p.nextProbe and max(snow,p.snow)>.015 then probe(p,wx.surfaceAt);break end
 end
 stats.patches,stats.rings=active,0
end
local format={{'VertexPosition','float',3},{'GroundData','float',4}}
local uv={0,0,1,0,1,1,0,0,1,1,0,1}
local source=[[
#ifdef VERTEX
extern mat4 vp;attribute vec4 GroundData;varying vec4 vGround;
vec4 position(mat4 t,vec4 v){vGround=GroundData;return vp*vec4(v.xyz,1.0);}
#endif
#ifdef PIXEL
varying vec4 vGround;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
 vec2 p=vGround.xy*2.0-1.0;float seed=fract(vGround.z)*4.0;
  float angle=seed*6.2831853;float c=cos(angle);float s=sin(angle);
  vec2 q=vec2(c*p.x-s*p.y,s*p.x+c*p.y);
  q*=vec2(.82+.35*seed,1.20-.25*seed);
  float edge=length(q)+.18*sin(q.x*5.0+seed*6.0)*sin(q.y*4.0+seed*3.0)
    +.10*sin(q.y*7.0+seed*9.0);
  float mask=1.0-smoothstep(.80,1.08,edge);
   float grain=fract(sin(dot(floor((p+1.0)*9.0),vec2(12.9898,78.233))+seed*43.0)*43758.5453);
   mask*=.82+.18*smoothstep(.70,.86,grain);
 return vec4(vec3(.96,.98,1.0),vGround.a*mask)*color;
}
#endif
]]
local function getShader()
 if shader==nil then
  local ok,s=pcall(love.graphics.newShader,source)
  if ok then shader=s;stats.error=nil else shader=false;stats.error=tostring(s)end
 end
 return shader
end
local function quad(x,y,z,r,kind,a)
 for j=1,6 do
  local u,v=uv[j*2-1],uv[j*2];local row=buf.v[buf.n+j]
  row[1],row[2],row[3]=x+(u*2-1)*r,y,z+(v*2-1)*r
  row[4],row[5],row[6],row[7]=u,v,kind,a
 end
 buf.n=buf.n+6
end
function M.draw(view,beginPass,endPass)
 if not enabled or not(view and view.vp)or not(B and beginPass and endPass)then return false end
 if not getShader()then return false end
 local cached,count=B.cachedDraw(buf,1,view,getShader,beginPass,endPass)
 if cached then stats.vertices=count or 0;stats.drawCalls=stats.drawCalls+1;return true end
 buf.n=0;B.prepareCull(view.vp,buf)
 for i=1,25 do local p=patches[i]
  if p.finish and p.ready and now<=p.nextProbe then
   local amount=p.snow
   if amount>.015 then
    local r=p.radius;local x,z=p.x+p.offsetX,p.z+p.offsetZ
    if B.visibleSphere(x,p.y,z,r*1.415)then
     quad(x,p.y,z,r,1+p.seed*.249,amount*.84*(.8+p.seed*.2))
    end
   end
  end
 end
 stats.vertices=buf.n;mesh=B.upload(mesh,format,buf)
 if not mesh then return false end
 beginPass(view,shader);pcall(love.graphics.setColor,1,1,1,1)
 local ok,err=pcall(love.graphics.draw,mesh);endPass(view)
 stats.drawCalls=stats.drawCalls+1;stats.uploads=stats.uploads+1
 if ok then stats.error=nil else stats.error=tostring(err)end
 return ok
end
function M.invalidate()
 reset();enabled=false;stats.enabled=false;stats.patches,stats.rings,stats.vertices=0,0,0
 stats.error=nil
 if B and B.release then B.release(buf)end
 mesh=nil
 if shader and shader.release then pcall(shader.release,shader)end;shader=nil
 mapKey,revision,samplerPresent=nil,nil,false
end
function M.status()return stats end
return M
