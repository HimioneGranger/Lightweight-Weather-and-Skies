-- Only the Emerald TWS sandbox installs this adapter. It does not replace
-- engine require or import legacy Gen1 implementations into a Gen3 session.
local mod,nativeRequire=...
local Runtime=nativeRequire('src.core.game3.runtime')
local warned={}
local function unsupported(name)
 if not warned[name]then warned[name]=true;mod.log:warn('rse: unsupported legacy mutation %s',name)end
 error('unsupported Emerald weather legacy mutation: '..name,2)
end
local function readonly(t,label)
 return setmetatable({}, {__index=t,__newindex=function(_,k)unsupported(label..'.'..tostring(k))end})
end
local game=setmetatable({}, {
 __index=function(_,key)
  local g=Runtime._game
  if key=='overworld' or key=='world' then
   return mod.world:overworld()
  end
  if key=='save' then return g and g.save or Runtime.getSession()end
  if key=='options' then
   local s=Runtime.getSession();return g and g.options or s and s.options
  end
  local value=g and g[key]
  if type(value)=='function'then
   return function()unsupported('Game.'..tostring(key))end
  end
  return value
 end,
 __newindex=function(_,key)unsupported('Game.'..tostring(key))end,
})
local outdoor={[1]=true,[2]=true,[3]=true,[6]=true}
local function isOutside(def)return type(def)=='table' and outdoor[tonumber(def.mapType)]==true end
local map=readonly({isOutdoor=isOutside,isOutside=isOutside},'Map')
-- Native battles are services, not Gen1 StateStack instances. Activity is
-- supported; the legacy BattleState.draw wrapper has no compatible native
-- signature and must remain unavailable instead of patching engine draw.
local battle=readonly({
 isActive=function()return nativeRequire('src.core.game3.battle').isActive()end,
 state=function()return nativeRequire('src.core.game3.battle').getState()end,
},'BattleState')
local adapters={['src.core.Game']=game,['src.world.Map']=map,['src.battle.BattleState']=battle}
return function(name)
 if adapters[name]then return adapters[name]end
 -- Permissions, missing modules and genuine native failures retain the
 -- original sandbox require behavior; only three known legacy reads adapt.
 return nativeRequire(name)
end