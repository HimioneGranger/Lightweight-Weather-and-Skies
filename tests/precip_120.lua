local root=(arg[1] or '../lib/voxel_atmos')..'/'
local n=0;local function check(v,label)assert(v,label);n=n+1 end
local V={require=function()return {}end}
local B=assert(loadfile(root..'PrecipBuffers.lua'))(V)
local P=assert(loadfile(root..'PrecipVisuals.lua'))()
local identity={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
local rows={};for i=1,6 do rows[i]={0,0,0,0,0,0,0}end
local buf={v=rows,n=0,cap=6};function buf:reserve(cap)
 for i=self.cap+1,cap do self.v[i]={0,0,0,0,0,0,0}end;self.cap=math.max(self.cap,cap)
end
local coords={{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}}
local references={};for i=1,6 do references[i]=rows[i]end
for i=1,6 do P.pushRain(buf,i,i+1,i+2,.6,coords[i][1],coords[i][2],-3)end
local legacy={v={},n=6};for i=1,6 do legacy.v[i]={i,i+1,i+2,.6,.6,.6,.6}end
P.tagRain(legacy,2)
for i=1,6 do
 check(buf.v[i]==references[i],'reserved rain row reused')
 for j=1,7 do check(buf.v[i][j]==legacy.v[i][j],'packed visual attributes exactly preserved')end
end
B.step();B.prepareCull(identity,buf)
check(B.visibleSphere(0,0,0,0),'visible sphere retained')
check(not B.visibleSphere(20,0,0,1),'outside geometry rejected')
check(B.visibleSphere(2,0,0,.1),'nearby second-eye guard retained')
local builds=B.stats.cullBuilds;B.prepareCull(identity,{})
check(B.stats.cullBuilds==builds and B.stats.cullHits==1,'same VP planes extracted once across passes')
local bad={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
B.prepareCull(bad,{});check(B.visibleSphere(10000,0,0,0),'degenerate matrix fails open')
B.prepareCull(identity,{});check(not B.visibleSphere(20,0,0,1),'invalid matrix cannot poison cached planes')
local releases,created,draws=0,0,0;local failUpload,failRange=false,false
local function newMesh()
 created=created+1
 return {setVertices=function()if failUpload then error('upload')end end,
  setDrawRange=function()if failRange then error('range')end end,
  release=function()releases=releases+1 end}
end
love={graphics={newMesh=newMesh,draw=function()draws=draws+1 end,setColor=function()end}}
buf.n=6;local mesh=B.upload(nil,{},buf);check(mesh~=nil and created==1,'initial retained mesh')
B.upload(mesh,{},buf);check(created==1,'steady prefix upload keeps mesh')
local old=mesh;buf.n=600;buf:reserve(600);mesh=B.upload(mesh,{},buf)
check(mesh and mesh~=old and releases==1,'grown VBO releases superseded allocation')
old=mesh;buf.n=1600;buf:reserve(1600);failUpload=true
check(B.upload(mesh,{},buf)==nil and releases==2,'failed grown upload releases only new VBO')
failUpload=false;buf.n=600;mesh=B.upload(nil,{},buf)
check(mesh==old,'failed growth preserves prior mesh ownership for retry')
failRange=true;check(B.upload(mesh,{},buf)==nil,'failed draw range prevents stale capacity draw');failRange=false
local emptyCreated=created;buf.n=0;check(B.upload(mesh,{},buf)==nil and created==emptyCreated,'empty geometry keeps capacity without allocation')
buf.n=6;B.upload(mesh,{},buf)
local begins,ends=0,0;local function begin()begins=begins+1 end;local function finish()ends=ends+1 end
local sh=function()return {}end
local vpRight={1,0,0,-.1,0,1,0,0,0,0,1,0,0,0,0,1}
local left={vp=identity,eye={0,0,0}};local right={vp=vpRight,eye={.1,0,0}}
B.cachedDraw(buf,1,left,sh,begin,finish);B.prepareCull(identity,buf);B.upload(mesh,{},buf)
check(B.cachedDraw(buf,1,right,sh,begin,finish)and begins==1 and ends==1,'near stereo world geometry reused with second eye pass')
local teleported={vp={1,0,0,-10,0,1,0,0,0,0,1,0,0,0,0,1},eye={10,0,0}}
check(not B.cachedDraw(buf,1,teleported,sh,begin,finish,true),'wet cull cache cannot survive distant same-frame relocation')
local before=releases;B.invalidate();check(releases==before+1,'invalidate releases owned live VBO once')
local sent={};love.graphics.setBlendMode=function()end;love.graphics.setDepthMode=function()end;love.graphics.setShader=function()end
local uniformShader={send=function(_,key,a,b)sent[#sent+1]=b or a end}
B.beginPass(left,uniformShader);B.beginPass(right,uniformShader)
check(sent[1]==identity and sent[2]==vpRight,'each actual eye sends its own VP even when geometry shared')
-- Actual WorldPrecip simulation: rendering optimizations cannot change downward
-- travel, native surface authority or the private Quest rain/snow ceilings.
local function read(path)local f=assert(io.open(root..path,'rb'));local s=f:read('*a');f:close();return s end
local env={questLitePrivate=true,mod={generation=3}}
function env.mod:read(path)
 local file=path:match('([^/]+)$')
 if file=='Fireflies.lua'then return 'return {update=function()end,draw=function()end,invalidate=function()end}'end
 return read(file)
end
function env.require(name)
 if name=='DesktopWeatherProfile'then return {current=function()end,value=function(_,_,fallback)return fallback end}end
 return {isFirstPerson=function()return false end}
end
local WP=assert(loadfile(root..'WorldPrecip.lua'))(env)
math.randomseed(4726)
local weather={wxId='RAIN',rainIntensity=1,rainSpeed=1,surfaceAt=function()return -10000 end}
WP.update(.01,{0,0,0},weather);local a=WP.sample(1)[1]
WP.update(.01,{0,0,0},weather);local b=WP.sample(1)[1]
local idA,yA=a:match('Rain#(%d+) pos=%([^,]+,([^,]+),')
local idB,yB=b:match('Rain#(%d+) pos=%([^,]+,([^,]+),')
check(idA==idB and tonumber(yB)<tonumber(yA),'same independent raindrop falls downward')
check(WP.rainSurface({},0,0,17)==nil,'private rain does not invent fallback terrain')
check(WP.rainSurface({surfaceAt=function()return 42 end},0,0,17)==42,'native surface provider remains authoritative')
weather.wxId='STORM';weather.rainIntensity=2;WP.update(.01,{0,0,0},weather)
check(WP.describe():match('rain=(%d+)')=='120','storm rain hard ceiling preserved')
weather.wxId='SNOW';weather.rainIntensity=0;weather.snowIntensity=2;WP.update(.01,{0,0,0},weather)
check(WP.describe():match('snow=(%d+)')=='240','snow hard ceiling preserved')
print('precip optimization: '..n..' checks passed')
