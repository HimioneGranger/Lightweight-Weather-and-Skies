-- Quest cadence only. Geometry, travel, fade and colors remain World NightSky.
-- Four shower nights per 30 natural days; unchanged 100/hour shower intensity.
local Schedule = {}
Schedule.__index = Schedule
Schedule.KEY = "questMeteorSchedule"
Schedule.NORMAL = {75,180} -- real active-play seconds between ordinary singles
Schedule.SHOWER = {24,48} -- about 100 per real active-play hour; randomized, no bursts

function Schedule.new(saved, seed)
  saved = type(saved)=="table" and saved or {}
  local self=setmetatable({},Schedule)
  self.seed=math.floor(tonumber(saved.seed) or tonumber(seed) or os.time())%2147483647
  if self.seed<=0 then self.seed=1 end
  self.day=math.max(0,math.floor(tonumber(saved.day) or 0))
  self.block=math.floor(self.day/30)
  self.showerNight=tonumber(saved.showerNight)
  if not self.showerNight or self.showerNight<1 or self.showerNight>30 then
    self.showerNight=math.floor(self:random()*30)+1
  end
  self.wait=math.max(0,tonumber(saved.wait) or self:delay(false))
  self.wasShower=false
  return self
end

function Schedule:random()
  self.seed=(self.seed*48271)%2147483647
  return (self.seed-1)/2147483646
end

function Schedule:delay(shower)
  local range=shower and self.SHOWER or self.NORMAL
  return range[1]+self:random()*(range[2]-range[1])
end

function Schedule:isShower(night,moving)
  if not (night and moving)then return false end
  local offset=(self.day%30+1-self.showerNight)%30
  return offset==0 or offset==7 or offset==15 or offset==22
end

function Schedule:update(dt,hour,mode,night,busy)
  dt=math.max(0,math.min(0.25,tonumber(dt) or 0))
  hour=(tonumber(hour) or 12)%24
  -- Count at dawn, not midnight: a shower must stay the same all night.
  local phase=(hour-6)%24
  local moving=mode=="cycle" or mode=="sync" or mode=="system"
  if moving and mode==self.lastMode and self.lastPhase then
    local delta=(phase-self.lastPhase)%24
    -- Large jumps/pins/clock changes are not completed natural cycles.
    if delta>0 and delta<0.25 and phase<self.lastPhase then
      self.day=self.day+1
      local block=math.floor(self.day/30)
      if block~=self.block then
        self.block=block
        self.showerNight=math.floor(self:random()*30)+1
      end
    end
  end
  self.lastPhase,self.lastMode=phase,mode
  local shower=self:isShower(night,moving)
  if shower~=self.wasShower then self.wait=self:delay(shower) end
  self.wasShower=shower
  if not night then
    self.wasNight=false
    return nil
  end
  if not self.wasNight then
    self.wasNight=true
    self.wait=self:delay(shower)
  end
  self.wait=math.max(0,self.wait-dt)
  if self.wait>0 or busy then return nil end
  self.wait=self:delay(shower)
  return shower and "shower" or "single"
end

function Schedule:snapshot()
  return {version=2,seed=self.seed,day=self.day,showerNight=self.showerNight,wait=self.wait}
end

return Schedule
