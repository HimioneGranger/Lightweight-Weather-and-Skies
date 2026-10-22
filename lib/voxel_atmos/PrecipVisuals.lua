-- Shared Quest particle finish (Gen1/2/3). Existing quads and particle counts.
-- No textures, extra attributes, per-particle tables, or additional draws.
local M={}
local uv={0,0, 1,0, 1,1, 0,0, 1,1, 0,1}
-- Write final packed rain attributes once, instead of writing a tint then
-- revisiting all six rows to replace it with UV/tag data. Reuses reserved rows.
function M.pushRain(buf,x,y,z,a,u,v,tag)
  local n=buf.n+1;buf.n=n
  local row=buf.v[n]
  if not row then row={};buf.v[n]=row;buf.cap=n end
  row[1],row[2],row[3],row[4],row[5],row[6],row[7]=x,y,z,u,v,tag,a
end
function M.tagRain(buf,variant)
  for j=1,6 do
    local row=buf.v[buf.n-6+j]
    row[4],row[5],row[6]=uv[j*2-1],uv[j*2],-1-(variant or 0)
  end
end

local rainShader=[[
#ifdef VERTEX
  extern mat4 vp;
  attribute vec4 RainTint;
  varying vec4 vDrop;
  vec4 position(mat4 t, vec4 v) {
    vDrop=RainTint;
    return vp * vec4(v.xyz,1.0);
  }
#endif
#ifdef PIXEL
  varying vec4 vDrop;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Wet ground marks share this shader but retain their original tint/tag.
    if(vDrop.b>=0.0) return vec4(0.72,0.82,0.95,vDrop.a)*color;
    float y=vDrop.g, x=abs(vDrop.r*2.0-1.0);
    // Exposure streak, not a literal teardrop. Stable seeded brightness family.
    float variant=clamp(-vDrop.b-1.0,0.0,2.0);
    float width=0.62+variant*0.09;
    float edge=1.0-smoothstep(width*0.35,width,x);
    float ends=smoothstep(0.0,0.12,y)*(1.0-smoothstep(0.88,1.0,y));
    float highlight=0.80+0.20*cos(y*(6.2831853+variant*3.14159265)+variant);
    float core=1.0-smoothstep(0.0,width*0.48,x);
    vec3 rgb=mix(vec3(0.50,0.65,0.78),vec3(0.79,0.89,0.97),core);
    return vec4(rgb,min(1.0,vDrop.a*edge*ends*highlight*1.6))*color;
  }
#endif
]]
local sandBranch=[[
    if(vLeaf.z < -0.5) {
      // Fine suspended dust stays soft; sand is a compact mineral fleck.
      vec2 p=vLeaf.xy*2.0-1.0;
      p.x=(p.x+0.22*p.y)*1.12;
      p.y*=1.08;
      float d=dot(p,p);
      float edge;
      float opacity=1.0;
      if(vLeaf.z < -1.5) {
        edge=1.0-smoothstep(0.02,0.96,d);
        edge*=edge;
        opacity=0.45;
      } else {
        float shape=max(abs(p.x)*0.92+abs(p.y)*0.50,abs(p.y)*1.12);
        edge=1.0-smoothstep(0.55,0.83,shape);
      }
      float shade=0.86+0.14*(1.0-clamp(d,0.0,1.0));
      return vec4(vCol.rgb*shade,min(1.0,vCol.a*edge*opacity*1.7))*color;
    }
]]
function M.shader(source)
  if source:find('attribute vec3 LeafData;',1,true) then
    local marker='    if (vLeaf.z < 0.5)'
    local at=assert(source:find(marker,1,true),'grain shader seam changed')
    return source:sub(1,at-1)..sandBranch..source:sub(at)
  end
  return rainShader
end
return M
