local root=assert(arg[1]);local n=0
local function check(v,m)n=n+1;assert(v,m)end
local mod={exports={}}
local F=assert(loadfile(root..'/compat/FrameOnce.lua'))(mod)
check(F.perf.frameOnce==false,'batching opt-in')
check(assert(loadfile(root..'/compat/FrameOnce.lua'))(mod)==F,'one scheduler per mod')
local trace={};local function stage(name,order)
 return F.stage(name,order,function(dt,last,count,dts)
  trace[#trace+1]={name=name,dt=dt,last=last,count=count,dts=dts}
 end)
end
local b=stage('deck',40);local a=stage('weather',20)
local go,dt,last=F.take(a,.02);check(go and dt==.02 and last==.02,'OFF immediately preserves tick')
F.setOn(true)
check(not F.take(b,.02)and not F.take(a,.02),'first ticks deferred')
check(not F.take(b,.03)and not F.take(a,.03),'second ticks deferred')
F.frameBegin()
check(#trace==2 and trace[1].name=='weather'and trace[2].name=='deck','dependency order')
check(math.abs(trace[1].dt-.05)<1e-9 and trace[1].last==.03 and trace[1].count==2,'sum and last tick preserved')
check(trace[1].dts[1]==.02 and trace[1].dts[2]==.03,'lightning can replay tick times')
trace={};F.frameBegin();check(#trace==0,'second eye cannot repeat settled work')
F.take(a,.09);F.take(a,.09);F.frameBegin()
check(#trace==1 and trace[1].dt==F.CAP and F.status().lost>.079,'bounded multi-tick catchup')
F.take(a,.007);F.setOn(false)
check(#trace==2 and trace[2].dt==.007,'switch OFF flushes pending')
F.setOn(true);F.frameBegin()
for i=1,3 do check(not F.take(a,.01),'await host frame')end
local g,d,_,count=F.take(a,.01)
check(g and math.abs(d-.04)<1e-9 and count==4,'missing host signal falls back')
F.frameBegin();trace={}
for _,bad in ipairs({-1,math.huge,0/0})do F.take(a,bad)end
F.flush();check(#trace==1 and trace[1].dt==0,'invalid dt cannot poison scheduler')
stage('broken',30);F.stage('broken',30,function()error('fixture')end)
local broken=F.stage('broken',30,function()error('fixture')end)
F.take(broken,.01);F.take(b,.02);F.frameBegin()
check(F.status().errors==1 and trace[#trace].name=='deck','one stage failure does not block later stages')
print('PASS frame-once '..n..' checks')
