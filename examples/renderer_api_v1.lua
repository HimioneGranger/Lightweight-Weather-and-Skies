-- Reference glue, not a new renderer. `engine` supplies the documented backend
-- methods; see docs/RENDERER_API.md. No Battle Art/private module names required.
return function(mod,engine)
 assert(type(engine.createWeatherScope)=='function','engine:createWeatherScope required')
 assert(type(engine.onWeatherPrepare)=='function','engine:onWeatherPrepare required')
 assert(type(engine.onWeatherInvalidate)=='function','engine:onWeatherInvalidate required')
 return{api=1,space={unitsPerMetre=10,up='Y',east='+X',south='+Z'},
 isActive=type(engine.isActive)=='function'and function()return engine:isActive()==true end or nil,
 register=function(callbacks)
  local scope,offPrepare,offInvalidate,closed
  local function dispose()
   if closed then return end;closed=true
   if offPrepare then pcall(offPrepare)end
   if offInvalidate then pcall(offInvalidate)end
   pcall(callbacks.dispose)
   pcall(function()if scope and type(scope.destroy)=='function'then scope:destroy()end end)
  end
  local ok,err=pcall(function()
   scope=assert(engine:createWeatherScope(mod.id..':lws:'..tostring(callbacks.id)))
   assert(type(scope.destroy)=='function','scope:destroy required')
   offPrepare=assert(engine:onWeatherPrepare(function(frame)
    if closed then return false,'disposed'end
    return callbacks.prepare(frame)
   end))
   assert(type(offPrepare)=='function','prepare subscription must return unsubscribe function')
   offInvalidate=assert(engine:onWeatherInvalidate(function()
    if not closed then return callbacks.invalidate()end
   end))
   assert(type(offInvalidate)=='function','invalidate subscription must return unsubscribe function')
  end)
  if not ok then dispose();return nil,tostring(err)end
  return{effects=function()return scope end,dispose=dispose}
 end}
end
