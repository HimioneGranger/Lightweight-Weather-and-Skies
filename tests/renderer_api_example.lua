local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
local factory=assert(loadfile(root..'/examples/renderer_api_v1.lua'))()
local prepare,invalidate;local off,destroyed,disposed=0,0,0
local scope={destroy=function()destroyed=destroyed+1 end}
local engine={isActive=function()return true end,
 createWeatherScope=function(_,id)check(id=='renderer:lws:weather','scope uniquely names renderer and weather');return scope end,
 onWeatherPrepare=function(_,fn)prepare=fn;return function()off=off+1 end end,
 onWeatherInvalidate=function(_,fn)invalidate=fn;return function()off=off+1 end end}
local provider=factory({id='renderer'},engine)
check(provider.isActive(),'example exposes optional renderer-owned selection predicate')
local callbacks={id='weather',prepare=function(f)return f.id end,invalidate=function()return 'reset'end,dispose=function()disposed=disposed+1 end}
local lease=assert(provider.register(callbacks))
check(lease:effects()==scope and prepare({id=3})==3 and invalidate()=='reset','example bridges frame and invalidation callbacks')
lease:dispose();lease:dispose()
check(off==2 and destroyed==1 and disposed==1 and not prepare({id=4}),'example teardown unsubscribes and releases exactly once')
engine.onWeatherInvalidate=function()error('partial subscription failure')end
local failed=provider.register(callbacks)
check(not failed and off==3 and destroyed==2 and disposed==2,'partial setup failure cleans prior subscription and scope')
print('PASS '..n..' public renderer example lifecycle assertions')
