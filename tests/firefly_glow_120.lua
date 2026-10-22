local root=assert(arg[1]);local checks=0
local function check(v,m)checks=checks+1;assert(v,m)end
local libs={Scene={now={outdoor=true,visible='field',mapId='FOREST',environment='FOREST'}},TimeOfDay={isNight=function()return true end},WeatherState={level=1}}
local V={require=function(n)return libs[n]end}
V.mod={read=function(_,p)local f=assert(io.open(root..'/'..p:match('[^/]+$')));local s=f:read('*a');f:close();return s end,exports={}}
local verts,shaderSource
local B={changed=function()end,cachedDraw=function()return false end,upload=function(_,_,b)
 verts={};for i=1,b.n do verts[i]={unpack(b.v[i])}end;return{} end}
love={graphics={newShader=function(s)shaderSource=s;return{}end,setColor=function()end,draw=function()end}}
local F=assert(loadfile(root..'/Fireflies.lua'))(V,B)
local prev,maxDelta,maxAlpha,lit,peaks=nil,0,0,0,{}
local rising=false
for step=1,2400 do
 F.update(.01,{24,18,24},{wxId='CLEAR',surfaceAt=function()return 16 end})
 local _,_,_,a=F.sample(1)
 check(a>=0 and a<=.85,'bounded softer opacity')
 if a>0 then lit=lit+1 end
 if prev then
  maxDelta=math.max(maxDelta,math.abs(a-prev))
  if rising and a<prev then peaks[#peaks+1]=step*.01 end
  if a>prev then rising=true elseif a<prev then rising=false end
 end
 prev=a;maxAlpha=math.max(maxAlpha,a)
 if a>.8 and not verts then F.draw({vp={},eye={0,20,0}},function()end,function()end)end
end
check(maxDelta<.010,'gentle brightness slope at100Hz')
check(maxAlpha>.84 and lit>600 and lit<2300,'breath has a bright peak and dark interval')
check(#peaks>=2,'multiple real production pulses observed')
for i=2,#peaks do check(peaks[i]-peaks[i-1]>=5.99 and peaks[i]-peaks[i-1]<=9.01,'slower6-9second period')end
check(verts and #verts>0 and #verts<=108 and #verts%6==0,'same bounded billboard vertices during lit phase')
for i=1,#verts,6 do check(math.abs(math.abs(verts[i][2]-verts[i+2][2])-1.2)<1e-8,'larger1.2worldunit diameter')end
check(shaderSource:find('halo=halo%*halo%*%.22')~=nil,'soft feathered halo shader present')
print('PASS '..checks..' actual module glow/geometry checks; max alpha step='..maxDelta)
