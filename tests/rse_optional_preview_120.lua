local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
for _,withPreview in ipairs({false,true})do
 local options={};local tod={phaseAt=function(h)return h<6 and 'NITE'or'DAY'end}
 local rt={_game={options=options},getSession=function()return{options=options}end}
 local rows={build=function()return{{id='native'}}end,group=function(r)return r end}
 local preview={KEY='preview',label=function()return'NOON'end,step=function(o)o.preview=12 end,
  apply=function(t)return{hours=12,minutes=30,seconds=0,days=t.days,lightingPreview=true}end}
 local native={['src.core.game3.runtime']=rt,['src.core.game3.rtc']={calcLocalTime=function()return{hours=5,minutes=0,seconds=0,days=2}end},
  ['src.core.game3.profile']={family=function()return'rse'end},['src.mods.Runtime']={call=function(_,_,game,base)return base end},
  ['src.ui.game3.option_rows']=rows,['src.ui.game3.frlg_font']={measure=function(s)return#s end}}
 if withPreview then native['src.core.game3.lighting_preview']=preview end
 local V={require=function(name)if name=='TimeOfDay'then return tod end;if name=='Interop'then return{}end;error(name)end}
 local mod={id='weather',exports={lib={require=function()return{LEVEL_LABELS={'OFF','AUTO','CYCLE'}}end}},events={on=function()end},options={get=function()return'AUTO'end},find=function()end}
 local env=setmetatable({require=function(name)return assert(native[name],'missing optional/native '..name)end},{__index=_G})
 local function load(name,...)local chunk=assert(loadfile(root..'/'..name));setfenv(chunk,env);return chunk(...)end
 local shared={options={setMode=function()end}}
 local clock=load('compat/gen3/RseClock.lua',mod,nil,V,shared)
 check(clock.read().hour==(withPreview and 12.5 or 5),'native RTC fallback / preview clock')
 check(clock.read().source==(withPreview and 'emerald-lighting-preview'or'emerald-rtc'),'truthful clock source')
 check(V._rseNightVisibility()==(withPreview and 0 or .5),'dawn fade uses same clock')
 local wrapper=load('compat/gen3/RseMenuBridge.lua',mod,nil,V,shared)
 local P=wrapper('src.render.Pipelines')
 local pr=P.rows();check(#pr==(withPreview and 2 or 1),'only offer available preview control')
 check(pr[#pr].id=='pipeline:weather','weather retained on older host')
 local built=rows.build({options=options,session={},game={}})
 check(#built==(withPreview and 2 or 1),'native rows remain usable without preview module')
 if withPreview then check(built[2].id=='pipeline:lighting_preview','preview row included once')end
end
print('PASS optional Emerald preview '..n..' checks')
