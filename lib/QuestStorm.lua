-- Quest remaster of World's storm channels/lightning. One event owns the
-- world bolt, atmosphere flash and delayed thunder. No 2D flash rectangles.
local V=...
local Storm={clock=0,flashValue=0,strength=0,serial=0,seed=math.max(1,os.time()%2147483647),
  GAPS={calm={20,45},rare={45,90},active={8,18}}}
local remaining,active,queued,ready,wasEligible,lastMap=nil,nil,nil,nil,false,nil
local testRequested,lastTest,weatherEligible=false,-math.huge,false
local host,voxel,originalTint,originalProvider
local originalCloudLightning
local originalStormFront
local originalWeatherHaze
-- Independent RNG preserves the tested nearby-strike cadence/geometry.
local distantSeed=math.max(1,(os.time()+7919)%2147483647)
local distant,distantQueued,distantReady,distantWait,distantTest=nil,nil,nil,nil,false
local lastNear=-math.huge
local spicy=nil
Storm.FLASH_SPEED=1.25 -- 25% faster playback, not 25% more strikes
Storm.VARIANTS={}
local variantBags={}
local variantSeed=math.max(1,(os.time()+104729)%2147483647)
local function variantRandom(n)
  variantSeed=(variantSeed*48271)%2147483647
  return 1+math.floor((variantSeed-1)/2147483646*n)
end
-- Ten authored parameter profiles per family, plus existing per-event detail.
-- Keep the mesh budgets fixed; silhouette, sweep, width and dispersion vary.
for _,kind in ipairs({'forked','anvil','rolling','cloud'})do
  local list={}
  for i=1,10 do list[i]={id=i,kind=kind,
    fade=.78+.04*i,dispersion=.72+.06*i,width=.80+.04*i,
    span=.70+.06*i,radius=.68+.055*i,bend=(i-5.5)*26,
    branches=1+i%2,reverse=i%2==0,
    jagged=.55+.09*((i*3)%10)} end
  Storm.VARIANTS[kind]=list
end
local function nextVariant(kind)
  local bag=variantBags[kind]
  if not bag then bag={items={}};variantBags[kind]=bag end
  if #bag.items==0 then
    for i=1,10 do bag.items[i]=i end
    for i=10,2,-1 do local j=variantRandom(i);bag.items[i],bag.items[j]=bag.items[j],bag.items[i]end
    if bag.items[10]==bag.last then bag.items[1],bag.items[10]=bag.items[10],bag.items[1]end
    -- Random shuffling alone can reproduce the previous permutation. Reject
    -- that exact order explicitly; swapping the last two played entries
    -- leaves the no-immediate-repeat boundary protection intact.
    if table.concat(bag.items,',')==bag.previousOrder then
      bag.items[1],bag.items[2]=bag.items[2],bag.items[1]
    end
    bag.previousOrder=table.concat(bag.items,',')
  end
  bag.last=table.remove(bag.items)
  return Storm.VARIANTS[kind][bag.last]
end
local distantGaps={calm={14,26},rare={30,50},active={9,16}}
local function distantRandom(a,b)
  distantSeed=(distantSeed*48271)%2147483647
  return a+(b-a)*(distantSeed-1)/2147483646
end
local function nextDistant(pace)
  local r=distantGaps[pace]or distantGaps.calm
  return distantRandom(r[1],r[2])
end
local function distantStrike(preview)
  local eye=voxel and voxel.eye or {0,32,0}
  local az=distantRandom(0,math.pi*2)
  if preview and voxel and voxel.focus then
    az=math.atan2(voxel.focus[1]-eye[1],voxel.focus[3]-eye[3])
  end
  local distance=distantRandom(3200,4200)
  distant={age=0,light={eye[1]+math.sin(az)*distance,
    eye[3]+math.cos(az)*distance,1/distantRandom(1200,1700),0}}
  distant.variant=nextVariant('cloud')
  distant.radius=(1/distant.light[3])*distant.variant.radius
  local front=V.require('QuestStormFront')
  if front.managed then
    distant.light[1],distant.light[2]=front.constrain(distant.light[1],distant.light[2])
    if front.cell then distant.radius=math.min(distant.radius,front.cell.radius*.35)end
  end
  distantQueued={due=Storm.clock+distantRandom(6,9),gain=distantRandom(.10,.18),
    sound='quest_thunder_roll',pitch=distantRandom(.82,.93),distant=true}
end
function Storm.cloudLightning() return distant and distant.light or active and active.cloudLight or nil end
local function random(a,b)
  Storm.seed=(Storm.seed*48271)%2147483647
  return a+(b-a)*(Storm.seed-1)/2147483646
end
function Storm.preferences()
  local found=V.mod and V.mod.find and V.mod.find('BATTLE_ART_QUEST_COMPAT')
  local q=V.mod.exports.weatherPreferences or (found and found.exports and found.exports.quest)
  if q and q.storm then return q.storm() end
  return {mode='full',pace='calm'}
end
local function gap(pace)
  local range=Storm.GAPS[pace] or Storm.GAPS.calm
  return random(range[1],range[2])
end
function Storm.reset()
  remaining,active,queued,ready,wasEligible,lastMap=nil,nil,nil,nil,false,nil
  Storm.flashValue,Storm.strength=0,0
  testRequested,lastTest,weatherEligible=false,-math.huge,false
  Storm.lastPace=nil
  distant,distantQueued,distantReady,distantWait,distantTest=nil,nil,nil,nil,false
  lastNear=-math.huge
  spicy=nil
end
-- Adapted from World Lightning.lua's recursive midpoint-displacement bolt.
-- The extra axis and fixed endpoint positions make this actual world geometry.
local function displace(points,a,b,spread,depth)
  if depth<=0 then points[#points+1]=b;return end
  local mid={(a[1]+b[1])/2+random(-spread,spread),
    (a[2]+b[2])/2+random(-spread*.2,spread*.2),
    (a[3]+b[3])/2+random(-spread,spread)}
  displace(points,a,mid,spread*.55,depth-1)
  displace(points,mid,b,spread*.55,depth-1)
end
local function strike(mode,preview,style)
  lastNear=Storm.clock
  local eye=voxel and voxel.eye or {0,32,0}
  local far=voxel and (voxel.far or (voxel.camera and voxel.camera.far)) or 1600
  local distance=random(math.min(280,far*.35),math.min(440,far*.58))
  local az=random(0,math.pi*2)
  if preview and voxel and voxel.focus then
    -- Capture heading once; the resulting bolt never follows head rotation.
    az=math.atan2(voxel.focus[1]-eye[1],voxel.focus[3]-eye[3])
  end
  local x,z=eye[1]+math.sin(az)*distance,eye[3]+math.cos(az)*distance
  local cloudY=host and host.clouds and host.clouds.ALT or 640
  local cloudOnly=random(0,1)<0.65
  if preview then cloudOnly=false end
  local top={x+random(-70,70),cloudY,z+random(-50,50)}
  local hit={x,cloudOnly and cloudY-random(70,150) or 0,z}
  local points={top}
  displace(points,top,hit,cloudOnly and 32 or 45,4)
  local fork
  if random(0,1)<0.5 then
    local p=points[7];fork={p}
    displace(fork,p,{p[1]+random(-65,65),p[2]-random(35,90),p[3]+random(-50,50)},14,3)
  end
  Storm.serial=Storm.serial+1
  active={id=Storm.serial,age=0,mode=mode,points=points,fork=fork,
    distance=distance,cloudOnly=cloudOnly,boltAlpha=0,origin={eye[1],eye[2],eye[3]}}
  active.style=style=='anvil' and 'anvil' or style=='rolling' and 'rolling'
    or (not preview and cloudOnly and (Storm.serial%2==0 and 'anvil' or 'rolling')) or 'forked'
  local variant=nextVariant(active.style)
  active.variant=variant
  if active.style=='forked' then
    for i,p in ipairs(points)do
      local u=(i-1)/(#points-1);local bend=math.sin(math.pi*u)*variant.bend
      p[1]=p[1]+math.cos(az)*bend;p[3]=p[3]-math.sin(az)*bend
    end
  end
  -- Independent shape detail: never consumes the cadence/placement RNG.
  local shapeSeed=Storm.serial*7919+137
  local function shapeRandom(a,b)
    shapeSeed=(shapeSeed*48271)%2147483647
    return a+(b-a)*(shapeSeed-1)/2147483646
  end
  active.branches={}
  for j=1,variant.branches do
    local p=points[j==1 and (3+variant.id%5) or (10+variant.id%4)]
    local branch={p}
    local side=shapeRandom(0,1)<.5 and -1 or 1
    local dx,dz=side*shapeRandom(50,95)*variant.span,shapeRandom(-60,60)*variant.span
    for k=1,6 do
      local u=k/6
      branch[#branch+1]={p[1]+dx*u+shapeRandom(-8,8),
        math.max(0,p[2]-shapeRandom(65,110)*u),p[3]+dz*u+shapeRandom(-8,8)}
    end
    active.branches[#active.branches+1]=branch
  end
  if active.style~='forked' then
    -- Capture the cloud path once, in world coordinates. Crawlers skim just
    -- under the opaque deck; rolling events light its interior without a bolt.
    cloudOnly=true;active.cloudOnly=true
    local range=shapeRandom(1100,1700)
    local cx,cz=eye[1]+math.sin(az)*range,eye[3]+math.cos(az)*range
    local span=(active.style=='rolling' and 1800 or 1000)*variant.span
    local sx,sz=math.cos(az)*span/2,-math.sin(az)*span/2
    active.points={};active.fork=nil;active.branches={}
    for i=0,20 do
      local u=i/20
      if variant.reverse then u=1-u end
      local bend=math.sin(math.pi*u)*variant.bend
      active.points[#active.points+1]={cx+sx*(2*u-1)+math.sin(az)*bend+shapeRandom(-24,24)*variant.jagged,
        cloudY-45+shapeRandom(-14,14),cz+sz*(2*u-1)+math.cos(az)*bend+shapeRandom(-24,24)*variant.jagged}
    end
    if active.style=='anvil' then
      for j=1,variant.branches do
        local p=active.points[j==1 and 7 or 14];local branch={p}
        for k=1,6 do branch[#branch+1]={p[1]+math.sin(az)*k*25+shapeRandom(-12,12),
          p[2]-k*4,p[3]+math.cos(az)*k*25+shapeRandom(-12,12)}end
        active.branches[#active.branches+1]=branch
      end
    end
    active.cloudLight={active.points[1][1],active.points[1][3],
      1/(active.style=='rolling' and 650 or 340),0}
    active.cloudRadius=(1/active.cloudLight[3])*variant.radius
  end
  -- Art-distance mapping, not a claim that voxel units are physical metres.
  if not active.cloudLight then
    active.cloudLight={active.points[1][1],active.points[1][3],1/650,0}
    active.cloudRadius=650
  end
  local front=V.require('QuestStormFront')
  if front.managed then
    local paths={active.points,active.fork or {}}
    for _,p in ipairs(active.branches or {})do paths[#paths+1]=p end
    for _,path in ipairs(paths)do for _,p in ipairs(path)do p[1],p[3]=front.constrain(p[1],p[3])end end
    if active.cloudLight then
      active.cloudLight[1],active.cloudLight[2]=active.points[1][1],active.points[1][3]
      if front.cell then active.cloudRadius=math.min(active.cloudRadius,front.cell.radius*.35)end
    end
  end
  queued={due=Storm.clock+2+3*(distance/math.max(1,math.min(440,far*.58))),
    gain=random(.30,.48)*(cloudOnly and .80 or 1),
    sound=cloudOnly and 'quest_thunder_roll' or 'quest_thunder_clap',pitch=random(.94,1.03)}
end
-- User-requested showcase controls, retained for recording and previews.
function Storm.testStatus(kind)
  if spicy then return 'SPICY ACTIVE' end
  local scene=V.require('Scene').now or {}
  if not scene.outdoor or scene.indoors then return 'OUTDOORS ONLY' end
  if not weatherEligible then return 'STORM ONLY' end
  if Storm.preferences().mode=='off' then return 'LIGHTNING OFF' end
  if (kind=='cloud' and distantTest) or (kind~='cloud' and testRequested) then return 'QUEUED - CLOSE MENU' end
  if distantTest or testRequested or distant or distantQueued or distantReady then return 'WAIT' end
  if active or queued or ready or Storm.clock-lastTest<8 then return 'WAIT' end
  return 'TRIGGER'
end
function Storm.triggerTest(kind)
  if Storm.testStatus(kind)~='TRIGGER' then return false end
  if kind=='cloud' then distantTest=true else testRequested=kind or 'forked' end
  lastTest=Storm.clock
  return true
end
-- Bounded showcase mode; natural storm pace is unchanged.
function Storm.spicyStatus()
  if not spicy then return Storm.testStatus('spicy') end
  local scene=V.require('Scene').now or {}
  if scene.visible~='world' then return 'PAUSED - CLOSE MENU' end
  return ('SPICY %ds - PRESS TO STOP'):format(math.ceil(spicy.left))
end
function Storm.triggerSpicy()
  if spicy then
    spicy=nil;active,queued,ready,distant,distantQueued,distantReady=nil,nil,nil,nil,nil,nil
    Storm.flashValue=0;remaining=gap(Storm.preferences().pace)
    return true
  end
  if Storm.testStatus('spicy')~='TRIGGER' then return false end
  spicy={left=120,wait=0,index=0}
  return true
end
function Storm.update(dt,state,settings)
  dt=math.max(0,math.min(.25,tonumber(dt)or 0))
  Storm.clock=Storm.clock+dt
  local scene=V.require('Scene').now or {}
  local pref=Storm.preferences()
  local weather=state and state.id=='STORM' and (tonumber(state.level)or 0)>0
    and (not settings.worldWeatherEnabled or settings.worldWeatherEnabled())
  local outdoors=scene.outdoor==true and not scene.indoors and scene.visible=='world'
  local front=V.require('QuestStormFront')
  local coverage=front.managed and front.coverage or 1
  weatherEligible=weather and coverage>.25 and scene.outdoor==true and not scene.indoors
  local target=weather and coverage or 0
  Storm.strength=Storm.strength+(target-Storm.strength)*(1-math.exp(-dt/(weather and 9 or 14)))
  if not weather and Storm.strength<.0001 then Storm.strength=0 end
  local nearAllowed=coverage>.25
  local approaching=front.managed and front.cell and (front.warning or 0)>.01
  local eligible=weather and (nearAllowed or approaching) and outdoors and pref.mode~='off'
  if not eligible or (lastMap and lastMap~=scene.mapId) then
    distant,distantQueued,distantReady,distantWait=nil,nil,nil,nil
    active,queued,ready=nil,nil,nil
    Storm.flashValue=0
    wasEligible=false
    remaining=nil
    -- Preserve a menu-requested test until the world is visible, but never
    -- carry it into another map, indoors, clear weather, or lightning OFF.
    if not weatherEligible or pref.mode=='off' or (lastMap and lastMap~=scene.mapId) then
      testRequested=false
      distantTest=false
      spicy=nil
    end
  end
  lastMap=scene.mapId
  if not eligible then return end
  if not wasEligible then remaining=gap(pref.pace);wasEligible=true end
  -- A newly selected pace starts a fresh wait in that pace's advertised range.
  if Storm.lastPace~=pref.pace then remaining=gap(pref.pace);distantWait=nil end
  Storm.lastPace=pref.pace
  if approaching and front.cell.showcaseApproach and not front.cell.showcaseFlashQueued then
    distantWait=5;front.cell.showcaseFlashQueued=true
  end
  remaining=math.max(0,(remaining or 0)-dt)
  if not nearAllowed then remaining=math.max(remaining,12) end
  if spicy then
    spicy.left=spicy.left-dt;spicy.wait=spicy.wait-dt
    remaining=math.max(remaining,12)
    if spicy.left<=0 then spicy=nil;remaining=gap(pref.pace)
    elseif spicy.wait<=0 and not active and not queued and not ready
        and not distant and not distantQueued and not distantReady then
      local styles={'forked','anvil','rolling','cloud'}
      spicy.index=spicy.index%4+1
      local style=styles[spicy.index]
      local savedSeed,savedDistant=Storm.seed,distantSeed
      if style=='cloud' then distantStrike(true) else strike(pref.mode,true,style) end
      Storm.seed,distantSeed=savedSeed,savedDistant
      spicy.wait=12
    end
  elseif distantTest then
    distantStrike(true);distantTest=false
    remaining=math.max(remaining,12);distantWait=nextDistant(pref.pace)
  elseif testRequested then
    strike(pref.mode,true,testRequested);testRequested=false;remaining=gap(pref.pace)
  elseif remaining<=0 and nearAllowed then strike(pref.mode);remaining=gap(pref.pace) end
  Storm.flashValue=0
  if active then
    active.age=active.age+dt
    -- No repeated strobe pulses. FULL is still a restrained single envelope.
    local mode=pref.mode
    local variant=active.variant
    local visualAge=active.age*Storm.FLASH_SPEED
    local life=(active.style=='rolling' and 2.6 or active.style=='anvil' and 1.7
      or mode=='soft' and 1.8 or .85)*variant.fade
    if visualAge>=life then active=nil
    else
      local f=math.sin(math.pi*visualAge/life)^2
      Storm.flashValue=f*(mode=='soft' and .12 or .24)*Storm.strength
      -- Fast luminous core, then a single smooth decay: no repeated strobe.
      local rise=math.min(1,visualAge/(.045*variant.fade))
      local fade=math.max(0,1-math.max(0,visualAge-.045*variant.fade)/(.52*variant.dispersion))
      active.boltAlpha=mode=='full' and rise*rise*(3-2*rise)*fade*fade or 0
      active.reveal=1
      if active.style~='forked' then
        local progress=math.min(1,visualAge/((active.style=='rolling' and 2.3 or 1.05)*variant.dispersion))
        active.reveal=progress
        local path=active.points
        local cursor=progress*(#path-1)
        local index=math.min(#path-1,math.floor(cursor)+1)
        local u=math.min(1,cursor-(index-1))
        active.cloudLight[1]=path[index][1]+(path[index+1][1]-path[index][1])*u
        active.cloudLight[2]=path[index][3]+(path[index+1][3]-path[index][3])*u
        local spread=progress*progress*(3-2*progress)
        active.cloudLight[3]=1/(active.cloudRadius*(.65+.65*spread))
        active.cloudLight[4]=f*(mode=='soft' and .09 or .20)*Storm.strength
        Storm.flashValue=active.style=='anvil' and Storm.flashValue*.35 or 0
        active.boltAlpha=mode=='full' and active.style=='anvil' and f*.85 or 0
      else
        active.cloudLight[3]=1/(650+350*math.min(1,visualAge/life))
        active.cloudLight[4]=f*(mode=='soft' and .065 or .16)*Storm.strength
      end
    end
  end
  if queued and Storm.clock>=queued.due then ready=queued;queued=nil end
  -- Leave nearby strike + thunder space untouched; distant events use only
  -- a quiet gap with enough room for their delayed roll to arrive first.
  distantWait=math.max(0,(distantWait or nextDistant(pref.pace))-dt)
  if not spicy and distantWait<=0 and remaining>11 and Storm.clock-lastNear>6
      and not active and not queued and not ready
      and not distant and not distantQueued and not distantReady then
    distantStrike(false);distantWait=nextDistant(pref.pace)
  end
  if distant then
    distant.age=distant.age+dt
    local visualAge=distant.age*Storm.FLASH_SPEED
    local life=(pref.mode=='soft' and 2.2 or 1.5)*distant.variant.fade
    if visualAge>=life then distant=nil
    else
      local spread=math.min(1,visualAge/(life*distant.variant.dispersion))
      distant.light[3]=1/(distant.radius*(.65+.65*spread*spread*(3-2*spread)))
      distant.light[4]=math.sin(math.pi*visualAge/life)^2
        *(pref.mode=='soft' and .07 or .14)*math.max(Storm.strength,
          approaching and (front.cell.strength or 0)*math.min(1,(front.warning or 0)*2) or 0)
    end
  end
  if distantQueued and Storm.clock>=distantQueued.due then
    distantReady=distantQueued;distantQueued=nil
  end
end
function Storm.consumeThunder()
  if ready then local event=ready;ready=nil;return event end
  local event=distantReady;distantReady=nil;return event
end
function Storm.flash() return Storm.flashValue end
function Storm.bolt() return active end
function Storm.status()
  return {wait=remaining,flash=Storm.flashValue,strength=Storm.strength,
    serial=Storm.serial,active=active~=nil,pendingThunder=queued~=nil,
    readyThunder=ready~=nil,distantActive=distant~=nil,
    distantPending=distantQueued~=nil,distantReady=distantReady~=nil,distantWait=distantWait,
    distantVariant=distant and distant.variant.id or nil}
end
function Storm.tint(base,outdoor,sky)
  if not outdoor then return base end
  local scene=V.require('Scene').now or {}
  local strength=Storm.strength
  local recovery=V.require('QuestAfterStorm')
  strength=math.max(strength,(recovery.cloud or 0)*.85)
  local f=scene.visible=='world' and scene.outdoor and not scene.indoors and Storm.flashValue or 0
  if strength<=0 and f<=0 then return base end
  local multiplier=1-strength*(sky and .22 or .18)
  return {math.min(1,base[1]*multiplier+f*.70),
    math.min(1,base[2]*multiplier+f*.80),math.min(1,base[3]*multiplier+f)}
end
function Storm.bindCamera(worldVoxel) voxel=worldVoxel end
function Storm.attach(hostLib,worldVoxel)
  voxel=worldVoxel
  if host then return end
  local dn,sky,clouds=hostLib.require('DayNight'),hostLib.require('Sky'),hostLib.require('Clouds')
  host={dayNight=dn,sky=sky,clouds=clouds}
  host.renderer=hostLib.require('Voxel3D')
  originalWeatherHaze=host.renderer.weatherHazeProvider
  host.renderer.weatherHazeProvider=function()
    local scene=V.require('Scene').now or {}
    if not scene.outdoor or scene.indoors then return 0 end
    return (V.require('QuestStormFront').haze or 0)*.00010,sky.haze()
  end
  originalCloudLightning=clouds.lightningProvider
  clouds.lightningProvider=Storm.cloudLightning
  originalStormFront=clouds.stormFrontProvider
  clouds.stormFrontProvider=function()return V.require('QuestStormFront').cloudField()end
  if type(dn.tint)=='function' then
    originalTint=dn.tint
    dn.tint=function(outdoor,t) return Storm.tint(originalTint(outdoor,t),outdoor,false) end
  end
  -- Uniform modulation, not rebuilding palette textures during each flash.
  originalProvider=sky.atmosphereProvider
  sky.atmosphereProvider=function()
    local recovery=V.require('QuestAfterStorm')
    return math.max(Storm.strength,(recovery.cloud or 0)*.85)*.22,Storm.flashValue
  end
end
function Storm.detach()
  if host then
    if originalTint then host.dayNight.tint=originalTint end
    host.sky.atmosphereProvider=originalProvider
    host.clouds.lightningProvider=originalCloudLightning
    host.clouds.stormFrontProvider=originalStormFront
    host.renderer.weatherHazeProvider=originalWeatherHaze
  end
  host,voxel,originalTint,originalProvider=nil,nil,nil,nil
  originalCloudLightning=nil
  Storm.reset()
end
if V.mod and V.mod.events then
  for _,name in ipairs({'save.loaded','save.created'})do V.mod.events:on(name,Storm.reset) end
end
return Storm
