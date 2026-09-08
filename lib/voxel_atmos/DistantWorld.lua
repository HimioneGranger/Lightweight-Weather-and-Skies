-- Procedural distant world beyond the loaded Kanto map.
--
-- This is deliberately NOT another sky texture. It is painted after Sky has
-- drawn the day/night gradient and celestial body, but before the live 3D
-- depth pass begins. The playable map therefore draws over it, while mountains
-- and forest on the horizon can naturally cover the setting sun/moon.
--
-- At this distance silhouettes and atmospheric perspective carry the illusion
-- more cheaply (and more robustly on Android) than extruding another several
-- kilometres of voxel terrain. Multiple independently scrolling layers give a
-- small amount of parallax as the camera travels, so the horizon does not feel
-- glued to the phone screen.

local V = ...

local Sky = V.require("Sky")
local DayNight = V.require("DayNight")

local DistantWorld = {}

local sin, cos, floor, max, min = math.sin, math.cos, math.floor, math.max, math.min
local PI2 = math.pi * 2

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function mix(a, b, t)
  return a + (b - a) * t
end

local function mix3(a, b, t)
  return { mix(a[1], b[1], t), mix(a[2], b[2], t), mix(a[3], b[3], t) }
end

local function mul3(a, k)
  return { clamp01(a[1] * k), clamp01(a[2] * k), clamp01(a[3] * k) }
end

-- Continuous, cheap ridge noise. Using trigonometric octaves rather than
-- seeded random points means camera parallax can move the sampling coordinate
-- continuously without mountains popping or rebuilding.
local function noise1(x, seed)
  local a = sin(x * 0.91 + seed * 1.73)
  local b = sin(x * 1.87 + seed * 3.11) * 0.46
  local c = cos(x * 3.31 - seed * 0.79) * 0.21
  return (a + b + c) / 1.67
end

local function ridgePoints(w, baseY, amp, wavelength, phase, seed, step)
  local pts = { 0, baseY + 2 }
  step = max(10, step or 22)
  local x = 0
  while x <= w + step do
    local u = (x / max(w, 1)) * wavelength + phase
    -- Mountains should mostly rise above their base rather than oscillate
    -- equally above/below it. Squaring the upper half gives occasional peaks
    -- with broad shoulders instead of a sine-wave skyline.
    local n = noise1(u, seed)
    local peak = 0.22 + 0.78 * (0.5 + n * 0.5)
    peak = peak * peak
    local y = baseY - amp * peak
    pts[#pts + 1], pts[#pts + 2] = x, y
    x = x + step
  end
  pts[#pts + 1], pts[#pts + 2] = w, baseY + 2
  return pts
end

local function treeLine(g, w, baseY, height, phase, color, alpha, scale)
  g.setColor(color[1], color[2], color[3], alpha or 1)
  local spacing = max(7, height * 0.34)
  local shift = ((phase * spacing * 3.7) % spacing) - spacing
  local x = shift
  local i = 0
  while x < w + spacing do
    i = i + 1
    local n = 0.72 + 0.28 * (0.5 + 0.5 * sin(i * 1.71 + phase * 2.3))
    local th = height * n
    local tw = max(5, th * (0.34 + 0.06 * sin(i * 2.17)))
    -- two overlapping triangular crowns make a tiny conifer/forest silhouette
    -- that remains readable even after the final canvas is filtered/scaled.
    g.polygon("fill", x, baseY, x + tw * 0.5, baseY - th,
                       x + tw, baseY)
    g.polygon("fill", x + tw * 0.12, baseY - th * 0.24,
                       x + tw * 0.5, baseY - th * 0.83,
                       x + tw * 0.88, baseY - th * 0.24)
    x = x + spacing
  end
end

-- `edge` is the sky/horizon join in canvas pixels. `cx/cy` are the current
-- world focus. The backdrop is screen-space because it is kilometres away,
-- but the very small focus-dependent phase shifts give each distance layer a
-- distinct parallax rate without ever exposing map boundaries.
function DistantWorld.draw(w, h, edge, sky, cx, cy)
  if not (w and h and w > 0 and h > 0 and sky and sky.bands) then return end
  local g = love and love.graphics
  if not g then return end

  edge = edge or Sky.region(h, nil) or h * Sky.SPAN
  edge = max(1, min(h * 0.55, edge))

  local haze = sky.bands[#sky.bands] or { sky[1] or 0.55, sky[2] or 0.72, sky[3] or 0.84 }
  local upper = sky.bands[max(1, #sky.bands - 1)] or haze
  local tint = DayNight.tint(true)

  -- Atmospheric perspective: the farther a layer is, the more sky/haze it
  -- inherits. Near forest is still heavily desaturated because it is far past
  -- the playable map, but remains dark enough to read as land rather than sea.
  local landBase = mix3(haze, { 0.22 * tint[1], 0.34 * tint[2], 0.24 * tint[3] }, 0.44)
  local farMount = mix3(haze, { 0.23 * tint[1], 0.30 * tint[2], 0.34 * tint[3] }, 0.34)
  local midMount = mix3(haze, { 0.16 * tint[1], 0.26 * tint[2], 0.24 * tint[3] }, 0.55)
  local hills = mix3(haze, { 0.12 * tint[1], 0.24 * tint[2], 0.16 * tint[3] }, 0.66)
  local forest = mix3(haze, { 0.055 * tint[1], 0.15 * tint[2], 0.075 * tint[3] }, 0.78)

  local oldShader = g.getShader and g.getShader() or nil
  local oldBlend, oldAlpha
  if g.getBlendMode then oldBlend, oldAlpha = g.getBlendMode() end
  g.setShader()
  if g.setBlendMode then g.setBlendMode("alpha", "alphamultiply") end

  -- A distant ground plane replaces the endless blue void below the map edge.
  -- Several haze-weighted strips fake kilometres of depth; the real voxel map
  -- paints over all of this a moment later.
  local bandH = max(10, h * 0.055)
  for i = 0, 5 do
    local y0 = edge + i * bandH
    local t = i / 5
    local c = mix3(landBase, hills, t * 0.72)
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", 0, y0, w, max(bandH + 2, h - y0))
  end

  -- Camera movement only nudges far scenery. Vertical/southward travel is
  -- folded into the same phase so routes in every orientation still feel
  -- surrounded by one continuous Kanto rather than a panorama strip.
  cx, cy = cx or 0, cy or 0
  local travel = cx * 0.0041 + cy * 0.0027
  local step = max(12, floor((w / 44) + 0.5))

  -- Far mountains: broad and hazy, with the tallest ridge deliberately rising
  -- into the sky enough that a low sun/moon can disappear behind it.
  local farBase = edge + h * 0.025
  local farPts = ridgePoints(w, farBase, h * 0.105, 8.0,
                              travel * 0.055, 2.6, step * 1.5)
  g.setColor(farMount[1], farMount[2], farMount[3], 0.95)
  g.polygon("fill", farPts)

  -- Mid mountain chain: different scale/phase = visible but very slow parallax.
  local midBase = edge + h * 0.058
  local midPts = ridgePoints(w, midBase, h * 0.077, 11.5,
                              travel * 0.095 + 1.8, 4.9, step)
  g.setColor(midMount[1], midMount[2], midMount[3], 0.98)
  g.polygon("fill", midPts)

  -- Low rolling foothills close the valleys between mountain silhouettes.
  local hillBase = edge + h * 0.094
  local hillPts = ridgePoints(w, hillBase, h * 0.043, 17.0,
                               travel * 0.145 + 3.7, 8.1, step * 0.75)
  g.setColor(hills[1], hills[2], hills[3], 1)
  g.polygon("fill", hillPts)

  -- Two forest belts give the final horizon a populated-world texture. Their
  -- independent parallax is the strongest backdrop motion, still tiny compared
  -- with anything on the actual map.
  treeLine(g, w, edge + h * 0.119, h * 0.026,
           travel * 0.19 + 0.6, mix3(forest, haze, 0.24), 0.94)
  treeLine(g, w, edge + h * 0.140, h * 0.038,
           travel * 0.27 + 2.2, forest, 1)

  -- A thin atmospheric veil at the horizon prevents a hard join between sky,
  -- mountain feet and the curved edge of the playable map.
  local veil = mix3(haze, upper, 0.20)
  g.setColor(veil[1], veil[2], veil[3], 0.16)
  g.rectangle("fill", 0, edge - h * 0.006, w, h * 0.032)

  g.setColor(1, 1, 1, 1)
  if g.setBlendMode and oldBlend then g.setBlendMode(oldBlend, oldAlpha) end
  if oldShader then g.setShader(oldShader) else g.setShader() end
end

return DistantWorld
