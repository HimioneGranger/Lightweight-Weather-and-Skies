-- Optional desktop policy; absent providers leave shared rendering unchanged.
local V = ...
local P = {}
function P.current()
  if not (love and love.system and love.system.getOS) then return nil end
  if love.system.getOS() ~= 'Windows' then return nil end
  if not (V.mod and V.mod.find) then return nil end
  local ok, compat = pcall(V.mod.find, 'BATTLE_ART_QUEST_COMPAT')
  local profile = ok and compat and compat.exports and compat.exports.desktopWeatherProfile
  if type(profile) == 'table' and profile.api == 1 then return profile end
end
function P.value(profile, key, fallback, ceiling)
  local n = profile and tonumber(profile[key])
  if not n or n ~= n or n < 0 then return fallback end
  return math.min(n, ceiling)
end
return P
