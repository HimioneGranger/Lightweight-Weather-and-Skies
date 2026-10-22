local root=assert(arg[1]);local checks=0
local function check(v,m)checks=checks+1;assert(v,m)end
local H=assert(loadfile(root..'/FireflyHabitat.lua'))()
local scene={outdoor=true,visible='field',mapId='ROUTE1',environment='ROUTE'}
local focus={24,18,24};local tree,water=0,false;local calls=0
local world={vegetationAt=function(x,z)
 check(math.abs(x)<=7.5 and math.abs(z)<=7.5,'root cell coordinate conversion')
 calls=calls+1;return tree end,isWater=function()calls=calls+1;return water end}
local c=H.new()
local open=H.update(c,0,focus,scene,world)
check(open==.35 and calls==18,'open density and fixed query budget')
for i=1,100 do H.update(c,i*.01,{24,18+i,24},scene,world)end
check(calls==18,'no head height/per-frame habitat resampling')
scene.visible='hidden'
check(H.update(c,1.01,focus,scene,world)==0,'hidden immediately suppresses cached ecology')
scene.visible='field'
check(H.update(c,1.02,focus,scene,world)==open,'visible resumes ecology')
scene.isTown=true;local city=H.update(c,1.1,focus,scene,world)
check(city==.035 and city<open,'rare vegetation-free city')
tree=.5;local park=H.update(c,1.2,focus,scene,world,1)
check(park>open and park<1,'city greenery responds to actual trees')
tree=1;local woods=H.update(c,1.3,focus,scene,world,2)
check(woods==1,'densest local trees even inside town')
scene.isTown=false;scene.environment='FOREST';tree=0
check(H.update(c,1.4,focus,scene,world)==1,'forest metadata fallback')
scene.environment='BEACH';local beach=H.update(c,1.5,focus,scene,world)
check(beach==.12 and beach<open,'beach below open')
tree=1;local woodedBeach=H.update(c,1.6,focus,scene,world,3)
check(woodedBeach==.5 and woodedBeach<woods,'wooded beach still below inland')
water=true;local coast=H.update(c,1.7,focus,scene,world,4)
check(coast<woodedBeach,'shoreline reduction')
scene.environment='CAVE';check(H.update(c,1.8,focus,scene,world)==0,'excluded habitat')
scene.environment='ROUTE';scene.isTown=true
local broken={vegetationAt=function()error('unavailable')end,isWater=function()return nil end}
check(H.update(c,1.9,focus,scene,broken)==.035,'unknown ecology conservative city fallback')
local absent=H.new();scene.isTown=false
check(H.update(absent,0,focus,scene,nil)==open,'older host metadata fallback')
print('PASS contextual habitat '..checks..' checks')

scene.environment='ROUTE';scene.isTown=false;tree=0;water=false
world.behavior=function()return 0x21 end
local sandy=H.update(c,2.1,focus,scene,world,10)
check(sandy==.12 and c.sand==1,'real ROUTE metadata with native MB_SAND is sparse')
scene.isTown=true
check(H.update(c,2.2,focus,scene,world,11)==.035,'sand must not increase bare city density')
scene.isTown=false;world.behavior=function()return 0x06 end
check(H.update(c,2.3,focus,scene,world,12)==0,'native deep-sand desert excluded without route-wide ban')
world.behavior=nil;scene.isTown=false

-- Exercise the actual production Fireflies update/draw, not just the policy.
scene.environment='ROUTE';tree=0;water=false
local state={level=1};local night=true;local samples=0
local libs={Scene={now=scene},TimeOfDay={isNight=function()return night end},WeatherState=state}
local V={require=function(n)return assert(libs[n],n)end}
V.mod={read=function(_,p)local f=assert(io.open(root..'/'..p:match('[^/]+$')));local s=f:read('*a');f:close();return s end,
 find=function()return {exports={vrHost={world=world}}}end,exports={}}
local B={changed=function()end,cachedDraw=function()return false end,upload=function(_,_,b)check(b.n<=108,'unchanged108 vertex cap');return {}end}
love={graphics={newShader=function()return {}end,setColor=function()end,draw=function()end}}
local F=assert(loadfile(root..'/Fireflies.lua'))(V,B)
local wx={wxId='CLEAR',surfaceAt=function()samples=samples+1;return 16 end}
local function count(kind,t,w)
 scene.environment=kind;scene.isTown=kind=='CITY';tree=t;water=w or false
 F.invalidate();F.update(.01,focus,wx);return F.active,F.status()
end
local a,st=count('FOREST',0);check(a==18,'forest uses18-slot cap')
scene.visible='hidden';F.update(.01,focus,wx);check(F.active==0,'hidden immediately suppresses admitted bugs')
scene.visible='field';F.update(.01,focus,wx);check(F.active==18,'field resumes after hidden')
local b=count('ROUTE',0);local d=count('BEACH',0);local e=count('CITY',0)
check(a>b and b>d and d>=e,'actual contextual counts forest/open/beach/city')
local p=count('CITY',1);check(p==18,'actual wooded city admits full pool')
local before=F.status().ecologyProbes
for i=1,50 do F.update(.01,{24,18+i*.01,24},wx)end
check(F.status().ecologyProbes==before,'actual update caching')
local ground=samples
F.draw({vp={},eye={0,20,0}},function()end,function()end)
check(samples==ground,'draw never queries terrain')
water=true;F.invalidate();F.update(.01,focus,wx);check(F.active==0,'over-water slots still rejected')
water=false;night=false;F.update(.01,focus,wx);check(F.active==0,'day still excluded')
night=true;scene.indoors=true;F.update(.01,focus,wx);check(F.active==0,'indoors still excluded')
scene.indoors=false;wx.rainIntensity=.03;F.update(.01,focus,wx);check(F.active==0,'rain still excluded')
wx.rainIntensity=nil;state.level=0;F.update(.01,focus,wx);check(F.active==0,'weather off still excluded')
state.level=1;wx.fireflies=false;F.update(.01,focus,wx);check(F.active==0,'toggle respected')
print(('PASS production fireflies %d checks; counts forest=%d open=%d beach=%d city=%d woodedCity=%d'):format(checks,a,b,d,e,p))
