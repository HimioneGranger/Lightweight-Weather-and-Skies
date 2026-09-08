-- At most two streaming voices total, including crossfades. No long static PCM.
local B={};B.__index=B
function B.new(load,rng) return setmetatable({load=load,rng=rng,voices={},last={},gap=0,gains={birds=0,insects=0}},B)end
local function stop(s)pcall(function()s:stop();if s.release then s:release()end end)end
function B:reset()for _,v in ipairs(self.voices)do stop(v.src)end;self.voices={};self.gap=0 end
function B:update(dt,targets,volume)
  for k,t in pairs(targets)do local g=self.gains[k];self.gains[k]=g+(t-g)*(1-math.exp(-dt/(t<g and 4 or 12)))end
  self.gap=math.max(0,self.gap-dt)
  for i=#self.voices,1,-1 do
    local v=self.voices[i];v.age=v.age+dt
    local fade=math.max(0,math.min(1,v.age/6,(v.length-v.age)/8))
    local ok=pcall(function()v.src:setVolume(fade*self.gains[v.kind]*volume)end)
    if not ok or v.age>=v.length then stop(v.src);table.remove(self.voices,i)end
  end
  local latest=self.voices[#self.voices]
  if #self.voices>=2 or self.gap>0 or (latest and latest.age<latest.length-8)then return end
  local sum=targets.birds+targets.insects;if sum<.002 or volume<=0 then return end
  local kind=self.rng(10000)/10000<targets.birds/sum and 'birds'or 'insects'
  local index=self.rng(3);local previous=self.last[kind]
  if previous and index>=previous then index=index+1 end
  if not previous then index=self.rng(4)end
  local src=self.load('assets/sounds/nature/'..kind..'-long-'..index..'.ogg','stream')
  if not src then self.gap=30;return end
  local length=55+self.rng(24)
  local ok=pcall(function()src:setLooping(false);src:seek(self.rng(10)-1,'seconds');src:setVolume(0);src:play()end)
  if not ok then stop(src);self.gap=30;return end
  self.last[kind]=index
  self.voices[#self.voices+1]={src=src,kind=kind,age=0,length=length}
  -- Occasionally let the segment finish and breathe before the next recording.
  if self.rng(4)==1 then self.gap=length+3+self.rng(9)end
end
return B
