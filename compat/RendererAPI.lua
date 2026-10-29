-- Versioned registration/discovery. Presence is never active-renderer evidence.
local M={}
function M.new(mod,loadModule,selection)
 local Provider=loadModule('RendererProvider')
 local registrations,blockedAuto={},{}
 local current,currentOwner,currentProvider
 local api={api=1}
 local function ownerValid(s)return type(s)=='string'and #s>0 and #s<=128 and s:match('^[%w_.%-]+$')end
 local function resolve(owner)
  if not ownerValid(owner)then return nil,'invalid-owner'end
  local found=mod.find(owner)
  if not(found and type(found.exports)=='table')then return nil,'owner-unavailable'end
  local r=registrations[owner]
  local p=r and r.provider or found.exports.lwsRendererProvider
  if not r and p==blockedAuto[owner]then return nil,'disposed'end
  local ok,why=Provider.validate(p);if not ok then return nil,why end
  return p,nil,r or p
 end
 local function selected()
  local ok,pipeline,selected=pcall(selection)
  if ok and pipeline and ownerValid(selected)then return pipeline,selected,'pipeline-provenance'end
  -- Engines without the standard pipeline registry can explicitly register
  -- a read-only active-renderer predicate. Never infer activity from presence.
  local winner
  for id in pairs(registrations)do
   local p=resolve(id)
   if p and type(p.isActive)=='function'then
    local good,on=pcall(p.isActive)
    if good and on==true then
     if winner then return nil,nil,'ambiguous-active-renderers'end
     winner=id
    end
   end
  end
  if winner then return'lws-public:'..winner,winner,'registered-active-predicate'end
  return nil,nil,'no-active-public-renderer'
 end
 local function active(owner,p)
  local pipeline,id=selected()
  return pipeline~=nil and id==owner and resolve(owner)==p
 end
 function api.registerRenderer(spec)
  if type(spec)~='table'or spec.api~=1 or not ownerValid(spec.owner)then return nil,'expected api=1 and valid owner mod id'end
  local valid,why=Provider.validate(spec.provider);if not valid then return nil,why end
  if registrations[spec.owner]then return nil,'owner already registered; dispose its registration first'end
  local found=mod.find(spec.owner);if not(found and found.exports)then return nil,'owner-unavailable'end
  local owner,p=spec.owner,spec.provider
  local token={provider=p};registrations[owner]=token;blockedAuto[owner]=nil
  local handle={}
  function handle:dispose()
   if registrations[owner]~=token then return false end
   registrations[owner]=nil;blockedAuto[owner]=p
   if currentOwner==owner and currentProvider==p and current then
    pcall(current.detach,current);current,currentOwner,currentProvider=nil,nil,nil
   end
   return true
  end
  function handle:status()return api.status(owner)end
  return handle
 end
 function api.status(owner)
  local p,why=resolve(owner)
  local out={api=1,owner=owner,registered=p~=nil,selected=p~=nil and active(owner,p)or false,ready=false,active=false,reason=why or 'awaiting-selected-frame'}
  if current and currentOwner==owner and currentProvider==p then
   local ok,s=pcall(current.status,current)
   if ok then out.ready=s.ready==true;out.active=out.selected and s.active==true;out.reason=s.reason end
  end
  return out
 end
 function api.snapshot()
  local ok,state=pcall(function()
   local lib=assert(mod.exports.lib,'weather namespace not ready')
   local settings,weather,tod=lib.require('Settings'),lib.require('WeatherState'),lib.require('TimeOfDay')
   local channels={}
   for _,k in ipairs{'rain','snow','sand','ash','fog','dim','gust','strike','splash'}do
    local v=weather.channel(k)
    channels[k]=type(v)=='number'and v==v and math.abs(v)<math.huge and v or 0
   end
   local function number(v,fallback)return type(v)=='number'and v==v and math.abs(v)<math.huge and v or fallback end
   return{api=1,skySource=settings.lwsSkyEnabled()and 'full'or 'native',clouds=settings.cloudsOn(),
    weather={id=type(weather.id)=='string'and weather.id or 'UNKNOWN',level=number(weather.level,0),channels=channels},clock={hour=number(tod.hour,12)%24}}
  end)
  if not ok then return nil,tostring(state)end
  return state
 end
 local manager={api=api,resolve=resolve,selection=selected}
 function manager:newAdapter(owner,p)
  local modules={}
  for _,name in ipairs{'BattleArtClient','EffectPackets','SourceDrawPackets','CloudPackets','CelestialPackets'}do modules[name]=loadModule(name)end
  local client,err=Provider.new(mod,p,modules,mod.exports.lib,function()return active(owner,p)end)
  if not client then return nil,err end
  current,currentOwner,currentProvider=client,owner,p
  return client
 end
 return manager
end
return M
