-- Visual recovery only: never changes weather IDs, encounters or event RNG.
local V=...
local A={rain=0,cloud=0,rainbow=0,age=nil,seed=math.max(1,os.time()%2147483647)}
local wetTime,armed,wasWet,lastRain,startRain,selected=0,false,false,0,0,false
local testClear,testMap
local cloudStart=1
local function rainy(id)
  return id=='STORM' or id=='RAIN_LIGHT' or id=='RAIN_HEAVY' or id=='HEAVY_RAIN' or id=='VERDANT_RAIN'
end
local function locked(state)
  local p=state.pinnedBy
  return p=='config' or p=='force' or p=='always' or p=='location' or p=='legend' or p=='psystorm'
end
-- User-requested showcase control; retained in the Showcase Controls submenu.
function A.testStatus()
  local state=V.require('WeatherState');local scene=V.require('Scene').now or {}
  local settings=V.require('Settings')
  if not scene.outdoor or scene.indoors then return 'OUTDOORS ONLY' end
  if (tonumber(state.level)or 0)<=0 or (settings.worldWeatherEnabled and not settings.worldWeatherEnabled()) then return 'WEATHER OFF' end
  if locked(state) then return 'WEATHER LOCKED' end
  if testClear then return 'QUEUED - CLOSE MENU' end
  if A.age then return 'CLEARING ACTIVE' end
  return rainy(state.id) and 'TRIGGER' or 'RAIN ONLY'
end
function A.triggerTest(clearWeather)
  if type(clearWeather)~='function' or A.testStatus()~='TRIGGER' then return false end
  testClear=clearWeather;testMap=(V.require('Scene').now or {}).mapId
  return true
end
local function smooth(x)x=math.max(0,math.min(1,x));return x*x*(3-2*x)end
function A.reset()
  cloudStart=1
  testClear,testMap=nil,nil
  A.rain,A.cloud,A.rainbow,A.age=0,0,0,nil
  wetTime,armed,wasWet,lastRain,startRain,selected=0,false,false,0,0,false
end
function A.update(dt,state,settings)
  dt=math.max(0,math.min(.25,tonumber(dt)or 0))
  local scene=V.require('Scene').now or {}
  if (tonumber(state.level)or 0)<=0 or (settings.worldWeatherEnabled and not settings.worldWeatherEnabled())
    or not scene.outdoor or scene.indoors then A.reset();return end
  if testClear then
    if not rainy(state.id) or locked(state) or scene.mapId~=testMap then testClear,testMap=nil,nil
    elseif scene.visible=='world' then
      local clear=testClear;testClear,testMap=nil,nil
      local priorRain=math.max(.12,math.min(1.38,state.channel and state.channel('rain') or 1.12))
      local ok,result=pcall(clear)
      if ok and result and (state.id=='CLEAR' or state.id=='SUNNY') then
        A.age=0;startRain=priorRain;selected=true;armed=false;wasWet=false
        cloudStart=1
      end
    end
  end
  local id=state.id
  local front=V.require('QuestStormFront')
  if id=='STORM' and front.managed and front.coverage<=.02 then id='CLEAR' end
  local wet=rainy(id)
  local clear=id=='CLEAR' or id=='SUNNY'
  if wet then
    wetTime=wetTime+dt
    if id=='STORM' and wetTime>=20 then armed=true end
    lastRain=math.max(.12,math.min(1.38,state.channel and state.channel('rain') or 1.12))
    A.age=nil;A.rain,A.cloud=0,0;selected=false
  elseif not clear then
    wetTime,armed=0,false;A.age=nil;A.rain,A.cloud=0,0;selected=false
  else
    if wasWet and armed then
      A.age=0;startRain=lastRain
      -- A passing spatial edge already tapers rain/clouds. Keep the rainbow
      -- opportunity, but do not reintroduce full storm dimming behind it.
      local spatial=state.id=='STORM' and front.managed
      cloudStart=spatial and 0 or 1
      if spatial then startRain=0 end
      A.seed=(A.seed*48271)%2147483647;selected=A.seed/2147483647<.30
    end
    wetTime,armed=0,false
    if A.age then
      A.age=A.age+dt
      A.rain=startRain*(1-smooth(A.age/18))
      A.cloud=cloudStart*(1-smooth((A.age-4)/66))
      if A.age>150 then A.age=nil;selected=false end
    end
  end
  wasWet=wet
  local lit=false
  if selected and A.age and clear then
    local hour=tonumber(V.require('TimeOfDay').hour)or 12
    local sun=V.require('CelestialBodies').bodies(hour).sun
    lit=sun and sun.above and sun.dy>.08 and sun.dy<.66
  end
  local target=selected and A.age and A.age>26 and A.age<130 and lit and clear
    and smooth((A.age-26)/18)*(1-smooth((A.age-105)/25))*.20 or 0
  A.rainbow=A.rainbow+(target-A.rainbow)*(1-math.exp(-dt/5))
  if A.rainbow<.0001 then A.rainbow=0 end
end
if V.mod and V.mod.events then
  for _,name in ipairs({'save.loaded','save.created'})do V.mod.events:on(name,A.reset)end
end
return A
