-- Design tendencies, not real-world climate claims. No geometry or particles.
local R={}
local profiles={
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
}
local maps={PALLETTOWN='pallet',VIRIDIANCITY='forest',VIRIDIANFOREST='forest',
 PEWTERCITY='mountain',CERULEANCITY='north',VERMILIONCITY='harbor',
 CELADONCITY='central',SAFFRONCITY='central',LAVENDERTOWN='east',
 FUCHSIACITY='marsh',CINNABARISLAND='island',INDIGOPLATEAU='indigo'}
local routes={'pallet','forest','mountain','mountain','central','harbor','central','east',
 'north','east','harbor','east','marsh','marsh','marsh','central','marsh','marsh',
 'island','island','island','indigo','indigo','north','north'}
for i,profile in ipairs(routes)do maps['ROUTE'..i]=profile end
function R.enabled()
 local ok,g=pcall(require,'src.core.Game')
 return not(ok and g.save and g.save.options and g.save.options.qRegionalWeather==false)
end
function R.profile(mapId)
 local key=tostring(mapId or ''):upper():gsub('[^A-Z0-9]','')
 return profiles[maps[key]or 'neutral']
end
function R.weight(mapId,id)
 if not R.enabled()then return 1 end
 local p=R.profile(mapId)
 if id=='CLEAR'then return p.clear end
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
return R
