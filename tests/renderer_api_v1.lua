local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
local function read(p)local f=assert(io.open(root..'/'..p,'rb'));local s=f:read('*a');f:close();return s end
local function loadMod(p,...)return assert(loadfile(root..'/'..p))(... )end
local Provider=loadMod('compat/RendererProvider.lua')
local space={unitsPerMetre=10,up='Y',east='+X',south='+Z'}
local function descriptor()return{api=1,space=space,register=function()end}end
check(not Provider.validate({api=2}),'unknown provider version rejected')
check(not Provider.validate({api=1,space={},register=function()end}),'unknown coordinate units rejected')
check(not Provider.validate(setmetatable({},{__index=function()error('bad descriptor')end})),'validation exceptions contained')

local selectedOwner='THIRD_PARTY';local mods={THIRD_PARTY={exports={}},OTHER={exports={}}}
local settings={lwsSkyEnabled=function()return false end,cloudsOn=function()return true end}
local weather={id='STORM',level=7,channel=function()return 1 end}
local owner={exports={lib={require=function(name)return({Settings=settings,WeatherState=weather,TimeOfDay={hour=13}})[name]end}},find=function(id)return mods[id]end}
local made,detached=0,0
local providerModule={validate=Provider.validate,new=function()
 made=made+1
 return{ready=false,active=false,reason='waiting',status=function()return{ready=true,active=true,reason='mock-frame'}end,detach=function()detached=detached+1 end}
end}
local registry=loadMod('compat/RendererAPI.lua').new(owner,function(name)if name=='RendererProvider'then return providerModule end;return{}end,function()return'world',selectedOwner end)
local p=descriptor();local binding,err=registry.api.registerRenderer{api=1,owner='THIRD_PARTY',provider=p}
check(binding and not err,'unknown renderer id registers without source whitelist patch')
check(registry.api.status('THIRD_PARTY').selected and made==0,'registration does not render or falsely report readiness')
check(not registry.api.registerRenderer{api=1,owner='THIRD_PARTY',provider=p},'duplicate owner rejected')
check(not registry.api.registerRenderer{api=1,owner='MISSING',provider=p},'missing owner rejected')
check(not registry.api.registerRenderer{api=9,owner='OTHER',provider=p},'unknown registration version rejected')
local Router=loadMod('compat/Router.lua')
local router=Router.new({lws_renderer=function(id)return registry:newAdapter(id,registry.resolve(id))end},function(_,id)local x,_,revision=registry.resolve(id);if x then return'lws_renderer',id,revision end end)
router:update('world','OTHER','Android',true);check(made==0,'installed but inactive provider never activated')
router:update('world','THIRD_PARTY','Android',true);check(made==1 and registry.api.status('THIRD_PARTY').ready,'selected provider activated')
local a=registry.api.snapshot();a.weather.channels.rain=99;a.clock.hour=0
local b=registry.api.snapshot();check(b.weather.channels.rain==1 and b.clock.hour==13 and b.skySource=='native','snapshot detached/read-only data')
check(binding:dispose()and not binding:dispose(),'idempotent registration disposal')
check(detached==1 and not registry.resolve('THIRD_PARTY'),'disposal releases active resources')
local again=assert(registry.api.registerRenderer{api=1,owner='THIRD_PARTY',provider=p})
router:update('world','THIRD_PARTY','Android',true);check(made==2,'same provider re-registration gets fresh revision/adapter')
again:dispose()
local auto=descriptor();mods.THIRD_PARTY.exports.lwsRendererProvider=auto
router:update('world','THIRD_PARTY','Linux',false);check(made==3,'new advertised provider discovered')
mods.THIRD_PARTY.exports.lwsRendererProvider=descriptor()
router:update('world','THIRD_PARTY','Linux',false);check(made==4,'same owner provider replacement rebuilds via revision token')

local nativeOwner=nil
local fallback=loadMod('compat/RendererAPI.lua').new(owner,function()return providerModule end,function()
 if nativeOwner then return 'world',nativeOwner end
 error('engine has no standard pipeline registry')
end)
local fp,other=descriptor(),descriptor();local enabled=true
fp.isActive=function()return enabled end
other.isActive=function()return false end
assert(fallback.api.registerRenderer{api=1,owner='THIRD_PARTY',provider=fp})
assert(fallback.api.registerRenderer{api=1,owner='OTHER',provider=other})
local _,winner=fallback.selection()
check(winner=='THIRD_PARTY' and fallback.api.status(winner).selected,'explicit predicate supports engines without private registry')
enabled=false;check(fallback.selection()==nil,'installed inactive renderer never wins')
fp.isActive=function()error('predicate fault')end
check(fallback.selection()==nil,'active predicate faults fail closed')
fp.isActive=function()return true end;other.isActive=function()return true end
local pipeline,ambiguous,reason=fallback.selection()
check(not pipeline and not ambiguous and reason=='ambiguous-active-renderers','multiple active declarations fail closed')
nativeOwner='OTHER';local _,known=fallback.selection()
check(known=='OTHER' and not fallback.api.status('THIRD_PARTY').selected,'known native provenance takes priority over fallback')

-- Real packet client behind the public facade; private engine Game access
-- throws, proving frame context is sufficient for an unknown renderer.
local ClientChunk=assert(loadfile(root..'/compat/BattleArtClient.lua'))
setfenv(ClientChunk,setmetatable({require=function()error('private engine lookup forbidden')end},{__index=_G}))
local Client=ClientChunk()
local calls={cloud=0,bolt=0,rain=0,body=0,stars=0,clear=0,dispose=0,release=0}
local callbacks,atmos;local full=true;local active=true;local failDraw=false;local unavailable=false
local cam={available=true,eye={0,40,0},focus={0,40,-10},mapId='A',far=4000,fov=1.2,viewportHeight=1600,skyVisible=true}
local backend={camera=function()if unavailable then return{available=false}end;return cam end,
 clear=function()calls.clear=calls.clear+1 end,submitAtmosphere=function(_,v)atmos=v;return true end}
for _,k in ipairs{'material','mesh','image','updateMesh','enqueue','release'}do backend[k]=function()return{}end end
local realProvider={api=1,space=space,register=function(c)
 callbacks=c;return{effects=function()return backend end,dispose=function()calls.dispose=calls.dispose+1 end}
end}
local modules={BattleArtClient=Client,
 EffectPackets={new=function()return{bolt=function()calls.bolt=calls.bolt+1 end,aurora=function()end,rainbow=function()end,release=function()calls.release=calls.release+1 end}end},
 CelestialPackets={baker=function()return{}end,new=function()return{draw=function()calls.body=calls.body+1;return true end,release=function()end}end},
 CloudPackets={new=function()return{clouds={setWeatherProvider=function()end,observeMap=function()end},ceilingAt=function()return 1920 end,
 draw=function(_,camera)check(camera.overhead==true,'public skyVisible reaches cloud eligibility');if failDraw then error('cloud draw fault')end;calls.cloud=calls.cloud+1 end,release=function()end}end},
 SourceDrawPackets={new=function()return{graphics={},begin=function()end,camera=function(_,c)return c end,release=function()end,
 load=function()return{invalidate=function()end,update=function(_,_,weather)
  if weather.surfaceAt then check(weather.surfaceAt(0,0)==5 or weather.surfaceAt(0,0)==nil,'public optional ground height')end
 end,draw=function()calls.rain=calls.rain+1 end,describe=function()return{}end}end}end}}
local stub={Settings={lwsSkyEnabled=function()return full end},QuestStorm={bindCloudCeiling=function()end,bindCamera=function()end,cloudLightning=function()end,
 bolt=function()return{}end,flash=function()return 1 end,tint=function(v)return v end,strength=1},
 QuestSkyEvents={flourish=function()return 0,0,0,0 end,context=function()return false,true end,bearing=function()return 0 end},
 QuestAfterStorm={cloud=1},TimeOfDay={hour=13},CelestialBodies={bodies=function()return{sun={}}end},QuestMoon={current=function()return{}end},
 NightSky={drawWorld=function()calls.stars=calls.stars+1 end},WeatherState=weather,QuestStormFront={haze=1},
 DramalessAtmos={questWeatherFrame=function()return{weather={rainIntensity=1}}end},QuestStormBolt={},QuestAurora={},QuestRainbow={}}
local world={privateGraphicsEnvironment={graphics={}},require=function(name)return assert(stub[name],'private/unexpected dependency '..name)end}
local instance,why=Provider.new({id='weather',read=function()return'return{}'end},realProvider,modules,world,function()return active end)
check(instance and not why and not instance.ready,'public adapter waits for a valid real frame')
local function frame(id)return{id=id,dt=.016,world={visible='world',outdoor=true,indoors=false,map={id='A'},neighbors={},surfaceAt=function()return 5 end},lighting={hour=13,tint={1,1,1},haze={.4,.5,.6}}}end
check(callbacks.prepare(frame(1))and instance.ready and calls.cloud==1 and calls.rain==1,'complete public rendering without private Game/world modules')
check(not callbacks.prepare(frame(1))and calls.cloud==1,'stereo duplicate preparation does not advance effects twice')
full=false;check(callbacks.prepare(frame(2))and atmos.sky.replaceCelestials==false,'native sky policy supported through generic API')
check(calls.cloud==2 and calls.bolt==2 and calls.rain==2 and calls.body==1 and calls.stars==1,'native still clouds/lightning/weather; no replacement bodies/stars')
local bad=frame(3);bad.lighting.hour=0/0
check(not callbacks.prepare(bad)and not instance.ready,'nonfinite frame input rejected and status fails closed')
check(callbacks.prepare(frame(4))and instance.ready,'valid frame recovers after fault')
cam.eye={0/0,0,0};check(not callbacks.prepare(frame(5)),'nonfinite camera rejected');cam.eye={0,40,0}
check(callbacks.prepare(frame(6)),'camera recovery')
failDraw=true;check(not callbacks.prepare(frame(7))and not instance.ready,'authored draw exceptions contained');failDraw=false
check(callbacks.prepare(frame(8))and instance.ready,'draw failure recovery resets only LWS resources')
local zero=frame(9);zero.world.surfaceAt=function()error('height fault')end
check(callbacks.prepare(zero),'unknown ground height suppresses decals, not sky/weather')
active=false;check(not callbacks.prepare(frame(10))and not instance:status().active,'unselected renderer clears its own weather');active=true
unavailable=true;check(callbacks.prepare(frame(11))and not instance.ready,'camera unavailable is safe inactive state');unavailable=false
check(callbacks.invalidate()and callbacks.prepare(frame(0)),'invalidate allows frame counter reset')
local hidden=frame(1);hidden.world={visible='hidden',outdoor=false,indoors=true};hidden.lighting=nil
check(callbacks.prepare(hidden)and not instance:status().active,'hidden/menu/indoors do not draw')
instance:detach();check(calls.dispose==1 and not callbacks.prepare(frame(2)),'detach disposes lease once and ignores stale callbacks')
instance:detach();check(calls.dispose==1,'detach idempotent')
print('PASS '..n..' public renderer API version/selection/lifecycle/context/sky/fault/snapshot assertions')
