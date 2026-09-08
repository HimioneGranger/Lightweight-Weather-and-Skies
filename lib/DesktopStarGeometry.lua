-- Project fixed celestial centers, then expand only their pixel footprint.
local G = {}
function G.project(m,x,y,z,width,height,halfPixels)
  local w=m[13]*x+m[14]*y+m[15]*z+m[16]
  if w<=1e-6 then return nil end
  local nx=(m[1]*x+m[2]*y+m[3]*z+m[4])/w
  local ny=(m[5]*x+m[6]*y+m[7]*z+m[8])/w
  return nx,ny,2*halfPixels/math.max(1,width),2*halfPixels/math.max(1,height)
end
return G
