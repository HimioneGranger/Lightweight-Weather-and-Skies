local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
local function read(p)local f=assert(io.open(root..'/'..p,'rb'));local s=f:read('*a');f:close();return s end
local active='THIRD_PARTY';local prepared=false;local made,detached=0,0
local provider={api=1,space={unitsPerMetre=10,up='Y',east='+X',south='+Z'},register=function()end}
local mods={THIRD_PARTY={exports={lwsRendererProvider=provider}},OTHER={exports={}}}
local game={data={render_pipelines={_owners={world='THIRD_PARTY'}}}}
local events={};local mod={id='weather',exports={lib={}},find=function(id)return mods[id]end,log={info=function()end,warn=function()end}}
mod.events={on=function(_,name,fn,priority)events[#events+1]={name=name,fn=fn,priority=priority or 0}end}
mod.read=function(_,path)
 if path=='compat/Controls.lua'then return'return function()end'end
 if path=='compat/Preferences.lua'then return[[return{new=function()return{define=function()end,applyNaturalDefaults=function()end,stormPreferences=function()return{}end,readSkySource=function()return'full'end,readConstellations=function()return false end}end}]]end
 if path=='compat/RendererProvider.lua'then return'return TEST_PROVIDER'end
 return read(path)
end
local base={}
local realProvider=assert(loadfile(root..'/compat/RendererProvider.lua'))()
local env=setmetatable({TEST_PROVIDER={validate=realProvider.validate,new=function()
 made=made+1
 local v={reason='waiting',status=function()return{ready=prepared,active=prepared,reason='frame-status'}end,detach=function()detached=detached+1 end}
 return setmetatable(v,{__index=function(_,k)if k=='ready'or k=='active'then return prepared end end})
end},love={system={getOS=function()return'Android'end}},require=function(name)
 if name=='src.core.Game'then return game end
 if name=='src.render.Pipelines'then return{worldPipeline=function()return'world'end}end
 error(name)
end},{__index=_G})
env.loadstring=function(s,name)local f,e=loadstring(s,name);if f then setfenv(f,env)end;return f,e end
local chunk=assert(loadfile(root..'/compat/Bootstrap.lua'));setfenv(chunk,env);chunk(mod)
check(mod.exports.lwsRendererAPI.api==1,'public API published by real bootstrap')
check(mod.exports.rendererReady()==false and made==1,'unknown provider selected but not falsely ready')
check(mod.exports.ownedWeatherAdapter==true,'generic packet mode prevents duplicate legacy renderer')
prepared=true;check(mod.exports.rendererReady()==true and mod.exports.weatherFrameOwned(),'actual frame readiness')
local handle,id=mod.exports.activeWeatherHost();check(handle==mods.THIRD_PARTY and id=='THIRD_PARTY','active provider routed without whitelist')
-- Model the actual Gen3Host mods.loaded@50 export replacement.
mod.events:on('mods.loaded',function()
 mod.exports.rendererReady=function()return false,'gen3-legacy-no-active-host'end
 mod.exports.activeWeatherHost=function()return nil,'legacy'end
 mod.exports.compatibilityStatus=function()return{adapter='gen3-legacy'}end
end,50)
table.sort(events,function(a,b)return a.priority>b.priority end)
for _,e in ipairs(events)do if e.name=='mods.loaded'then e.fn()end end
check(mod.exports.rendererReady()==true and mod.exports.compatibilityStatus().adapter=='lws_renderer','late Gen3 hooks do not steal a public renderer')
game.data.render_pipelines._owners.world='OTHER'
check(not mod.exports.weatherFrameOwned(),'renderer switch stops owned-frame claims immediately')
local ready,why=mod.exports.rendererReady()
check(not ready and why=='gen3-legacy-no-active-host'and detached==1,'fallback restores legacy readiness and detaches old client')
check(not mod.exports.ownedWeatherAdapter,'old public mode ownership cleared')
game.data.render_pipelines._owners.world='THIRD_PARTY';mod.exports.rendererReady();check(made==2,'switch back creates clean public adapter')
mods.THIRD_PARTY.exports.lwsRendererProvider={api=1,space=provider.space,register=function()end}
mod.exports.rendererReady();check(made==3 and detached==2,'provider revision replacement detaches old resources')
local before=made
for _,e in ipairs(events)do if e.name=='mods.loaded'then e.fn()end end
check(mod.exports.rendererReady()==true and made==before,'re-fired mods.loaded does not stack wrappers or re-register')
game.data=nil
local explicit={api=1,space=provider.space,register=function()end,isActive=function()return true end}
assert(mod.exports.lwsRendererAPI.registerRenderer{api=1,owner='THIRD_PARTY',provider=explicit})
check(mod.exports.rendererReady()==true and mod.exports.activeWeatherHost()==mods.THIRD_PARTY,'real bootstrap routes explicit provider without engine-private registry')
explicit.isActive=function()return false end
check(not mod.exports.weatherFrameOwned(),'inactive fallback immediately relinquishes weather ownership')
print('PASS '..n..' real bootstrap/unknown-renderer/Gen3-priority/fallback/lifecycle assertions')
