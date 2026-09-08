-- THE PASS: everything that happens to a frame, in the order it happens.
--
-- Both whole-frame stages -- `worldPresent` over a world pipeline's canvas
-- and `present` over the flat composite -- call exactly this one function
-- with a different rectangle, so there is ONE description of what weather
-- looks like and no chance of the renderers drifting apart.  The battle
-- screen has its own small compositor (lib/BattleDraw.lua) because it
-- draws in a different coordinate space.
--
-- THE ORDER IS THE POINT:
--
--   1. TIME-OF-DAY GRADE, multiplied.  Under everything, because the
--      time of day is a property of the light in the world, not of the
--      water in front of it: rain lit by a sun that set an hour ago
--      should be dark, and a grade over the top would dim the drops too.
--   2. WEATHER GRADE, also multiplied.  The gloom of the storm, on top of
--      the hour.  Two multiplies rather than one combined colour because
--      they have different lifetimes -- the hour eases over minutes, the
--      storm over seconds -- and combining them would mean recomputing
--      both whenever either moved.
--   3. FOG banks, between the world and the falling water.
--   4. VEIL, the flat achromatic haze a whiteout or a real murk has, over
--      the banks so it flattens them too.
--   5. PRECIPITATION, in front of all of it.
--   6. GLARE, an additive bloom, over the water: sunlight is on the lens,
--      not in the scene.
--   7. LIGHTNING, over everything including the rain, because a strike
--      lights the drops as well as the ground.
--
-- STATE IS FENCED AT BOTH ENDS.  The engine already wraps a pipeline
-- callback in love.graphics.push("all")/pop() so a mod cannot leak a bound
-- shader into the composite, but this restores blend mode, colour and
-- scissor itself anyway: worldPresent hands its canvas onward to the UI
-- composite within the same frame, and a mod that relies on somebody
-- else's cleanup is a mod that breaks when the cleanup moves.

local V = ...
local Harden = nil
pcall(function() Harden = V.require("Harden") end)
local Scene = V.require("Scene")
local State = V.require("WeatherState")
local Settings = V.require("Settings")
local Config = V.require("Config")
local Quality = V.require("Quality")
local Particles = V.require("Particles")
local Lightning = V.require("Lightning")
local Fog = V.require("Fog")
local Audio = V.require("Audio")
local Lightning = V.require("Lightning")
local Atmos = nil
pcall(function() Atmos = V.require("DramalessAtmos") end)
local TOD = V.require("TimeOfDay")
local BattleDraw = V.require("BattleDraw")
local Legendary = V.require("Legendary")
local Funnel = V.require("Funnel")
local Rainbow = V.require("Rainbow")

-- Optional 3D atmosphere bridge (Kanto path). Loaded lazily / safely so a
-- missing module never breaks the post-process compositor.
local VoxelAtmos = nil
do
  local ok, mod = pcall(V.require, "VoxelAtmosBridge")
  if ok then VoxelAtmos = mod end
end

local Draw = {}

-- True only for the overworld when the 3D bridge is actively drawing the
-- corresponding layer. Battles always keep the 2D overlays.
local function use3dPrecip()
  if Scene.now.visible == "battle" then return false end
  -- Player chose original 2D Weather FX overlays.
  if Settings.force2dPresent and Settings.force2dPresent() then return false end
  if VoxelAtmos and VoxelAtmos.handlesPrecipitation and VoxelAtmos.handlesPrecipitation() then
    return true
  end
  -- FPV: prefer world-space path whenever the voxel bridge is present
  if Settings.isFirstPerson and Settings.isFirstPerson() then
    if VoxelAtmos and (VoxelAtmos.active or VoxelAtmos.handlesPrecipitation) then
      return true
    end
  end
  return false
end

local function use3dFog()
  if Scene.now.visible == "battle" then return false end
  if Settings.force2dPresent and Settings.force2dPresent() then return false end
  return VoxelAtmos and VoxelAtmos.handlesFog and VoxelAtmos.handlesFog()
end

-- WHICH WEATHER THIS FRAME IS SHOWING.
--
-- Two authorities, one per context, and never both at once:
--
--   * the overworld's eased channels (WeatherState) for the world;
--   * the BATTLE's eased channels (BattleDraw) whenever a battle is on
--     screen, because a battle's weather comes from
--     `battle.field.weather` and not from the sky outside -- which is
--     what stops a gym battle raining and lets a Rain Dance rain.
--
-- The whole compositor goes through this, so the two can never be mixed
-- inside one frame.
function Draw.channels()
  local ch
  if Scene and Scene.now and Scene.now.visible == "battle" and BattleDraw and BattleDraw.live then
    local ok, c = pcall(function() return BattleDraw.channels() end)
    if ok then ch = c end
  end
  if type(ch) ~= "table" then
    ch = (State and State.ch) or {}
  end
  if type(ch) ~= "table" then ch = {} end
  return ch
end

-- The rect the last draw used, so the update tick has somewhere to
-- simulate before the first frame has told it how big the screen is.
local lastRect = { x = 0, y = 0, w = 0, h = 0, scale = 1 }

-- The wind is one slow oscillator shared by rain, snow, grains and
-- (faintly) fog, so everything leans together instead of each system
-- having its own idea of which way the weather is blowing.  Two sines at
-- unrelated periods: enough never to repeat visibly, cheap enough not to
-- care.
local function windAt(t, gust)
  if gust <= 0 then return 0 end
  local slow = math.sin(t * 0.19) * 0.7 + math.sin(t * 0.53 + 1.7) * 0.3
  return slow * 52 * gust        -- GB pixels per second
end

-- THE GLARE GRADIENT.
--
-- This used to be TWO rectangles -- a brighter one over the top 55% of the
-- frame and a dimmer one over the rest -- which put a hard horizontal seam
-- straight across the middle of the screen wherever they met.  Outdoors in
-- rain it was hidden under the precipitation; indoors, where nothing falls
-- but the grade still draws, it was a band across a Poke Mart.
--
-- A four-vertex mesh with per-vertex alpha gives the same "brighter toward
-- the sky" falloff as one continuous ramp, one draw call, and no edge
-- anywhere.  The lesson is small and general: two adjacent fills at
-- different alphas are a seam, not a gradient.
local glare = { mesh = nil }

local function glareMesh(x, y, w, h, topA, botA)
  if not glare.mesh then
    local ok, made = pcall(function()
      return love.graphics.newMesh({
        { 0, 0, 0, 0, 1, 1, 1, 1 },
        { 1, 0, 1, 0, 1, 1, 1, 1 },
        { 1, 1, 1, 1, 1, 1, 1, 1 },
        { 0, 1, 0, 1, 1, 1, 1, 1 },
      }, "fan", "stream")
    end)
    if not ok then return end
    glare.mesh = made
  end
  local r, g, b = 1.0, 0.94, 0.72
  glare.mesh:setVertices({
    { x,     y,     0, 0, r, g, b, topA },
    { x + w, y,     1, 0, r, g, b, topA },
    { x + w, y + h, 1, 1, r, g, b, botA },
    { x,     y + h, 0, 1, r, g, b, botA },
  })
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(glare.mesh)
end

-- WETNESS: the trace rain leaves behind.
--
-- Weather that simply stops does not read as real -- a downpour ends and
-- the world is instantly as dry as if it had never happened.  So the
-- ground REMEMBERS: `wet` rises while rain falls and drains away over a
-- couple of minutes afterwards, and puddles are drawn from it.
--
-- It is not a channel.  Channels belong to a weather and ease toward that
-- weather's value; wetness belongs to the GROUND and outlives the weather
-- entirely -- a channel would be dragged to zero the moment the rain
-- stopped, which is the one thing this must not do.
Draw.wet = 0

-- Puddles only for these overworld weather ids (labels: rain, heavy, primal,
-- storm, psy, sleet, dragon).
local PUDDLE_WEATHER = {
  RAIN_LIGHT = true, RAIN_HEAVY = true, HEAVY_RAIN = true, STORM = true,
  SLEET = true, PSYSTORM = true, DRAGONSTORM = true,
}

function Draw.puddleWeather(id)
  id = tostring(id or ""):upper()
  if PUDDLE_WEATHER[id] then return true end
  -- Soft match on label fragments if a custom id is used
  if id:find("RAIN", 1, true) and not id:find("VERDANT", 1, true) then return true end
  if id == "PSY" or id:find("PSYSTORM", 1, true) then return true end
  if id:find("SLEET", 1, true) then return true end
  if id:find("DRAGON", 1, true) and id:find("STORM", 1, true) then return true end
  return false
end

-- Puddle positions are fixed once and reused, so a puddle stays where it
-- is while the player walks past rather than swimming across the screen.
-- They are anchored to the WORLD by the camera, like the splashes.
local puddles = {}
local PUDDLES = 18
-- Minimum center-to-center distance in screen-space units (1 = full viewport).
local PUDDLE_MIN_DIST = 0.22

local function seedPuddles()
  if #puddles > 0 then return end
  local r = (love and love.math and love.math.random) or math.random
  local tries = 0
  while #puddles < PUDDLES and tries < 800 do
    tries = tries + 1
    local x = r() * 1.6 - 0.3   -- spread across ~1.6 screens
    local y = r() * 1.6 - 0.3
    local ok = true
    for j = 1, #puddles do
      local dx = x - puddles[j].x
      local dy = y - puddles[j].y
      if (dx * dx + dy * dy) < (PUDDLE_MIN_DIST * PUDDLE_MIN_DIST) then
        ok = false
        break
      end
    end
    if ok then
      puddles[#puddles + 1] = {
        x = x, y = y,
        -- 50% larger than original baseline
        w = (3 + r() * 7) * 1.5,
        h = (2 + r() * 2.5) * 1.5,
        a = 0.25 + r() * 0.5,
      }
    end
  end
end

-- Small puddles (GALE): 100 on screen, each lives 2s then teleports.
local smallPuddles = {}
local SMALL_PUDDLES = 100
local SMALL_PUDDLE_LIFE = 2.0
local smallPuddleFrame = -1

local function nowTime()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return (State and State.elapsed) or 0
end

local function isGaleWeather()
  local id = tostring(State.id or ""):upper()
  if id == "GALE" then return true end
  -- Soft handoff: still GALE-like if debris+rain heavy and label matches
  if id:find("GALE", 1, true) then return true end
  return false
end

local function randomSmallPos(r)
  return r() * 1.85 - 0.42, r() * 1.85 - 0.42
end

local function initSmallPuddle(i, stagger)
  local r = (love and love.math and love.math.random) or math.random
  local x, y = randomSmallPos(r)
  local t0 = nowTime()
  local age0 = stagger and (r() * SMALL_PUDDLE_LIFE) or 0
  smallPuddles[i] = {
    x = x, y = y,
    w = math.max(2.0, (4 + r() * 8) * 0.35),
    h = math.max(1.4, (2.5 + r() * 3) * 0.35),
    a = 0.50 + r() * 0.40,
    born = t0 - age0,
    expire = t0 - age0 + SMALL_PUDDLE_LIFE,
  }
end

local function seedSmallPuddles()
  for i = 1, SMALL_PUDDLES do
    if not smallPuddles[i] then
      initSmallPuddle(i, true)
    end
  end
end

local function updateSmallPuddles(dt)
  if not isGaleWeather() then
    if smallPuddles[1] then
      for i = 1, SMALL_PUDDLES do smallPuddles[i] = nil end
    end
    return
  end
  -- One update per frame max
  local frame = 0
  if love and love.timer and love.timer.getTime then
    frame = math.floor(love.timer.getTime() * 60)
  else
    frame = math.floor(((State and State.elapsed) or 0) * 60)
  end
  if frame == smallPuddleFrame then return end
  smallPuddleFrame = frame

  seedSmallPuddles()
  local t = nowTime()
  local r = (love and love.math and love.math.random) or math.random
  for i = 1, SMALL_PUDDLES do
    local p = smallPuddles[i]
    if not p then
      initSmallPuddle(i, true)
      p = smallPuddles[i]
    end
    if t >= (p.expire or 0) then
      -- Disappear + reappear elsewhere (stagger handled by different expire times)
      local nx, ny = randomSmallPos(r)
      -- Guarantee a different cell-ish position
      if math.abs(nx - p.x) < 0.12 and math.abs(ny - p.y) < 0.12 then
        nx = (nx + 0.35 + r() * 0.5) % 1.85 - 0.42
        ny = (ny + 0.35 + r() * 0.5) % 1.85 - 0.42
      end
      p.x, p.y = nx, ny
      p.w = math.max(2.0, (4 + r() * 8) * 0.35)
      p.h = math.max(1.4, (2.5 + r() * 3) * 0.35)
      p.a = 0.50 + r() * 0.40
      p.born = t
      p.expire = t + SMALL_PUDDLE_LIFE
    end
    -- age for fade (0..1 through life)
    local life = SMALL_PUDDLE_LIFE
    p.age = math.max(0, math.min(life, t - (p.born or t)))
  end
end

local function drawPuddleBatch(list, wetAlpha, x, y, w, h, scale, camX, camY, alpha, lifeFade)
  local px = math.max(0.5, scale or 1)
  for i = 1, #list do
    local p = list[i]
    local lifeA = 1
    if lifeFade and p.age and SMALL_PUDDLE_LIFE then
      local t = p.age / SMALL_PUDDLE_LIFE
      -- Soft in/out so disappear at 1s reads clean
      if t < 0.15 then lifeA = t / 0.15
      elseif t > 0.85 then lifeA = (1 - t) / 0.15
      end
    end
    local sx = x + ((p.x * w) - (camX * px) % (w * 1.5))
    local sy = y + ((p.y * h) - (camY * px) % (h * 1.5))
    if sx > x - 40 and sx < x + w and sy > y - 20 and sy < y + h then
      local wa = wetAlpha * lifeA
      love.graphics.setColor(0.30, 0.36, 0.48, p.a * wa * 0.55 * alpha)
      love.graphics.rectangle("fill", sx, sy, p.w * px, p.h * px)
      love.graphics.setColor(0.75, 0.85, 1.0, p.a * wa * 0.22 * alpha)
      love.graphics.rectangle("fill", sx, sy, math.max(1, p.w * px), math.max(1, math.max(px * 0.35, p.h * px * 0.35)))
    end
  end
end

Draw.wind = 0
Draw.lastDt = 1 / 60

-- ------- the tick

function Draw.update(dt, level)
  -- Rainbow disabled
  Draw.lastDt = dt
  if (level or 0) <= 0 then return end
  Quality.update(dt)

  local ch = Draw.channels()
  Draw.wind = windAt(State.elapsed, ch.gust or 0)

  local vp = Scene.viewport
  if lastRect.w <= 1 and vp then
    lastRect.x, lastRect.y = vp.x, vp.y
    lastRect.w, lastRect.h = vp.w, vp.h
    lastRect.scale = vp.scale
  end
  if lastRect.w <= 1 or lastRect.h <= 1 then return end

  Particles.setRect(lastRect.w, lastRect.h, lastRect.scale)
  Particles.spread = Config.get().splashSpread or 1
  local _, precipitation = Scene.drawScale(Settings)
  local tuning = Config.tuningFor(State.id)
  local splashesOn = precipitation
    and Settings.is("splash", "on") and Config.visual("splashes")
  Particles.update(dt, ch, Quality.budget(tuning.density), Draw.wind,
    Scene.now.camX, Scene.now.camY, splashesOn)

  local mode = Settings.get("lightning")
  if not Config.visual("lightning") then mode = "off" end
  do
    local camX = (Scene.now and Scene.now.camX) or 0
    local camY = (Scene.now and Scene.now.camY) or 0
    local vw = lastRect.w > 1 and lastRect.w or 160
    local vh = lastRect.h > 1 and lastRect.h or 144
    local sc = (lastRect.scale and lastRect.scale > 0) and lastRect.scale or 1
    if not V.questLitePrivate then
      Lightning.update(dt, ch.strike or 0, mode, camX, camY, vw, vh, sc)
    end
  end
  Funnel.update(dt)

  -- Puddles only for whitelist weathers; wetness clears otherwise.
  local allow = Draw.puddleWeather(State.id)
  local rain = math.min(1, ch.rain or 0)
  if allow and rain > 0.02 then
    Draw.wet = math.min(1, Draw.wet + dt * math.max(0.15, rain) * 0.08)
  elseif allow and (State.id == "PSYSTORM" or State.id == "DRAGONSTORM" or State.id == "SLEET") then
    Draw.wet = math.min(1, Draw.wet + dt * 0.04)
  else
    Draw.wet = 0
  end
  updateSmallPuddles(dt)
end

-- ------- the pass

-- `alpha` is the frame's overall strength; `precipitation` is false
-- indoors, where the grade and the lightning survive but nothing falls.
function Draw.pass(x, y, w, h, scale, alpha, precipitation)
  if alpha <= 0 or w <= 1 or h <= 1 then return end
  local ch = Draw.channels()
  local lightMode = Settings.get("lightning")
  if not Config.visual("lightning") then lightMode = "off" end
  local flash = Lightning.flash(lightMode)

  lastRect.x, lastRect.y, lastRect.w, lastRect.h = x, y, w, h
  lastRect.scale = scale
  Particles.setRect(w, h, scale)
  Particles.camX, Particles.camY = Scene.now.camX, Scene.now.camY

  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local prevBlend, prevAlphaMode = love.graphics.getBlendMode()

  -- ------- 1. the weather's own grade
  --
  -- The TIME-OF-DAY grade is NOT here.  It used to be, and that was a
  -- design error: it welded a separate feature to the weather pipeline's
  -- ladder, so switching weather off also switched the day/night tint off.
  -- It has its own pipeline now (see main.lua), at a higher priority so it
  -- composites underneath this.
  --
  -- A strike lifts the gloom for as long as it lasts, which is the cue
  -- that sells lightning from inside a building: the room brightens even
  -- though the bolt is not on screen.
  if Config.visual("tint") then
    local sid = State.id
    local sandDust = (sid == "SANDSTORM" or sid == "DUSTSTORM")
    -- Sand/dust: no multiply dim (darkening). Visibility comes from fog/veil haze.
    local dim = sandDust and 0 or math.max(0, (ch.dim or 0) * alpha - flash * 0.55)
    local cool, warm = ch.cool or 0, (ch.warm or 0) * alpha
    if sandDust then warm = warm * 0.35 end  -- light warmth only, not a dark grade
    if dim > 0.002 or warm > 0.002 then
      local r = 1 - dim * (1.00 + cool * 0.28) + warm * 0.10
      local g = 1 - dim * (1.00 + cool * 0.06) - warm * 0.02
      local b = 1 - dim * (1.00 - cool * 0.48) - warm * 0.16
      love.graphics.setBlendMode("multiply", "premultiplied")
      love.graphics.setColor(math.max(0, math.min(1, r)),
        math.max(0, math.min(1, g)), math.max(0, math.min(1, b)), 1)
      love.graphics.rectangle("fill", x, y, w, h)
      love.graphics.setBlendMode("alpha")
    end
  end

  -- ------- 2. fog
  -- FOG INTENSITY OFF → no fog/veil. Also: only fog-family weather (FOG/MIST/…)
  -- may show the 2D fog bank — never on boot CLEAR or non-fog skies.
  local fogOff = Settings.fogOff and Settings.fogOff()
  local fogWeather = State.isFogWeather and State.isFogWeather(State.id)
  -- Sand/dust haze uses same fog/veil path when channels are active.
  if not fogWeather and State.id then
    local sid = State.id
    if sid == "SANDSTORM" or sid == "DUSTSTORM" then
      if (ch.fog or 0) > 0.004 or (ch.veil or 0) > 0.004 then fogWeather = true end
    end
  end
  -- First-person + 3D fog path: never draw the 2D fog overlay.
  local fpNo2dFog = false
  if Settings.isFirstPerson and Settings.isFirstPerson() then fpNo2dFog = true end
  if use3dFog and use3dFog() then fpNo2dFog = true end
  local fog = (ch.fog or 0) * alpha
  if fogWeather and not fogOff and not fpNo2dFog and Config.visual("fog")
      and fog > 0.004 and Fog.ready() then
    if Fog.setTint then
      local sid = State.id
      if sid == "SANDSTORM" then
        Fog.setTint(0.85, 0.72, 0.48, 1)  -- sand tan, drift right
      elseif sid == "DUSTSTORM" then
        Fog.setTint(0.78, 0.66, 0.46, 1)  -- dust brown, drift right
      else
        Fog.resetTint()
      end
    end
    love.graphics.push()
    love.graphics.translate(x, y)
    -- Top-down / diorama needs denser banks than first person: the camera
    -- sees the whole map floor, so thin full-screen fog looks absent.
    local topDown = true
    if Settings.isFirstPerson and Settings.isFirstPerson() then topDown = false end

    local fogMul = 1
    if Settings.fogIntensity then fogMul = Settings.fogIntensity() or 1 end
    local weatherInt = 1
    if Settings.intensity then
      local okI, iv = pcall(Settings.intensity)
      if okI and type(iv) == "number" then weatherInt = iv end
    end
    -- Quality: potato/low (and voxel detail ~75% and under) get a boost so
    -- a single fog layer still reads as weather on the ground.
    local qTier = "high"
    if Quality.tier then
      local okT, tname = pcall(Quality.tier)
      if okT and type(tname) == "string" then qTier = tname end
    end
    local qBoost = 1
    if qTier == "potato" then qBoost = 1.85
    elseif qTier == "low" then qBoost = 1.55
    elseif qTier == "medium" then qBoost = 1.25
    end
    -- Top-down / overhead: 50% less 2D fog so the map stays readable.
    -- First-person fog strength is unchanged.
    if topDown then qBoost = qBoost * 0.675 end  -- was 1.35; -50%

    local fogAlpha = 2.20 + math.min(3.0, fog * 0.55)
    if topDown then fogAlpha = fogAlpha * 0.625 end  -- was 1.25; -50%
    local layers = Quality.budget(1).fogLayers or 1
    if fog > 1.5 then layers = math.max(layers, 3) end
    if fog > 4 then layers = math.max(layers, 4) end
    if fog > 7 then layers = math.max(layers, 5) end
    if topDown then layers = math.max(layers, 1) end
    if topDown and (qTier == "potato" or qTier == "low") then
      layers = math.max(layers, 2)
    end
    layers = math.min(layers, 5)

    local fogAmt = fog * (topDown and 0.575 or 1)  -- was 1.15; -50%
    Fog.draw(fogAmt, fogAlpha, layers, State.elapsed,
      Scene.now.camX, Scene.now.camY, scale, w, h, ch.fogSpeed or 0.5)

    -- Ground fog: lower-screen pool scaled by FOG INTENSITY × intensity × quality
    if topDown and Fog.drawGround then
      local gStrength = fogMul * math.max(0.35, weatherInt) * qBoost * 0.5
      local gLayers = 2
      if qTier == "potato" or qTier == "low" then gLayers = 3 end
      if fogMul >= 2 then gLayers = math.min(3, gLayers + 1) end
      Fog.drawGround(fogAmt, fogAlpha * 0.95, gLayers, State.elapsed,
        Scene.now.camX, Scene.now.camY, scale, w, h, ch.fogSpeed or 0.5, gStrength)
    end
    love.graphics.pop()
    if Fog.resetTint then Fog.resetTint() end
  end

  -- ------- 3. the veil (fog-family only — same gate as fog bank)
  -- Suppressed in first person / when 3D fog volumes own the haze.
  local veil = (ch.veil or 0) * alpha
  if fogWeather and not fogOff and not fpNo2dFog and Config.visual("veil") and veil > 0.004 then
    love.graphics.setBlendMode("alpha")
    local va = math.min(0.95, veil * 0.55)
    local topDownV = true
    if Settings.isFirstPerson and Settings.isFirstPerson() then topDownV = false end
    if topDownV then va = math.min(0.95, va * 0.6) end  -- was 1.2; -50% for overhead
    love.graphics.setColor(0.86, 0.88, 0.92, va)
    love.graphics.rectangle("fill", x, y, w, h)
  end

  -- ------- 4. what falls
  -- 2D particles always draw for snow/sand/ash/debris/hail.
  -- Only 2D *rain* is suppressed when 3D rain is active (avoids double streaks).
  if precipitation and Config.visual("precipitation") and Particles.ready() then
    local drawCh = ch
    if use3dPrecip() then
      local ch2 = {}
      for k, v in pairs(ch) do ch2[k] = v end
      ch2.rain = 0
      ch2.snow = 0
      drawCh = ch2
    elseif Settings.isFirstPerson and Settings.isFirstPerson() then
      local ch2 = {}
      for k, v in pairs(ch) do ch2[k] = v end
      ch2.snow = 0
      drawCh = ch2
    end
    local has = (drawCh.rain or 0) + (drawCh.snow or 0) + (drawCh.sand or 0)
        + (drawCh.ash or 0) + (drawCh.debris or 0) + (drawCh.hail or 0)
    if has > 0.01 then
      love.graphics.push()
      love.graphics.translate(x, y)
      Particles.draw(alpha, drawCh)
      love.graphics.pop()
    end
  end

  -- Keep SFX locked to what is on screen
  pcall(function()
    if Audio and Audio.nudgeFromVisual then
      local rainOn = ((ch.rain or 0) + (ch.hail or 0)) > 0.02
      local boltOn = (ch.strike or 0) > 0.02 or (Lightning and (Lightning.age or -1) >= 0)
      Audio.nudgeFromVisual(State.id, rainOn, boltOn)
    end
  end)

  -- ------- 4a. rainbow disabled

  -- ------- 4b. the psychic wash
  --
  -- ADDITIVE, not a multiply like every other tint in this pass: a
  -- psystorm's sky glows violet rather than being darkened toward it, and
  -- a multiply can only ever take light away.  Drawn after the
  -- precipitation so the rain glows too, which is what makes it read as
  -- the air itself being lit rather than a filter over the picture.
  local psy = (ch.psy or 0) * alpha
  if Config.visual("tint") and psy > 0.004 then
    love.graphics.setBlendMode("add")
    love.graphics.setColor(0.42, 0.10, 0.55, math.min(0.6, psy * 0.42))
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setBlendMode("alpha")
  end

  -- ------- 5. glare
  local glare = (ch.glare or 0) * alpha
  if Config.visual("glare") and glare > 0.004 then
    love.graphics.setBlendMode("add")
    glareMesh(x, y, w, h, math.min(0.5, glare * 0.34), math.min(0.28, glare * 0.16))
    love.graphics.setBlendMode("alpha")
  end

  -- ------- 6b. puddles
  --
  -- Under the falling water and over the world, because a puddle is ON the
  -- ground: drawn after the grade so it darkens with the sky, and before
  -- the funnel, which is not weather.
  if Config.visual("puddles") ~= false then
    local camX, camY = Scene.now.camX, Scene.now.camY
    love.graphics.setBlendMode("alpha")
    -- Full puddles: rain-family whitelist
    if precipitation and Draw.wet > 0.02 and Draw.puddleWeather(State.id) then
      seedPuddles()
      drawPuddleBatch(puddles, Draw.wet, x, y, w, h, scale, camX, camY, alpha)
    end
    -- GALE: no splash / small-puddle ground flecks (leaves/debris only)
  end

  -- ------- 6. lightning
  --
  -- A roused bird lends the strike its colour, so a Zapdos storm is not
  -- merely a storm that happens to contain a Zapdos.
  Lightning.tint = Legendary.boltTint()
  do
    local camX = (Scene.now and Scene.now.camX) or 0
    local camY = (Scene.now and Scene.now.camY) or 0
    -- Always request bolt; Lightning.draw handles soft/off itself
    Lightning.draw(x, y, w, h, alpha, lightMode, true, camX, camY)
  end

  love.graphics.setBlendMode(prevBlend, prevAlphaMode)
  love.graphics.setColor(prevR, prevG, prevB, prevA)
end

-- ------- clipping
--
-- Two scissors, not one.  The outer one keeps weather inside the playfield
-- so it never falls in the letterbox bars.  The inner one -- only on the
-- flat renderer, and only while a dialog box is open -- keeps the FALLING
-- part above the box, so rain lands behind the text instead of on it.
--
-- The rect the particles are SIMULATED in does not change when a box
-- opens; only the visible region does.  Changing the field would rescale
-- every particle twice per conversation.

local function textBoxCut(x, y, w, h)
  if not Config.visual("textBoxClear") then return nil end
  local box = Scene.now.textBox
  if not box then return nil end
  -- the box rect is in 160x144 canvas units; the playfield is that canvas
  -- scaled to (w, h), so the conversion is one ratio per axis
  local topFrac = box.y / 144
  local visible = math.floor(h * topFrac)
  if visible <= 4 then return nil end
  return { x = x, y = y, w = w, h = visible }
end

function Draw.frame(x, y, w, h, scale, allowTextBoxCut)
  if Scene.now.visible=="world" and V.mod.exports.weatherFrameOwned and V.mod.exports.weatherFrameOwned()then return false end
  local alpha, precipitation = Scene.drawScale(Settings)
  if alpha <= 0 then return false end

  -- Area-name / route banners and dialog boxes are drawn in the finished
  -- frame BEFORE present. Full-screen grade/fog/weather in present would
  -- cover them. Skip present compositing while any UI overlay/text box is up.
  local now = Scene.now
  if allowTextBoxCut and now and (now.textBox or now.uiOverlay) then
    return false
  end

  local sx, sy, sw, sh = love.graphics.getScissor()
  local ok, err

  local cut = allowTextBoxCut and textBoxCut(x, y, w, h) or nil
  if cut and precipitation then
    -- Everything except the precipitation covers the whole playfield --
    -- a grade that stopped at the text box would be worse than no grade.
    -- So the pass runs twice: once full-rect with nothing falling, once
    -- clipped with only the precipitation.
    love.graphics.setScissor(x, y, w, h)
    ok, err = pcall(Draw.pass, x, y, w, h, scale, alpha, false)
    if ok then
      love.graphics.setScissor(cut.x, cut.y, cut.w, cut.h)
      ok, err = pcall(Draw.passPrecipitationOnly, x, y, w, h, scale, alpha)
    end
  else
    love.graphics.setScissor(x, y, w, h)
    ok, err = pcall(Draw.pass, x, y, w, h, scale, alpha, precipitation)
  end

  if sx then
    love.graphics.setScissor(sx, sy, sw, sh)
  else
    love.graphics.setScissor()
  end
  if not ok then error(err, 0) end   -- let the engine retire the pipeline
  return true
end

-- The precipitation layer on its own, for the clipped second pass.
function Draw.passPrecipitationOnly(x, y, w, h, scale, alpha)
  -- When the 3D atmosphere bridge is drawing world-space rain, skip the
  -- 2D particle pass so the two never stack.
  -- Selective 3D ownership handled in Draw.pass; precip-only pass still draws non-owned channels.
  if not (Config.visual("precipitation") and Particles.ready()) then return end
  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local prevBlend, prevAlphaMode = love.graphics.getBlendMode()
  love.graphics.push()
  love.graphics.translate(x, y)
  Particles.draw(alpha, Draw.channels())
  love.graphics.pop()
  -- ------- 7. the funnel, over everything
  --
  -- Last, and outside the weather's own alpha: a tornado is an event
  -- happening TO the frame rather than weather in it, so it is not thinned
  -- by the BATTLES setting or the indoor rule.
  Funnel.draw(x, y, w, h, scale)

  love.graphics.setBlendMode(prevBlend, prevAlphaMode)
  love.graphics.setColor(prevR, prevG, prevB, prevA)
end

-- THE TIME-OF-DAY GRADE, on its own.
--
-- Its own pass, called by its own pipeline, so it survives the weather
-- being switched off entirely.  A multiply for the colour of the light and
-- an add to put a little back into the shadows -- an add is what stops a
-- night grade reading as "the brightness control is broken".
--
-- Returns true if it drew, which the pipeline's stage handshake needs.
function Draw.grade(x, y, w, h, indoors)
  if Scene.now.visible=="world" and V.mod.exports.weatherFrameOwned and V.mod.exports.weatherFrameOwned()then return false end
  local mr, mg, mb, ar, ag, ab = TOD.grade(indoors)
  if not mr then return false end
  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local prevBlend, prevAlphaMode = love.graphics.getBlendMode()
  love.graphics.setBlendMode("multiply", "premultiplied")
  love.graphics.setColor(mr, mg, mb, 1)
  love.graphics.rectangle("fill", x, y, w, h)
  if ar > 0.001 or ag > 0.001 or ab > 0.001 then
    love.graphics.setBlendMode("add")
    love.graphics.setColor(ar, ag, ab, 1)
    love.graphics.rectangle("fill", x, y, w, h)
  end
  love.graphics.setBlendMode(prevBlend, prevAlphaMode)
  love.graphics.setColor(prevR, prevG, prevB, prevA)
  return true
end

function Draw.invalidate()
  glare.mesh = nil
  puddles = {}
  smallPuddles = {}  -- reseed with new sizes
  Particles.invalidate()
  Fog.invalidate()
  Lightning.reset()
  lastRect.w, lastRect.h = 0, 0
end

return Draw
