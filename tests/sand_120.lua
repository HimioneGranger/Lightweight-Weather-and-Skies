-- Run from task/tests only after coordinator grants the shared runtime slot.
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local Scene={now={outdoor=true,visible='world'}};local State={level=1}
local V={require=function(name)return name=='Scene'and Scene or name=='WeatherState'and State or {}end}
local root=(arg[1] or '../lib/voxel_atmos')..'/'
local B=assert(loadfile(root..'PrecipBuffers.lua'))(V)
local M=assert(loadfile(root..'SandDust.lua'))(V,B)
local focus={0,0,0};local calls=0
local wx={wxId='SANDSTORM',sandIntensity=1,windX=1,windZ=0,rainWind=1,
 surfaceAt=function()calls=calls+1;return 0 end}
B.step();M.update(.1,focus,wx)
check(M.active==18 and M.stats.surfaceCalls==18,'bounded active dust and surface probes')
local x,y,z,a,vx,vz=M.sample(1)
check(vx>0 and vz==0 and y>=.5 and y<=10,'world wind and ground-hugging wisps')
local before=x;B.step();M.update(.1,focus,wx);x=M.sample(1)
check(x>before and calls==18,'retained world simulation no per-frame surface probes')
local saved=x;focus[1]=10;B.step();M.update(0,focus,wx);x=M.sample(1)
check(x==saved,'focus movement does not parent particles')
focus[1]=0
local function rejected(label)
 B.step();M.update(.1,focus,wx);check(M.active==0,label)
end
for _,id in ipairs({'CLEAR','RAIN','SNOW','ASH','STORM'})do wx.wxId=id;rejected('other weather '..id)end
wx.wxId='DUSTSTORM';B.step();M.update(.1,focus,wx);check(M.active==18,'native dust mode')
Scene.now.outdoor=false;rejected('indoor gate');Scene.now.outdoor=true
Scene.now.visible='hidden';rejected('hidden scene');Scene.now.visible='world'
State.level=0;rejected('weather OFF');State.level=0/0;rejected('invalid weather level');State.level=1
wx.sandIntensity=0;rejected('actual sand channel zero');wx.sandIntensity=1
wx.sandDust=false;rejected('explicit disable');wx.sandDust=nil
local knownSurface=wx.surfaceAt
for _,surface in ipairs({function()return nil end,function()error('unknown terrain')end,function()return 0/0 end})do
 M.invalidate();wx.surfaceAt=surface;B.step();M.update(.1,focus,wx)
 check(M.active==0,'unknown ground fails closed')
end
M.invalidate();wx.surfaceAt=nil;B.step();M.update(.1,focus,wx)
check(M.active==0,'missing surface provider fails closed')
M.invalidate();wx.surfaceAt=knownSurface;B.step();M.update(.1,focus,wx)
check(M.active==18,'known ground recovers bounded normal count')
local sparseCalls=0
M.invalidate();wx.surfaceAt=function()sparseCalls=sparseCalls+1;if sparseCalls%2==0 then return 0 end end
B.step();M.update(.1,focus,wx)
check(M.active==9 and sparseCalls==18,'mixed unknown ground remains bounded')
local stableValidX=M.sample(2)
for _=1,4 do B.step();M.update(.1,focus,wx)end
check(sparseCalls==18 and M.active==9 and M.sample(2)>stableValidX,'mixed valid slots move while unknown retries wait')
M.invalidate();local unknownCalls=0
wx.surfaceAt=function()unknownCalls=unknownCalls+1;return nil end
for _=1,100 do B.step();M.update(.01,focus,wx)end
check(unknownCalls>=18 and unknownCalls<=36 and M.active==0,'one second invalid terrain bounded to two attempts per slot')
wx.surfaceAt=knownSurface
for _=1,101 do B.step();M.update(.01,focus,wx)end
check(M.active==18,'known terrain recovers within one second retry budget')
M.invalidate();wx.surfaceAt=knownSurface
local meshes,uploads,draws,pushes,pops,shaderSources=0,0,0,0,0,{}
local state='old';local stack={};local fail=false
love={graphics={
 newShader=function(src)shaderSources[#shaderSources+1]=src;return{send=function()end}end,
 newMesh=function(fmt,n,mode,usage)meshes=meshes+1;check(usage=='stream','retained streamed buffer');return{
  setVertices=function()uploads=uploads+1 end,setDrawRange=function()end}end,
 push=function()pushes=pushes+1;stack[#stack+1]=state end,
 pop=function()pops=pops+1;state=table.remove(stack)end,
 setMeshCullMode=function()state='effect'end,setColor=function()end,
 setBlendMode=function()end,setDepthMode=function()end,setShader=function()end,
 draw=function()if fail then error('injected dust draw')end;draws=draws+1 end,
}}
local begin=function(view,shader)B.beginPass(view,shader)end
local finish=function()end
local left={eye={0,8,0},vp={.005,0,0,0,0,.005,0,-.04,0,0,.005,0,0,0,0,1}}
local right={eye={.02,8,0},vp={.005,0,0,-.0001,0,.005,0,-.04,0,0,.005,0,0,0,0,1}}
B.step();M.update(.1,focus,wx)
check(M.draw(left,begin,finish),'left draw')
local count=M.stats.vertices;check(count>0 and count<=108,'maximum eighteen small quads')
local firstUploads=uploads;check(M.draw(right,begin,finish),'right draw')
check(uploads==firstUploads and meshes==1 and B.stats.hits>0,'retained stereo upload')
check(state=='old'and pushes==pops,'graphics state restoration')
local geometryCalls=M.stats.surfaceCalls
B.step();M.update(.1,focus,wx);check(M.draw(left,begin,finish),'next simulation draw')
check(meshes==1 and M.stats.surfaceCalls==geometryCalls,'steady state retained mesh and no surface calls')
check(#shaderSources==1 and shaderSources[1]:find('#ifdef PIXEL',1,true),'one bounded shader resource')
fail=true;B.step();M.update(.1,focus,wx)
check(not M.draw(left,begin,finish)and M.error:find('injected',1,true),'draw failure contained')
check(state=='old'and pushes==pops,'failure restores graphics state')
M.invalidate();check(M.active==0,'invalidate disables effect')
print('sand_dust: '..checks..' checks passed')
