-- Source-derived branching paths rendered as narrow crossed world ribbons.
-- Mesh regenerated only for a new strike, shared unchanged by both eyes.
local V=...
local Bolt={}
Bolt.SPICY_WIDTH_BOOST=2.25
local mesh,shader,lastId
Bolt.SHADER=[[
varying float ribbonEdge;
varying float pathProgress;
#ifdef VERTEX
uniform mat4 vp;
attribute float BoltEdge;
attribute float BoltProgress;
vec4 position(mat4 transform_projection,vec4 vertex_position){ribbonEdge=BoltEdge;pathProgress=BoltProgress;return vp*vertex_position;}
#endif
#ifdef PIXEL
uniform float opacity;
uniform float reveal;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
  float edge=1.0-smoothstep(0.15,1.0,abs(ribbonEdge));
  float leader=smoothstep(pathProgress,pathProgress+0.008,reveal);
  return vec4(color.rgb,color.a*opacity*edge*leader);
}
#endif
]]
local FORMAT={{'VertexPosition','float',3},{'VertexColor','float',4},{'BoltEdge','float',1},{'BoltProgress','float',1}}
function Bolt.widthScale(event,index)
  local w=index==1 and 1 or .60
  if event.style=='forked' and event.prominentForks and index>1 then w=.90 end
  if event.style=='anvil' then
    w=w*(event.variant and event.variant.anvilWidth or 1.9)
  end
  if event.verification then w=w*Bolt.SPICY_WIDTH_BOOST end
  return w*(event.variant and event.variant.width or 1)
end
local function pathsFor(event)
  local paths={event.points,event.fork or {}}
  for _,branch in ipairs(event.branches or {})do paths[#paths+1]=branch end
  for _,twig in ipairs(event.twigs or {})do paths[#paths+1]=twig end
  return paths
end
-- Per-node progress follows parent junctions, including secondary forks.
-- The first point of every child has exactly its parent's junction progress.
function Bolt.pathProgress(event)
  local paths=pathsFor(event)
  local progress={}
  for index,path in ipairs(paths)do
    local nodes={}
    local start,finish=0,event.style=='anvil' and .72 or .99
    if path.parentPath then
      local parent=assert(progress[path.parentPath],'child precedes parent path')
      start=assert(parent[path.parentPoint],'missing parent junction')
      finish=start+(1-start)*(path.parentPath==event.points and .78 or .90)
    elseif index>1 then
      start,finish=.30,.95
    end
    for i=1,#path do
      nodes[i]=start+(finish-start)*(i-1)/math.max(1,#path-1)
    end
    progress[path]=nodes
  end
  return progress,paths
end
function Bolt.vertices(event)
  local vertices={}
  local function ribbon(a,b,ox,oz,width,tip,alpha,core,pa,pb)
    local function v(p,s,w,u)return{p[1]+ox*w*s,p[2],p[3]+oz*w*s,
      core and .96 or .42,core and .98 or .65,1,alpha,s,u}end
    local p,q,r,s=v(a,-1,width,pa),v(a,1,width,pa),v(b,1,tip,pb),v(b,-1,tip,pb)
    for _,x in ipairs({p,q,r,p,r,s})do vertices[#vertices+1]=x end
  end
  local progress,paths=Bolt.pathProgress(event)
  for index,path in ipairs(paths)do
    for i=1,#path-1 do
      for _,axis in ipairs({{1,0},{0,1}})do
        -- Keep the distant core wider than a subpixel at Quest eye resolution.
        local w=Bolt.widthScale(event,index)
        local a=1-.60*(i-1)/math.max(1,#path-1)
        local b=1-.60*i/math.max(1,#path-1)
        local pa,pb=progress[path][i],progress[path][i+1]
        ribbon(path[i],path[i+1],axis[1],axis[2],8*w*a,8*w*b,.22,false,pa,pb)
        ribbon(path[i],path[i+1],axis[1],axis[2],2*w*a,2*w*b,.96,true,pa,pb)
      end
    end
  end
  return vertices
end
function Bolt.drawWorld(voxel)
  local storm=V.require('QuestStorm')
  local event=storm.bolt()
  if not event or event.boltAlpha<=.001 then return false end
  local g=love.graphics
  shader=shader or g.newShader(Bolt.SHADER)
  if lastId~=event.id then
    local vertices=Bolt.vertices(event)
    if mesh and mesh.release then mesh:release() end
    mesh=g.newMesh(FORMAT,vertices,'triangles','static');lastId=event.id
  end
  g.push('all')
  local ok,err=pcall(function()
    g.setShader(shader);shader:send('vp','row',voxel.vp);shader:send('opacity',event.boltAlpha)
    shader:send('reveal',event.reveal or 1)
    g.setColor(1,1,1,1);g.setBlendMode('alpha','alphamultiply')
    g.setDepthMode('lequal',false);g.setMeshCullMode('none');g.draw(mesh)
  end)
  g.pop()
  if not ok then error(err) end
  return true
end
return Bolt
