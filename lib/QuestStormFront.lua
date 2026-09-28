-- One persistent storm cell in connected-map world coordinates. No map writes.
local V=...
local F={managed=false,coverage=0,warning=0,cell=nil,seed=math.max(1,os.time()%2147483647)}
local graph,graphRoot,latched,restart=nil,nil,false,false
local approaching=false
local localX,localZ=0,0
local zero={0,0,0,0}
local field={0,0,0,0}
local axis={1,0};field.axis=axis
local growth,fill,grownFor=0,0,0
local clearingAge,clearingStrength=nil,nil
local CLEARING_SECONDS=66
F.haze=0
local function smooth(x)x=math.max(0,math.min(1,x));return x*x*(3-2*x)end
local function random(a,b)F.seed=(F.seed*48271)%2147483647;return a+(b-a)*(F.seed-1)/2147483646 end
local function context()
  if F.contextProvider then return F.contextProvider() end
  local s=V.require('Scene').now or {}
  -- Gold/Silver owns Game2; the public mod.game handle covers both engines.
  local g=V.mod and V.mod.game
  if not (g and g.data and g.data.maps) then
    local ok,legacy=pcall(require,'src.core.Game')
    if ok then g=legacy end
  end
  if not g or not g.data or not g.data.maps or not s.mapId then return nil end
  local id,x,z,dx,dz=V.require('OutdoorWeatherAreas').position(g.data.maps,s.mapId,s.playerX,s.playerZ)
  return {maps=g.data.maps,mapId=id,climateMapId=s.mapId,x=x,z=z,offsetX=dx,offsetZ=dz,outdoor=s.outdoor,
    indoors=s.indoors,visible=s.visible}
end
-- Exact Gen1 connection offsets: blocks are32 world pixels. Stable traversal.
function F.buildGraph(maps,root)
  if not maps or not maps[root] then return nil end
  local out={[root]={x=0,z=0}};local queue={root};local cursor=1
  while queue[cursor] and cursor<=512 do
    local id=queue[cursor];cursor=cursor+1
    local def,origin=maps[id],out[id]
    for _,dir in ipairs({'north','south','west','east'})do
      local c=def.connections and def.connections[dir]
      -- Gen 1 raw definitions use `map`; Gen 2 raw definitions use `mapId`.
      -- Runtime Map objects normalize this, but the weather graph deliberately
      -- reads game.data.maps so it must accept both source schemas itself.
      local destId=c and (c.mapId or c.map)
      local dest=type(destId)=='string' and maps[destId] or nil
      if dest and not out[destId] then
        local x,z=0,0;local offset=(tonumber(c.offset)or 0)*32
        if dir=='north'then x,z=offset,-(dest.height or 0)*32
        elseif dir=='south'then x,z=offset,(def.height or 0)*32
        elseif dir=='west'then x,z=-(dest.width or 0)*32,offset
        else x,z=(def.width or 0)*32,offset end
        out[destId]={x=origin.x+x,z=origin.z+z};queue[#queue+1]=destId
      end
    end
  end
  return out
end
function F.coordinates(x,z)
  local c=F.cell;if not c then return 0,0,1,0 end
  local speed=math.sqrt(c.vx*c.vx+c.vz*c.vz)
  local ux,uz=1,0;if speed>.01 then ux,uz=c.vx/speed,c.vz/speed end
  local dx,dz=(x-c.x)/c.radius,(z-c.z)/c.radius
  return dx*ux+dz*uz,(-dx*uz+dz*ux)/2.6,ux,uz
end
function F.sample(x,z)
  local c=F.cell;if not c then return 0 end
  local along,across=F.coordinates(x,z)
  local edge=along+.05*math.sin(across*7)
  return (1-smooth((edge-.65)/.35))*smooth((along+1.4)/.8)
    *(1-smooth((math.abs(across)-.7)/.3))*c.strength
end
function F.reset()
  approaching=false
  clearingAge,clearingStrength=nil,nil
  F.haze=0
  growth,fill,grownFor=0,0,0
  F.cell=nil;F.managed=false;F.coverage=0;F.warning=0;F.windX=nil;F.windZ=nil
  graph,graphRoot,latched,restart=nil,nil,false,false
end
function F.update(dt,state,settings)
  dt=math.max(0,math.min(.25,tonumber(dt)or 0))
  F.warning=0;F.windX=nil;F.windZ=nil
  local pref=V.require('QuestStorm').preferences()
  if pref.motion=='static' or (state.level or 0)<=0
      or (settings.worldWeatherEnabled and not settings.worldWeatherEnabled())then F.reset();return end
  local ctx=context()
  if not ctx then F.managed=false;F.coverage=0;F.haze=0;growth,fill,grownFor=0,0,0;return end
  -- Indoor/menu transitions must not destroy an existing storm. Explicit
  -- weather changes are authoritative when an outdoor map is available.
  if ctx.outdoor and state.id~='STORM' then
    -- Clear weather should let the existing bank drift away, not erase its
    -- spatial field on the same frame that the rain-clearing preview fires.
    if (state.id~='CLEAR' and state.id~='SUNNY') or not F.cell then F.reset();return end
    if not clearingAge then
      clearingAge=0
      clearingStrength=F.cell.strength
    end
  elseif state.id=='STORM' then
    clearingAge,clearingStrength=nil,nil
  end
  if not latched and ctx.outdoor and ctx.visible=='world' and state.id=='STORM'
      and type(ctx.x)=='number' and type(ctx.z)=='number' then
    graphRoot=ctx.mapId;graph=F.buildGraph(ctx.maps,graphRoot)
    if not graph then return end
    -- Three times the width, same passage duration. This moves the density
    -- envelope over the existing cloud deck; no extra geometry or particles.
    local a=random(0,math.pi*2);local speed=random(18,30);local radius=random(3000,4800)
    local life=random(420,660)
    if not approaching and state.LEVEL_IDS and state.LEVEL_IDS[(state.level or 0)+1]=='AUTO'
        and (not state.pinnedBy or state.pinnedBy=='auto')then
      a,speed,radius,life=V.require('QuestRegional').front(ctx.climateMapId or ctx.mapId,a,speed,radius,life)
    end
    F.cell={root=graphRoot,x=ctx.x-math.cos(a)*radius*.55,z=ctx.z-math.sin(a)*radius*.55,
      vx=math.cos(a)*speed,vz=math.sin(a)*speed,radius=radius,age=0,
      life=life,strength=0}
    if approaching then
      local dx,dz=0,-1
      local found
      if V.mod.exports and V.mod.exports.activeWeatherHost then
        found=V.mod.exports.activeWeatherHost()
      end
      found=found or V.mod.find('BATTLE_ART_VOXEL_FORK') or V.mod.find('BATTLE_ART_VOXEL_GEN2')
      local renderer=found and found.exports and found.exports.lib.require('Voxel3D')
      if renderer and renderer.eye and renderer.focus then
        local x,z=renderer.focus[1]-renderer.eye[1],renderer.focus[3]-renderer.eye[3]
        local len=math.sqrt(x*x+z*z)
        if len>.01 then dx,dz=x/len,z/len end
      end
      F.cell.radius=3600;F.cell.x=ctx.x+dx*4320;F.cell.z=ctx.z+dz*4320
      F.cell.vx=-dx*24;F.cell.vz=-dz*24;F.cell.age=45;F.cell.life=600
      F.cell.showcaseApproach=true;approaching=false
    end
    latched=true;restart=false
  end
  if restart and ctx.visible=='world' and ctx.outdoor then
    growth,fill,grownFor=0,0,0
    latched=false;F.cell=nil;restart=false;return F.update(0,state,settings)
  end
  F.managed=latched
  local c=F.cell
  if c then
    if not graph then graphRoot=c.root;graph=F.buildGraph(ctx.maps,c.root)end
    -- Menus/connected maps keep advancing; app suspension contributes no dt.
    c.age=c.age+dt;c.x=c.x+c.vx*dt;c.z=c.z+c.vz*dt
    if clearingAge then
      clearingAge=clearingAge+dt
      c.strength=clearingStrength*(1-smooth(clearingAge/CLEARING_SECONDS))
    else
      c.strength=smooth(c.age/45)*(1-smooth((c.age-(c.life-90))/90))
    end
    if c.age>=c.life or (clearingAge and clearingAge>=CLEARING_SECONDS) then
      F.reset();return
    end
  end
  local origin=graph and graph[ctx.mapId]
  F.coverage=0
  if origin then
    localX,localZ=origin.x+(ctx.offsetX or 0),origin.z+(ctx.offsetZ or 0)
    if ctx.outdoor and not ctx.indoors and type(ctx.x)=='number' and type(ctx.z)=='number' then
      F.coverage=F.sample(origin.x+ctx.x,origin.z+ctx.z)
      if c then
        local speed=math.sqrt(c.vx*c.vx+c.vz*c.vz)
        if speed>.01 then
          F.windX,F.windZ=c.vx/speed,c.vz/speed
          local along,across=F.coordinates(origin.x+ctx.x,origin.z+ctx.z)
          -- Leading edge only: up to 45 seconds of warning outside the rain.
          -- The formation ramp builds sooner than rain; no extra random draws.
          local approach=smooth(along/.35)
          local reach=1-smooth(((along+.05*math.sin(across*7))-1)*c.radius/(speed*45))
          reach=reach*(1-smooth((math.abs(across)-.7)/.3))
          local forming=smooth(c.age/12)*(1-smooth((c.age-(c.life-90))/90))
          F.warning=approach*reach*forming*(1-F.coverage)
        end
      end
    end
  end
  F.localMap=origin~=nil and ctx.outdoor and not ctx.indoors
  local hazeTarget=math.min(1,(F.warning or 0)*.85+F.coverage*.45)
  if not F.localMap or not c then F.haze=0
  else F.haze=F.haze+(hazeTarget-F.haze)*(1-math.exp(-dt/7)) end
  -- Rule: noise-shaped clouds expand first. Only a fully grown, settled deck
  -- may close its remaining gaps into full-sky overcast.
  if not F.localMap or not c then growth,fill,grownFor=0,0,0
  else
    local target=smooth((F.coverage-.35)/.5)
    growth=growth+(target-growth)*(1-math.exp(-dt/8))
    if growth>.97 and target>.97 then grownFor=grownFor+dt else grownFor=0 end
    local fillTarget=grownFor>=10 and 1 or 0
    fill=fill+(fillTarget-fill)*(1-math.exp(-dt/(fillTarget>fill and 12 or 5)))
  end
end
function F.cloudField()
  if not F.managed then return nil end
  local c=F.cell
  if not c or not F.localMap then return zero end
  field[1],field[2],field[3],field[4]=c.x-localX,c.z-localZ,1/c.radius,c.strength
  -- Interior overcast fills the existing horizon deck. Outside the bank this
  -- is zero, retaining the approaching shelf instead of globally forcing storm.
  field.canopy=growth
  field.fill=fill
  field.ready=smooth((c.age-45)/20)
  local _,_,ux,uz=F.coordinates(c.x,c.z);axis[1],axis[2]=ux,uz
  return field
end
function F.constrain(x,z)
  local c=F.cell
  if not F.managed or not c or not F.localMap then return x,z end
  local cx,cz=c.x-localX,c.z-localZ
  local dx,dz=x-cx,z-cz;local d=math.sqrt(dx*dx+dz*dz);local r=c.radius*.72
  if d>r then return cx+dx*r/d,cz+dz*r/d end
  return x,z
end
function F.status()
  if approaching then return 'CLOSE BOTH MENUS' end
  if V.require('QuestStorm').preferences().motion=='static' then return 'STATIC' end
  if restart then return 'QUEUED - CLOSE MENU' end
  if not F.managed then return 'SELECT STORM' end
  local c=F.cell
  if not c then return 'DISSIPATED - RESTART' end
  local phase=c.age<45 and 'FORMING' or c.age>c.life-90 and 'DISSIPATING' or 'TRAVELING'
  return ('%s %d%%'):format(phase,math.floor(F.coverage*100+.5))
end
function F.trigger()
  local s=V.require('Scene').now or {}
  local state=V.require('WeatherState')
  if not s.outdoor or s.indoors or state.id~='STORM' or (state.level or 0)<=0
      or V.require('QuestStorm').preferences().motion=='static' then return false end
  restart=true;return true
end
function F.triggerApproach()
  local s=V.require('Scene').now or {}
  if not s.outdoor or s.indoors then return false end
  approaching=true;restart=true;return true
end
function F.store()
  local save=V.mod and V.mod.save;if not(save and save.set)then return end
  local cell
  if F.cell then cell={};for k,v in pairs(F.cell)do cell[k]=v end end
  save:set('questStormFront',{version=2,seed=F.seed,latched=latched,cell=cell})
end
function F.restore()
  F.reset();local save=V.mod and V.mod.save;if not(save and save.get)then return end
  local data=save:get('questStormFront')
  if type(data)~='table' or (data.version~=1 and data.version~=2) then return end
  local c=data.cell
  if c then
    if type(c)~='table' or type(c.root)~='string' then return end
    for _,k in ipairs({'x','z','vx','vz','radius','age','life','strength'})do
      local n=c[k];if type(n)~='number' or n~=n or math.abs(n)>10000000 then return end
    end
    local limit=data.version==1 and 1 or 3
    if c.radius<200 or c.radius>4000*limit or c.life<60 or c.life>1800 or c.age<0
        or math.abs(c.vx)>100*limit or math.abs(c.vz)>100*limit then return end
    F.cell={};for k,v in pairs(c)do F.cell[k]=v end
    -- Upgrade an in-progress legacy cell once; preserve age and world center.
    if data.version==1 then
      F.cell.radius=c.radius*3;F.cell.vx=c.vx*3;F.cell.vz=c.vz*3
    end
  end
  if type(data.seed)=='number' and data.seed>0 and data.seed<2147483647 then F.seed=data.seed end
  latched=data.latched==true;F.managed=latched
end
if V.mod and V.mod.events then
  V.mod.events:on('save.writing',F.store)
  V.mod.events:on('save.loaded',F.restore)
  V.mod.events:on('save.created',F.reset)
end
return F
