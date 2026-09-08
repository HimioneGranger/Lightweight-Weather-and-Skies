-- The World 5.18.2: generic overworld Pokemon sprite-provider registry.
-- Packs register original/licensed art at runtime; The World never requires
-- players to replace core assets. Higher priority wins. WX forms fall back to
-- their base species so the existing WX recolour pipeline can tint them.
local P={providers={}}
local function norm(s) return type(s)=='string' and s:upper() or s end
local function baseSpecies(s)
  if type(s)~='string' then return s end
  local b=s:match('^WX_%d+_(%w+)_')
  return b or s
end
local function sortp() table.sort(P.providers,function(a,b) return (a.priority or 0)>(b.priority or 0) end) end
function P.register(id,provider,priority)
  if type(id)~='string' or type(provider)~='table' or type(provider.resolve)~='function' then return false,'id and provider.resolve required' end
  P.unregister(id); provider.id=id; provider.priority=tonumber(priority or provider.priority) or 0
  P.providers[#P.providers+1]=provider; sortp(); return true
end
function P.unregister(id) for i=#P.providers,1,-1 do if P.providers[i].id==id then table.remove(P.providers,i); return true end end return false end
function P.resolve(species,game,context)
  local original=norm(species); local base=norm(baseSpecies(species))
  for _,p in ipairs(P.providers) do
    local ok,res=pcall(p.resolve,p,original,game,context or {})
    if ok and type(res)=='table' and res.image then return res,p.id,false end
    if base~=original then
      ok,res=pcall(p.resolve,p,base,game,context or {})
      if ok and type(res)=='table' and res.image then return res,p.id,true end
    end
  end
  return nil
end
function P.list() local out={} for _,p in ipairs(P.providers) do out[#out+1]={id=p.id,priority=p.priority or 0} end return out end
return P
