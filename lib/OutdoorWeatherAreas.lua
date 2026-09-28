-- Climate identities are distinct from spatial anchors. Never replace gameplay maps.
local M={}
local parents={VIRIDIAN_FOREST='ROUTE_2',SAFARI_ZONE_CENTER='FUCHSIA_CITY',
 SAFARI_ZONE_EAST='FUCHSIA_CITY',SAFARI_ZONE_NORTH='FUCHSIA_CITY',SAFARI_ZONE_WEST='FUCHSIA_CITY'}
function M.parent(id)return parents[id]end
function M.identity(id)
 if id=='VIRIDIAN_FOREST' then return id end
 if parents[id]=='FUCHSIA_CITY' then return 'SAFARI_ZONE_CENTER' end
 return id
end
function M.position(maps,id,x,z)
 local parent=parents[id];local a,b=maps and maps[id],maps and maps[parent]
 if not(parent and a and b)then return id,x,z,0,0 end
 local dx=((b.width or 0)-(a.width or 0))*16
 local dz=((b.height or 0)-(a.height or 0))*16
 return parent,type(x)=='number' and x+dx or x,type(z)=='number' and z+dz or z,dx,dz
end
return M
