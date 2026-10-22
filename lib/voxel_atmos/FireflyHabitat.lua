-- Cached local ecology. Native queries use root-map cells, not render pixels.
-- No global RNG, lights, world mutation, per-frame vegetation scans or new pools.
local M={}
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<1e7 end
local function clamp(v)return math.max(0,math.min(1,v))end
local excluded={'DESERT','CAVE','VOLCANO','MOUNTAIN','OCEAN','DEEP_SEA'}
function M.base(scene)
 local e=tostring(scene.environment or ''):upper()
 local id=tostring(scene.mapId or ''):upper()
 for _,bad in ipairs(excluded)do if e:find(bad,1,true)then return 0,'excluded' end end
 if scene.visible=='hidden'then return 0,'excluded'end
 if e:find('BEACH',1,true)or e:find('COAST',1,true)or id:find('BEACH',1,true)then return .12,'beach'end
 if scene.isTown or e:find('TOWN',1,true)or e:find('CITY',1,true)then return .035,'city'end
 if e:find('FOREST',1,true)or id:find('FOREST',1,true)or id:find('WOODS',1,true)then return 1,'forest'end
 return .35,'open'
end
function M.new()return {nextAt=0,probes=0,density=.35,kind='open',trees=0,water=0,sand=0,desert=0}end
function M.update(c,time,focus,scene,world,revision)
 local cx,cz=math.floor(focus[1]/48),math.floor(focus[3]/48)
 local base,kind=M.base(scene)
 local signature=tostring(scene.mapId)..':'..tostring(scene.environment)..':'..tostring(scene.isTown)..':'..tostring(scene.visible)
 if c.cx==cx and c.cz==cz and c.signature==signature and c.world==world
 and c.revision==revision and time<c.nextAt then return c.density end
 c.cx,c.cz,c.signature,c.world,c.revision=cx,cz,signature,world,revision;c.nextAt=time+2
 local trees,water,sand,desert,knownTrees,knownWater,knownMaterial=0,0,0,0,0,0,0
 -- Fixed 3x3 census spanning the same nine world cells as the18-slot pool.
 -- Anchor the census to cells, not eye motion, so head movement cannot respawn it.
 for dz=-1,1 do for dx=-1,1 do
  local x,z=(cx+dx+.5)*3,(cz+dz+.5)*3
  if world and type(world.vegetationAt)=='function'then
   local ok,v=pcall(world.vegetationAt,x,z);c.probes=c.probes+1
   if ok and finite(v)then trees=trees+clamp(v);knownTrees=knownTrees+1 end
  end
  if world and type(world.isWater)=='function'then
   local ok,v=pcall(world.isWater,x,z);c.probes=c.probes+1
   if ok and type(v)=='boolean'then water=water+(v and 1 or 0);knownWater=knownWater+1 end
  end
  if world and type(world.behavior)=='function'then
   local ok,v=pcall(world.behavior,x,z);c.probes=c.probes+1
   if ok and finite(v)then
    -- MB_SAND=0x21 in both FRLG and Emerald. Do not guess TREE from RSE behavior.
    sand=sand+(v==0x21 and 1 or 0);knownMaterial=knownMaterial+1
    -- RSE MB_DEEP_SAND=0x06: suppress desert cells, not all of mixed Route111.
    desert=desert+(v==0x06 and 1 or 0)
   end
  end
 end end
 trees=knownTrees>0 and trees/knownTrees or 0
 water=knownWater>0 and water/knownWater or 0
 sand=knownMaterial>0 and sand/knownMaterial or 0
 desert=knownMaterial>0 and desert/knownMaterial or 0
 local density=base
 if base>0 then
  -- A city park responds to real trees; a bare street retains only rare bugs.
  -- Beaches stay below comparable inland greenery, including wooded coastline.
  density=math.max(base,kind=='beach'and trees*.5 or .035+trees*.965)
  -- Actual maps usually report ROUTE/TOWN, not BEACH. Use native sandy ground
  -- to soften exposed beach patches rather than relying on a map-name label.
  if sand>0 and kind~='beach' then
   density=density*(1-sand)+math.min(density,math.max(.12,trees*.5))*sand
   kind='sandy-shore'
  end
  if water>0 then density=density*(1-water*.8);kind=kind=='forest'and 'forest-shore'or 'shore'end
  if desert>0 then density=density*(1-desert);kind='desert-edge'end
 end
 c.density,c.kind,c.trees,c.water,c.sand,c.desert=clamp(density),kind,trees,water,sand,desert
 return c.density
end
return M
