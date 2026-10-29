-- Public Renderer API v1 -> weather-owned packet producer. No host patches.
local M={}
local METHODS={'camera','material','mesh','image','updateMesh','enqueue','release','submitAtmosphere','clear'}
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<math.huge end
local function vector(v,label)
 assert(type(v)=='table',label..' must be a vector')
 local r={};for i=1,3 do assert(finite(v[i]),label..' must have3finite components');r[i]=v[i]end;return r
end
local function validate(p)
 if type(p)~='table'or p.api~=1 then return false,'renderer provider api must be1'end
 if type(p.register)~='function'then return false,'renderer provider missing register'end
 if p.isActive~=nil and type(p.isActive)~='function'then return false,'provider isActive must be callable'end
 local s=p.space
 if type(s)~='table'or s.unitsPerMetre~=10 or s.up~='Y'or s.east~='+X'or s.south~='+Z'then
  return false,'provider must expose canonical LWS space (10units/metre,Yup,+Xeast,+Zsouth)'
 end
 return true
end
function M.validate(p)
 local ok,valid,why=pcall(validate,p)
 if not ok then return false,'provider validation failed: '..tostring(valid)end
 return valid,why
end
function M.new(mod,p,modules,world,isSelected)
 local valid,why=M.validate(p);if not valid then return nil,why end
 local current,lighting,client,closed,lastId,lastError,lease
 local wrappers=setmetatable({},{__mode='k'})
 local function clear()
  pcall(function()
   if lease and type(lease.effects)=='function'then
    local a=lease:effects()
    if type(a)=='table'and type(a.clear)=='function'then a:clear()end
   end
  end)
 end
 local function frame(f)
  assert(type(f)=='table'and finite(f.id)and f.id>=0 and f.id==math.floor(f.id),'frame.id must be a nonnegative integer')
  assert(finite(f.dt)and f.dt>=0 and f.dt<=1,'frame.dt must be finite seconds in[0,1]')
  local w=f.world;assert(type(w)=='table'and type(w.visible)=='string','frame.world.visible required')
  assert(type(w.outdoor)=='boolean'and type(w.indoors)=='boolean','world outdoor/indoors booleans required')
  local active=w.visible=='world'and w.outdoor and not w.indoors
  if active then
   assert(type(w.map)=='table'and type(w.map.id)=='string'and #w.map.id>0,'world.map.id required')
   assert(w.neighbors==nil or type(w.neighbors)=='table','world.neighbors must be a table')
   assert(w.surfaceAt==nil or type(w.surfaceAt)=='function','world.surfaceAt must be callable')
   local l=f.lighting;assert(type(l)=='table'and finite(l.hour)and l.hour>=0 and l.hour<24,'lighting.hour required in[0,24)')
   lighting={hour=l.hour,tint=vector(l.tint,'lighting.tint'),haze=vector(l.haze,'lighting.haze')}
  end
  current={scene={visible=w.visible,outdoor=w.outdoor,indoors=w.indoors,mapId=w.map and w.map.id},
   map=w.map,neighbors=w.neighbors or {},surfaceAt=w.surfaceAt and function(x,z)
    local ok,y=pcall(w.surfaceAt,x,z)
    if ok and finite(y)then return y end
    return nil
   end or function()return nil end}
 end
 local function guardedApi(a)
  assert(type(a)=='table','effects() must return a resource API table')
  local cached=wrappers[a];if cached then return cached end
  for _,k in ipairs(METHODS)do assert(type(a[k])=='function','resource API missing '..k)end
  local proxy={}
  for _,k in ipairs(METHODS)do
   local method=k
   proxy[method]=function(_,...)return a[method](a,...)end
  end
  proxy.camera=function()
   local c=a:camera();assert(type(c)=='table','camera() must return a table')
   if c.available~=true then return{available=false,reason=c.reason}end
   assert(current and current.map and c.mapId==current.map.id,'camera.mapId must match world.map.id')
   assert(finite(c.far)and c.far>0 and finite(c.fov)and c.fov>0 and c.fov<math.pi,'camera far/fov invalid')
   assert(finite(c.viewportHeight)and c.viewportHeight>0,'camera.viewportHeight required')
   assert(type(c.skyVisible)=='boolean','camera.skyVisible boolean required')
   local eye,focus=vector(c.eye,'camera.eye'),vector(c.focus,'camera.focus')
   assert((focus[1]-eye[1])^2+(focus[2]-eye[2])^2+(focus[3]-eye[3])^2>1e-12,'camera focus must differ from eye')
   return{available=true,eye=eye,focus=focus,far=c.far,fov=c.fov,viewportHeight=c.viewportHeight,
    mapId=c.mapId,mode=c.mode or 'first_person',overhead=c.skyVisible}
  end
  wrappers[a]=proxy;return proxy
 end
 local legacy={capabilities={atmosphere_effects_draft=1,atmosphere_render_camera=1}}
 legacy.register=function(spec)
  local callbacks={api=1,id=spec.id}
  callbacks.prepare=function(f)
   if closed then return false,'disposed'end
   if not isSelected()then clear();pcall(spec.invalidate);lastId=nil;return false,'not-selected'end
   if type(f)=='table'and lastId~=nil and f.id==lastId then return false,'duplicate-frame'end
   local ok,err=pcall(function()
    frame(f)
    assert(lastId==nil or f.id>lastId,'stale frame.id; invalidate before resetting frame counter')
    lastId=f.id
    spec.prepareAtmosphere(f)
   end)
   if not ok then
    lastError=tostring(err);clear();pcall(spec.invalidate)
    return false,lastError
   end
   lastError=nil;return true
  end
  callbacks.invalidate=function()
   if closed then return false,'disposed'end
   lastId,current,lighting,lastError=nil,nil,nil,nil;clear()
   local ok,e=pcall(spec.invalidate);return ok,e
  end
  callbacks.dispose=function()
   if closed then return false end
   closed=true;clear();pcall(spec.dispose);return true
  end
  local ok,value=pcall(p.register,callbacks)
  if not ok then return nil,'provider register failed: '..tostring(value)end
  if type(value)~='table'or type(value.effects)~='function'or type(value.dispose)~='function'then
   if type(value)=='table'and type(value.dispose)=='function'then pcall(value.dispose,value)end
   return nil,'register must return lease with effects() and dispose()'
  end
  lease=value
  return{effects=function()return guardedApi(lease:effects())end,
   dispose=function()closed=true;clear();pcall(lease.dispose,lease)end}
 end
 local facade={require=function(name)
  if name=='DayNight'then return{time=function()return((assert(lighting,'lighting unavailable').hour-6)%24)*50 end,
   tint=function()return vector(assert(lighting,'lighting unavailable').tint,'tint')end}end
  if name=='Sky'then return{haze=function()return vector(assert(lighting,'lighting unavailable').haze,'haze')end}end
  if name=='TileShape'then return{}end
  error('public renderer facade unsupported module '..tostring(name))
 end}
 local err
 client,err=modules.BattleArtClient.new(mod,legacy,modules,world,facade,isSelected,{context=function()return current end})
 if not client then closed=true;clear();return nil,err end
 local adapter={}
 setmetatable(adapter,{__index=function(_,k)
  if k=='reason'and closed then return'disposed'end
  if k=='reason'and lastError then return'public-render-error: '..lastError end
  if (k=='ready'or k=='active')and(closed or lastError)then return false end
  return client[k]
 end})
 function adapter:status()
  return{api=1,ready=not closed and not lastError and client.ready==true,active=not closed and isSelected()and client.active==true,
   reason=closed and 'disposed'or lastError or client.reason,drawnFrames=client.drawnFrames or 0}
 end
 function adapter:detach()
  if closed then return end
  closed=true;clear();pcall(client.detach,client)
 end
 return adapter
end
return M
