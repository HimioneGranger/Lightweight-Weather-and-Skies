local root=assert(arg[1])
local savedTime=os.time
os.time=function()return 1700000000 end
local scene={now={mapId='ROUTE_29',outdoor=true,indoors=false,visible='world'}}
local front={managed=false,coverage=1,warning=0}
local weather={id='STORM',level=1,current=function()return{ch={rain=1}}end}
local modules={Scene=scene,QuestStormFront=front,
  OutdoorWeatherAreas={identity=function(id)return id end},
  QuestRegional={lightningRate=function()return 1 end}}
local lightningMode='full'
local V={mod={exports={weatherPreferences={storm=function()
  return{mode=lightningMode,pace='active'}
end}}},require=function(name)return assert(modules[name],name)end}
local storm=assert(loadfile(root..'/lib/QuestStorm.lua'))(V)
os.time=savedTime
modules.QuestStorm=storm
storm.seed=24681357
storm.bindCamera({eye={0,40,0},focus={0,40,-100},far=5000})
local settings={worldWeatherEnabled=function()return true end}

storm.update(1/90,weather,settings)
local firstWait=assert(storm.status().wait)
assert(storm.ACTIVITY_MULTIPLIER==1.85,
  'post-launch activity multiplier changed unexpectedly')
assert(firstWait>=8/storm.ACTIVITY_MULTIPLIER-1/30
    and firstWait<=18/storm.ACTIVITY_MULTIPLIER,
  'active natural-lightning wait is outside the tuned range')
assert(storm.GROUND_STRIKE_CHANCE>.50 and storm.GROUND_STRIKE_CHANCE<.70,
  'regular ground strikes are not the natural majority')
assert(storm.ANVIL_CLOUD_SHARE>.65 and storm.ANVIL_CLOUD_SHARE<.80,
  'cloud-only mix no longer favors anvil crawlers')

assert(storm.triggerTest('anvil'),'anvil showcase did not queue')
storm.strength=1
storm.update(1/90,weather,settings)
local event=assert(storm.bolt(),'anvil event was not scheduled')
assert(event.style=='anvil' and event.cloudOnly,
  'anvil request did not produce a cloud crawler')
assert(#event.branches>=3 and #event.branches<=5,
  'anvil crawler branch count is outside the bounded variety range')
assert(#event.twigs>=6 and #event.twigs<=10,
  'anvil crawler secondary fork count escaped its budget')
local dx=event.points[1][1]
local dz=event.points[1][3]
local horizontal=math.sqrt(dx*dx+dz*dz)
assert(math.atan2(event.points[1][2]-40,horizontal)<math.pi/4,
  'anvil crawler starts above a level Quest field of view')

local a,b=event.points[1],event.points[#event.points]
local span=math.sqrt((a[1]-b[1])^2+(a[3]-b[3])^2)
assert(span>=1480,'anvil crawler is not long enough')
local bend=0
for i=2,#event.points-1 do
  local p=event.points[i]
  local cross=math.abs((p[1]-a[1])*(b[3]-a[3])-(p[3]-a[3])*(b[1]-a[1]))/span
  bend=math.max(bend,cross)
end
assert(bend>=35,'anvil main channel reads as a straight wire')
for _,branch in ipairs(event.branches)do
  assert(#branch==8,'anvil branch segment budget changed')
  local p,q=branch[1],branch[#branch]
  local reach=math.sqrt((p[1]-q[1])^2+(p[3]-q[3])^2)
  assert(reach>=150,'anvil branch is too short to read at cloud distance')
end
for _,twig in ipairs(event.twigs)do
  assert(#twig==3,'anvil secondary fork segment budget changed')
end

local bolt=assert(loadfile(root..'/lib/QuestStormBolt.lua'))(V)
local width=bolt.widthScale(event,1)
assert(width>1.3 and width<2.7,
  'anvil width is not within the thinner visible-core range')
local progress,paths=bolt.pathProgress(event)
for _,path in ipairs(paths)do
  if path.parentPath then
    assert(path[1]==path.parentPath[path.parentPoint],
      'child geometry is detached from its parent junction')
    assert(progress[path][1]==progress[path.parentPath][path.parentPoint],
      'child reveal starts before or after its parent junction')
  end
  for i=2,#path do
    assert(progress[path][i]>progress[path][i-1],
      'path reveal does not advance toward its tip')
  end
end
local vertices=bolt.vertices(event)
assert(#vertices>=1464 and #vertices<=1944,
  'anvil mesh escaped the bounded vertex budget')
local offset=0
for _,path in ipairs(paths)do
  for i=1,#path-1 do
    assert(vertices[offset+1][9]==progress[path][i]
      and vertices[offset+3][9]==progress[path][i+1],
      'mesh BoltProgress differs from the parent-aware reveal')
    offset=offset+24
  end
end
assert(offset==#vertices,'unexpected vertices outside crawler paths')

local maxFlash,maxCloud=0,0
for _=1,100 do
  storm.update(1/90,weather,settings)
  maxFlash=math.max(maxFlash,storm.flash())
  local light=storm.cloudLightning()
  if light then maxCloud=math.max(maxCloud,light[4]or 0)end
end
assert(maxFlash>.10 and maxFlash<=1,
  'anvil world illumination is not stronger and bounded')
assert(maxCloud>.20 and maxCloud<=1,
  'anvil cloud illumination is not stronger and bounded')

-- SOFT keeps its gentler natural envelope even in verification mode.
storm.reset()
lightningMode='soft'
storm.update(1/90,weather,settings)
assert(storm.triggerSpicy(),'soft spicy showcase did not start')
storm.strength=1
local maxSoftFlash,maxSoftCloud=0,0
for _=1,180 do
  storm.update(1/90,weather,settings)
  maxSoftFlash=math.max(maxSoftFlash,storm.flash())
  local softEvent=storm.bolt()
  if softEvent then assert(softEvent.boltAlpha==0,'SOFT drew sharp bolt geometry')end
  local light=storm.cloudLightning()
  if light then maxSoftCloud=math.max(maxSoftCloud,light[4]or 0)end
end
assert(maxSoftFlash<=.121,'SOFT showcase boosted the world flash')
assert(maxSoftCloud<=.091,'SOFT showcase boosted cloud illumination')
assert(storm.bolt()==nil,'SOFT showcase extended the natural flash duration')

-- An explicit SOFT anvil keeps its pre-redesign duration and cloud travel.
storm.reset()
storm.update(1/90,weather,settings)
assert(storm.triggerTest('anvil'),'SOFT anvil showcase did not queue')
storm.strength=1
storm.update(1/90,weather,settings)
local softAnvil=assert(storm.bolt(),'SOFT anvil was not scheduled')
assert(softAnvil.boltAlpha==0,'SOFT anvil drew bolt geometry')
for _=1,35 do storm.update(1/90,weather,settings)end
softAnvil=assert(storm.bolt(),'SOFT anvil expired before its old lifetime')
local expectedTravel=math.min(1,softAnvil.age*storm.FLASH_SPEED/
  (1.05*softAnvil.variant.dispersion))
assert(math.abs(softAnvil.reveal-expectedTravel)<1e-9,
  'SOFT anvil cloud light travel changed from the old timing')
local softExpiry=1.7*softAnvil.variant.fade/storm.FLASH_SPEED
while softAnvil.age+1/90<softExpiry do
  storm.update(1/90,weather,settings)
  softAnvil=assert(storm.bolt(),'SOFT anvil expired before its old lifetime')
end
storm.update(1/90,weather,settings)
assert(storm.bolt()==nil,'SOFT anvil outlived its old duration')

-- Even at the 2x regional cadence, a new near event must wait for the prior
-- thunder slot to be consumed instead of overwriting it.
storm.reset()
lightningMode='full'
modules.QuestRegional.lightningRate=function()return 2 end
storm.GAPS.active={1,1}
storm.update(.25,weather,settings)
local first
for _=1,12 do
  storm.update(.25,weather,settings)
  first=first or storm.bolt()
end
first=assert(first,'fast regional cadence did not schedule a strike')
local firstId=first.id
for _=1,16 do storm.update(.25,weather,settings)end
assert(storm.status().serial==firstId,
  'fast cadence overwrote an active or pending-thunder event')
assert(storm.consumeThunder(),'protected strike never delivered thunder')
storm.update(.25,weather,settings)
assert(storm.status().serial==firstId+1,
  'scheduler did not resume after thunder was consumed')
-- The same parent-node rule also applies to the original ground bolt forks.
storm.reset()
modules.QuestRegional.lightningRate=function()return 1 end
storm.update(1/90,weather,settings)
assert(storm.triggerTest('forked'),'ground fork reveal test did not queue')
storm.update(1/90,weather,settings)
local ground=assert(storm.bolt(),'ground fork event was not scheduled')
local groundProgress,groundPaths=bolt.pathProgress(ground)
for _,path in ipairs(groundPaths)do
  if path.parentPath then
    assert(path[1]==path.parentPath[path.parentPoint],
      'ground fork is detached from its parent')
    assert(groundProgress[path][1]==groundProgress[path.parentPath][path.parentPoint],
      'ground fork starts before its parent junction')
  end
end
-- Every authored anvil profile must remain inside the same GPU geometry cap.
local seen,maxProfileVertices={},0
for _=1,40 do
  storm.reset()
  storm.update(1/90,weather,settings)
  assert(storm.triggerTest('anvil'),'profile showcase did not queue')
  storm.update(1/90,weather,settings)
  local sample=assert(storm.bolt(),'profile crawler was not scheduled')
  seen[sample.variant.id]=true
  local sampleVertices=bolt.vertices(sample)
  maxProfileVertices=math.max(maxProfileVertices,#sampleVertices)
  assert(#sampleVertices<=1944,'anvil profile exceeded the GPU vertex cap')
  assert(#sample.branches>=3 and #sample.branches<=5
    and #sample.twigs>=6 and #sample.twigs<=10,'profile branch budget changed')
  local start,finish=sample.points[1],sample.points[#sample.points]
  local reach=math.sqrt((start[1]-finish[1])^2+(start[3]-finish[3])^2)
  assert(reach>=1480,'expanded profile lost its larger main-channel span')
  local sampleProgress,samplePaths=bolt.pathProgress(sample)
  for _,path in ipairs(samplePaths)do
    if path.parentPath then
      assert(path[1]==path.parentPath[path.parentPoint]
        and sampleProgress[path][1]==sampleProgress[path.parentPath][path.parentPoint],
        'anvil profile child detached from parent junction')
    end
  end
end
local profileCount=0
for _ in pairs(seen)do profileCount=profileCount+1 end
assert(profileCount==20,'authored anvil profiles were not all sampled')
assert(maxProfileVertices==1944,'five-branch crawler did not match the 1,944-vertex cap')
print('Gen2 lightning variety, activity, illumination, and mesh budget: PASS')
