local root=assert(arg[1],'mod root required')
local function module(path,...)
  return assert(loadfile(root..'/'..path))(...)
end

-- Gen 2 raw map definitions name destinations mapId; Gen 1 uses map.
local modules={}
local V={mod={events={on=function()end},find=function()return nil end,exports={}}}
function V.require(name)return modules[name]end
modules.OutdoorWeatherAreas={position=function(id,x,z)return id,x,z,0,0 end}
modules.QuestStorm={preferences=function()return {motion='moving'}end}
modules.QuestRegional={front=function(a,s,r,l)return a,s,r,l end}
local Storm=module('lib/QuestStormFront.lua',V)
local graph=assert(Storm.buildGraph({
  ROUTE_29={width=10,height=8,connections={east={mapId='NEW_BARK_TOWN',offset=1}}},
  NEW_BARK_TOWN={width=12,height=9,connections={west={mapId='ROUTE_29',offset=1}}},
},'ROUTE_29'))
assert(graph.NEW_BARK_TOWN and graph.NEW_BARK_TOWN.x==320)
local graph1=assert(Storm.buildGraph({
  ROUTE_1={width=10,height=8,connections={north={map='VIRIDIAN_CITY',offset=0}}},
  VIRIDIAN_CITY={width=12,height=9,connections={}},
},'ROUTE_1'))
assert(graph1.VIRIDIAN_CITY and graph1.VIRIDIAN_CITY.z==-288)

-- The shared encounter API feeds time-correct Gen 2 species to local cries.
local registered={
  HOOTHOOT={dex=163,evolutions={{species='NOCTOWL'}}},NOCTOWL={dex=164,evolutions={}},
}
local world={effectiveEncounters=function(_,map,terrain,opts)
  assert(map=='ROUTE_29' and terrain=='grass' and opts.daytime=='NITE')
  return {chance=.25,dist={NOCTOWL=.5}}
end}
local dayNight={time=function()return 700 end}
local natureV={mod={
  world=world,
  assets={path=function(_,p)return p end},
}}
local natureModules={
  RouteCalls=module('lib/RouteCalls.lua'),QuestCryIndex={},
  Interop={dayNight=function()return dayNight,'BATTLE_ART_VOXEL_GEN2'end},
  QuestNatureBeds={new=function()return {update=function()end,reset=function()end}end},
  Scene={now={visible='hidden'}},WeatherState={},QuestStormFront={},
}
function natureV.require(name)return natureModules[name]end
package.loaded['src.core.Game']={data={pokemon=registered},save={options={}}}
local Nature=module('lib/QuestNature.lua',natureV)
Nature.update(.1,1)
natureModules.Scene.now={visible='world',outdoor=true,indoors=false,mapId='ROUTE_29'}
Nature.update(.1,1)
assert(#Nature.pool==2 and Nature.pool[1]=='HOOTHOOT' and Nature.pool[2]=='NOCTOWL')

-- Johto gets authored climate identities instead of BALANCED.
package.loaded['src.core.Game']={save={options={qRegionalWeather=true}}}
local regionalV={require=function(name)
  assert(name=='OutdoorWeatherAreas');return {identity=function(id)return id end}
end}
local Regional=module('lib/QuestRegional.lua',regionalV)
assert(Regional.profile('NEW_BARK_TOWN').label=='SOUTHEAST JOHTO')
assert(Regional.profile('ROUTE_43').label=='LAKE OF RAGE')
assert(Regional.profile('ROUTE_27').label=='JOHTO HIGHLANDS')

-- Region prefix matching is boundary-aware: ROUTE_10 is not ROUTE_1.
local frontModules={
  OutdoorWeatherAreas={identity=function(id)return id end},
  Types={DEFAULT='CLEAR',get=function(id)return {id=id}end,list={}},
  Config={get=function()return {fronts={enabled=true,drift=.5}}end,
    weatherEnabled=function()return true end},
}
local frontsV={mod={save={get=function()end,set=function()end}}}
function frontsV.require(name)return frontModules[name]end
local Fronts=module('lib/Fronts.lua',frontsV)
assert(Fronts.regionFor('ROUTE_1').id=='PALLET')
assert(Fronts.regionFor('ROUTE_10').id=='LAVENDER')

-- Renderer routing recognizes Gen 2 Battle Art and keeps standalone Quest
-- on the verified per-eye bridge.
local Router=module('compat/Router.lua')
local key,owner=Router.select('voxel','BATTLE_ART_VOXEL_GEN2','Windows',false)
assert(key=='battle_art_gen2' and owner=='BATTLE_ART_VOXEL_GEN2')
key=Router.select('voxel','BATTLE_ART_VOXEL_GEN2','Android',true)
assert(key=='battle_art_quest')

local interopV={mod={find=function(id)
  if id=='BATTLE_ART_VOXEL_GEN2' then
    return {exports={lib={require=function(name)
      assert(name=='DayNight');return dayNight
    end}}}
  end
end}}
local Interop=module('lib/Interop.lua',interopV)
local discovered,discoveredId=Interop.dayNight()
assert(discovered==dayNight and discoveredId=='BATTLE_ART_VOXEL_GEN2')

print('Gen 2 weather compatibility: PASS')
