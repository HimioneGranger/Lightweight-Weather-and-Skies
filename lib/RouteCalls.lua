-- Preparation only: supply the active time-filtered LAND encounter group.
local M = {}
function M.pool(pokemon, group)
  local allowed, parents = {}, {}
  local function valid(id)
    local p=pokemon[id]
    return p and type(p.dex)=='number' and p.dex>=1 and p.dex<=252
  end
  for id,p in pairs(pokemon) do
    if valid(id) then
      for _,e in ipairs(p.evolutions or {}) do
        if valid(e.species) then
          parents[e.species]=parents[e.species] or {}
          table.insert(parents[e.species],id)
        end
      end
    end
  end
  local function add(id)
    if not valid(id) or allowed[id] then return end
    allowed[id]=true
    for _,parent in ipairs(parents[id] or {}) do add(parent) end
  end
  if group and type(group.rate)=='number' and group.rate>0 then
    for _,slot in ipairs(group.slots or {}) do add(slot.species) end
  end
  local out={}
  for id in pairs(allowed) do out[#out+1]=id end
  table.sort(out)
  return out
end
function M.choose(pool,previous,rng)
  if #pool==0 then return nil end
  if #pool==1 then return pool[1] end
  local choices={}
  for _,id in ipairs(pool) do
    if id~=previous then choices[#choices+1]=id end
  end
  return choices[rng(#choices)]
end
return M
