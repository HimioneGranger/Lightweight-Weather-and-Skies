-- Quest-only additions, not artwork or features attributed to the World ZIP.
-- Natural clock comes from the persisted meteor planner: no second day counter.
local V = ...
local Events = {clock=0, alpha=0}
local state, meteorPreview, auroraPreview, meteorWait = nil,0,0,0
local previewBearing
local spicyRemaining,spicyElapsed,spicyFade=0,0,0
local meteorSpicyRemaining,meteorSpicyWait=0,0
-- Independent deterministic placement stream: never changes event rarity RNG.
function Events.chooseBearing(seed)
  local s=(math.floor(seed or 1)*48271)%2147483647
  local common=s/2147483647<.8
  s=(s*48271)%2147483647
  local t=s/2147483647
  return (common and (-20+40*t) or (45+270*t))*math.pi/180
end
local function random()
  state.seed=(state.seed*48271)%2147483647
  return (state.seed-1)/2147483646
end
local function restore()
  local saved=V.mod and V.mod.save and V.mod.save:get('questSkyEvents') or {}
  saved=type(saved)=='table' and saved or {}
  state={seed=math.max(1,math.floor(tonumber(saved.seed) or os.time())%2147483647),
    block=tonumber(saved.block), night=tonumber(saved.night)}
  if tonumber(saved.version or 0)<3 then
    state.block=nil
    state.night=state.night and ((state.night-1)%15+1)or nil
  end
  if not state.night or state.night<1 or state.night>15 then
    state.night=math.floor(random()*15)+1
  end
  state.bearing=tonumber(saved.bearing)
  if not state.bearing or state.bearing~=state.bearing or math.abs(state.bearing)>math.pi*2 then
    state.bearing=Events.chooseBearing(state.seed)
  end
  previewBearing=nil
  spicyRemaining,spicyElapsed,spicyFade=0,0,0
  meteorSpicyRemaining,meteorSpicyWait=0,0
  meteorPreview,auroraPreview,meteorWait,Events.alpha=0,0,0,0
end
local function ensure() if not state then restore() end end
function Events.context()
  local scene=V.require('Scene').now or {}
  local hour=(tonumber(V.require('TimeOfDay').hour) or 12)%24
  return (hour>=20 or hour<4), scene.outdoor==true and not scene.indoors,
    true -- any outdoor location; third return retained for older callers
end
function Events.bearing()
  ensure()
  return previewBearing or state.bearing
end
function Events.status(kind)
  local night,outdoor,north=Events.context()
  if not night then return 'NIGHT ONLY' end
  if not outdoor then return 'OUTDOORS ONLY' end
  if kind=='meteor_spicy' then
    if meteorSpicyRemaining>0 then
      local scene=V.require('Scene').now or {}
      return scene.visible=='hidden' and 'QUEUED - CLOSE MENU' or 'SPICY ACTIVE'
    end
    return 'TRIGGER'
  end
  if kind=='aurora_spicy' then
    if spicyRemaining>0 then
      local scene=V.require('Scene').now or {}
      return scene.visible=='hidden' and 'QUEUED - CLOSE MENU' or 'SPICY ACTIVE'
    end
    return 'TRIGGER'
  end
  if (kind=='aurora' and auroraPreview>0) or (kind=='meteor' and meteorPreview>0) then
    return 'ACTIVE'
  end
  return 'TRIGGER'
end
-- User-requested showcase control; retained in the Showcase Controls submenu.
function Events.trigger(kind)
  ensure()
  if kind=='meteor_spicy' then
    if Events.status(kind)~='TRIGGER' then return false end
    meteorSpicyRemaining,meteorSpicyWait=120,1
    return true
  end
  if kind=='aurora_spicy' then
    if Events.status(kind)~='TRIGGER' then return false end
    spicyRemaining,spicyElapsed=120,0
    -- Upgrading an already-visible aurora must not teleport its bearing.
    if not previewBearing and Events.alpha<=0 then
      previewBearing=Events.chooseBearing(state.seed+math.floor(Events.clock*1000))
    end
    return true
  end
  if kind~='meteor' and kind~='aurora' then return false end
  if Events.status(kind)~='TRIGGER' then return false end
  if kind=='meteor' then meteorPreview,meteorWait=90,0
  else
    auroraPreview=90
    previewBearing=Events.chooseBearing(state.seed+math.floor(Events.clock*1000))
  end
  return true
end
local function envelope(t,start,finish,ramp)
  local x=math.max(0,math.min(1,(t-start)/ramp,(finish-t)/ramp))
  return x*x*(3-2*x)
end
-- No extra RNG consumption or saved showcase state. All flourishes share
-- the existing two curtains; preview runs them sooner, not faster.
function Events.flourish()
  ensure()
  if spicyRemaining>0 or spicyFade>0 then
    local t=spicyElapsed
    return envelope(t,65,120,15)*spicyFade,
      envelope(t,28,90,15)*spicyFade,
      envelope(t,5,58,12)*spicyFade,t
  end
  if not Events.natural then return 0,0,0,Events.clock end
  local t=(Events.clock+state.bearing*50)%600
  return envelope(t,430,505,25)*0.7,
    envelope(t,230,310,25)*0.65,envelope(t,60,150,30)*0.7,t
end
function Events.update(dt,day,mode,busy)
  ensure()
  dt=math.max(0,math.min(0.25,tonumber(dt) or 0))
  Events.clock=Events.clock+dt
  day=math.max(0,math.floor(tonumber(day) or 0))
  local block=math.floor(day/15)
  if state.block==nil then state.block=block
  elseif block~=state.block then
    state.block=block;state.night=math.floor(random()*15)+1
    state.bearing=Events.chooseBearing(state.seed)
  end
  local night,outdoor,north=Events.context()
  local moving=mode=='cycle' or mode=='sync' or mode=='system'
  Events.natural=night and moving and day%15+1==state.night
  V.require('QuestMountainSnow').update(day,Events.natural)
  local scene=V.require('Scene').now or {}
  local showcasing=night and outdoor and scene.visible~='hidden' and spicyRemaining>0
  if showcasing then
    spicyRemaining=math.max(0,spicyRemaining-dt)
    spicyElapsed=math.min(120,spicyElapsed+dt)
  end
  if not (night and outdoor) then spicyRemaining=0 end
  spicyFade=math.max(0,math.min(1,spicyFade+(spicyRemaining>0 and dt/8 or -dt/8)))
  local enabled=night and outdoor and (Events.natural or auroraPreview>0 or spicyRemaining>0)
  -- Eight-second fade; the location/night gate is also enforced at draw time.
  Events.alpha=math.max(0,math.min(1,Events.alpha+(enabled and dt/8 or -dt/8)))
  local meteorEvent=false
  if meteorSpicyRemaining>0 then
    if not (night and outdoor) then meteorSpicyRemaining=0
    elseif scene.visible~='hidden' then
      meteorSpicyRemaining=math.max(0,meteorSpicyRemaining-dt)
      meteorSpicyWait=math.max(0,meteorSpicyWait-dt)
      if meteorSpicyWait<=0 and not busy then
        meteorEvent='spicy'
        meteorSpicyWait=3+3*((math.sin(Events.clock*19.31)*43758.5453)%1)
      end
    end
  elseif night and outdoor and meteorPreview>0 then
    meteorWait=math.max(0,meteorWait-dt)
    if meteorWait<=0 and not busy then
      meteorEvent=true
      -- Preview randomness does not consume the saved natural-event RNG.
      meteorWait=6+12*((math.sin(Events.clock*17.17)*43758.5453)%1)
    end
  end
  meteorPreview=math.max(0,meteorPreview-dt)
  auroraPreview=math.max(0,auroraPreview-dt)
  if auroraPreview==0 and spicyRemaining==0 and Events.alpha==0 then previewBearing=nil end
  return meteorEvent
end
function Events.snapshot()
  ensure()
  return {version=3,seed=state.seed,block=state.block,night=state.night,bearing=state.bearing}
end
if V.mod and V.mod.events then
  V.mod.events:on('save.loaded',restore)
  V.mod.events:on('save.created',restore)
  V.mod.events:on('save.writing',function()
    if V.mod.save then V.mod.save:set('questSkyEvents',Events.snapshot()) end
  end)
end
return Events
