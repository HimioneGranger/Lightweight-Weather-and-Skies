-- Quest adapter: sample the same tile shapes that Battle Art renders.
-- Unknown/off-map/irregular shapes produce no decal, never a camera-height slab.
local Surface={}
function Surface.sampler(map,shapesAPI)
  if not(map and map.inBounds and map.tileAt and shapesAPI and shapesAPI.forMap and shapesAPI.at)then
    return function() return nil end
  end
  local shapes=shapesAPI.forMap(map)
  return function(x,z)
    if not map:inBounds(math.floor(x/16),math.floor(z/16))then return nil end
    local tx,tz=math.floor(x/8),math.floor(z/8)
    local s=shapesAPI.at(map,shapes,map:tileAt(tx,tz),tx,tz)
    if not s or (s.art~='flat' and s.art~='top')then return nil end
    return tonumber(s.h) or 0
  end
end
return Surface
