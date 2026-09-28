local root=assert(arg[1],'mod root required')
local function module(path,...)
  return assert(loadfile(root..'/'..path))(...)
end

local wrapped
local mod={id='the_world_weather_quest_lite_private',exports={
  rendererReady=function()return true end,
}}
mod.hooks={wrap=function(_,name,fn,priority)
  assert(name=='ui.options.rows' and priority==1000)
  wrapped=fn
end}

local settings={}
function settings:constellationsRow()
  return {id=mod.id..':skyConstellations',label='CONSTELLATIONS'}
end
function settings:stormRows()return{}end
function settings:_writeOption()end

local adapter={exports={lib={require=function(name)
  assert(name=='DayNight')
  return {setting={row=function()
    return {id='BATTLE_ART_VOXEL_GEN2:daytime',label='DAYTIME'}
  end}}
end}}}

local stubs={
  QuestNature={status=function()return'READY'end,trigger=function()return true end},
  QuestRegional={profile=function()return{label='JOHTO'}end},
  Scene={now={mapId='ROUTE_29',outdoor=true}},
  QuestStorm={testStatus=function()return'TEST'end,triggerTest=function()return true end,
    spicyStatus=function()return'OFF'end,triggerSpicy=function()return true end},
  QuestStormFront={status=function()return'CLEAR'end,trigger=function()return true end,
    triggerApproach=function()return true end},
  QuestSkyEvents={status=function()return'TRIGGER'end,trigger=function()return true end},
  WeatherState={LEVEL_IDS={'AUTO','CLEAR','STORM','PARTLY_SNOW'},setWeather=function()end},
  QuestMoon={previewStatus=function()return'FULL'end,previewNext=function()return true end},
  NightSky={meteorStatus=function()return{day=0}end},
  QuestAfterStorm={testStatus=function()return'READY'end,triggerTest=function()return true end},
}
local world={lib={require=function(name)
  return assert(stubs[name],'missing stub '..tostring(name))
end}}

module('compat/Controls.lua')(mod,settings,adapter,function()return world end)
assert(type(wrapped)=='function')
local rows=wrapped(function(_,input)return input end,{},
  {{id='pipeline:weather',label='WEATHER'},
   {id='BATTLE_ART_VOXEL_GEN2:daytime',label='DAYTIME'}})
local lite
for _,row in ipairs(rows)do if row.id=='quest:lite_weather_fx'then lite=row end end
assert(lite and type(lite.activate)=='function')

local Gen2Menu={}
Gen2Menu.__index=Gen2Menu
package.loaded['src.ui.gen2.OptionsMenu']=Gen2Menu
package.loaded['src.ui.OptionsMenu']=nil
package.loaded['src.ui.OptionRows']=nil
local pushed
local options={}
local game={options=options,save={options=options},stack={
  push=function(_,screen)pushed=screen end,
  top=function()return pushed end,
},applyOptions=function(self)self.applied=true end,
persistOptions=function(self)self.persisted=true end}
lite.activate(game)
assert(pushed and getmetatable(pushed)==Gen2Menu)
assert(pushed.options==options and pushed.view[#pushed.view].cancel==true)
assert(package.loaded['src.ui.OptionRows']==nil,'Gen 1 OptionRows must not load on Gold')
pushed.onDone(options)
assert(game.applied and game.persisted)

-- Gen 1 OptionsMenu.new rebuilds the root Options rows and ignores opts.rows.
-- The weather and nested Showcase pages must use the native screen shape.
local Gen1Menu={}
Gen1Menu.__index=Gen1Menu
package.loaded['src.ui.OptionsMenu']=Gen1Menu
local gen1Pushed
local gen1Game={save={options={}},stack={
  push=function(_,screen)gen1Pushed=screen end,
}}
lite.activate(gen1Game)
assert(gen1Pushed and getmetatable(gen1Pushed)==Gen1Menu)
assert(gen1Pushed.game==gen1Game and gen1Pushed.index==1)
assert(gen1Pushed.rows==lite.members)
local showcase
for _,row in ipairs(gen1Pushed.rows)do
  if row.id=='quest:showcase_controls'then showcase=row end
end
assert(showcase and type(showcase.activate)=='function')
showcase.activate(gen1Game)
assert(gen1Pushed.rows==showcase.members)
assert(gen1Pushed.rows~=lite.members)

-- A Gen 2 install gets its own one-time AUTO marker.  This is intentionally
-- distinct from the older Gen 1 marker so a stale cross-generation options
-- table cannot leave the weather pipeline silently OFF.
local prefMod={id=mod.id,options={values={}}}
function prefMod.options:define()end
function prefMod.options:get(key)return self.values[key]end
local gen2Options={}
local gen2Game={options=gen2Options,save={options=gen2Options},mods={},
  persistOptions=function(self)self.persisted=true end}
local setting={values={'off','cycle'},setIndex=function(self,index,owner)
  assert(index==2 and owner==gen2Game);self.selected=index
end}
local state={level=0}
local tod={pin='night'}
local pipelineLevel=0
local pipelines={
  setLevel=function(id,level)assert(id=='weather');pipelineLevel=level;return level end,
  syncOptions=function(opts)opts.pipelines={weather=pipelineLevel}end,
}
local Preferences=module('compat/Preferences.lua')
local prefs=Preferences.new(prefMod,function(name)
  assert(name=='src.core.Game');return gen2Game
end)
assert(prefs:applyNaturalDefaults(gen2Game,{require=function(name)
  assert(name=='DayNight');return{setting=setting}
end},{require=function(name)
  if name=='WeatherState'then return state end
  if name=='TimeOfDay'then return tod end
  error(name)
end},pipelines))
assert(pipelineLevel==1 and state.level==1)
assert(gen2Options.lwsGen2NaturalDefaultsV1==true and gen2Options.qRegionalWeather==true)
assert(tod.pin==nil and setting.selected==2 and gen2Game.persisted)

print('Gen 2 weather controls: PASS')
