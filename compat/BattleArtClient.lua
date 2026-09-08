local M={}
local function must(v,e)assert(v,e);return v end
function M.new(mod,provider,modules,world,host,isSelected)
 if not(provider and provider.capabilities and provider.capabilities.atmosphere_effects_draft==1)then return nil,'atmosphere API unavailable'end
 local self={ready=false,reason='awaiting-first-frame',drawnFrames=0}
 local handle,facade,packets,stars,precip,wp,clouds,celestials,surfaceMap,surface
 local function reset()
  self.active=false
  for _,p in ipairs({packets or false,stars or false,precip or false,clouds or false,celestials or false})do if p then p:release()end end
  packets,stars,precip,wp,clouds,celestials,facade=nil,nil,nil,nil,nil,nil,nil
  surfaceMap,surface=nil,nil
 end
 local function setup(api)
  packets=modules.EffectPackets.new(api,{bolt=world.require('QuestStormBolt'),aurora=world.require('QuestAurora'),rainbow=world.require('QuestRainbow')})
  stars=modules.SourceDrawPackets.new(api,'celestial_before_clouds',true)
  precip=modules.SourceDrawPackets.new(api,'translucent_after_actors',false)
  local particleWorld=setmetatable({require=function(name)
   if name=='Settings' then return setmetatable({isFirstPerson=function()return self.cameraMode=='first_person'end},{__index=world.require('Settings')})end
   return world.require(name)
  end},{__index=world})
  wp=precip:load(assert(mod:read('lib/voxel_atmos/WorldPrecip.lua')),particleWorld,love,'@weather/WorldPrecip')
  clouds=modules.CloudPackets.new(api,{
   shader=assert(mod:read('compat/CloudShader.glsl')),clouds=assert(mod:read('compat/CloudsSource.lua')),
   light=assert(mod:read('compat/CloudLightSource.lua')),space=assert(mod:read('compat/CloudSpace.lua'))},love,function()return host.require('DayNight').time()end)
  clouds.clouds.setWeatherProvider(function()
   local s=world.require('WeatherState');local a=world.require('QuestAfterStorm')
   return s.channel('rain'),s.channel('snow'),s.channel('dim'),s.channel('gust'),s.channel('ash'),s.id,a.cloud
  end)
  clouds.clouds.lightningProvider=world.require('QuestStorm').cloudLightning
  clouds.clouds.stormFrontProvider=world.require('QuestStormFront').cloudField
  celestials=modules.CelestialPackets.new(api,modules.CelestialPackets.baker(assert(mod:read('lib/WorldCelestialDisc.lua')),love,world))
 end
 local function tick(frame)
  self.active=false
  if not handle then return end
  local api,err=handle:effects();if not api then self.reason=err;return end
  if facade~=api then reset();facade=api;setup(api)end
  local scene=world.require('Scene').now or {}
  if not isSelected()or scene.visible~='world'or not scene.outdoor or scene.indoors then api:clear();return end
  local camera=api:camera()
  if not(camera and camera.available)then api:clear();self.reason='camera-unavailable';return end
  self.cameraMode=camera.mode
  local dt=math.max(0,math.min(.1,tonumber(frame.dt)or 0))
  local storm=world.require('QuestStorm');storm.bindCamera(camera)
  local events=world.require('QuestSkyEvents');local after=world.require('QuestAfterStorm')
  local tod=world.require('TimeOfDay');local bodies=world.require('CelestialBodies').bodies(tod.hour)
  local replace=celestials:draw(bodies,camera.far*.90,world.require('QuestMoon').current())
  local crown,pink,split,time=events.flourish()
  local night,outdoor=events.context()
  packets:bolt(storm.bolt())
  packets:aurora{night=night,outdoor=outdoor,alpha=events.alpha,clock=events.clock,bearing=events.bearing(),flourish={crown,pink,split,time},far=camera.far}
  packets:rainbow{outdoor=true,alpha=after.rainbow,sun=bodies.sun,far=camera.far}
  stars:begin()
  local environment=world.privateGraphicsEnvironment
  local previous=environment.graphics;environment.graphics=stars.graphics
  local ok,problem=pcall(world.require('NightSky').drawWorld,stars:camera(camera),events.clock)
  environment.graphics=previous
  if not ok then error(problem)end
  local haze=host.require('Sky').haze()
  local tint=storm.tint(host.require('DayNight').tint(true),true,false)
  local game=require('src.core.Game');local overworld=game.overworld
  if overworld and overworld.map and overworld.map.id==camera.mapId then
   clouds.clouds.observeMap(overworld.map,overworld.neighbors)
  end
  clouds:draw(camera,dt,tint,haze)
  local strength=math.max(storm.strength,(after.cloud or 0)*.85);local flash=storm.flash()
  must(api:submitAtmosphere{sky={dim=strength*.22,flash=flash,replaceCelestials=replace},
   tint={multiplier={1-strength*.18,1-strength*.18,1-strength*.18},additive={flash*.7,flash*.8,flash}},
   haze={density=(world.require('QuestStormFront').haze or 0)*.00010,color=haze}})
  local game=require('src.core.Game');local map=game.overworld and game.overworld.map
  if surfaceMap~=map then surfaceMap=map;wp.invalidate();surface=world.require('QuestRainSurface').sampler(map,host.require('TileShape'))end
  local weather=world.require('DramalessAtmos').questWeatherFrame({weather={}},world.require('WeatherState').id).weather
  weather.surfaceAt=surface
  precip:begin()
  wp.update(dt,{camera.eye[1],0,camera.eye[3]},weather)
  wp.draw(precip:camera(camera),{weather=weather})
  self.precipitation=wp.describe();self.active=true;self.ready=true;self.reason='rendering';self.drawnFrames=self.drawnFrames+1
 end
 local err
 handle,err=provider.register{api=1,id=mod.id,priority=120,requires={'world_snapshot','render_phases','atmosphere_effects_draft'},update=tick,invalidate=reset,dispose=reset}
 if not handle then reset();return nil,err end
 function self:detach()if facade then facade:clear()end;reset();if handle then local h=handle;handle=nil;h:dispose()end end
 function self:status()return {ready=self.ready,reason=self.reason,drawnFrames=self.drawnFrames,precipitation=self.precipitation,active=self.active}end
 return self
end
return M
