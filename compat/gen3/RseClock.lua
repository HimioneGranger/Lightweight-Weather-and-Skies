-- Emerald native local time is the sole clock, including save offset/skew.
local mod, loadModule, V, shared = ...
local Runtime = require('src.core.game3.runtime')
local Rtc = require('src.core.game3.rtc')
local Profile = require('src.core.game3.profile')
local previewOk, Preview = pcall(require, 'src.core.game3.lighting_preview')
if not previewOk or type(Preview)~='table' or type(Preview.apply)~='function' then Preview=nil end
local TOD = V.require('TimeOfDay')
local function read()
  local ok, value = pcall(function()
    local s=Runtime.getSession()
    if not s or Profile.family(s)~='rse' then return nil end
    local g=Runtime._game
    local t=Rtc.calcLocalTime(s)
    if Preview then t=Preview.apply(t,g and g.options or s.options) end
    local h,m,sec=t.hours,t.minutes,t.seconds
    if type(h)~='number' or h~=h or h<0 or h>=24
      or type(m)~='number' or m~=m or m<0 or m>=60
      or type(sec)~='number' or sec~=sec or sec<0 or sec>=60 then return nil end
    return {hour=h+m/60+sec/3600,minute=m,second=sec,days=t.days,
      period=h>=4 and h<10 and 'morning' or h>=10 and h<18 and 'day' or 'night',
      source=t.lightingPreview and 'emerald-lighting-preview' or 'emerald-rtc'}
  end)
  return ok and value or nil
end
-- Replaces this session's cached TOD clock; neither a cycle nor a pin can diverge.
TOD.update=function()
  local t=read()
  if t then TOD.hour,TOD.tod,TOD.source=t.hour,TOD.phaseAt(t.hour),t.source;TOD.pin=nil
  else TOD.source='emerald-rtc-unavailable' end
end
TOD._forceOffByHost=false
TOD.grade=function()return nil end -- voxel AtmosTime owns the only 3D grade
TOD.setHostOwnsClock=function()TOD.pin=nil end
-- Nature/celestial clients use the same local RTC even without a voxel host.
local Interop=V.require('Interop')
local nativeClock={
  CYCLE=1200,DAY_LEN=600,
  hours=function()local t=read();return t and t.hour end,
  time=function()local t=read();return t and ((t.hour-6)%24)*50 end,
  isNight=function()local t=read();return t and t.period=='night' or false end,
  setting={values={'system'},get=function()return 'system'end},
}
-- CinematicAtmos expects named phase weights; the native voxel host's mix
-- is a numeric dial. Supply this contract only in TWS's private namespace.
nativeClock.mix=function()
 local t=read();local h=t and t.hour or 12
 local from,to,u
 if h<6 then from,to,u='night','dawn',h/6
 elseif h<12 then from,to,u='dawn','day',(h-6)/6
 elseif h<18 then from,to,u='day','dusk',(h-12)/6
 else from,to,u='dusk','night',(h-18)/6 end
 return {[from]=1-u,[to]=u}
end
local atmosphereClock,clockHost
V._rseAtmosDayNight=function(hostLib,profiles)
 if profiles and V._rseQuestWeatherProfiles then
  for id,profile in pairs(V._rseQuestWeatherProfiles)do profiles[id]=profile end
 end
 if atmosphereClock and clockHost==hostLib then return atmosphereClock end
 local hostClock=hostLib.require('DayNight')
 atmosphereClock=setmetatable({time=nativeClock.time,mix=nativeClock.mix,
   isNight=nativeClock.isNight,hours=nativeClock.hours}, {__index=hostClock})
 clockHost=hostLib
 return atmosphereClock
end
Interop.dayNight=function()return nativeClock,'emerald-rtc'end
shared.clockStatus=read
if shared.options and shared.options.setMode then shared.options.setMode('rtc') end
-- Match the native sky's dawn/dusk blend, rather than keeping the weather
-- mod's six-hour morning stars after the native sky is fully daylight.
local function nightWeight()
 local t=read();local h=t and t.hour or 12
 if h<4 or h>=18.5 then return 1 end
 if h<6 then local u=(h-4)/2;return 1-u*u*(3-2*u) end
 if h>=18 then return (h-18)/.5 end
 return 0
end
V._rseNightVisibility=nightWeight
local registeredHost
local function register()
  local h=mod.find('FRLG_VOXEL')
  local clock=h and h.exports and h.exports.vrHost and h.exports.vrHost.clock
  if clock and clock~=registeredHost and type(clock.register)=='function' then
    clock.register('tws-emerald-rtc',read,100);registeredHost=clock
  end
end
register()
mod.events:on('game.ready',register,-160)
mod.events:on('mods.loaded',register,0)
mod.exports.gen3=mod.exports.gen3 or {}
mod.exports.gen3.readClock=read
TOD.update()
return {read=read,mode=function()return 'emerald-rtc'end}
