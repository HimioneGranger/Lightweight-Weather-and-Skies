-- Continuous underside illumination on the existing 1200-second sky dial.
-- Multipliers complement (not replace) dayTint, keeping night genuinely dark.
local L={}
local keys={
  {0,1.18,.91,.78}, {60,1.10,.97,.88}, {150,1,1,1},
  {450,1,1,1}, {510,1.13,.94,.83}, {600,1.20,.85,.80},
  {690,.86,.95,1.12}, {1050,.86,.95,1.12}, {1200,1.18,.91,.78},
}
function L.sample(t,out)
  out=out or {};t=(tonumber(t)or 300)%1200
  for i=1,#keys-1 do
    local a,b=keys[i],keys[i+1]
    if t<=b[1] then
      local u=(t-a[1])/(b[1]-a[1]);u=u*u*(3-2*u)
      for k=1,3 do out[k]=a[k+1]+(b[k+1]-a[k+1])*u end
      return out
    end
  end
end
return L
