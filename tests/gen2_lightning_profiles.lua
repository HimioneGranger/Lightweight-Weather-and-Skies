local root=assert(arg[1])
local scene={now={mapId='ROUTE_29',outdoor=true,indoors=false,visible='world'}}
local weather={id='STORM',level=1,current=function()return{ch={rain=1}}end}
local modules={Scene=scene,QuestStormFront={managed=false,coverage=1,warning=0},
  OutdoorWeatherAreas={identity=function(id)return id end},
  QuestRegional={lightningRate=function()return 1 end}}
local V={mod={exports={weatherPreferences={storm=function()
  return{mode='full',pace='rare'}end}}},require=function(name)return assert(modules[name],name)end}
local settings={worldWeatherEnabled=function()return true end}
local total=0
for _,kind in ipairs({'forked','anvil','rolling','cloud'})do
  local storm=assert(loadfile(root..'/lib/QuestStorm.lua'))(V)
  modules.QuestStorm=storm
  storm.bindCamera({eye={0,40,0},focus={0,40,-100},far=5000})
  local bolt=assert(loadfile(root..'/lib/QuestStormBolt.lua'))(V)
  local profiles=storm.VARIANTS[kind]
  assert(#profiles==20,kind..' does not have twenty profiles')
  local signatures={}
  local bounds={fade={.82,1.18},dispersion={.78,1.32},width={.84,1.20},
    span={.76,1.30},radius={.735,1.23},bend={-117,117},
    anvilWidth={1.705,2.20},jagged={.55,1.36},branches={1,2},anvilBranches={3,5}}
  for id,p in ipairs(profiles)do
    assert(p.id==id and p.kind==kind,'invalid profile identity')
    for key,b in pairs(bounds)do
      assert(p[key]>=b[1]-1e-9 and p[key]<=b[2]+1e-9,kind..' expanded '..key)
    end
    if id<=10 then
      assert(p.fade==.78+.04*id and p.span==.70+.06*id
        and p.radius==.68+.055*id,'original profile changed')
    end
    local signature=table.concat({p.fade,p.dispersion,p.radius},',')
    assert(not signatures[signature],'duplicate effective timing/light profile')
    signatures[signature]=true
    total=total+1
  end
  local previousId,previousOrder
  for cycle=1,3 do
    local seen,order={},{}
    for i=1,20 do
      storm.reset();storm.update(1/90,weather,settings)
      assert(storm.triggerTest(kind),'profile showcase failed')
      storm.update(1/90,weather,settings)
      local event=storm.bolt()
      local id=kind=='cloud' and storm.status().distantVariant or event.variant.id
      assert(id and not seen[id],'shuffle repeats before exhausting the family')
      assert(id~=previousId,'immediate profile repeat at shuffle boundary')
      seen[id]=true;order[#order+1]=id;previousId=id
      if kind=='anvil' or kind=='forked' then
        if kind=='forked' then
          assert(event.prominentForks==(id%2==1),'ground fork variety changed')
          for _,branch in ipairs(event.branches)do
            assert(#branch==7,'ground branch gained segments')
            local a,b=branch[1],branch[#branch]
            local reach=math.sqrt((a[1]-b[1])^2+(a[3]-b[3])^2)
            assert(event.prominentForks and reach>=180 or
              not event.prominentForks and reach<180,'ground fork reach is wrong')
            assert(b[2]>=0 and b[2]<a[2],'ground fork must descend above ground')
          end
        end
        assert(#bolt.vertices(event)<=(kind=='anvil' and 1944 or 864),
          'profile exceeded existing geometry cap')
        local progress,paths=bolt.pathProgress(event)
        for _,path in ipairs(paths)do
          if path.parentPath then
            assert(path[1]==path.parentPath[path.parentPoint]
              and progress[path][1]==progress[path.parentPath][path.parentPoint],
              'profile has detached branch geometry or reveal')
          end
        end
      elseif kind=='rolling' then
        assert(event.boltAlpha==0,'rolling profile exposed a sharp bolt')
      end
    end
    local sequence=table.concat(order,',')
    assert(sequence~=previousOrder,'shuffle repeated its complete previous order')
    previousOrder=sequence
  end
end
assert(total==80,'lightning profile total is not eighty')
print('80 lightning profiles, bounded envelopes, geometry and shuffle cycles: PASS')
