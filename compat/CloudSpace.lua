-- Carry the cloud coordinate origin through the same placements as terrain.
-- Connected edges are authoritative; warps do not invent adjacency.
local Space={};Space.__index=Space
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<1e9 end
function Space.new()return setmetatable({x=0,z=0,links={},known={},count=0},Space)end
function Space:reset()self.x,self.z=0,0;self.map=nil;self.links={};self.known={};self.count=0;self.reason='reset'end
function Space:observe(map,neighbors)
  local id=map and map.id;if type(id)~='string'then return end
  if self.map==id then return end -- shared by both eyes, no frame-time graph walks
  local shift=self.links[id]
  if not shift and self.map then
    for _,nb in ipairs(neighbors or {})do
      if nb.map and nb.map.id==self.map and finite(nb.ox)and finite(nb.oy)then
        shift={x=-nb.ox,z=-nb.oy};break
      end
    end
  end
  if shift then
    self.x,self.z=self.x+shift.x,self.z+shift.z;self.reason='connected'
  else
    local previous=self.known[id]
    self.x,self.z=previous and previous.x or 0,previous and previous.z or 0
    self.reason=previous and 'return' or 'unconnected'
  end
  -- Bounded history restores the outdoor anchor after an interior visit.
  if not self.known[id]then
    if self.count>=512 then self.known={};self.count=0 end
    self.count=self.count+1
  end
  self.known[id]={x=self.x,z=self.z};self.map=id;self.links={}
  for _,nb in ipairs(neighbors or {})do
    if nb.map and type(nb.map.id)=='string'and finite(nb.ox)and finite(nb.oy)then
      self.links[nb.map.id]={x=nb.ox,z=nb.oy}
    end
  end
end
function Space:placement(eye,tile,drift)
  local sx=math.floor((eye[1]+self.x-drift)/tile+.5)*tile+drift-self.x
  local sz=math.floor((eye[3]+self.z)/tile+.5)*tile-self.z
  return sx,sz
end
return Space
