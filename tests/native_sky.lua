local root=assert(arg[1]);local checks=0
local function check(v,m)checks=checks+1;assert(v,m)end
local function loadModule(p,...)return assert(loadfile(root..'/'..p))(...)end
-- Actual settings default/fallback and shared persisted menu key.
local values={};local mod={id='weather',options={values=values,get=function(_,k)return values[k]end},exports={}}
local Settings=loadModule('lib/Settings.lua',{mod=mod,require=function(n)if n=='Types'then return{PINNED={}}end;return{rows=function()return{}end}end})
check(Settings.lwsSkyEnabled(),'full sky is default')
values.skySource='garbage';check(Settings.lwsSkyEnabled(),'unknown saved choice stays full')
values.skySource='native';check(not Settings.lwsSkyEnabled()and Settings.cloudsOn(),'native sky does not disable clouds')
check(mod.exports.directWorldCelestials==false and mod.exports.celestialRenderer=='host-native','native ownership metadata')
local row
for _,r in ipairs(Settings.SCHEMA)do if r.key=='skySource'then row=r end end
check(row and row.default=='full'and #row.choices==2,'typed persisted schema/default')
local P=loadModule('compat/Preferences.lua').new(mod)
local game={options={},mods={}}
local r=P:skySourceRow();check(r.value()=='NATIVE SKY','native choice visible')
r.step(game);check(Settings.lwsSkyEnabled()and game.options.modOptions.weather.skySource=='full','menu persists same full key')
check(mod.exports.directWorldCelestials==true,'full ownership metadata restored')
r.step(game);check(not Settings.lwsSkyEnabled(),'live switch native')
check(P:applyNaturalDefaults(game,{require=function()error('native must not rewrite host clock')end},{},{})==false,'native selection does not force natural host clock defaults')

for _,id in ipairs{'BATTLE_ART_VOXEL_FORK','BATTLE_ART_VOXEL_GEN2','FRLG_VOXEL'}do
 for _,mode in ipairs{'legacy','fast','once'}do
  local full=true;local count={cloud=0,body=0,stars=0,bolt=0,rain=0,paint=0}
  local shadow={KX=7,KZ=9};local nativeBody={native=true};local seenBody
  love={graphics={getCanvas=function()return'eye'end,push=function()end,pop=function()end,
   getBlendMode=function()return'alpha','alphamultiply'end,getColor=function()return 1,1,1,1 end,
   setColor=function()end,setShader=function()end,setDepthMode=function()end,setBlendMode=function()end}}
  local function endEye()return'eye-result'end
  local voxel={vp={},eye={0,40,0},focus={0,40,1},endScene=endEye}
  local sky={paint=function(w,h,s,hy,c,b)count.paint=count.paint+1;seenBody=b;return'sky-result'end,discImage=function()return'native-image'end}
  local hostCloud={draw=function()error('must use LWS cloud deck')end}
  local hostLib={require=function(n)
   if n=='Voxel3D'then return voxel end
   if n=='Sky'then return sky end
   if n=='Clouds'then return hostCloud end
   if n=='ShadowMap'then return shadow end
   if n=='DayNight'then return{time=function()return 300 end}end
   if n=='TileShape'or n=='VoxelScene'then return{}end
   error(n)
  end}
  local host={exports={lib=hostLib}}
  local perf={hoist=mode~='legacy',tier='full',frameOnce=mode=='once',frameSerial=0,tickSerial=0}
  local owner={path='weather',exports={questPerf=perf,rendererReady=function()return true end,activeWeatherHost=function()return host,id end},log={warn=function()end}}
  owner.read=function(_,p)
   if p:find('CinematicAtmos',1,true)then return'return{frame=function()return{weather={}}end,update=function()end}'end
   if p:find('WorldPrecip',1,true)then return'return{update=function()end,draw=function()TEST_NATIVE_RAIN()end}'end
   return'return{}'
  end
  TEST_NATIVE_RAIN=function()count.rain=count.rain+1 end
  local scene={now={outdoor=true,visible='world',mapId='A'}}
  local V={mod=owner,path='weather',questLitePrivate=true}
  V.require=function(n)
   if n=='Settings'then return{lwsSkyEnabled=function()return full end}end
   if n=='Scene'then return scene end
   if n=='TimeOfDay'then return{hour=12,isNight=function()return false end}end
   if n=='Gen2VoxelClouds'then return{new=function()return{update=function()end,draw=function()count.cloud=count.cloud+1;return true end}end}end
   if n=='CelestialBodies'then return{drawWorld=function()count.body=count.body+1;return true end,shearAt=function()return 2,3 end}end
   if n=='NightSky'then return{drawWorld=function()count.stars=count.stars+1;return true end}end
   if n=='QuestAurora'or n=='QuestRainbow'then return{drawWorld=function()return true end}end
   if n=='QuestStormBolt'then return{drawWorld=function()count.bolt=count.bolt+1;return true end}end
   if n=='QuestStorm'then return{attach=function()end,flash=function()return 1 end}end
   if n=='QuestRainSurface'then return{sampler=function()return function()return 0 end end}end
   if n=='WeatherState'then return{channel=function()return 1 end}end
   return{}
  end
  local A=loadModule('lib/DramalessAtmos.lua',V);check(A.install(),'host install '..id)
  local function frame()
   perf.frameSerial=perf.frameSerial+1;perf.tickSerial=perf.tickSerial+1
   A.update(.016)
   if id=='BATTLE_ART_VOXEL_GEN2'then voxel.endScene=endEye end
   check(sky.paint(100,100,{bands={{1,1,1}}},42,4,nativeBody)=='sky-result','host sky return preserved')
   if id=='BATTLE_ART_VOXEL_FORK'then hostCloud.draw(voxel.eye)end
   check(voxel.endScene()=='eye-result','host scene closes')
  end
  frame();check(count.body>0 and count.stars>0,'full draws LWS bodies/stars '..id..mode)
  check(shadow.KX==2 and shadow.KZ==3,'full owns celestial shear')
  local body,stars,cloud,bolt,rain=count.body,count.stars,count.cloud,count.bolt,count.rain
  full=false;frame()
  check(count.body==body and count.stars==stars,'native skips LWS celestial draws '..id..mode)
  check(count.bolt>bolt and count.rain>rain,'native keeps lightning and precipitation '..id..mode)
  if id~='FRLG_VOXEL'then check(count.cloud>cloud,'native keeps Gen1/2 LWS clouds')end
  check(shadow.KX==7 and shadow.KZ==9,'native restores host shadow values')
  check(seenBody==nativeBody and sky.discImage()=='native-image','native forwards original body/image')
  full=true;frame();check(count.body>body and count.stars>stars,'switch back restores full sky')
  shadow.KX,shadow.KZ=11,13;full=false;frame()
  check(shadow.KX==11 and shadow.KZ==13,'newer host shadow writes never clobbered')
 end
end
print('PASS '..checks..' native sky default/persistence/live-switch/host ownership/cloud/lightning/rain assertions')
