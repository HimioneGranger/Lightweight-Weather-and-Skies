local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
local function loadModule(p,...)return assert(loadfile(root..'/'..p))(...)end
local full=true;local count={cloud=0,bolt=0,rain=0,body=0,stars=0,clear=0,aurora=0}
local current={map={id='A'},neighbors={}}
local callback,lastAtmos
local api={clear=function()count.clear=count.clear+1 end,camera=function()return{available=true,mode='first_person',mapId='A',eye={0,40,0},far=1000}end,
 submitAtmosphere=function(_,v)lastAtmos=v;return true end}
local provider={capabilities={atmosphere_effects_draft=1,atmosphere_render_camera=1},register=function(spec)callback=spec.prepareAtmosphere;return{effects=function()return api end}end}
local modules={
 EffectPackets={new=function()return{bolt=function()count.bolt=count.bolt+1 end,aurora=function()count.aurora=count.aurora+1 end,rainbow=function()end,release=function()end}end},
 CelestialPackets={baker=function()return{}end,new=function()return{draw=function()count.body=count.body+1;return true end,release=function()end}end},
 CloudPackets={new=function()return{clouds={setWeatherProvider=function()end,observeMap=function()end},ceilingAt=function()return 1920 end,draw=function()count.cloud=count.cloud+1 end,release=function()end}end},
 SourceDrawPackets={new=function()return{graphics={},begin=function()end,camera=function(_,c)return c end,release=function()end,
  load=function()return{invalidate=function()end,update=function()end,draw=function()count.rain=count.rain+1 end,describe=function()return{}end}end}end},
}
local s={lwsSkyEnabled=function()return full end}
local stub={Settings=s,Scene={now={visible='world',outdoor=true,mapId='A'}},
 QuestStorm={bindCloudCeiling=function()end,bindCamera=function()end,bolt=function()return{}end,flash=function()return 1 end,tint=function(v)return v end,strength=1},
 QuestSkyEvents={flourish=function()return 0,0,0,0 end,context=function()return true,true end,bearing=function()return 0 end},
 QuestAfterStorm={cloud=1},TimeOfDay={hour=13},CelestialBodies={bodies=function()return{sun={}}end},QuestMoon={current=function()return{}end},
 NightSky={drawWorld=function()count.stars=count.stars+1 end},WeatherState={id='STORM',channel=function()return 0 end},
 QuestStormFront={haze=1},QuestRainSurface={sampler=function()return function()return 0 end end},
 DramalessAtmos={questWeatherFrame=function()return{weather={rainIntensity=1}}end},QuestStormBolt={},QuestAurora={},QuestRainbow={}}
local world={privateGraphicsEnvironment={graphics={}},require=function(name)return assert(stub[name],name)end}
local host={require=function(name)if name=='Sky'then return{haze=function()return{.4,.5,.6}end}end;if name=='DayNight'then return{time=function()return 300 end,tint=function()return{1,1,1}end}end;return{}end}
local mod={id='weather',read=function()return'return{}'end}
local chunk=assert(loadfile(root..'/compat/BattleArtClient.lua'))
setfenv(chunk,setmetatable({require=function(name)assert(name=='src.core.Game');return{overworld=current}end},{__index=_G}))
local client=chunk().new(mod,provider,modules,world,host,function()return true end)
callback({dt=.016});check(count.body==1 and count.stars==1 and lastAtmos.sky.replaceCelestials==true,'full packet sky owns celestial replacement')
full=false;callback({dt=.016})
check(count.body==1 and count.stars==1 and count.aurora==1,'native packets omit LWS sun/stars/aurora')
check(count.cloud==2 and count.bolt==2 and count.rain==2,'native packets retain clouds lightning precipitation')
check(lastAtmos.sky.replaceCelestials==false,'native host bodies restored')
check(lastAtmos.sky.flash==1 and lastAtmos.haze.density>0 and lastAtmos.tint.additive[3]==1,'native keeps flash and weather visibility')
check(count.clear==1,'switch clears only own stale sky commands')
full=true;callback({dt=.016});check(count.body==2 and count.stars==2 and count.cloud==3 and count.bolt==3 and count.rain==3,'full packet mode restored')
check(count.clear==2 and lastAtmos.sky.replaceCelestials==true,'full ownership restored live')
-- Exercise the actual old Sky.paint wrapper's native fast path, not a copy.
local f=assert(io.open(root..'/weather_main.lua','rb'));local source=f:read('*a');f:close()
local part=assert(source:match('(local function installNightSkyWrap%(%).-\n  Sky%._wxNightWrapped = true\r?\nend)'))
local originalSky={native=true};local originalBody={nativeBody=true};local got
local sky={paint=function(...)got={...};return'host',17 end}
local fn=assert(loadstring(part..'\nreturn installNightSkyWrap','@native-paint-test'))
setfenv(fn,setmetatable({Interop={hostLib=function()return{require=function()return sky end}end},
 Settings={lwsSkyEnabled=function()return false end},V={require=function()return{}end},mod=mod},{__index=_G}))
fn()()
local a,b=sky.paint(100,90,originalSky,30,4,originalBody,'extra')
check(a=='host'and b==17 and got[3]==originalSky and got[6]==originalBody and got[7]=='extra','native sky painter/body/extra args/multiple returns exact')
-- Native mode must not apply LWS's separate time-of-day grade.
local draw=loadModule('lib/Draw.lua',{mod={exports={}},require=function(name)
 if name=='Settings'then return{lwsSkyEnabled=function()return false end}end
 if name=='TimeOfDay'then return{grade=function()error('native must not reach LWS grade')end}end
 return{}
end})
check(draw.grade(0,0,100,100,false)==false,'native skips time-of-day grade')
print('PASS '..n..' native packet sky/clear/flash/cloud/precip and original sky forwarding assertions')
