local root=assert(arg[1])..'/'
local n=0
local function check(v,m)n=n+1;assert(v,m)end
local scene={now={visible='world',outdoor=true,indoors=false,mapId='TEST'}}
local state={level=1}
local water=false
local V={require=function(name)return name=='Scene'and scene or name=='WeatherState'and state or{}end}
V.mod={find=function()return{exports={vrHost={world={isWater=function()return water end}}}}end}
local B=assert(loadfile(root..'PrecipBuffers.lua'))(V)
local F=assert(loadfile(root..'SnowGround.lua'))(V,B)
local draws,vertices,shader=0,0,nil
love={graphics={newShader=function(s)shader=s;return{send=function()end,release=function()end}end,
 newMesh=function()return{setVertices=function(_,_,_,count)vertices=count end,
 setDrawRange=function()end,release=function()end}end,
 setColor=function()end,draw=function()draws=draws+1 end}}
local calls=0
local wx={rainIntensity=1,snowIntensity=0,surfaceRevision=1,
 surfaceAt=function()calls=calls+1;return 4 end}
local focus={0,20,0}
for i=1,100 do B.step();F.update(.05,focus,wx)end
check(calls==0 and F.status().patches==0,'rain never probes/emits frost')
check(F.impact==nil and F.status().rings==0,'no puddle/ripple impact API/pool')
wx.snowIntensity=1
for i=1,120 do
 local before=calls;B.step();F.update(.05,focus,wx)
 check(calls-before<=5,'bounded five native surface probes per update')
end
check(F.status().patches>0 and F.status().patches<=25,'snow creates bounded frost')
local view={eye={0,20,0},vp={.01,0,0,0,0,.01,0,-.2,0,0,.01,0,0,0,0,1}}
check(F.draw(view,function()end,function()end),'actual production frost draw with mock graphics')
check(vertices>0 and vertices<=150,'snow-only geometry cap150')
check(not shader:find('kind>1.5',1,true)and not shader:find('.035,.065,.085',1,true),'no ripple/wet shader branches')
scene.now.indoors=true;B.step();F.update(.05,focus,wx)
check(not F.draw(view,function()end,function()end),'indoor frost suppressed')
scene.now.indoors=false;state.level=0;B.step();F.update(.05,focus,wx)
check(not F.status().enabled and F.status().vertices==0,'OFF clears output')
state.level=1;water=true;wx.surfaceRevision=2
for i=1,120 do B.step();F.update(.05,focus,wx)end
check(F.status().patches==0,'water does not get frost')
water='unknown';wx.surfaceRevision=3
for i=1,120 do B.step();F.update(.05,focus,wx)end
check(F.status().patches==0 and F.status().waterUnknown>0,'unknown native water classification fails closed')
F.invalidate();check(F.status().vertices==0,'invalidation clears frost')
print('snow-only ground: '..n..' checks passed (mock graphics, not GPU/headset)')
