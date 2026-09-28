-- Design tendencies, not real-world climate claims. No geometry or particles.
local V=...
local R={}
local profiles={
 evergreen={label='VIRIDIAN FOREST',clear=.65,rain=1.55,storm=.9,wind=.65,span=1.2,speed=.8,size=1},
 savannah={label='SAFARI SAVANNAH',clear=3,rain=.65,storm=.8,wind=1.1,span=1.05,speed=1.1,size=1.08,lightning=2},
 neutral={label='BALANCED',clear=1,rain=1,storm=1,wind=1,span=1,speed=1,size=1},
 pallet={label='PALLET COAST',clear=1.4,rain=.8,storm=.65,wind=.85,span=.95,speed=1,size=1,heading=0},
 forest={label='VIRIDIAN WOODS',clear=.85,rain=1.3,storm=1.05,wind=.85,span=1.1,speed=.9,size=1},
 mountain={label='PEWTER FOOTHILLS',clear=1.15,rain=.85,storm=.85,wind=1.3,span=.85,speed=1.1,size=1},
 north={label='NORTHERN PLAINS',clear=1.2,rain=1,storm=.9,wind=1,span=.95,speed=1.05,size=1},
 harbor={label='VERMILION COAST',clear=.95,rain=1.15,storm=1.35,wind=1.4,span=1,speed=1.15,size=1.08,heading=-math.pi/2},
 central={label='CENTRAL KANTO',clear=1.15,rain=1,storm=.85,wind=.9,span=1,speed=1,size=1},
 east={label='LAVENDER COAST',clear=.85,rain=1.25,storm=1.1,wind=1.1,span=1.12,speed=.95,size=1.04,heading=math.pi},
 marsh={label='FUCHSIA LOWLANDS',clear=.8,rain=1.4,storm=1.2,wind=.9,span=1.15,speed=.85,size=1.06},
 island={label='SOUTHERN ISLANDS',clear=1,rain=1.1,storm=1.35,wind=1.5,span=.9,speed=1.2,size=1.08,heading=-math.pi/2},
 indigo={label='INDIGO HIGHLANDS',clear=1,rain=1,storm=1.1,wind=1.3,span=.85,speed=1.1,size=1},
 johto_start={label='SOUTHEAST JOHTO',clear=1.25,rain=.9,storm=.8,wind=.9,span=.95,speed=1,size=1},
 johto_woods={label='ILEX WOODLANDS',clear=.8,rain=1.35,storm=1,wind=.75,span=1.15,speed=.9,size=1.03},
 johto_plains={label='JOHTO PLAINS',clear=1.15,rain=1,storm=.9,wind=1.05,span=1,speed=1.05,size=1},
 johto_coast={label='JOHTO COAST',clear=.95,rain=1.15,storm=1.3,wind=1.4,span=1,speed=1.15,size=1.08,heading=-math.pi/2},
 johto_lake={label='LAKE OF RAGE',clear=.75,rain=1.45,storm=1.35,wind=1.1,span=1.18,speed=.9,size=1.08},
 johto_highlands={label='JOHTO HIGHLANDS',clear=1,rain=.9,storm=1.05,wind=1.35,span=.9,speed=1.1,size=1.04},
}
local maps={PALLETTOWN='pallet',VIRIDIANCITY='forest',VIRIDIANFOREST='evergreen',SAFARIZONECENTER='savannah',
 PEWTERCITY='mountain',CERULEANCITY='north',VERMILIONCITY='harbor',
 CELADONCITY='central',SAFFRONCITY='central',LAVENDERTOWN='east',
 FUCHSIACITY='marsh',CINNABARISLAND='island',INDIGOPLATEAU='indigo'}
local routes={'pallet','forest','mountain','mountain','central','harbor','central','east',
 'north','east','harbor','east','marsh','marsh','marsh','central','marsh','marsh',
 'island','island','island','indigo','indigo','north','north'}
for i,profile in ipairs(routes)do maps['ROUTE'..i]=profile end
local johtoMaps={
 NEWBARKTOWN='johto_start',CHERRYGROVECITY='johto_start',VIOLETCITY='johto_plains',
 AZALEATOWN='johto_woods',ILEXFOREST='johto_woods',GOLDENRODCITY='central',
 NATIONALPARK='johto_plains',ECRUTEAKCITY='johto_plains',OLIVINECITY='johto_coast',
 CIANWOODCITY='johto_coast',MAHOGANYTOWN='johto_lake',LAKEOFRAGE='johto_lake',
 BLACKTHORNCITY='johto_highlands',MTSILVER='johto_highlands',SILVERCAVE='johto_highlands',
}
for id,profile in pairs(johtoMaps)do maps[id]=profile end
local johtoRoutes={
 [26]='johto_highlands',[27]='johto_highlands',[28]='johto_highlands',
 [29]='johto_start',[30]='johto_start',[31]='johto_plains',[32]='johto_plains',
 [33]='johto_woods',[34]='central',[35]='johto_plains',[36]='johto_plains',
 [37]='johto_plains',[38]='johto_coast',[39]='johto_coast',[40]='johto_coast',
 [41]='johto_coast',[42]='johto_lake',[43]='johto_lake',[44]='johto_highlands',
 [45]='johto_highlands',[46]='johto_highlands',[47]='johto_coast',[48]='johto_coast',
}
for route,profile in pairs(johtoRoutes)do maps['ROUTE'..route]=profile end
function R.enabled()
 local ok,g=pcall(require,'src.core.Game')
 return not(ok and g.save and g.save.options and g.save.options.qRegionalWeather==false)
end
function R.profile(mapId)
 if V and V.require then mapId=V.require('OutdoorWeatherAreas').identity(mapId) end
 local key=tostring(mapId or ''):upper():gsub('[^A-Z0-9]','')
 return profiles[maps[key]or 'neutral']
end
function R.weight(mapId,id)
 if not R.enabled()then return 1 end
 local p=R.profile(mapId)
 if id=='CLEAR' or ((p==profiles.savannah) and id=='SUNNY') then return p.clear end
 if id=='STORM'then return p.storm end
 if id=='RAIN_LIGHT'or id=='RAIN_HEAVY'or id=='HEAVY_RAIN'then return p.rain end
 if id=='STRONG_WINDS'or id=='GALE'then return p.wind end
 return 1 -- Never add weather types or defeat seasonal/safety exclusions.
end
function R.duration(mapId,id)
 if not R.enabled()then return 1 end
 local p=R.profile(mapId)
 if id=='STORM'or id=='RAIN_LIGHT'or id=='RAIN_HEAVY'or id=='HEAVY_RAIN'then return p.span end
 return 1
end
function R.front(mapId,a,speed,radius,life)
 if not R.enabled()then return a,speed,radius,life end
 local p=R.profile(mapId)
 if p.heading then a=p.heading+(a-math.pi)*.35 end
 return a,speed*p.speed,radius*p.size,life*p.span
end
function R.lightningRate(mapId,weatherId)
 if weatherId~='STORM' or not R.enabled()then return 1 end
 return R.profile(mapId).lightning or 1
end
return R
