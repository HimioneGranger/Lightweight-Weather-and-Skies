-- One static world-oriented arc; no screen overlay, bloom or render target.
local V=...
local R={}
local mesh,shader
R.SHADER=[[
varying float height;
#ifdef VERTEX
uniform mat4 vp;
uniform vec3 eye;
uniform vec3 antiSun;
uniform vec3 arcRight;
uniform vec3 arcUp;
uniform float radius;
vec4 position(mat4 transform_projection,vec4 vertex_position){
  float theta=VertexTexCoord.x*3.14159265;
  float angle=mix(0.6981317,0.7504916,VertexTexCoord.y);
  vec3 direction=antiSun*cos(angle)+(arcRight*cos(theta)+arcUp*sin(theta))*sin(angle);
  height=direction.y;
  return vp*vec4(eye+direction*radius,1.0);
}
#endif
#ifdef PIXEL
uniform float opacity;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
  float edge=smoothstep(0.0,0.18,tc.y)*(1.0-smoothstep(0.82,1.0,tc.y));
  float ends=smoothstep(0.0,0.03,height);
  // Continuous spectral gradient, violet inside / red outside. No hard bands.
  vec3 tint=clamp(vec3(1.5-abs(4.0*tc.y-3.0),1.5-abs(4.0*tc.y-2.0),1.5-abs(4.0*tc.y-1.0)),0.0,1.0);
  tint=mix(tint,vec3(1.0),.22);
  return vec4(tint,opacity*edge*ends)*color;
}
#endif
]]
function R.vertices()
  local out={}
  for i=0,63 do local a,b=i/64,(i+1)/64
    for _,uv in ipairs({{a,0},{b,0},{b,1},{a,0},{b,1},{a,1}})do out[#out+1]={0,0,0,uv[1],uv[2]}end
  end
  return out
end
function R.drawWorld(voxel)
  local after=V.require('QuestAfterStorm')
  if (after.rainbow or 0)<=.001 then return false end
  local scene=V.require('Scene').now or {}
  if not scene.outdoor or scene.indoors then return false end
  local sun=V.require('CelestialBodies').bodies(V.require('TimeOfDay').hour).sun
  if not sun or not sun.above or sun.dy<=.08 or sun.dy>=.66 then return false end
  local ax,ay,az=-sun.dx,-sun.dy,-sun.dz
  local length=math.sqrt(ax*ax+az*az)
  if length<.001 then return false end
  local rx,rz=-az/length,ax/length
  local ux,uy,uz=-ay*rz,rz*ax-rx*az,ay*rx
  -- Right x antiSun points upward for the upper half of the bow.
  if uy<0 then ux,uy,uz=-ux,-uy,-uz end
  local g=love.graphics
  shader=shader or g.newShader(R.SHADER)
  mesh=mesh or g.newMesh({{'VertexPosition','float',3},{'VertexTexCoord','float',2}},R.vertices(),'triangles','static')
  g.push('all')
  local ok,err=pcall(function()
    g.setShader(shader);shader:send('vp','row',voxel.vp);shader:send('eye',voxel.eye)
    shader:send('antiSun',{ax,ay,az});shader:send('arcRight',{rx,0,rz});shader:send('arcUp',{ux,uy,uz})
    shader:send('radius',(voxel.far or 500)*.90);shader:send('opacity',after.rainbow)
    g.setDepthMode('lequal',false);g.setBlendMode('alpha','alphamultiply');g.setMeshCullMode('none');g.setColor(1,1,1,1);g.draw(mesh)
  end)
  g.pop();if not ok then error(err)end;return true
end
return R
