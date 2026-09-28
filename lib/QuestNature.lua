-- Two varied streaming ambience segments + at most one rare local cry.
local V=...
local N={pool={},lastSpecies=nil,lastError=nil}
local Route=V.require('RouteCalls')
local Index=V.require('QuestCryIndex')
local ok,Game=pcall(require,'src.core.Game');if not ok then Game={} end
local beds
local cry,cryOwned,lastMap,lastPhase,lastData,refresh,delay,preview=nil,false,nil,nil,nil,0,90,false
local seed=(os.time()+3571)%2147483647
local function rng(n) seed=(seed*48271)%2147483647;return 1+math.floor(seed/2147483647*n) end
local function clamp(x) return math.max(0,math.min(1,tonumber(x)or 0)) end
local function release(s) if s then pcall(function()s:stop();if s.release then s:release()end end)end end
local function stopCry()
  if cryOwned then release(cry) elseif cry then pcall(function()cry:stop()end)end
  cry=nil;cryOwned=false
end
function N.reset()
  if beds then beds:reset()end
  stopCry();lastMap=nil;lastPhase=nil;lastData=nil;N.pool={};refresh=0;delay=90;preview=false;N.lastError=nil
end
local keys={{0,.65,.2},{150,1,0},{450,.55,0},{600,.15,.5},{690,0,1},{1050,0,1},{1200,.65,.2}}
function N.levels(t)
  t=(tonumber(t)or 300)%1200
  for i=1,#keys-1 do local a,b=keys[i],keys[i+1]
    if t<=b[1] then local u=(t-a[1])/(b[1]-a[1]);u=u*u*(3-2*u)
      return a[2]+(b[2]-a[2])*u,a[3]+(b[3]-a[3])*u end
  end
end
local function time()
  local good,t=pcall(function()
    -- Interop discovers the active voxel host by capability and includes the
    -- Gen 2 Battle Art id. A literal Gen 1 host lookup made every Gold-only
    -- install fall back to 300 (day), suppressing MORN/NITE local cry pools.
    local interop=V.require('Interop')
    local dayNight=interop and interop.dayNight and interop.dayNight()
    return dayNight and dayNight.time()
  end)
  return good and tonumber(t)or 300
end
local function load(relative,kind)
  if not (love and love.audio and love.audio.newSource)then return nil end
  local good,s=pcall(function()return love.audio.newSource(V.mod.assets:path(relative),kind or 'static')end)
  if good then return s end
  N.lastError=tostring(s);return nil
end
local function options()return Game.save and Game.save.options or {}end
local function getBeds()
  if not beds then beds=V.require('QuestNatureBeds').new(load,rng)end
  return beds
end
local function activeGroup(data,map,phase)
  -- Prefer the engine's generation-neutral read-only encounter API. It
  -- resolves Gen 2 MORN/DAY/NITE tables, swarms and encounter.table hooks,
  -- while returning the same distribution shape on Gen 1.
  local world=V.mod and V.mod.world
  if world and type(world.effectiveEncounters)=='function' then
    local daytime=({morning='MORN',day='DAY',night='NITE'})[phase] or 'DAY'
    local ok,effective=pcall(world.effectiveEncounters,world,map,'grass',{daytime=daytime})
    if ok and type(effective)=='table' and type(effective.dist)=='table' then
      local group={rate=tonumber(effective.chance) or 0,slots={}}
      for species,chance in pairs(effective.dist)do
        if (tonumber(chance) or 0)>0 then group.slots[#group.slots+1]={species=species} end
      end
      table.sort(group.slots,function(a,b)return tostring(a.species)<tostring(b.species)end)
      return group
    end
  end
  local encounters=data and data.encounters
  local enc=encounters and encounters[map]
  local grass=enc and enc.grass
  -- Raw Gen 2 fallback for older hosts without mod.world.
  if not grass and encounters and encounters.grass then grass=encounters.grass[map] end
  if not grass then return nil end
  -- Gen1 uses flat slots. Explicit timed groups must resolve to this phase;
  -- do not union all hours or guess an unknown encounter schema.
  if grass.rates and grass.slots then
    local key=({morning='MORN',day='DAY',night='NITE'})[phase] or 'DAY'
    return {rate=tonumber(grass.rates[key] or grass.rates.DAY) or 0,
      slots=grass.slots[key] or grass.slots.DAY or {}}
  end
  if grass.slots then return grass end
  return grass[phase]
end
function N.status()
  if options().qNatureAudio=='off' then return 'AMBIENCE OFF'end
  if options().qNatureCalls==false then return 'CRIES OFF'end
  if #N.pool==0 then return 'NO LOCAL CRIES'end
  if preview then
    if (V.require('Scene').now or {}).visible=='hidden'then return 'QUEUED - CLOSE MENU'end
    return N.waitReason or ('CRY IN '..math.ceil(delay)..'s')
  end
  if cry then return 'PLAYING '..tostring(N.lastSpecies or '')end
  if N.lastError then return 'AUDIO ERROR'end
  return #N.pool..' LOCAL - PRESS A'
end
function N.trigger()
  if #N.pool==0 or options().qNatureCalls==false or options().qNatureAudio=='off' then return false end
  preview=true;delay=5;N.waitReason=nil;N.lastError=nil;return true
end
local function play(id,gain)
  stopCry()
  local def=Game.data and Game.data.pokemon and Game.data.pokemon[id]
  if not def then return end
  local files=Index[def.dex]or {}
  local first=#files>0 and rng(#files)or 1
  for i=1,#files do
    cry=load(files[1+(first+i-2)%#files]);if cry then cryOwned=true;break end
  end
  if not cry then
    -- Same-species engine/Pokedex fallback. Clone before adjusting its gain;
    -- leave the shared engine template volume unchanged for future battles.
    local good,s=pcall(function()return require('src.core.Sound').playCry(Game.data,id)end)
    if good and s then
      s:stop()
      if s.clone then local cloned,c=pcall(function()return s:clone()end)
        if cloned then cry=c;cryOwned=true end end
    end
  end
  if cry then
    local good,err=pcall(function()cry:setLooping(false);cry:setVolume(gain);cry:play()end)
    if not good then N.lastError=tostring(err);stopCry()else N.lastSpecies=id;N.lastError=nil end
  end
end
function N.update(dt,master)
  local scene=V.require('Scene').now or {}
  local opt=options()
  local live=scene.visible=='world' and scene.outdoor and not scene.indoors and scene.mapId
  if not live or master<=0 or opt.qNatureAudio=='off' then
    if scene.visible=='hidden' and scene.mapId==lastMap and master>0 and opt.qNatureAudio~='off' then
      -- Keep the local pool and queued preview available inside Options.
      -- Audio stops, but closing menus must not cancel the test button.
      if beds then beds:reset()end;stopCry()
    elseif lastMap or cry then N.reset()end
    return
  end
  dt=math.max(0,math.min(.25,tonumber(dt)or 0))
  local t=time()%1200
  local phase=t>=600 and t<1100 and 'night' or (t<150 or t>=1100)and 'morning'or 'day'
  local changed=lastMap~=scene.mapId
  refresh=refresh-dt
  if changed or phase~=lastPhase or Game.data~=lastData or refresh<=0 then
    if changed then stopCry();delay=90+rng(120);preview=false end
    lastMap=scene.mapId;lastPhase=phase;lastData=Game.data;refresh=5
    N.pool=Route.pool(Game.data and Game.data.pokemon or {},activeGroup(Game.data,scene.mapId,phase))
    if cry and N.lastSpecies then
      local found=false;for _,id in ipairs(N.pool)do if id==N.lastSpecies then found=true end end
      if not found then stopCry()end
    end
  end
  local state=V.require('WeatherState');local front=V.require('QuestStormFront')
  local rain=state.channel and state.channel('rain')or 0
  local snow=state.channel and state.channel('snow')or 0
  local suppression=math.max(clamp((front.warning or 0)*2),clamp(front.coverage),clamp(rain),clamp(snow))
  local calm=1-suppression
  local scale=({low=.5,normal=1,high=1.5})[opt.qNatureAudio]or 1
  local sfx=opt.sfxVol==nil and 1 or clamp((tonumber(opt.sfxVol)or 0)/7)
  local volume=math.min(1,master*scale*sfx)
  local bird,insect=N.levels(t)
  local targets={birds=bird*.19*calm,insects=insect*.12*calm}
  getBeds():update(dt,targets,volume)
  if cry then
    if opt.qNatureCalls==false then stopCry()
    elseif not cry:isPlaying()then stopCry()
    else cry:setVolume(.16*volume*calm)end
  end
  N.waitReason=nil
  if suppression>.15 or scene.textBox or opt.qNatureCalls==false or volume==0 then
    N.waitReason=suppression>.15 and 'WAIT: CALM WEATHER' or 'WAIT: AUDIO / DIALOGUE'
    if not preview then delay=math.max(delay,30)end;return
  end
  delay=delay-dt
  if delay<=0 then
    preview=false
    delay=90+rng(120)
    local id=Route.choose(N.pool,N.lastSpecies,rng)
    if id then play(id,.16*volume*calm)end
  end
end
return N
