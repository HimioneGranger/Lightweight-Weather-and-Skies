-- Select the existing per-eye renderer only with a verified standalone bridge.
local Q={}
function Q.new(mod,owner)
  local host=mod.find(owner)
  local compat=mod.find('BATTLE_ART_QUEST_COMPAT')
  local h=host and host.exports
  local c=compat and compat.exports
  local ready=h and h.lib and type(h.lib.require)=='function'
    and c and type(c.questVrInput)=='table' and h.questVrInput==c.questVrInput
  mod.exports.ownedWeatherAdapter=false
  return {ready=ready==true,reason=ready and 'standalone-renderer-selected' or 'standalone-bridge-unavailable'}
end
return Q
