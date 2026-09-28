local M={}
local FORMAT={{'VertexPosition','float',3},{'VertexTexCoord','float',2}}
local SHADER=[[
#ifdef VERTEX
uniform mat4 vp;
uniform vec3 eye;
vec4 position(mat4 t,vec4 v){return vp*vec4(v.xyz+eye,1.0);}
#endif
#ifdef PIXEL
uniform bool isMoon;
uniform vec3 moonLight;
vec4 effect(vec4 color,Image tex,vec2 tc,vec2 sc){
 vec4 c=Texel(tex,tc)*color;if(c.a<0.01)discard;
 if(isMoon){
  vec2 p=tc*2.0-1.0;
  vec3 n=vec3(p.x,-p.y,sqrt(max(0.0,1.0-dot(p,p))));
  float lit=smoothstep(-0.035,0.08,dot(n,moonLight));
  float face=max(0.0,dot(n,moonLight));
  // The same earthshine and terminator at every phase. Let sky show through
  // the unlit face instead of stamping an opaque black disc over it.
  float earthshine=0.30*(0.55+0.45*n.z);
  c.rgb*=mix(vec3(0.12,0.15,0.21),vec3(0.65+0.35*sqrt(face)),lit);
  c.a*=mix(earthshine,1.0,lit);
 }
 return c;
}
#endif
]]
local function must(v,e)assert(v,e);return v end
-- Run only the original texture baker with a local newImage recorder. This
-- changes no global love table, artwork pixels, active canvas or other mod.
function M.baker(source,realLove,world)
  local proxy={image=realLove.image,graphics={newImage=function(data)
    return {data=data,setFilter=function()end,setWrap=function()end}
  end}}
  local chunk=assert((loadstring or load)("local _, love = ...;\n"..source,'@weather/disc-baker'))
  return chunk(world,proxy)
end
function M.new(api,disc)
  local self={images={},meshes={},closed=false}
  function self:draw(bodies,radius,moonLight)
    assert(not self.closed,'celestial resources released')
    self.material=self.material or must(api:material{source=SHADER,skyDepth=true,uniforms={isMoon=false,moonLight={0,0,1}}})
    local count=0
    for _,body in ipairs({bodies.sun,bodies.moon})do
      if body and (body.alpha or 0)>.02 then
        local key=body.kind=='moon' and 'moon'or 'sun'
        if not self.images[key]then
          local data=disc.image(key=='moon').data
          self.images[key]=must(api:image{width=data:getWidth(),height=data:getHeight(),rgba=data:getString(),wrap='clamp'})
        end
        local right,up=disc.axes(body)
        local half=(key=='moon' and 14 or 22)*(1+.35*math.max(0,math.min(1,body.dy or 0)))
        -- Keep both bodies' angular sizes stable as desktop terrain range
        -- changes; retain sky-layer distance for terrain/cloud occlusion.
        half=half*radius/420
        local function vertex(x,y,u,v)return {body.dx*radius+half*(right[1]*x+up[1]*y),
          body.dy*radius+half*(right[2]*x+up[2]*y),body.dz*radius+half*(right[3]*x+up[3]*y),u,v}end
        local a,b,c,d=vertex(-1,1,0,0),vertex(1,1,1,0),vertex(1,-1,1,1),vertex(-1,-1,0,1)
        local vertices={a,b,c,a,c,d}
        if self.meshes[key]then must(api:updateMesh(self.meshes[key],vertices))
        else self.meshes[key]=must(api:mesh{format=FORMAT,vertices=vertices})end
        must(api:enqueue{phase='celestial_before_clouds',material=self.material,mesh=self.meshes[key],image=self.images[key],tint={1,1,1,body.alpha},uniforms={isMoon=key=='moon',moonLight=moonLight or {0,0,1}}})
        count=count+1
      end
    end
    return count>0
  end
  function self:release()
    if self.closed then return end;self.closed=true
    for _,group in ipairs({self.images,self.meshes})do for _,token in pairs(group)do pcall(api.release,api,token)end end
    if self.material then pcall(api.release,api,self.material)end
  end
  return self
end
return M
