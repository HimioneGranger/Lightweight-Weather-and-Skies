-- Lightweight Quest-native northern curtains. No screen-aligned overlay,
-- offscreen canvas, texture upload, particle pool, or camera-facing axes.
local V=...
local Aurora={}
local mesh,shader
local FORMAT={{'VertexPosition','float',3},{'VertexTexCoord','float',2}}
Aurora.SHADER=[[
uniform LOVE_HIGHP_OR_MEDIUMP float clock;
uniform LOVE_HIGHP_OR_MEDIUMP float layer;
uniform LOVE_HIGHP_OR_MEDIUMP vec4 flourish; // crown, pink, split, event time
#ifdef VERTEX
uniform mat4 vp;
uniform vec3 eye;
uniform float radius;
uniform float bearing;
vec4 position(mat4 transform_projection,vec4 vertex_position) {
  vec3 direction=vertex_position.xyz;
  vec2 uv=VertexTexCoord.xy;
  float t=clock*(1.0-0.19*layer)+89.0*layer;
  // Slow large folds deform the curtain, not camera-facing billboard axes.
  float fold=sin(uv.x*9.0+t*0.025)+0.45*sin(uv.x*17.0-t*0.017);
  direction.x+=0.055*fold*sin(uv.y*3.14159265);
  direction.y+=0.025*sin(uv.x*13.0-t*0.021)*(0.3+uv.y)+0.075*layer;
  direction.z+=0.028*sin(uv.x*7.0+t*0.019)*uv.y;
  direction.x+=flourish.z*0.045*sin(uv.x*13.0+flourish.w*0.025+layer)*uv.y;
  // The same curtain fans into an overhead crown: no third layer or mesh.
  float crownAz=(uv.x-0.5)*6.0+layer*0.12;
  float crownEl=0.94+uv.y*0.60+0.025*fold*(1.0-uv.y);
  vec3 crown=vec3(cos(crownEl)*sin(crownAz),sin(crownEl),-cos(crownEl)*cos(crownAz));
  direction=mix(direction,crown,flourish.x);
  float c=cos(bearing+0.16*layer),s=sin(bearing+0.16*layer);
  direction.xz=vec2(direction.x*c-direction.z*s,direction.x*s+direction.z*c);
  return vp * vec4(normalize(direction) * radius + eye,1.0);
}
#endif
#ifdef PIXEL
uniform float opacity;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  float t=clock*(1.0-0.19*layer)+89.0*layer;
  float x=tc.x+0.018*sin(tc.y*6.0+t*0.019), y=tc.y;
  float wave=0.23+0.07*sin(x*11.0+t*0.035)+0.04*sin(x*23.0-t*0.023);
  float above=y-wave;
  float base=smoothstep(-0.035,0.02,above)*exp(-max(above,0.0)*5.5);
  float folds=0.65+0.22*sin(x*75.0+sin(x*18.0+t*0.023)*3.0+t*0.035)
    +0.13*sin(x*143.0-t*0.047);
  float edges=smoothstep(0.0,0.12,x)*(1.0-smoothstep(0.88,1.0,x));
  // Broad luminous packets travel along the folds; no global flashing.
  float packet=pow(0.5+0.5*sin(x*10.0-t*0.045+0.6*sin(x*4.0+t*0.009)),4.0);
  float shimmer=0.78+0.32*packet;
  float a=base*folds*edges*(1.0-smoothstep(0.7,1.0,y))*opacity
    *mix(0.48,0.25,layer)*shimmer;
  // A soft, moving rift separates and reconnects folds without blinking.
  float rift=0.48+0.12*sin(flourish.w*0.035+layer*1.7);
  a*=1.0-flourish.z*(1.0-smoothstep(0.012,0.065,abs(x-rift)));
  // Green dominates the lower edge; teal, violet and rose drift through
  // different folds over minutes. No synchronized rainbow or pulsing flash.
  float hue=0.5+0.5*sin(t*0.017+x*5.0+0.6*sin(t*0.009+x*13.0));
  vec3 low=mix(vec3(0.13,0.94,0.40),vec3(0.12,0.78,0.81),hue*0.70);
  vec3 high=mix(vec3(0.40,0.30,0.88),vec3(0.82,0.27,0.58),
    (0.5+0.5*sin(t*0.012-x*6.0))*0.35);
  vec3 tint=mix(low,high,smoothstep(0.10,0.48+0.06*sin(t*0.014+x*4.0),above));
  tint=mix(tint,vec3(0.40,1.0,0.68),packet*0.20*(1.0-smoothstep(0.05,0.35,above)));
  float fringe=smoothstep(0.14,0.37,above)*(0.65+0.35*packet);
  tint=mix(tint,vec3(0.96,0.30,0.66),flourish.y*fringe*0.75);
  return vec4(tint,a);
}
#endif
]]
function Aurora.vertices()
  local verts={}
  local function point(u,v)
    local az=(u-0.5)*2.3
    local el=0.12+v*0.95
    local r=1
    return {r*math.cos(el)*math.sin(az),r*math.sin(el),-r*math.cos(el)*math.cos(az),u,v}
  end
  -- Four rows soften vertical folds. Shared static mesh: 1536 vertices,
  -- two draws, no per-frame mesh rebuild, textures or extra render targets.
  for row=0,3 do for col=0,63 do
    local a,b,c,d=point(col/64,row/4),point((col+1)/64,row/4),
      point((col+1)/64,(row+1)/4),point(col/64,(row+1)/4)
    for _,p in ipairs({a,b,c,a,c,d}) do verts[#verts+1]=p end
  end end
  return verts
end
function Aurora.drawWorld(voxel)
  local events=V.require('QuestSkyEvents')
  local night,outdoor,north=events.context()
  if not (night and outdoor) or events.alpha<=0 then return false end
  local g=love.graphics
  shader=shader or g.newShader(Aurora.SHADER)
  mesh=mesh or g.newMesh(FORMAT,Aurora.vertices(),'triangles','static')
  g.push('all')
  local ok,err=pcall(function()
    g.setShader(shader)
    shader:send('vp','row',voxel.vp)
    shader:send('eye',voxel.eye)
    local far=voxel.far or (voxel.camera and voxel.camera.far) or 500
    shader:send('clock',events.clock)
    shader:send('bearing',events.bearing and events.bearing() or 0)
    shader:send('opacity',events.alpha)
    local crown,pink,split,time=0,0,0,events.clock
    if events.flourish then crown,pink,split,time=events.flourish() end
    shader:send('flourish',{crown,pink,split,time})
    g.setDepthMode('lequal',false)
    g.setBlendMode('alpha','alphamultiply')
    g.setMeshCullMode('none')
    g.setColor(1,1,1,1)
    -- Back-to-front alpha compositing, both anchored to the event bearing.
    for layer=1,0,-1 do
      shader:send('layer',layer)
      shader:send('radius',far*(0.90+0.01*layer))
      g.draw(mesh)
    end
  end)
  g.pop()
  if not ok then error(err) end
  return true
end
return Aurora
