-- Shared Quest retained uploads and stereo preparation. Geometry lives
-- in WorldPrecip; both eyes still draw, each with its current view-projection.
local V = ...
local B = {zeroEye={0,0,0}}
local states = {}
local serial = 0
local prefix, defaultSend
local settings, leaf = nil, 'green'
local stats = {builds=0,uploads=0,hits=0,passes=0,newMeshes=0,reserves=0,sliceGrowth=0,vpSends=0,empty=0,
  meshReleases=0,uploadFailures=0,cullBuilds=0,cullHits=0,cullTests=0,cullRejected=0}
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
  local sameCull=true
  if s.cullKey then
    local vp=voxel.vp
    if type(vp)~='table' or #vp~=16 then sameCull=false
    else for i=1,16 do
      if type(vp[i])~='number' or vp[i]~=vp[i] then sameCull=false;break end
      if i%4~=0 then
        if vp[i]~=s.cullKey[i] then sameCull=false;break end
      else
        -- Only translation explained by the eye movement is safe to share.
        local expected=s.cullKey[i]-vp[i-3]*dx-vp[i-2]*dy-vp[i-1]*dz
        if math.abs(vp[i]-expected)>1e-5 then sameCull=false;break end
      end
    end end
  end
  if sameCull and s.serial==serial and s.active==active and dx*dx+dy*dy+dz*dz<=B.eyeReuseDistance*B.eyeReuseDistance then
    stats.hits=stats.hits+1
    if s.n>=3 and s.mesh then
      beginPass(voxel,shader())
      if wet then pcall(love.graphics.setColor,.25,.30,.38,1)
      else pcall(love.graphics.setColor,1,1,1,1) end
      pcall(love.graphics.draw,s.mesh)
      if wet then pcall(love.graphics.setColor,1,1,1,1) end
      endPass(voxel)
    end
    return true,s.n
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
  local oldMesh,oldCap=mesh,s.cap
  local grew=false
  if not mesh or s.cap<n then
    local want=math.floor(n*1.35)+256
    buf:reserve(want);stats.reserves=stats.reserves+1
    local ok,m=pcall(love.graphics.newMesh,fmt,want,'triangles','stream')
    if not ok or not m then s.serial=-1;return nil end
    mesh=m;s.cap=want;grew=true;stats.newMeshes=stats.newMeshes+1
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
  if ok then ok=pcall(mesh.setDrawRange,mesh,1,n) end
  if not ok then
    s.serial=-1;stats.uploadFailures=stats.uploadFailures+1
    if grew then
      if mesh.release then pcall(mesh.release,mesh);stats.meshReleases=stats.meshReleases+1 end
      s.cap=oldCap;s.mesh=oldMesh
    end
    return nil
  end
  if grew and oldMesh and oldMesh~=mesh and oldMesh.release then
    pcall(oldMesh.release,oldMesh);stats.meshReleases=stats.meshReleases+1
  end
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
    if s.mesh and s.mesh.release then pcall(s.mesh.release,s.mesh);stats.meshReleases=stats.meshReleases+1 end
    s.serial=-1;s.mesh=nil;s.cap=0;s.n=0;s.active=nil
  end
  prefix=nil;defaultSend=nil
end
-- Release one optional effect stream without disrupting other eyes/streams.
function B.release(buf)
  local s=states[buf]
  if not s then return end
  if s.mesh and s.mesh.release then
    pcall(s.mesh.release,s.mesh);stats.meshReleases=stats.meshReleases+1
  end
  s.serial=-1;s.mesh=nil;s.cap=0;s.n=0;s.active=nil;s.cullKey=nil
end
function B.changed() serial=serial+1 end
-- Default LOVE flat VP layout is row-major. Unknown host matrix types keep
-- the uncullled path. Extract normalized planes once, not per particle.
local planes={ {},{},{},{},{},{} }
local cull=false
local planeKey={}
local planeSerial=-1
function B.prepareCull(vp,buf)
  cull=false
  local s=buf and state(buf)
  if s then s.cullKey=nil end
  if type(vp)~='table' or #vp~=16 then planeSerial=-1;return end
  for i=1,16 do if type(vp[i])~='number' or vp[i]~=vp[i] or math.abs(vp[i])==math.huge then planeSerial=-1;return end end
  local same=planeSerial==serial
  if same then for i=1,16 do if planeKey[i]~=vp[i] then same=false;break end end end
  if same then stats.cullHits=stats.cullHits+1 else
  planeSerial=-1 -- a failed/degenerate matrix must not poison reusable planes
  for axis=1,3 do for side=1,2 do
    local p=planes[(axis-1)*2+side];local sign=side==1 and 1 or -1;local row=(axis-1)*4
    local a,b,c,d=vp[13]+sign*vp[row+1],vp[14]+sign*vp[row+2],vp[15]+sign*vp[row+3],vp[16]+sign*vp[row+4]
    local len=math.sqrt(a*a+b*b+c*c)
    if len<1e-10 then return end
    p[1],p[2],p[3],p[4]=a/len,b/len,c/len,d/len
  end end
  for i=1,16 do planeKey[i]=vp[i] end
  planeSerial=serial;stats.cullBuilds=stats.cullBuilds+1
  end
  cull=true
  if s then
    s.cullStorage=s.cullStorage or {};s.cullKey=s.cullStorage
    for i=1,16 do s.cullKey[i]=vp[i] end
  end
end
function B.visibleSphere(x,y,z,r)
  if not cull then return true end
  stats.cullTests=stats.cullTests+1
  -- Pad for geometry shared by the nearby second eye.
  r=r+B.eyeReuseDistance
  for i=1,6 do local p=planes[i];if p[1]*x+p[2]*y+p[3]*z+p[4]<-r then stats.cullRejected=stats.cullRejected+1;return false end end
  return true
end
return B
