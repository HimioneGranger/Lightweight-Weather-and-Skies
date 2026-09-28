local root=assert(arg[1])
local draws,meshVertices,uniforms,meshes,releases=0,0,{},0,0
love={graphics={
  newShader=function()return{send=function(_,name,value)uniforms[name]=value end}end,
  newMesh=function(_,vertices)
    meshes=meshes+1
    meshVertices=#vertices
    return{release=function()releases=releases+1 end}
  end,
  push=function()end,pop=function()end,setShader=function()end,
  setColor=function()end,setBlendMode=function()end,setDepthMode=function()end,
  setMeshCullMode=function()end,draw=function()draws=draws+1 end,
}}
local scene={now={mapId='ROUTE_29',outdoor=true,indoors=false,visible='world'}}
local front={managed=false,coverage=1,warning=0}
local weather={id='STORM',level=1,current=function()
  return{ch={rain=1}}
end}
local modules={Scene=scene,QuestStormFront=front,
  OutdoorWeatherAreas={identity=function(id)return id end},
  QuestRegional={lightningRate=function()return 1 end}}
local V={mod={exports={weatherPreferences={storm=function()
  return{mode='full',pace='active'}
end}}},require=function(name)return assert(modules[name],name)end}
local storm=assert(loadfile(root..'/lib/QuestStorm.lua'))(V)
modules.QuestStorm=storm
local voxel={eye={0,40,0},focus={0,40,-100},vp={}}
storm.bindCamera(voxel)
local settings={worldWeatherEnabled=function()return true end}
storm.update(1/90,weather,settings)
assert(storm.triggerTest('forked'),'forked showcase did not queue')
storm.update(1/90,weather,settings)
local event=assert(storm.bolt(),'forked event was not scheduled')
assert(event.style=='forked' and not event.cloudOnly and event.boltAlpha>0,
  'forked showcase is not a visible full-mode strike')
assert(event.distance>=2100 and event.distance<=2500,
  'full-height strike is still too close to fit below the cloud deck')
assert(math.atan2(event.points[1][2]-voxel.eye[2],event.distance)<math.pi/4,
  'cloud-to-ground path starts above a level Quest field of view')
local bolt=assert(loadfile(root..'/lib/QuestStormBolt.lua'))(V)
assert(bolt.drawWorld(voxel),'forked event did not reach the world renderer')
assert(meshVertices>0 and draws==1 and uniforms.opacity>0,
  'forked bolt geometry or opacity is missing')
assert(bolt.drawWorld(voxel),'second eye did not draw the shared strike mesh')
assert(meshes==1 and releases==0 and draws==2,
  'stereo draw rebuilt or released a same-event strike mesh')
assert(storm.consumeThunder()==nil,'thunder played before the visible strike')
local thunder
for _=1,140 do
  storm.update(1/90,weather,settings)
  thunder=storm.consumeThunder() or thunder
end
assert(thunder and thunder.sound=='quest_thunder_clap',
  'the visible forked strike did not deliver its clap within 1.6 seconds')
print('Gen2 lightning strike scheduling and draw: PASS')
