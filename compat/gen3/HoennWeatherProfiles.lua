-- Authored Hoenn climate tendencies. Native map/header/coordinate weather wins.
-- No outside voxel data/assets. Weather ids below use this mod's vocabulary.
local H={}
local function profile(label,clear,rain,storm,wind)
 return {label=label,clear=clear,rain=rain,storm=storm,wind=wind,span=1,speed=1,size=1}
end
H.profiles={
 south=profile('SOUTHERN HOENN',1.4,.9,.7,.8),
 woods=profile('PETALBURG WOODS',.8,1.4,1,.7),
 west=profile('WESTERN HOENN COAST',1,1.1,1.2,1.3),
 highlands=profile('HOENN HIGHLANDS',1.1,.8,.8,1.3),
 volcanic=profile('CHIMNEY VOLCANIC BELT',1.5,.5,.5,1.1),
 desert=profile('ROUTE 111 DESERT',2.5,.15,.2,1.4),
 ash=profile('ROUTE 113 ASHFALL',1.5,.6,.5,.9),
 rainforest=profile('FORTREE RAINFOREST',.6,1.8,1.3,.8),
 east=profile('EASTERN HOENN COAST',1,1.2,1.3,1.2),
 sea=profile('HOENN SEA',1,1.1,1.3,1.5),
 pillar=profile('SKY PILLAR',1.2,.8,1.2,1.6),
 cave=profile('HOENN CAVE',1,0,0,0),
 underwater=profile('HOENN UNDERWATER',1,0,0,0),
 indoor=profile('HOENN INTERIOR',1,0,0,0),
 neutral=profile('HOENN',1,1,1,1),
}
H.locations={
 LITTLEROOT_TOWN='south',OLDALE_TOWN='south',PETALBURG_CITY='woods',RUSTBORO_CITY='west',
 DEWFORD_TOWN='west',SLATEPORT_CITY='west',MAUVILLE_CITY='south',VERDANTURF_TOWN='woods',
 FALLARBOR_TOWN='ash',LAVARIDGE_TOWN='volcanic',FORTREE_CITY='rainforest',LILYCOVE_CITY='east',
 MOSSDEEP_CITY='sea',SOOTOPOLIS_CITY='sea',PACIFIDLOG_TOWN='sea',EVER_GRANDE_CITY='sea',
 PETALBURG_WOODS='woods',MT_CHIMNEY='volcanic',JAGGED_PASS='volcanic',
 SAFARI_ZONE='rainforest',SKY_PILLAR='pillar',BATTLE_FRONTIER='sea',SOUTHERN_ISLAND='sea',
 GRANITE_CAVE='cave',RUSTURF_TUNNEL='cave',METEOR_FALLS='cave',FIERY_PATH='cave',
 SHOAL_CAVE='cave',SEAFLOOR_CAVERN='cave',CAVE_OF_ORIGIN='cave',VICTORY_ROAD='cave',
 NEW_MAUVILLE='cave',SEALED_CHAMBER='cave',DESERT_RUINS='cave',ISLAND_CAVE='cave',
 ANCIENT_TOMB='cave',MARINE_CAVE='cave',TERRA_CAVE='cave',DESERT_UNDERPASS='cave',
 MT_PYRE='highlands',SCORCHED_SLAB='cave',AQUA_HIDEOUT='cave',MAGMA_HIDEOUT='cave',
 MIRAGE_TOWER='cave',ABANDONED_SHIP='sea',NAVEL_ROCK='sea',BIRTH_ISLAND='sea',
 FARAWAY_ISLAND='rainforest',MIRAGE_ISLAND='sea',
}
local routes={
 [101]='south',[102]='woods',[103]='south',[104]='woods',[105]='sea',[106]='sea',[107]='sea',
 [108]='sea',[109]='west',[110]='west',[111]='highlands',[112]='volcanic',[113]='ash',
 [114]='highlands',[115]='west',[116]='highlands',[117]='woods',[118]='east',[119]='rainforest',
 [120]='rainforest',[121]='east',[122]='sea',[123]='rainforest',[124]='sea',[125]='sea',
 [126]='sea',[127]='sea',[128]='sea',[129]='sea',[130]='sea',[131]='sea',[132]='sea',
 [133]='sea',[134]='sea',
}
for id,p in pairs(routes)do H.locations['ROUTE'..id]=p end
function H.key(id)return tostring(id or ''):upper():gsub('^EM_','')end
function H.profile(id,def)
 local key=H.key(id)
 if def and def.mapType==5 or key:find('UNDERWATER',1,true) then return H.profiles.underwater end
 if def and def.mapType==4 then return H.profiles.cave end
 if def and (def.mapType==7 or def.mapType==8 or def.mapType==9) then return H.profiles.indoor end
 if key:find('ROUTE111',1,true) and ((def and def.weather==8) or key:find('DESERT',1,true))then return H.profiles.desert end
 local p=H.locations[key]
 if not p then
  local best=0
  for prefix,value in pairs(H.locations)do
   if key:sub(1,#prefix+1)==prefix..'_' and #prefix>best then p=value;best=#prefix end
  end
 end
 return H.profiles[p or 'neutral']
end
function H.weight(p,id)
 if id=='CLEAR' then return p.clear end
 if id=='STORM' then return p.storm end
 if id=='RAIN_LIGHT' or id=='RAIN_HEAVY' or id=='HEAVY_RAIN' then return p.rain end
 if id=='GALE' or id=='STRONG_WINDS' then return p.wind end
 if id=='ASHFALL' then return p==H.profiles.ash and 4 or p==H.profiles.volcanic and 2 or 0 end
 if id=='SNOW_LIGHT' then return 0 end -- no natural surface snowfall in this Hoenn table
 return 1
end
return H
