-- DramalessAtmos
--
-- Full Kanto-style atmosphere (clouds, light shafts, rain, fog, motes,
-- puddles, distant horizon) running inside Weather FX only.
-- Multi-host 3D atmosphere bridge. First-class hosts (all must keep working):
--   DRAMATIC_SHAPE, DRAMALESS_SHAPE, potato_voxel / POTATO_VOXEL, STADIUM2_OVERWORLD_MODELS
-- (Gen2-3D-Sprites). Other mods are never edited on disk;
-- we only read their exports.lib and wrap Voxel3D.endScene in memory.
--
-- Missing Dramatic Shape modules are supplied as stubs under
-- lib/voxel_atmos/stubs/. Features that need host data (e.g. sprite
-- reflections in puddles) degrade gracefully.

local V = ...
local mod = V.mod

local Atmos = {
  _ready = false,
  _active = false,
  _drawing = false,
  _reason = "not-initialised",
  _hostId = nil,
  _Voxel3D = nil,
  _origEndScene = nil,
  _cin = nil,
  _worldPrecip = nil,
  _distant = nil,
  _horizon = nil,
  _forest = nil,
  _lastMap = nil,
  _lastOutdoor = true,
  _lastNeighbors = nil,
  _lastPosed = nil,
}

-- These are deliberately distinct instead of mapping every rain id to the
-- same stock profile. The caps live in WorldPrecip; these values control the
-- visible density, fall speed, and wind within that fixed Quest budget.
local QUEST_WEATHER = {
  CLEAR = {},
  RAIN_LIGHT = { rainIntensity = 0.42, rainSpeed = 0.82, rainWind = 0.55 },
  RAIN_HEAVY = { rainIntensity = 0.96, rainSpeed = 1.00, rainWind = 1.00 },
  HEAVY_RAIN = { rainIntensity = 1.38, rainSpeed = 1.22, rainWind = 1.48 },
  STORM = { rainIntensity = 1.12, rainSpeed = 1.12, rainWind = 1.55 },
  SNOW_LIGHT = { snowIntensity = 0.65, snowSpeed = 0.55, snowWind = 0.65 },
  PARTLY_SNOW = { snowIntensity = 0.18, snowSpeed = 0.45, snowWind = 0.30 },
  STRONG_WINDS = { debrisIntensity = 0.55, rainWind = 1.75 },
  GALE = { debrisIntensity = 1.15, rainWind = 2.60 },
  ASHFALL = { ashIntensity = 0.80, rainWind = 0.70 },
}

local function questWeatherFrame(frame, id)
  local source = frame and frame.weather or {}
  local weather = {}
  for key, value in pairs(source) do weather[key] = value end
  weather.rainIntensity = 0
  weather.snowIntensity = 0
  weather.sandIntensity = 0
  weather.ashIntensity = 0
  weather.debrisIntensity = 0
  weather.snowCover = 0
  weather.windX,weather.windZ=nil,nil
  weather.wxId = id
  for key, value in pairs(QUEST_WEATHER[id] or QUEST_WEATHER.CLEAR) do
    weather[key] = value
  end
  frame.weather = weather
  if id=='PARTLY_SNOW' then
    local state=V.require('WeatherState')
    weather.snowIntensity=math.min(.18,math.max(0,state.channel('snow')or 0))
  end
  if id=='STORM' then
    local state=V.require('WeatherState')
    if state.channel then
      weather.rainIntensity=weather.rainIntensity*math.max(0,math.min(1,state.channel('rain') or 0))
      weather.rainWind=.35+1.4*math.max(0,math.min(1,state.channel('gust') or 0))
    end
    -- Reuse the wind-mode leaf pool during storm onset. No moving trees.
    local storm=V.require('QuestStorm')
    local buildup=1-math.max(0,math.min(1,storm.strength or 0))
    weather.debrisIntensity=0.32*buildup
    local front=V.require('QuestStormFront')
    if front.managed then
      weather.debrisIntensity=math.max(weather.debrisIntensity*front.coverage,
        .45*(front.warning or 0))
      weather.windX,weather.windZ=front.windX,front.windZ
    end
  end
  frame.wxId = id
  local recovery=V.require('QuestAfterStorm')
  if recovery.rain and recovery.rain>0 then
    weather.rainIntensity=math.max(weather.rainIntensity,recovery.rain)
    weather.rainSpeed=weather.rainSpeed or .82
    weather.rainWind=weather.rainWind or .65
  end
  return frame
end

local HOSTS = {
  "BATTLE_ART_VOXEL_FORK", "DRAMATIC_SHAPE", "DRAMALESS_SHAPE",
  "potato_voxel", "POTATO_VOXEL", "PotatoVoxel",
  -- Dramatic Shape and its Dramaless fork expose the same exports.lib contract.
  -- Gold/Silver Stadium 2 overworld (Gen2-3D-Sprites) follows that contract too.
  -- convention as Dramaless; host-specific only via mod.find id.
  "STADIUM2_OVERWORLD_MODELS",
}

local WX_TO_KANTO = {
  -- Clear / sun family
  CLEAR = "clear", SUNNY = "clear", HEATWAVE = "clear", HARSH_SUN = "clear",
  -- Rain / storm → closed deck + 3D rain (2D rain suppressed when 3D draws it)
  RAIN_LIGHT = "rain", RAIN_HEAVY = "rain", HEAVY_RAIN = "rain",
  VERDANT_RAIN = "rain", SLEET = "rain",
  STORM = "thunderstorm", DRAGONSTORM = "thunderstorm",
  -- Cold precip: dense overcast 3D clouds/fog; 2D keeps snow/hail particles
  SNOW_LIGHT = "snow", SNOW = "snow", SNOW_HEAVY = "blizzard",
  BLIZZARD = "blizzard", HAIL = "snow", THUNDERSNOW = "blizzard",
  -- Dust / ash / wind: broken cloud + fog volumes; 2D keeps sand/ash grains
  SANDSTORM = "overcast", DUSTSTORM = "overcast", ASHFALL = "overcast",
  STRONG_WINDS = "mostly", GALE = "gale", BRAWL_WIND = "mostly",
  FLOCKSTORM = "mostly",
  -- Fog / mist: high fog volumes in 3D; 2D fog layers still allowed
  FOG = "overcast", MIST = "cloudy", HAUNTED_MIST = "cloudy", SMOG = "cloudy",
  -- Typed fronts / oddities
  PLAIN_FRONT = "partly", SWARM = "partly", PSYSTORM = "thunderstorm",
}

local function findHost()
  if mod.exports.activeWeatherHost then return mod.exports.activeWeatherHost() end
  if not (mod and mod.find) then return nil, nil end
  for i = 1, #HOSTS do
    local ok, host = pcall(mod.find, mod, HOSTS[i])
    if ok and host then return host, HOSTS[i] end
  end
  return nil, nil
end


local function attachNightSkyHost(NightSky)
  if not (NightSky and Atmos._hostLib) then return end
  local hostLib = Atmos._hostLib
  pcall(function()
    -- The private Quest build uses Weather FX's 12-minute clock as the only
    -- celestial authority. Battle Art's independent DayNight module can be in
    -- a different phase and would otherwise turn stars on during our daytime.
    if V.questLitePrivate then
      NightSky._DayNight = nil
    else
      -- Always refresh DayNight so Dramaless night is seen by NightSky every frame.
      local ok, DN = pcall(hostLib.require, "DayNight")
      if ok and DN then NightSky._DayNight = DN end
    end
    if not NightSky._FirstPerson then
      local ok2, FP = pcall(hostLib.require, "FirstPerson")
      if ok2 then NightSky._FirstPerson = FP end
    end
    if not NightSky._Voxel then
      local ok3, Voxel = pcall(hostLib.require, "Voxel")
      if not ok3 or not Voxel then
        ok3, Voxel = pcall(hostLib.require, "VoxelState")
      end
      if ok3 and Voxel then NightSky._Voxel = Voxel end
    end
    pcall(function()
      local TOD = V.require("TimeOfDay")
      if TOD then NightSky._TOD = TOD end
    end)
  end)
end

local function want3d()
  local ok, Settings = pcall(V.require, "Settings")
  if ok and Settings then
    -- First-person: always 3D weather (overrides WX PRESENT = 2D).
    if Settings.isFirstPerson and Settings.isFirstPerson() then return true end
    if Settings.force2dPresent and Settings.force2dPresent() then return false end
    if Settings.allow3dPresent and not Settings.allow3dPresent() then return false end
  end
  return true
end

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then error("missing " .. rel, 0) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then error(rel .. " compile: " .. tostring(err), 0) end
  return chunk
end

-- Build a require namespace: host modules first, then Weather FX voxel_atmos
-- and stubs. Never writes into the host mod.
local function buildNamespace(hostLib)
  local own = {}
  local W = { path = mod.path, mod = mod,
    questLitePrivate = V.questLitePrivate == true }

  local STUBS = {
    ForestAtmos = "lib/voxel_atmos/stubs/ForestAtmos.lua",
    Mat4 = "lib/voxel_atmos/stubs/Mat4.lua",
    TileShape = "lib/voxel_atmos/stubs/TileShape.lua",
    SpriteBillboards = "lib/voxel_atmos/stubs/SpriteBillboards.lua",
    TerrainAtlas = "lib/voxel_atmos/stubs/TerrainAtlas.lua",
  }

  local OWN = {
    CinematicAtmos = "lib/voxel_atmos/CinematicAtmos.lua",
    WorldPrecip = "lib/voxel_atmos/WorldPrecip.lua",
    DistantWorld = "lib/voxel_atmos/DistantWorld.lua",
    HorizonApron = "lib/voxel_atmos/HorizonApron.lua",
    WeatherSetting = "lib/voxel_atmos/WeatherSetting.lua",
  }

  function W.require(name)
    if own[name] ~= nil then
      if own[name] == false then error("circular require " .. name, 0) end
      return own[name]
    end
    own[name] = false

    if OWN[name] then
      local value = chunkFor(OWN[name])(W)
      if value == nil then error(name .. " returned nil", 0) end
      own[name] = value
      return value
    end

    -- Prefer host module when present
    if hostLib and hostLib.require then
      local ok, value = pcall(hostLib.require, name)
      if ok and value ~= nil then
        own[name] = value
        return value
      end
    end

    if STUBS[name] then
      local value = chunkFor(STUBS[name])(W)
      if value == nil then error(name .. " stub returned nil", 0) end
      own[name] = value
      return value
    end

    -- Last resort: the mod's own modules. Without this, every
    -- `V.require("Settings")` / `V.require("Quality")` inside lib/voxel_atmos/
    -- fell through to the error below -- and because those call sites are all
    -- wrapped in pcall, they failed silently forever. The visible symptom was
    -- that the Quality tier never scaled WorldPrecip's particle caps: `qScale`
    -- was pinned at 1.0 on every tier including potato, so the quality setting
    -- did nothing for 3D precipitation. Kept last so a host module still wins.
    local okOwn, valueOwn = pcall(V.require, name)
    if okOwn and valueOwn ~= nil then
      own[name] = valueOwn
      return valueOwn
    end

    error("DramalessAtmos: cannot resolve " .. tostring(name), 0)
  end

  W.data = hostLib and hostLib.data
  return W
end

-- Report errors at the actual render boundary instead of silently losing a
-- celestial body (q92's GLES compile failure was swallowed here).
local function celestialPass(label, draw)
  local g = love.graphics
  g.push("all")
  local ok, result = pcall(draw)
  g.pop()
  Atmos._celestialDiagnostics = Atmos._celestialDiagnostics or {}
  local message = ok and "rendered" or tostring(result)
  if Atmos._celestialDiagnostics[label] ~= message then
    Atmos._celestialDiagnostics[label] = message
    local text = "q96 World " .. label .. ": " .. message
    print(text)
    pcall(function()
      local compat = mod:find("BATTLE_ART_QUEST_COMPAT")
      local xr = compat.exports.lib.require("VRXRQuest")
      if xr.trace then xr.trace(text) end
    end)
    if not ok then pcall(mod.log.warn, mod.log, "%s", text) end
  end
  return ok, result
end

local function drawInScene(skyOnly)
  if not Atmos._drawing or not want3d() then return end
  pcall(function()
    local TOD = V.require("TimeOfDay")
    local night = TOD and (TOD.pin == "NITE" or TOD.tod == "NITE" or (TOD.isNight and TOD.isNight()))
    package.loaded._WX_NIGHT = night and true or false
  end)
  local cin = Atmos._cin
  local Voxel3D = Atmos._Voxel3D
  if not (cin and Voxel3D and Voxel3D.vp) then return end

  -- Animation clock is advanced in Atmos.update(dt). Do not call
  -- ForestAtmos.update(0) here — that was a no-op that invited TOD snaps.

  -- Align light-shaft shear with the host sun/moon *this frame*.
  -- Cache DayNight/ShadowMap on Atmos so we never hostLib.require per frame.
  pcall(function()
    if not Atmos._DayNight or not Atmos._ShadowMap then
      local hostLib = Atmos._hostLib
      if not hostLib then return end
      if not Atmos._DayNight then
        local ok, DN = pcall(hostLib.require, "DayNight")
        if ok then Atmos._DayNight = DN end
      end
      if not Atmos._ShadowMap then
        local ok, SM = pcall(hostLib.require, "ShadowMap")
        if ok then Atmos._ShadowMap = SM end
      end
    end
    local DayNight, ShadowMap = Atmos._DayNight, Atmos._ShadowMap
    if not ShadowMap then return end
    -- Prefer Weather FX celestial shear (Y-axis orbit). Host DayNight.shearAt
    -- uses a different axis and was the source of "sun moves on X" lighting.
    local kx, kz
    pcall(function()
      local CB = V.require("CelestialBodies")
      if CB and CB.shearAt then
        local hour = nil
        pcall(function()
          local TOD = V.require("TimeOfDay")
          hour = TOD and TOD.hour
        end)
        kx, kz = CB.shearAt(hour)
      end
    end)
    if type(kx) ~= "number" and DayNight and DayNight.shearAt then
      local tt = DayNight.time and DayNight.time() or 0
      kx, kz = DayNight.shearAt(tt)
    end
    if type(kx) == "number" and type(kz) == "number" then
      ShadowMap.KX, ShadowMap.KZ = kx, kz
    end
  end)

  local map = Atmos._lastMap
  local outdoor = Atmos._lastOutdoor
  if outdoor == nil then outdoor = true end

  local prevBlend, prevAlpha
  pcall(function()
    prevBlend, prevAlpha = love.graphics.getBlendMode()
  end)
  local pr, pg, pb, pa
  pcall(function() pr, pg, pb, pa = love.graphics.getColor() end)

  -- Quest renders celestial objects before the alpha-blended cloud deck.
  -- Late endScene remains responsible for bolts and precipitation only.
  -- Interiors must not reach the late celestial fallback when the host skips its sky pass.
  if outdoor and (not V.questLitePrivate or skyOnly or not Atmos._skyDrawnThisScene) then
  -- Sun/Moon first (day + night): same 3D path as stars, independent of nightVis.
  pcall(function()
    if not Atmos._NightSky then
      Atmos._NightSky = V.require("NightSky")
    end
    local NightSky = Atmos._NightSky
    -- The private Quest path draws CelestialBodies once below. Other hosts use
    -- NightSky's normal ownership-aware renderer.
    if not V.questLitePrivate and NightSky and NightSky.drawSunMoonWorld then
      pcall(NightSky.drawSunMoonWorld, Voxel3D)
    end
  end)

  -- The authorized World renderer owns stars and planets on every 3D host,
  -- including Quest. q93 imports the user ZIP catalog, keeps all 1,280 stars,
  -- and adds only radial point edges to remove the requested square shapes.
  if V.questLitePrivate then
    celestialPass("aurora", function() V.require("QuestAurora").drawWorld(Voxel3D) end)
    celestialPass("rainbow", function() V.require("QuestRainbow").drawWorld(Voxel3D) end)
  end
  celestialPass("stars", function()
    if not Atmos._NightSky then
      Atmos._NightSky = V.require("NightSky")
    end
    local NightSky = Atmos._NightSky
    if not NightSky then return end
    attachNightSkyHost(NightSky)
    -- Force star visibility when Dramaless/host or Weather FX says night.
    pcall(function()
      local night = false
      local TOD = NightSky._TOD
      if V.questLitePrivate then
        if TOD and TOD.isNight then
          local okN, n = pcall(TOD.isNight)
          if okN and n then night = true end
        end
        if not night and TOD and (TOD.pin == "NITE" or TOD.pin == "NIGHT"
            or TOD.tod == "NITE" or TOD.tod == "NIGHT") then night = true end
        if not night and TOD and type(TOD.hour) == "number" then
          local h = TOD.hour % 24
          night = h >= 20 or h < 4
        end
        -- Clear a stale host/CinematicAtmos value just as deliberately as we
        -- set it. This keeps dawn/day from inheriting Battle Art's night.
        package.loaded._WX_NIGHT = night
        if rawget(_G, "V") then V._WX_NIGHT = night end
      else
        if NightSky.isNight and NightSky.isNight(nil) then night = true end
        local DN = NightSky._DayNight or Atmos._DayNight
        if not night and DN and DN.isNight then
          local okN, n = pcall(DN.isNight)
          if okN and n then night = true end
        end
        if not night and TOD and (TOD.pin == "NITE" or TOD.tod == "NITE") then night = true end
      end
      if night then
        NightSky._nightVis = 1
        NightSky._nightVisRaw = 1
        package.loaded._WX_NIGHT = true
      end
    end)
    local tt = (Atmos._forest and Atmos._forest.time) or 0
    local ok = false
    if NightSky.drawWorld then
      ok = NightSky.drawWorld(Voxel3D, tt) and true or false
    end
    if not ok and not V.questLitePrivate and NightSky.draw then
      pcall(function()
        local w, h = love.graphics.getDimensions()
        if Voxel3D and Voxel3D.canvas then
          local o, cw, ch = pcall(function()
            return Voxel3D.canvas:getWidth(), Voxel3D.canvas:getHeight()
          end)
          if o and cw then w, h = cw, ch end
        end
        pcall(love.graphics.push)
        pcall(love.graphics.origin)
        pcall(love.graphics.setDepthMode, "always", false)
        NightSky.draw(w, h, h * 0.7, nil, tt)
        pcall(love.graphics.setDepthMode, "lequal", true)
        pcall(love.graphics.pop)
      end)
    end
  end)

  -- Sun/moon: true 3D celestial sphere (player origin, world direction).
  -- Noon is overhead (+Y): visible in FPV/3rd only when looking UP.
  -- Do NOT draw a 2D screen disc here — that stays stuck on the HUD.
  celestialPass("sun-moon", function()
    local CB
    pcall(function() CB = V.require("CelestialBodies") end)
    if not CB then
      local src = mod:read("lib/CelestialBodies.lua")
      if src then CB = assert((loadstring or load)(src, "@CelestialBodies"))(V) end
    end
    if not CB or not CB.drawWorld then return end
    local hour
    pcall(function()
      local TOD = V.require("TimeOfDay")
      hour = TOD and TOD.hour
    end)
    pcall(love.graphics.setDepthMode, "always", false)
    local drawn = CB.drawWorld(Voxel3D, hour)
    if V.questLitePrivate and not drawn then
      error("World body renderer declined at hour " .. tostring(hour))
    end
    pcall(love.graphics.setDepthMode, "lequal", true)
  end)

  end -- celestial portion
  if skyOnly then return end
  if V.questLitePrivate then
    celestialPass('storm-bolt',function() V.require('QuestStormBolt').drawWorld(Voxel3D) end)
  end
  local ok, err = pcall(function()
    if V.questLitePrivate then
      -- Do not call CinematicAtmos.draw here: that function also owns cloud
      -- descriptors, mist banks, rays, puddles, reflections, and distant
      -- scenery. We borrow only its weather profile and feed The World's
      -- proven WorldPrecip renderer inside the active per-eye voxel scene.
      local frame = cin.frame and cin.frame(map, outdoor) or nil
      -- CinematicAtmos supports several hosts and therefore also samples the
      -- host DayNight clock. Reassert our single Quest clock after profiling.
      pcall(function()
        local TOD = V.require("TimeOfDay")
        local night = TOD and TOD.isNight and TOD.isNight() or false
        package.loaded._WX_NIGHT = night and true or false
        if rawget(_G, "V") then V._WX_NIGHT = night and true or false end
      end)
      local WP = Atmos._worldPrecip
      if not WP and Atmos._ns then
        WP = Atmos._ns.require("WorldPrecip")
        Atmos._worldPrecip = WP
      end
      if frame and WP and WP.update and WP.draw then
        local id = tostring(Atmos._wxId or "CLEAR"):upper()
        frame = questWeatherFrame(frame, id)
        -- Stream around position, not the look-at target (which rises/lowers
        -- as the headset pitches). Ground/water impacts use actual map shapes.
        local eye=Voxel3D.eye or Voxel3D.player or {0,32,0}
        local focus={eye[1],0,eye[3]}
        if Atmos._precipSurfaceMap~=map then
          if Atmos._precipSurfaceMap and WP.invalidate then WP.invalidate() end
          local shapeAPI=Atmos._hostLib.require('TileShape')
          Atmos._precipSurface=V.require('QuestRainSurface').sampler(map,shapeAPI)
          Atmos._precipSurfaceMap=map
        end
        frame.weather.surfaceAt=Atmos._precipSurface
        -- A real update serial, not elapsed wall time: two slow eye draws
        -- can be more than 4ms apart but still belong to the same game frame.
        local serial = Atmos._updateSerial or 0
        if Atmos._lastPrecipSerial ~= serial then
          WP.update(Atmos._updateDelta or 0, focus, frame.weather)
          Atmos._lastPrecipSerial = serial
        end
        WP.draw(Voxel3D, frame)
        Atmos._lastQuestFrame = id
      end
    elseif cin.draw then
      cin.draw(map, outdoor, Atmos._lastNeighbors, Atmos._lastPosed)
    end
  end)
  if not ok then
    Atmos._lastDrawError = tostring(err)
  else
    Atmos._lastDrawError = nil
  end

  pcall(love.graphics.setShader)
  if prevBlend then pcall(love.graphics.setBlendMode, prevBlend, prevAlpha) end
  if pr then pcall(love.graphics.setColor, pr, pg, pb, pa) end
  pcall(love.graphics.setDepthMode, "lequal", true)
end

function Atmos.install()
  if mod.exports.ownedWeatherAdapter then Atmos._reason="owned-renderer-api";return false end
  local pc=mod
  if pc and pc.exports then
    local ready,reason=false,'desktop-adapter-not-ready'
    if pc.exports.rendererReady then ready,reason=pc.exports.rendererReady() end
    if not ready then Atmos._reason=reason;return false end
  end
  if Atmos._ready and Atmos._active then return true end
  Atmos._ready = true
  Atmos._active = false
  Atmos._drawing = false

  local host, hostId = findHost()
  if not host then
    Atmos._reason = "no-3d-voxel-host"
    return false
  end
  Atmos._hostId = hostId

  -- General hosts keep their own clock. The private Quest study explicitly
  -- asked for The World's accelerated solar/lunar cycle, so it must remain
  -- clock authority and drive both the celestial sphere and Quest sky.
  if not V.questLitePrivate then
    pcall(function()
      local TOD = V.require("TimeOfDay")
      if TOD and TOD.setHostOwnsClock then
        TOD.setHostOwnsClock(true)
      end
    end)
    pcall(function()
      local Settings = V.require("Settings")
      if Settings and Settings.set then
        pcall(Settings.set, "daytime", "off")
      end
    end)
  end

  if not (host.exports and host.exports.lib) then
    Atmos._reason = "host-missing-exports-lib"
    return false
  end

  local hostLib = host.exports.lib
  Atmos._hostLib = hostLib
  local W = buildNamespace(hostLib)
  -- Keep the namespace reachable: handlesSnow() has to be able to ask
  -- WorldPrecip whether it is actually drawing before it suppresses the 2D
  -- layer. Without this it could only guess, which is why it gave up and
  -- returned a hardcoded false.
  Atmos._ns = W

  local okV, Voxel3D = pcall(function() return W.require("Voxel3D") end)
  if not okV or not Voxel3D or not Voxel3D.endScene then
    Atmos._reason = "Voxel3D-unavailable"
    return false
  end
  Atmos._Voxel3D = Voxel3D

  -- CinematicAtmos draws through beginEffect/endEffect (Dramatic Shape API).
  -- Dramaless does not define them; install safe in-memory polyfills so
  -- clouds/rays/rain can bind shaders without editing the host mod on disk.
  if type(Voxel3D.beginEffect) ~= "function" then
    function Voxel3D.beginEffect(shader)
      if not Voxel3D.vp then return false end
      if shader then
        local ok = pcall(love.graphics.setShader, shader)
        if not ok then return false end
      end
      -- Keep depth test; do not write depth for translucent volumes.
      pcall(love.graphics.setDepthMode, "lequal", false)
      return true
    end
  end
  if type(Voxel3D.endEffect) ~= "function" then
    function Voxel3D.endEffect()
      pcall(love.graphics.setShader)
      pcall(love.graphics.setDepthMode, "lequal", true)
    end
  end
  -- Optional fields some Kanto draws read; never crash if absent.
  if Voxel3D.focus == nil then Voxel3D.focus = { 0, 0, 0 } end
  if Voxel3D.eye == nil then Voxel3D.eye = { 0, 40, 0 } end

  local okF, forest = pcall(function() return W.require("ForestAtmos") end)
  if okF then Atmos._forest = forest end

  local okC, cin = pcall(function() return W.require("CinematicAtmos") end)
  if not okC or not cin then
    Atmos._reason = "CinematicAtmos-load-failed: " .. tostring(cin)
    return false
  end
  Atmos._cin = cin
  if V.questLitePrivate then
    local storm=V.require('QuestStorm')
    storm.attach(hostLib,Voxel3D)
    cin.lightningProvider=storm.flash
  end

  if not V.questLitePrivate then
    pcall(function() Atmos._distant = W.require("DistantWorld") end)
    pcall(function() Atmos._horizon = W.require("HorizonApron") end)
  end

  -- Night stars/planets + greyer rain sky via one Sky.paint wrap (host only).
  if not V.questLitePrivate and not Atmos._skyWrapped then
    local okSky, Sky = pcall(function() return hostLib.require("Sky") end)
    if okSky and Sky and type(Sky.paint) == "function" then
      local NightSky
      pcall(function()
        local src = mod:read("lib/NightSky.lua")
        if not src then return end
        NightSky = assert((loadstring or load)(src, "@NightSky"))(V)
      end)
      local origPaint = Sky.paint
      -- Gen2 Sky.paint may pass extra args (top, axis, ray); always forward them.
      function Sky.paint(w, h, sky, horizonY, cell, body, ...)
        local skyArg = sky
        if NightSky and sky and sky.bands and Atmos._cin and Atmos._cin.skyWeather then
          local ok, info = pcall(Atmos._cin.skyWeather)
          if ok and info then
            local copy = {}
            for k, v in pairs(sky) do copy[k] = v end
            copy.bands = NightSky.applyWeatherBands(sky.bands, info)
            skyArg = copy
          end
        end
        -- Never forward host DayNight body (wrong axis). Leave body to outer
        -- Weather FX wrap (main) which injects CelestialBodies positions.
        local result = origPaint(w, h, skyArg, horizonY, cell, body, ...)
        attachNightSkyHost(NightSky)
        local showStars = NightSky and NightSky.isNight and NightSky.isNight(nil)
        if NightSky and showStars then
          local edge
          pcall(function() edge = Sky.region(h, horizonY) end)
          local t = (Atmos._forest and Atmos._forest.time) or 0
          pcall(NightSky.draw, w, h, edge or (h * 0.42), nil, t)
        end
        return result
      end
      Atmos._skyWrapped = true
    end
  end

  -- Capture scene context from VoxelScene.render by wrapping it when available
  local okS, VoxelScene = pcall(function() return hostLib.require("VoxelScene") end)
  if okS and VoxelScene and VoxelScene.render and not Atmos._wrappedScene then
    local orig = VoxelScene.render
    VoxelScene.render = function(state, w, h, vw, vh, paletteFor)
      if state then
        Atmos._lastMap = state.map
        Atmos._lastNeighbors = state.neighbors
        Atmos._lastPosed = state.posed
        -- Prefer Weather FX Scene outdoor flag; fall back to outdoor=true for
        -- voxel overworld (host only renders outdoor maps in practice).
        -- Scene is authoritative for interiors: a canopy heuristic must never
        -- turn weather back on inside a lab/building/cave.
        local outdoor = true
        pcall(function()
          local Scene = V.require("Scene")
          if Scene and Scene.now and Scene.now.outdoor ~= nil then
            outdoor = Scene.now.outdoor and true or false
          end
        end)
        Atmos._lastOutdoor = outdoor
      end
      return orig(state, w, h, vw, vh, paletteFor)
    end
    Atmos._wrappedScene = true
  end

  if not Atmos._origEndScene then
    Atmos._origEndScene = Voxel3D.endScene
    if V.questLitePrivate then
      Voxel3D.questCelestialBeforeClouds=function()
        local g=love.graphics
        Atmos._skyDrawnThisScene=false
        if not (g.getCanvas and g.getCanvas()) or not Atmos._drawing or not want3d() then return end
        g.push('all')
        local ok,err=pcall(drawInScene,true)
        g.pop()
        Atmos._skyDrawnThisScene=ok
        if not ok then Atmos._lastDrawError=tostring(err) end
      end
    end
    function Voxel3D.endScene()
      -- endScene is also called by the host's error cleanup. Never run sky
      -- effects on the window after the eye canvas has already been closed.
      local g = love.graphics
      local target = g.getCanvas and g.getCanvas()
      if target and Atmos._drawing and want3d() then
        g.push("all")
        local ok, err = pcall(drawInScene)
        g.pop()
        if not ok then
          Atmos._lastDrawError = tostring(err)
          if Atmos._reportedDrawError ~= Atmos._lastDrawError then
            Atmos._reportedDrawError = Atmos._lastDrawError
            pcall(mod.log.warn, mod.log, "World draw failed: %s", tostring(err))
          end
        end
      end
      Atmos._skyDrawnThisScene=false
      return Atmos._origEndScene()
    end
  end

  Atmos._active = true
  Atmos._drawing = true
  Atmos._reason = (V.questLitePrivate and "quest-lite-world:" or "full-atmos:")
    .. tostring(hostId)
  return true
end

function Atmos.active()
  return Atmos._active and Atmos._drawing
end

function Atmos.reason()
  if Atmos._lastDrawError then
    return tostring(Atmos._reason) .. "|err:" .. tostring(Atmos._lastDrawError):sub(1, 40)
  end
  return Atmos._reason
end

function Atmos.handlesPrecipitation()
  -- Suppress the 2D rain layer only after world-space rain actually emitted
  -- geometry. This preserves the 2D fallback if a mesh upload fails.
  if not want3d() or not Atmos.active() then return false end
  local id = tostring(Atmos._wxId or ""):upper()
  local rainy = id:find("RAIN", 1, true) or id == "STORM" or id == "SLEET"
      or id == "VERDANT_RAIN" or id == "PSYSTORM"
  if not rainy then return false end
  local ns = Atmos._ns
  if not ns then return false end
  local ok, drawing = pcall(function()
    local WPmod = ns.require("WorldPrecip")
    return WPmod and WPmod.drawingRain and WPmod.drawingRain() or false
  end)
  return (ok and drawing) and true or false
end

-- 2D snow is suppressed ONLY when the 3D world-space snow is provably on
-- screen this frame.
--
-- History: this returned a hardcoded false because an earlier version returned
-- true whenever 3D *should* be running, which zeroed the 2D channel and then
-- left nothing at all on screen when 3D silently failed. The 3D path had in
-- fact been failing continuously -- WorldPrecip was a LuaJIT compile error and
-- never loaded at all -- so the hardcoded false was the only thing keeping any
-- snow visible, and what it kept was the flat 2D overlay.
--
-- The fix is not to flip the constant back. It is to ask the thing that knows:
-- WorldPrecip reports whether it emitted flake geometry on the last frame. If
-- it did, the 2D sheet is redundant and drawing both is what makes world snow
-- look like an overlay. If it did not -- module missing, host absent, zero
-- intensity, everything culled -- we fall back to 2D exactly as before. Fail
-- closed: any doubt returns false and the player still sees snow.
function Atmos.handlesSnow()
  if not want3d() or not Atmos.active() then return false end
  local ns = Atmos._ns
  if not ns then return false end
  local ok, drawing = pcall(function()
    local WPmod = ns.require("WorldPrecip")
    return WPmod and WPmod.drawingSnow and WPmod.drawingSnow() or false
  end)
  return (ok and drawing) and true or false
end

function Atmos.handlesGrains()
  if not want3d() or not Atmos.active() then return false end
  local WP = Atmos._worldPrecip
  if not (WP and WP.drawingGrains) then return false end
  local ok, drawing = pcall(WP.drawingGrains)
  return ok and drawing and true or false
end


function Atmos.handlesFog()
  if not want3d() or not Atmos.active() then return false end
  local id = tostring(Atmos._wxId or ""):upper()
  -- Fog family: 3D mist volumes replace 2D fog so it does not double up.
  if id == "FOG" or id == "MIST" or id == "HAUNTED_MIST" or id == "SMOG" then
    return true
  end
  -- Sand/dust: same 3D fog volumes as fog weather (no 2D overlay).
  if id == "SANDSTORM" or id == "DUSTSTORM" or id == "ASHFALL" then
    return true
  end
  -- Closed-deck rain/storm: 3D fog bed is the primary look.
  if id:find("RAIN", 1, true) or id == "STORM" or id == "SLEET"
      or id == "THUNDERSNOW" or id == "DRAGONSTORM" or id == "VERDANT_RAIN"
      or id == "PSYSTORM" then
    return true
  end
  -- Snow, ash, wind, clear: keep 2D fog/tint layers alongside 3D clouds.
  return false
end

function Atmos.syncFromWeatherFx(state)
  if not Atmos.active() or not Atmos._cin then return end
  local cin = Atmos._cin
  local weatherId = state and state.id
  if type(weatherId) == "table" then
    weatherId = weatherId.id or weatherId.name
  end
  weatherId = tostring(weatherId or ""):upper()
  -- When the Weather FX pipeline is disabled, clear the 3D profile too.
  -- Otherwise its last rain/snow profile can keep rendering after 2D stopped.
  local level = tonumber(state and state.level) or 0
  if level <= 0 or weatherId == "" or weatherId == "NIL" or weatherId == "NONE"
      or weatherId == "OFF" or weatherId == "NONE_WEATHER" then
    weatherId = "CLEAR"
  end
  Atmos._wxId = weatherId
  local kanto = WX_TO_KANTO[weatherId] or "clear"
  if weatherId == "CLEAR" or weatherId == "SUNNY" then kanto = "clear" end
  if cin.weatherSetting and cin.weatherSetting.setValue then
    pcall(function() cin.weatherSetting:setValue(kanto) end)
  end
  -- Ground snow packs clear when WX leaves snowy weather (all hosts).
  if cin.notifyWxWeather then
    pcall(cin.notifyWxWeather, weatherId)
  end
end

function Atmos.update(dt)
  Atmos._updateSerial = (Atmos._updateSerial or 0) + 1
  Atmos._updateDelta = math.max(0, math.min(0.1, tonumber(dt) or 0))
  if not Atmos._ready then Atmos.install() end
  if not Atmos.active() then
    if not Atmos._ready then return end
    -- retry install occasionally if host appeared late
    if not Atmos._active then pcall(Atmos.install) end
    return
  end
  -- Keep outdoor flag in sync with Weather FX Scene when available.
  pcall(function()
    local Scene = V.require("Scene")
    if Scene and Scene.now and Scene.now.outdoor ~= nil then
      local outdoor = Scene.now.outdoor and true or false
      if outdoor == false and Atmos._lastMap then
        -- leave previous canopy override if any; Scene is authoritative for indoors
      end
      Atmos._lastOutdoor = outdoor
    end
  end)
  local step = tonumber(dt) or 0
  if step < 0 then step = 0 end
  if step > 0.25 then step = 0.25 end  -- avoid hitch-induced lattice jumps
  if Atmos._forest and Atmos._forest.update then
    pcall(Atmos._forest.update, step)
  end
  if Atmos._cin and Atmos._cin.update then
    pcall(Atmos._cin.update, step)
  end
end

function Atmos.invalidate()
  Atmos._lastPrecipSerial = nil
  if Atmos._worldPrecip and Atmos._worldPrecip.invalidate then
    pcall(Atmos._worldPrecip.invalidate)
  end
  if Atmos._cin and Atmos._cin.invalidate then
    pcall(Atmos._cin.invalidate)
  end
end

Atmos.questWeatherFrame=questWeatherFrame
return Atmos
