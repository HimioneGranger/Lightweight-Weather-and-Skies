-- Narrow Gen 3 precipitation view. Caller applies the private Quest descriptor.
-- Dynamic and storm-front blending remain owned by the cinematic provider.
local profile, frontProfile, level, dayNight, weatherId = ...
local weather = {}
local frame = {weather=weather}
return function(map, outdoor)
  if level() <= 0 or not (outdoor or dayNight.isCanopy(map)) then return nil end
  local source = frontProfile(profile())
  for key in pairs(weather) do weather[key] = nil end
  for key, value in pairs(source) do weather[key] = value end
  -- This cinematic fallback precedes the Quest descriptor rainWind override.
  weather.snowWind = weather.snowWind or weather.rainWind or 1
  local id = weatherId and weatherId() or ''
  if id == 'BLIZZARD' or id == 'THUNDERSNOW' then
    weather.snowWind = math.max(tonumber(weather.snowWind) or 0, 1.35)
  elseif id == 'SNOW_LIGHT' or id == 'SNOW' then
    weather.snowWind = math.max(tonumber(weather.snowWind) or 0, .65)
  end
  frame.weather = weather
  return frame
end