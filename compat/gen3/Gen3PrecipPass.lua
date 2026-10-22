-- Gen 3 precipitation pass. Only DramalessAtmos's generation-3 seam loads this.
-- Keep the shared Gen 1/2 path unchanged; sample the existing cinematic profile
-- once per update, then prepare the private weather descriptor/focus in place.
local V, Atmos, descriptors = ...
local Pass = {}
local scratchWeather, focus, defaultEye = {}, {0,0,0}, {0,32,0}
local frame, cachedSerial, cachedMap, cachedOutdoor, cachedId, cachedCin, cachedWP, cachedHostLib
local stats = {frames=0, profiles=0, updates=0, draws=0}
Pass.stats = stats

local function syncNight()
  local TOD = V.require('TimeOfDay')
  local night = TOD and TOD.isNight and TOD.isNight() or false
  package.loaded._WX_NIGHT = night and true or false
  if rawget(_G, 'V') then V._WX_NIGHT = night and true or false end
end

-- Mirrors the private Quest descriptor contract, using a stable scratch table.
-- Copy inherited profile fields before applying descriptors, so snow heights,
-- speed fallbacks, and source profile extensions retain their existing meaning.
local function applyWeather(rawFrame, id, ownedView)
  local weather = rawFrame.weather
  -- The focused accessor owns and refreshes this stable table each update.
  -- Mutate that view directly; the full cinematic fallback still needs an
  -- isolated scratch copy to protect its potentially shared preset profile.
  if not ownedView then
    local source = weather
    weather = scratchWeather
    for key in pairs(weather) do weather[key] = nil end
    if source then
      for key, value in pairs(source) do weather[key] = value end
    end
  end
  weather.rainIntensity, weather.snowIntensity = 0, 0
  weather.sandIntensity, weather.ashIntensity, weather.debrisIntensity = 0, 0, 0
  weather.snowCover = 0
  weather.windX, weather.windZ = nil, nil
  weather.wxId = id
  for key, value in pairs(descriptors[id] or descriptors.CLEAR) do weather[key] = value end
  if id == 'PARTLY_SNOW' then
    local state = V.require('WeatherState')
    weather.snowIntensity = math.min(.18, math.max(0, state.channel('snow') or 0))
  end
  if id == 'STORM' then
    local state = V.require('WeatherState')
    if state.channel then
      weather.rainIntensity = weather.rainIntensity * math.max(0, math.min(1, state.channel('rain') or 0))
      weather.rainWind = .35 + 1.4 * math.max(0, math.min(1, state.channel('gust') or 0))
    end
    local storm = V.require('QuestStorm')
    local buildup = 1 - math.max(0, math.min(1, storm.strength or 0))
    weather.debrisIntensity = .32 * buildup
    local front = V.require('QuestStormFront')
    if front.managed then
      weather.rainIntensity = weather.rainIntensity * math.max(0, math.min(1, front.coverage or 0))
      weather.debrisIntensity = math.max(weather.debrisIntensity * front.coverage, .45 * (front.warning or 0))
      weather.windX, weather.windZ = front.windX, front.windZ
    end
  end
  local recovery = V.require('QuestAfterStorm')
  if recovery.rain and recovery.rain > 0 then
    weather.rainIntensity = math.max(weather.rainIntensity, recovery.rain)
    weather.rainSpeed = weather.rainSpeed or .82
    weather.rainWind = weather.rainWind or .65
  end
  rawFrame.weather, rawFrame.wxId = weather, id
  stats.profiles = stats.profiles + 1
  return rawFrame
end

function Pass.draw(Voxel3D, cin, map, outdoor)
  local WP = Atmos._worldPrecip
  if not WP and Atmos._ns then
    WP = Atmos._ns.require('WorldPrecip')
    Atmos._worldPrecip = WP
  end
  if not (WP and WP.update and WP.draw) then return end
  local serial = Atmos._updateSerial or 0
  local id = tostring(Atmos._wxId or 'CLEAR'):upper()
  local changedDescriptor = cachedId ~= id or cachedOutdoor ~= outdoor or cachedCin ~= cin
  local changedWP = cachedWP ~= WP
  local changedMap = Atmos._precipSurfaceMap ~= map
  local changedSurface = changedMap or cachedHostLib ~= Atmos._hostLib
  local changed = cachedSerial ~= serial or cachedMap ~= map or cachedOutdoor ~= outdoor
    or cachedId ~= id or cachedCin ~= cin or cachedWP ~= WP or changedSurface
    or (Atmos._lastPrecipSerial == nil and frame ~= nil)
  if changed then
    local getFrame = cin.gen3PrecipFrame or cin.frame
    local rawFrame = getFrame and getFrame(map, outdoor) or nil
    stats.frames = stats.frames + 1
    pcall(syncNight)
    frame = rawFrame and applyWeather(rawFrame, id, cin.gen3PrecipFrame ~= nil) or nil
    cachedSerial, cachedMap, cachedOutdoor, cachedId = serial, map, outdoor, id
    cachedCin, cachedWP, cachedHostLib = cin, WP, Atmos._hostLib
  end
  if not frame then return end
  if changedSurface then
    if Atmos._precipSurfaceMap and WP.invalidate then WP.invalidate() end
    local shapeAPI = Atmos._hostLib.require('TileShape')
    Atmos._precipSurface = V.require('QuestRainSurface').sampler(map, shapeAPI)
    Atmos._precipSurfaceMap = map
    -- A map transition can occur without a new update serial. Re-seed that
    -- map's sim immediately instead of drawing the just-invalidated pool.
    Atmos._lastPrecipSerial = nil
  end
  frame.weather.surfaceAt = Atmos._precipSurface
  if Atmos._lastPrecipSerial ~= serial or changedWP or changedDescriptor then
    local eye = Voxel3D.eye or Voxel3D.player or defaultEye
    focus[1], focus[2], focus[3] = eye[1], 0, eye[3]
    local dt = Atmos._lastPrecipSerial == serial and not changedWP and not changedSurface and 0 or (Atmos._updateDelta or 0)
    WP.update(dt, focus, frame.weather)
    Atmos._lastPrecipSerial = serial
    stats.updates = stats.updates + 1
  end
  WP.draw(Voxel3D, frame)
  stats.draws = stats.draws + 1
  Atmos._lastQuestFrame = id
end
return Pass