-- Visual lunar phases use the existing saved natural-day counter (30 days).
local V=...
local M={}
local preview=0
local previews={7.5,15,22.5,27,0}
local labels={'WAXING','FULL','WANING','CRESCENT','NEW'}
function M.previewStatus()return labels[preview]or 'NATURAL'end
function M.previewNext()preview=(preview+1)%6;return true end
if V.mod and V.mod.events then
  V.mod.events:on('save.loaded',function()preview=0 end)
  V.mod.events:on('save.created',function()preview=0 end)
end
function M.phase(day)return ((tonumber(day)or 0)%30)/30 end
function M.light(day)
  local a=M.phase(day)*math.pi*2
  return {math.sin(a),0,-math.cos(a)}
end
function M.current()
  return M.light(previews[preview] or V.require('NightSky').meteorStatus().day or 0)
end
-- One small cached albedo texture; craters/maria are baked, never per frame.
function M.imageData(api)
  local size=192;local data=api.newImageData(size,size)
  local craters={};local seed=79473
  local function random()seed=seed*48271%2147483647;return seed/2147483647 end
  local function noise(x,y)
    local ix,iy=math.floor(x),math.floor(y);local u,v=x-ix,y-iy
    u=u*u*(3-2*u);v=v*v*(3-2*v)
    local function h(a,b)return (math.sin(a*127.1+b*311.7)*43758.5453)%1 end
    local a,b,c,d=h(ix,iy),h(ix+1,iy),h(ix,iy+1),h(ix+1,iy+1)
    return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v
  end
  for i=1,64 do
    local a=random()*math.pi*2;local r=.96*math.sqrt(random())
    craters[i]={math.cos(a)*r,math.sin(a)*r,.010+.065*random()^2,.7+.6*random()}
  end
  for py=0,size-1 do for px=0,size-1 do
    local x=(px+.5)/size*2-1;local y=(py+.5)/size*2-1;local rr=x*x+y*y
    if rr<1 then
      local nx=x+.12*(noise(x*7+10,y*7+10)-.5)
      local ny=y+.16*(noise(x*9+30,y*9+30)-.5)
      local maria=.24*math.exp(-((nx+.30)^2/.12+(ny+.12)^2/.28))
        +.19*math.exp(-((nx-.29)^2/.16+(ny-.15)^2/.10))
        +.14*math.exp(-((nx-.1)^2/.09+(ny+.5)^2/.035))
      local shade=.85-maria+.05*(noise(x*12+20,y*12+20)-.5)
        +.035*(noise(x*45+20,y*45+20)-.5)
      for _,c in ipairs(craters)do
        local dx,dy=x-c[1],y-c[2];local d=math.sqrt(dx*dx+dy*dy*c[4])/c[3]
        if d<1.3 then shade=shade-.10*math.exp(-d*d*3)+.055*math.exp(-((d-.95)/.18)^2)*(1-dy/c[3]*.7)end
      end
      local edge=math.min(1,(1-math.sqrt(rr))*size/2)
      shade=math.max(0,math.min(1,shade))
      data:setPixel(px,py,shade*.96,shade*.98,shade,edge)
    end
  end end
  return data
end
return M
