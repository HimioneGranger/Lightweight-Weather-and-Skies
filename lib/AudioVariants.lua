-- Bounded two-source crossfades and shuffle bags for weather recordings.
local M={}
local pools={rain={'rain_var1','rain_var2','rain_var3','rain_var4','rain_soft'},
 heavy={'rain_var1','rain_var2','rain_var3','rain_var4'},
 wind={'wind_var1','wind_var2','wind_var3'},
 clap={'thunder_var2','thunder_var4','thunder_var7','thunder_var8'},
 roll={'thunder_var1','thunder_var3','thunder_var5','thunder_var6'}}
local durations={rain_var1=27,rain_var2=26,rain_var3=45,rain_var4=37.5,rain_soft=55,
 wind_var1=59.9,wind_var2=59.9,wind_var3=59.9}
local bags,last={},{}
local groups={rain={slots={}},wind={slots={}}}
local function random(n) return (love and love.math and love.math.random or math.random)(n) end
function M.pick(key)
 local pool=assert(pools[key]);local bag=bags[key]
 if not bag or #bag==0 then
  bag={};for i,v in ipairs(pool)do bag[i]=v end
  for i=#bag,2,-1 do local j=random(i);bag[i],bag[j]=bag[j],bag[i]end
  if #bag>1 and bag[#bag]==last[key]then bag[1],bag[#bag]=bag[#bag],bag[1]end
  bags[key]=bag
 end
 local name=table.remove(bag);last[key]=name;return name
end
local function stop(s)
 if s and s.src then pcall(function()s.src:stop();if s.src.release then s.src:release()end end)end
end
function M.reset()
 for _,g in pairs(groups)do for _,s in ipairs(g.slots)do stop(s)end;g.slots={};g.family=nil;g.age=0 end
end
function M.stopRain()
 local g=groups.rain
 for _,s in ipairs(g.slots)do stop(s)end
 g.slots={};g.family=nil;g.age=0
end
local function tick(g,dt,family,gain,master,source)
 if master<=0 then for _,s in ipairs(g.slots)do stop(s)end;g.slots={};g.family=nil;g.age=0;return end
 g.age=(g.age or 0)+dt
 if family and (family~=g.family or #g.slots==0 or g.age>=(g.rotate or 0))then
  local name=M.pick(family)
  while #g.slots>=2 do stop(table.remove(g.slots,1))end
  local src=source(name,'stream')
  if src then
   -- Never exceed two live streams per layer, even on rapid menu changes.
   for _,s in ipairs(g.slots)do s.out=true end
   local slot={src=src,level=0,out=false,name=name}
   g.slots[#g.slots+1]=slot
   pcall(function()src:setLooping(true);src:setVolume(0);src:play()end)
   g.rotate=(durations[name] or 30)-4
  else g.rotate=15 end
  g.family=family;g.age=0
 elseif not family then
  g.family=nil
  for _,s in ipairs(g.slots)do s.out=true end
 end
 for i=#g.slots,1,-1 do
  local s=g.slots[i];local target=s.out and 0 or gain
  local step=dt/3
  if s.level<target then s.level=math.min(target,s.level+step)else s.level=math.max(target,s.level-step)end
  pcall(function()s.src:setVolume(math.min(1,s.level*master))end)
  if s.out and s.level<=0 then stop(s);table.remove(g.slots,i)end
 end
end
function M.update(dt,rain,gain,wind,windGain,master,source)
 tick(groups.rain,dt,rain and (rain=='rain' and 'rain' or 'heavy'),gain,master,source)
 tick(groups.wind,dt,wind and 'wind',windGain,master,source)
end
function M.liveCount()
 return #groups.rain.slots+#groups.wind.slots
end
return M
