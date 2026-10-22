local mod,loadModule,V,shared=...
local Map=require('src.core.game3.map')
local Runtime=require('src.core.game3.runtime')
local Player=require('src.core.game3.player')
local Connections=require('src.core.game3.connections')
local UiStack=require('src.ui.game3.stack')
local H=loadModule('compat/gen3/HoennWeatherProfiles.lua')
local Scene=V.require('Scene')
local outdoorTypes={[1]=true,[2]=true,[3]=true,[6]=true}
local function definition(id)
 local g=Runtime._game
 return g and g.data and g.data.maps and g.data.maps[id] or Map.currentDef and id==Map.current and Map.currentDef()
end
local oldSample=Scene.sample
Scene.sample=function(...)
 local s=oldSample(...)
 local session=Runtime.getSession()
 local def=Map.currentDef and Map.currentDef()
 if session and def then
  s.mapId=Map.current
  s.outdoor=outdoorTypes[def.mapType]==true;s.indoors=not s.outdoor
  s.isTown=(def.mapType==1 or def.mapType==2) and s.outdoor
  s.playerX=tonumber(Player.px) or (tonumber(Player.cellX) or 0)*16
  s.playerZ=tonumber(Player.py) or (tonumber(Player.cellY) or 0)*16
  -- Native Game3 field handle can lack the Gen1 isOverworld marker.
  if UiStack.fullscreen() then
   s.visible='hidden'
  elseif s.visible=='hidden' then
   local g=Runtime._game;local stack=g and g.stack and g.stack.states
   local covered=false
   for _,state in ipairs(stack or {})do
    if state.isOpaque and not state.isOverworld and state~=g.world and state~=g.overworld then covered=true end
   end
   if not covered then s.visible='world' end
  end
 end
 return s
end
local Regional=V.require('QuestRegional')
Regional.profile=function(id)return H.profile(id,definition(id))end
Regional.weight=function(id,weather)
 if Regional.enabled and not Regional.enabled()then return 1 end
 return H.weight(Regional.profile(id),weather)
end
local Nature=V.require('QuestNature');Nature.pool={}
local Front=V.require('QuestStormFront')
Front.contextProvider=function()
 local s=Scene.now or {};local root=s.mapId;local def=definition(root)
 if not def then return nil end
 local maps={[root]={width=def.width,height=def.height,connections={}}}
 for _,c in ipairs(Connections.each(def) or {})do
  local other=definition(c.map)
  if other then
   maps[c.map]={width=other.width,height=other.height,connections={}}
   local dir=({north='north',south='south',east='east',west='west',
    up='north',down='south',left='west',right='east'})[c.dir]
   if dir then maps[root].connections[dir]={mapId=c.map,offset=(c.offset or 0)/2}end
  end
 end
 return {maps=maps,mapId=root,climateMapId=root,x=s.playerX or 0,z=s.playerZ or 0,
  offsetX=0,offsetZ=0,outdoor=s.outdoor,indoors=s.indoors,visible=s.visible}
end
shared.hoenn=H
return {definition=definition,profiles=H}
