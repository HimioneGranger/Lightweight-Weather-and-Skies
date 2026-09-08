-- A regional conjunction, not an entry-time dice roll. AUTO and night only.
local V=...
local M={active=false}
function M.eligible(map)
  local id=tostring(map or ''):upper():gsub('[^A-Z0-9]','')
  return id=='PEWTERCITY' or id=='ROUTE3' or id=='ROUTE4' or id=='MTMOON'
end
function M.update(day,aurora)
  local scene=V.require('Scene').now or {}
  local state=V.require('WeatherState')
  local regional=V.require('QuestRegional')
  M.active=aurora and scene.outdoor and not scene.indoors and M.eligible(scene.mapId)
    and regional.enabled() and state.LEVEL_IDS[state.level+1]=='AUTO' or false
end
function M.target(map,indoors)
  if M.active and not indoors and M.eligible(map)then return 'PARTLY_SNOW'end
end
return M
