-- RSE native weather owns scripted/header/coordinate effects; normal skies use TWS.
local mod,loadModule,V,shared=...
local Runtime=require('src.core.game3.runtime')
local Profile=require('src.core.game3.profile')
local Map=require('src.core.game3.map')
local Native=require('src.core.game3.field_weather_rse')
local Weather=require('src.core.game3.weather')
local Types=V.require('Types')
local State=V.require('WeatherState')
local Config=V.require('Config')
local Settings=V.require('Settings')
-- Native desert grains use the same existing Quest precipitation renderer.
V._rseQuestWeatherProfiles={SANDSTORM={sandIntensity=.9,rainWind=1.4}}
local additions={
 {id='SANDSTORM',label='SANDSTORM',sandy=true,battle='SANDSTORM',natural=false,
  ch={sand=1,gust=.8,fog=.12}},
 {id='HARSH_SUN',label='DROUGHT',sunny=true,battle='SUNNY',natural=false,
  ch={warm=.55,glare=.85}},
 {id='FOG',label='HOENN FOG',natural=false,ch={fog=.65,fogSpeed=.45,veil=.08}},
}
for _,def in ipairs(additions)do
 if not Types.byId[def.id]then
  def.index=#Types.list+1;Types.list[def.index]=def;Types.byId[def.id]=def
  for key in pairs(def.ch)do
   local found=false;for _,k in ipairs(Types.channels)do if k==key then found=true end end
   if not found then Types.channels[#Types.channels+1]=key;State.ch[key]=0 end
  end
 end
 local found=false
 for _,id in ipairs(State.LEVEL_IDS)do if id==def.id then found=true end end
 if not found then
  State.LEVEL_IDS[#State.LEVEL_IDS+1]=def.id
  State.LEVEL_LABELS[#State.LEVEL_LABELS+1]=def.label
 end
end
table.sort(Types.channels)
local ids={[0]='CLEAR',[1]='PARTLY_CLOUDY',[2]='CLEAR',[3]='RAIN_HEAVY',
 [4]='SNOW_LIGHT',[5]='STORM',[6]='FOG',[7]='ASHFALL',[8]='SANDSTORM',
 [9]='FOG',[10]='CLEAR',[11]='MOSTLY_CLOUDY',[12]='HARSH_SUN',
 [13]='HEAVY_RAIN',[14]='CLEAR'}
local scriptedMap
local function rse()
 local s=Runtime.getSession()
 return s and Profile.family(s)=='rse'
end
-- Only runtime function adapters, never engine-file changes. Mark even scripted CLEAR.
for _,name in ipairs({'set','setWeather','reset'})do
 local original=Weather[name]
 if type(original)=='function'then
  Weather[name]=function(...)
   if rse()then scriptedMap=Map.current end
   return original(...)
  end
 end
end
local function target()
 if not rse()then return nil end
 if scriptedMap and scriptedMap~=Map.current then scriptedMap=nil end
 local def=Map.currentDef and Map.currentDef()
 local header=tonumber(def and def.weather) or 0
 local n=Native.state or {}
 local current=Native.getCurrentWeather()
 local saved=Weather.getSaved(Runtime.getSession())
 local authoritative=scriptedMap~=nil or header>2 or (tonumber(current) or 0)>2
   or (tonumber(saved) or 0)>2 or saved~=header
 if not authoritative then return nil end
 -- The native effect's target handles abnormal drought/downpour cycling, not id 15.
 local code=tonumber(n.nextWeather) or tonumber(current) or tonumber(saved)
 if code==15 then code=tonumber(current) end
 return ids[code],code
end
local oldUpdate=State.update
local oldDebug=Settings.debugRain
local enforcing=false
local function manualSelected()
 return shared.weatherLevel and (tonumber(shared.weatherLevel()) or 0)>2
end
Settings.debugRain=function(...)
 if enforcing then return false end
 return oldDebug and oldDebug(...) or false
end
State.update=function(dt,level,id,indoors)
 local native,code=target()
 if not native or indoors or (tonumber(level) or 0)<=0 or manualSelected()
   or (Settings.worldWeatherEnabled and not Settings.worldWeatherEnabled())then
  return oldUpdate(dt,level,id,indoors)
 end
 local cfg=Config.get();local force=cfg.force
 cfg.force=native;enforcing=true
 -- Remove an outgoing regional crossfade so a script can never mix with a second sky.
 State.softFrom,State.softTo=nil,nil;State.softT,State.softDur=0,0
 State._sessionStart=false
 if State._wasIndoors then State._pausedWeatherId=native end
 State.setWeather(native,'emerald-native')
 local result={pcall(oldUpdate,dt,level,id,indoors)}
 cfg.force=force;enforcing=false
 if not result[1]then error(result[2],0)end
 State.pinnedBy='emerald-native';State.nativeCode=code
 -- Native storm covers this entire map, never a procedural front's coverage mask.
 local front=V.require('QuestStormFront');front.managed=false
 return unpack(result,2)
end
-- Front.update follows State.update; suppress its procedural authority on native maps.
local front=V.require('QuestStormFront');local oldFront=front.update
front.update=function(...)
 if target() and not manualSelected() then
  front.managed=false;front.cell=nil;front.coverage=1;front.warning=0
  local scene=V.require('Scene').now or {}
  local suppressed=State.indoors or scene.indoors or (State.level or 0)<=0
    or (Settings.worldWeatherEnabled and not Settings.worldWeatherEnabled())
  front.haze=not suppressed and (State.id=='STORM' and .7 or State.id=='SANDSTORM' and .5 or 0) or 0
  return
 end
 return oldFront(...)
end
shared.nativeWeather=function()
 local id,code=target()
 return {id=id,code=code,scriptedMap=scriptedMap,map=Map.current}
end
mod.exports.gen3=mod.exports.gen3 or {}
mod.exports.gen3.nativeWeather=shared.nativeWeather
return {target=target}
