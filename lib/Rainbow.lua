-- Rainbow after rain.
--
-- The arc spans TWO MAP WIDTHS: one foot on the current map, the other
-- past the eastern edge onto the neighboring map space.  Ends do not need
-- that neighbor to be loaded — the bow still draws through the sky.
-- Survives map transitions (only clears indoors / rain return / timer).
--
-- Timing:
--   • Any continuous wet (rain) spell arms a "had rain" flag.
--   • The rainbow only starts once the sky leaves rain entirely.
--   • Fade in gently, hold, then fade out.  One rainbow per rain spell.

local V = ...
local Scene = V.require("Scene")
local Types = V.require("Types")
local State = V.require("WeatherState")

local Rainbow = {}
Rainbow.enabled = false


-- Tunables (real seconds).
local FADE_IN = 10.0
local HOLD = 140.0
local FADE_OUT = 22.0
local TOTAL = FADE_IN + HOLD + FADE_OUT

-- Weather ids that count as "still raining" (no rainbow yet).
local function isRainId(id)
  if not id then return false end
  id = tostring(id):upper()
  if id == "RAIN_LIGHT" or id == "RAIN_HEAVY" or id == "HEAVY_RAIN"
      or id == "STORM" or id == "VERDANT_RAIN" or id == "SLEET" then
    return true
  end
  -- Tagged wet + precipitation channel for any future rain-like weather.
  local def = Types.get(id)
  if def and def.wet and def.ch and (def.ch.rain or 0) > 0.05 then
    return true
  end
  return false
end

local function hashStr(s)
  s = tostring(s or "")
  local h = 2166136261
  for i = 1, #s do
    h = (h * 16777619 + s:byte(i)) % 2147483647
  end
  return h
end

-- Map pixel size when the host exposes it; otherwise a generous default so
-- ends still land somewhere on typical Gen 1/2 outdoor maps.
local function mapPixelBounds()
  local w, h = 1280, 1152  -- ~80x72 tiles * 16
  pcall(function()
    local Game = require("src.core.Game")
    local ow = Game and Game.state and Game.state.overworld
    local map = ow and ow.map
    if not map then return end
    local tw = tonumber(map.width) or tonumber(map.w)
    local th = tonumber(map.height) or tonumber(map.h)
    local ts = 16
    if map.tileSize then ts = tonumber(map.tileSize) or 16 end
    if tw and th and tw > 4 and th > 4 then
      w, h = tw * ts, th * ts
    end
  end)
  return w, h
end

-- Two fixed feet for this map. Deterministic so reloading the same map
-- after the same rain spell can regenerate the same places if needed;
-- while active we keep the stored ends so they never drift.
-- WORLD asset: feet are permanent map-pixel coordinates (never camera).
-- Foot A on this map; foot B past the eastern edge into neighbor space.
local function anchorsCrossMap()
  local mw, mh = mapPixelBounds()
  local mapId = tostring(Scene.now and Scene.now.mapId or "map")
  local h1 = hashStr(mapId .. ":bow")
  local tilt = mh * (0.03 + ((h1 % 60) / 60) * 0.08)
  local margin = 24
  local ax = margin + mw * 0.10
  local ay = mh * 0.62 + tilt
  local bx = mw * 1.55
  local by = mh * 0.55 - tilt
  if ay < margin then ay = margin end
  if by < margin then by = margin end
  return ax, ay, bx, by
end

-- Live camera in the same pixel space as map anchors.
local function readCamera()
  local camX = (Scene.now and tonumber(Scene.now.camX)) or 0
  local camY = (Scene.now and tonumber(Scene.now.camY)) or 0
  pcall(function()
    local Game = require("src.core.Game")
    local ow = Game and ((Game.state and Game.state.overworld) or Game.overworld)
    if not ow then return end
    local cam = ow.camera or ow.cam or ow.scroll
    if type(cam) == "table" then
      local x = tonumber(cam.x) or tonumber(cam.scrollX) or tonumber(cam[1])
      local y = tonumber(cam.y) or tonumber(cam.scrollY) or tonumber(cam[2])
      if x then camX = x end
      if y then camY = y end
    end
  end)
  return camX, camY
end

-- Project a world-pixel point into the playfield rect.
-- scale: screen pixels per world pixel (letterbox / diorama scale).
local function worldToScreen(wx, wy, originX, originY, scale)
  local camX, camY = readCamera()
  local s = tonumber(scale) or 1
  if s < 0.25 then s = 1 end
  return originX + (wx - camX) * s, originY + (wy - camY) * s
end

Rainbow.active = false
Rainbow.alpha = 0
Rainbow.age = 0
Rainbow.mapId = nil
Rainbow.ax, Rainbow.ay, Rainbow.bx, Rainbow.by = 0, 0, 0, 0
Rainbow.hadRain = false
Rainbow.lastId = nil

function Rainbow.reset()
  Rainbow.active = false
  Rainbow.alpha = 0
  Rainbow.age = 0
  Rainbow.mapId = nil
  Rainbow.homeMapId = nil
  -- keep last ax/ay/bx/by for debug; they are only used while active
end

function Rainbow.update(dt)
  if Rainbow.enabled == false then Rainbow.active = false; Rainbow.alpha = 0; return end
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end
  if dt > 0.25 then dt = 0.25 end

  local id = State.id
  local raining = isRainId(id)

  if raining then
    Rainbow.hadRain = true
    -- Still in a wet spell (including light → primal): no rainbow yet.
    if Rainbow.active then
      -- Rain returned while a bow was up — clear it.
      Rainbow.reset()
    end
  elseif Rainbow.hadRain and not raining then
    -- Wet spell just ended. Start a map-locked rainbow outdoors only.
    local outdoor = Scene.now and Scene.now.outdoor
    local world = Scene.now and Scene.now.visible == "world"
    if outdoor and world and not Rainbow.active then
      local mapId = Scene.now.mapId or "UNKNOWN"
      Rainbow.mapId = mapId
      Rainbow.ax, Rainbow.ay, Rainbow.bx, Rainbow.by = anchorsCrossMap()
      Rainbow.homeMapId = mapId
      Rainbow.active = true
      Rainbow.age = 0
      Rainbow.alpha = 0
    end
    Rainbow.hadRain = false
  end

  Rainbow.lastId = id

  if not Rainbow.active then return end

  -- Survives map changes (neighbor foot may be on an unloaded map).
  -- Only clear when not on the outdoor overworld.
  if Scene.now then
    if Scene.now.visible ~= "world" or not Scene.now.outdoor then
      Rainbow.reset()
      return
    end
  end

  Rainbow.age = Rainbow.age + dt
  if Rainbow.age >= TOTAL then
    Rainbow.reset()
    return
  end

  if Rainbow.age < FADE_IN then
    Rainbow.alpha = Rainbow.age / FADE_IN
  elseif Rainbow.age < FADE_IN + HOLD then
    Rainbow.alpha = 1
  else
    local t = (Rainbow.age - FADE_IN - HOLD) / FADE_OUT
    Rainbow.alpha = math.max(0, 1 - t)
  end
end

-- Spectral band colours (light → violet), drawn as parallel arcs.
local BANDS = {
  { 0.95, 0.25, 0.22 },
  { 0.95, 0.55, 0.15 },
  { 0.95, 0.88, 0.20 },
  { 0.35, 0.85, 0.35 },
  { 0.30, 0.55, 0.95 },
  { 0.45, 0.30, 0.90 },
  { 0.65, 0.25, 0.80 },
}


function Rainbow.draw(x, y, w, h, scale)
  if Rainbow.enabled == false then return end
  if not Rainbow.active or Rainbow.alpha <= 0.01 then return end
  if not (love and love.graphics) then return end
  scale = scale or 1

  -- World asset projection: ends stay in map space; camera only changes view.
  local a1x, a1y = worldToScreen(Rainbow.ax, Rainbow.ay, x, y, scale)
  local b1x, b1y = worldToScreen(Rainbow.bx, Rainbow.by, x, y, scale)

  -- Arc geometry: span the screen/sky — tall arch, wide color bands.
  local mx, my = (a1x + b1x) * 0.5, (a1y + b1y) * 0.5
  local span = math.sqrt((b1x - a1x) ^ 2 + (b1y - a1y) ^ 2)
  if span < 8 then return end
  -- Arch height from world span (not a fixed screen overlay height).
  local arch = span * 0.42
  if arch < h * 0.35 then arch = h * 0.35 end
  if arch > h * 0.90 then arch = h * 0.90 end

  local alpha = Rainbow.alpha * 0.72
  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local prevBlend, prevMode = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha")
  love.graphics.setLineStyle("smooth")

  local steps = 72
  for bi, col in ipairs(BANDS) do
    local offset = (bi - 4) * (5.5 * scale)   -- wider band separation
    local bandA = alpha * (1.0 - math.abs(bi - 4) * 0.05)
    love.graphics.setColor(col[1], col[2], col[3], bandA)
    love.graphics.setLineWidth(math.max(2.0, 6.0 * scale))  -- thicker ribbons
    local pts = {}
    for i = 0, steps do
      local t = i / steps
      -- Quadratic Bezier-like arch: ends on the ground, peak above midpoint.
      local px = a1x + (b1x - a1x) * t
      local py = a1y + (b1y - a1y) * t - math.sin(t * math.pi) * arch + offset
      pts[#pts + 1] = px
      pts[#pts + 1] = py
    end
    if #pts >= 4 then
      pcall(love.graphics.line, pts)
    end
  end

  -- Soft feet so the player can hunt the ends on the ground.
  local footA = alpha * 0.35
  love.graphics.setColor(1, 1, 1, footA)
  local fr = 8 * scale
  pcall(love.graphics.circle, "fill", a1x, a1y, fr)
  pcall(love.graphics.circle, "fill", b1x, b1y, fr)
  love.graphics.setColor(0.85, 0.9, 1.0, footA * 0.6)
  pcall(love.graphics.circle, "line", a1x, a1y, fr * 1.6)
  pcall(love.graphics.circle, "line", b1x, b1y, fr * 1.6)

  love.graphics.setLineWidth(1)
  if prevBlend then love.graphics.setBlendMode(prevBlend, prevMode) end
  love.graphics.setColor(prevR, prevG, prevB, prevA)
end

function Rainbow.describe()
  if not Rainbow.active then return "off" end
  return string.format("on a=%.2f home=%s cross-map", Rainbow.alpha, tostring(Rainbow.homeMapId or Rainbow.mapId))
end

return Rainbow
