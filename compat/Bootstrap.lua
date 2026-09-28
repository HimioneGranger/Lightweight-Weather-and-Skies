local mod=...
local function module(name)
  return assert((loadstring or load)(assert(mod:read('compat/'..name..'.lua')),'@weather/compat/'..name))()
end
local settings=module('Preferences').new(mod)
local platformPolicy=module('Platform')
settings:define()
local adapters={}
-- Selection and package ownership are implemented. Rendering remains gated
-- until each backend is integrated against its real renderer contract.
for _,name in ipairs({'battle_art_pc','battle_art_gen2','battle_art_quest','dramatic','dramaless','potato','stadium2'})do
  local key=name
  adapters[key]=function(owner)return {owner=owner,ready=false,reason=key..'-integration-pending'}end
end
local router
adapters.battle_art_quest=function(owner)return module('QuestAdapter').new(mod,owner)end
adapters.battle_art_pc=function(owner)
 local found=mod.find(owner)
 local exports=found and found.exports
 local client,err
 if exports and exports.voxel_companion then
  local packets={}
  for _,name in ipairs({'EffectPackets','SourceDrawPackets','CloudPackets','CelestialPackets'})do packets[name]=module(name)end
  client,err=module('BattleArtClient').new(mod,exports.voxel_companion,packets,mod.exports.lib,exports.lib,
   function()return router and (router.key=='battle_art_pc' or router.key=='battle_art_android')end)
 end
 mod.exports.ownedWeatherAdapter=client~=nil
 return client or {ready=false,reason=err or 'waiting-for-host-api'}
end
-- Phones use the non-VR packet renderer, never the standalone Quest bridge.
-- Do not advertise rendering when the public host only exposes the base API.
adapters.battle_art_android=function(owner)
 local found=mod.find(owner)
 local exports=found and found.exports
 local provider=exports and exports.voxel_companion
 if not (provider and type(provider.capabilities)=='table'
   and provider.capabilities.atmosphere_effects_draft==1
   and type(provider.register)=='function'
   and exports.lib and type(exports.lib.require)=='function')then
  return {ready=false,reason='Android host needs atmosphere-effects API'}
 end
 return adapters.battle_art_pc(owner)
end
-- Gen 2 Battle Art currently exposes the older exports.lib/Voxel3D contract.
-- Prefer the packet API automatically if a future build publishes it; until
-- then, validate the legacy world-space hook before allowing DramalessAtmos
-- to attach. A recognized id alone is never enough to report readiness.
local function legacyVoxel(owner)
 local found=mod.find(owner)
 local exports=found and found.exports
 local host=exports and exports.lib
 if not(host and type(host.require)=='function')then
  return {ready=false,reason='Gen 2 host missing exports.lib'}
 end
 local ok,voxel=pcall(host.require,'Voxel3D')
 if not(ok and type(voxel)=='table' and type(voxel.endScene)=='function')then
  return {ready=false,reason='Gen 2 host missing Voxel3D.endScene'}
 end
 mod.exports.ownedWeatherAdapter=false
 return {owner=owner,ready=true,reason='legacy-world-hook-selected'}
end
adapters.battle_art_gen2=function(owner)
 local found=mod.find(owner)
 local exports=found and found.exports
 local provider=exports and exports.voxel_companion
 if provider and type(provider.capabilities)=='table'
   and provider.capabilities.atmosphere_effects_draft==1 then
  return adapters.battle_art_pc(owner)
 end
 return legacyVoxel(owner)
end
adapters.stadium2=legacyVoxel
router=module('Router').new(adapters)
local host={}
local lastSelection
local function refresh()
  local ok,pipeline,owner,platform=pcall(function()
    local game=require('src.core.Game')
    local pipes=require('src.render.Pipelines')
    local id=pipes.worldPipeline()
    local defs=game.data and game.data.render_pipelines
    local provenance=defs and defs._owners
    return id,provenance and provenance[id],love.system.getOS()
  end)
  local selectedHost=ok and owner and mod.find(owner)
  local bridge=mod.find('BATTLE_ART_QUEST_COMPAT')
  local standalone=platformPolicy.standalone(platform,bridge and bridge.exports,selectedHost and selectedHost.exports)
  mod.exports.standaloneQuest=standalone==true
  router:update(ok and pipeline or 'unknown',ok and owner or nil,platform,standalone)
  if router.key~=lastSelection then
    lastSelection=router.key
    mod.log:info('Weather adapter: %s; standalone=%s',tostring(router.key),tostring(standalone))
  end
  local found=router.owner and mod.find(router.owner)
  host.exports=found and found.exports
  if host.exports then
    local applied,problem=pcall(function()
      settings:applyNaturalDefaults(require('src.core.Game'),host.exports.lib,
        mod.exports.lib,require('src.render.Pipelines'))
    end)
    if not applied then mod.log:warn('Natural weather defaults: %s',tostring(problem))end
  end
  return router:ready()
end
mod.exports.weatherFrameOwned=function()return router.adapter and router.adapter.active==true or false end
mod.exports.rendererReady=refresh
mod.exports.weatherPreferences={storm=function()return settings:stormPreferences()end,
  constellations=function()return settings:readConstellations()end}
mod.exports.compatibilityStatus=function()
  local ready,reason=refresh()
  return {adapter=router.key,host=router.owner,ready=ready,reason=reason,bundled=true,details=router.adapter and router.adapter.status and router.adapter:status()}
end
mod.exports.activeWeatherHost=function()
  refresh()
  return router.owner and mod.find(router.owner),router.owner
end
module('Controls')(mod,settings,host,function()return mod.exports end)
mod.events:on('mods.loaded',refresh)
mod.events:on('game.ready',refresh)
