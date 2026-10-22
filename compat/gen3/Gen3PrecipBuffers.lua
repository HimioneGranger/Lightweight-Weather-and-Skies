-- Packet A2: Gen3-only retained uploads and stereo preparation. Geometry lives
-- in WorldPrecip; both eyes still draw, each with its current view-projection.
local V = ...
local B = {zeroEye={0,0,0}}
local states = {}
local serial = 0
local prefix, defaultSend
local settings, leaf = nil, 'green'
local stats = {builds=0,uploads=0,hits=0,passes=0,newMeshes=0,reserves=0,sliceGrowth=0,vpSends=0,empty=0}
B.stats = stats
-- One world unit is 1/16 tile. Reuse only near-coincident stereo views;
-- arbitrary same-step camera relocation must rebuild eye-facing geometry.
B.eyeReuseDistance = 1
local function state(buf)
  local s=states[buf]
  if not s then s={slice={},sliceN=0,sliceCap=0,cap=0,serial=-1};states[buf]=s end
  return s
end
function B.step()
  serial=serial+1
  if not settings then
    local ok,s=pcall(V.require,'Settings')
    if ok then settings=s end
  end
  if settings and settings.leafColor then
    local ok,value=pcall(settings.leafColor)
    if ok then leaf=value or 'green' end
  end
end
function B.leafColor() return leaf end
function B.cap(budget,wxId)
  return math.min(budget,wxId=='STORM' and 120 or 90)
end
function B.cachedDraw(buf,active,voxel,shader,beginPass,endPass,wet)
  if not (voxel and voxel.vp) or active<=0 then return false end
  local s=state(buf)
  local eye=voxel.eye or B.zeroEye
  local x,y,z=eye[1] or 0,eye[2] or 0,eye[3] or 0
  local dx,dy,dz=x-(s.x or x),y-(s.y or y),z-(s.z or z)
  if s.serial==serial and s.active==active and (wet or dx*dx+dy*dy+dz*dz<=B.eyeReuseDistance*B.eyeReuseDistance) then
    stats.hits=stats.hits+1
    if s.n>=3 and s.mesh then
      beginPass(voxel,shader())
      if wet then pcall(love.graphics.setColor,.25,.30,.38,1)
      else pcall(love.graphics.setColor,1,1,1,1) end
      pcall(love.graphics.draw,s.mesh)
      if wet then pcall(love.graphics.setColor,1,1,1,1) end
      endPass(voxel)
    end
    return true
  end
  s.x,s.y,s.z,s.active=x,y,z,active
  s.serial=-1
  stats.builds=stats.builds+1
  return false
end
function B.upload(mesh,fmt,buf)
  local s=state(buf)
  local n=buf.n
  s.n=n
  if n<3 then
    -- The caller sees no geometry, while this state retains its VBO capacity.
    s.serial=serial;stats.empty=stats.empty+1
    return nil
  end
  mesh=s.mesh or mesh
  if not mesh or s.cap<n then
    local want=math.floor(n*1.35)+256
    buf:reserve(want);stats.reserves=stats.reserves+1
    local ok,m=pcall(love.graphics.newMesh,fmt,want,'triangles','stream')
    if not ok or not m then s.serial=-1;return nil end
    mesh=m;s.mesh=m;s.cap=want;stats.newMeshes=stats.newMeshes+1
  end
  local ok=false
  if prefix~=false then
    ok=pcall(mesh.setVertices,mesh,buf.v,1,n)
    if ok then prefix=true else prefix=false end
  end
  if not ok then
    local slice=s.slice
    for i=1,n do slice[i]=buf.v[i] end
    for i=n+1,s.sliceN do slice[i]=nil end
    if n>s.sliceCap then stats.sliceGrowth=stats.sliceGrowth+1;s.sliceCap=n end
    s.sliceN=n
    ok=pcall(mesh.setVertices,mesh,slice)
  end
  if not ok then s.serial=-1;return nil end
  pcall(mesh.setDrawRange,mesh,1,n)
  s.serial=serial;s.mesh=mesh;stats.uploads=stats.uploads+1
  return mesh
end
function B.beginPass(voxel,sh)
  pcall(love.graphics.setBlendMode,'alpha','alphamultiply')
  pcall(love.graphics.setDepthMode,'lequal',false)
  local began=false
  if voxel.beginEffect and sh then began=voxel.beginEffect(sh) end
  if sh then
    if not began then pcall(love.graphics.setShader,sh) end
    -- Legacy sent row then default: when both work, default is the final uniform.
    -- Prefer that winner and only use row on hosts rejecting default layout.
    local ok=false
    if defaultSend~=false then
      ok=pcall(sh.send,sh,'vp',voxel.vp)
      if ok then defaultSend=true else defaultSend=false end
    end
    if not ok then pcall(sh.send,sh,'vp','row',voxel.vp) end
    stats.vpSends=stats.vpSends+1
  end
  stats.passes=stats.passes+1
end
function B.invalidate()
  serial=serial+1
  for _,s in pairs(states) do
    s.serial=-1;s.mesh=nil;s.cap=0;s.n=0;s.active=nil
  end
  prefix=nil;defaultSend=nil
end
function B.changed() serial=serial+1 end
return B