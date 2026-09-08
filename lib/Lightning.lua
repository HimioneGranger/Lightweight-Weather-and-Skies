-- LIGHTNING.
--
-- Flash + bolt. Bolts are world-anchored like ground splashes (birth playfield
-- pos + camera delta). Strikes only target the OUTER ring of the view so they
-- stay away from the player.
--
-- Reliability: first strike fires quickly once strike-rate > 0; bolts always
-- attempt to draw in FULL mode (quality can only suppress on explicit off).

local V = ...

local L = {}

local function rnd(a, b)
  if love and love.math and love.math.random then return love.math.random() * (b - a) + a end
  return math.random() * (b - a) + a
end

local TILE = 16

L.timer = 0.15          -- short delay before first strike after weather starts
L.age = -1
L.life = 0
L.bolt = nil
L.fork = nil
L.pulses = nil
L.side = 0
L.hitX, L.hitY = 0, 0
L.birthCamX, L.birthCamY = 0, 0
L.birthScale = 1
L.tint = nil
L.justStruck = false
L._hadRate = false

local function displace(points, x1, y1, x2, y2, spread, depth)
  if depth <= 0 then
    points[#points + 1] = x2
    points[#points + 1] = y2
    return
  end
  local mx = (x1 + x2) * 0.5 + rnd(-spread, spread)
  local my = (y1 + y2) * 0.5 + rnd(-spread * 0.2, spread * 0.2)
  local ns = spread * 0.55
  displace(points, x1, y1, mx, my, ns, depth - 1)
  displace(points, mx, my, x2, y2, ns, depth - 1)
end

-- Impact only on outer ring — never near view centre (player).
local function pickFarImpact(viewW, viewH)
  local cx, cy = viewW * 0.5, viewH * 0.5
  local minDist = math.max(TILE * 8, math.min(viewW, viewH) * 0.42)

  for _ = 1, 48 do
    local edge = math.floor(rnd(0, 3.99))
    local ix, iy
    if edge == 0 then
      ix = rnd(TILE * 0.5, viewW * 0.16)
      iy = rnd(viewH * 0.22, viewH * 0.90)
    elseif edge == 1 then
      ix = rnd(viewW * 0.84, viewW - TILE * 0.5)
      iy = rnd(viewH * 0.22, viewH * 0.90)
    elseif edge == 2 then
      ix = rnd(0, 1) < 0.5 and rnd(TILE, viewW * 0.25) or rnd(viewW * 0.75, viewW - TILE)
      iy = rnd(viewH * 0.06, viewH * 0.28)
    else
      ix = rnd(viewW * 0.10, viewW * 0.90)
      iy = rnd(viewH * 0.78, viewH - TILE * 0.25)
      if math.abs(ix - cx) < minDist * 0.4 then
        ix = cx + (ix < cx and -minDist or minDist) * 0.85
      end
    end
    local dx, dy = ix - cx, iy - cy
    if math.sqrt(dx * dx + dy * dy) >= minDist then
      return ix, iy
    end
  end
  local ix = (rnd(0, 1) < 0.5) and rnd(TILE, viewW * 0.14) or rnd(viewW * 0.86, viewW - TILE)
  local iy = (rnd(0, 1) < 0.5) and rnd(viewH * 0.12, viewH * 0.30) or rnd(viewH * 0.82, viewH - TILE)
  return ix, iy
end

local function makeBolt(camX, camY, viewW, viewH, scale)
  camX = tonumber(camX) or 0
  camY = tonumber(camY) or 0
  viewW = math.max(TILE * 6, tonumber(viewW) or 160)
  viewH = math.max(TILE * 6, tonumber(viewH) or 144)
  scale = tonumber(scale) or 1
  if scale < 0.01 then scale = 1 end

  local hitX, hitY = pickFarImpact(viewW, viewH)
  local skyX = hitX + rnd(-TILE * 2.0, TILE * 2.0)
  local skyY = rnd(-TILE * 3.5, TILE * 0.2)

  local points = { skyX, skyY }
  local span = math.max(8, math.abs(hitY - skyY) * 0.10)
  displace(points, skyX, skyY, hitX, hitY, span, 4)
  points[#points + 1] = hitX
  points[#points + 1] = hitY

  local fork = nil
  if #points >= 10 and rnd(0, 1) < 0.7 then
    local i = 2 * math.floor(#points / 6) + 1
    if i + 1 <= #points then
      local fx, fy = points[i], points[i + 1]
      fork = { fx, fy }
      displace(fork, fx, fy, fx + rnd(-TILE * 2.0, TILE * 2.0), fy + rnd(TILE * 0.8, TILE * 2.8), span * 0.4, 3)
    end
  end

  L.hitX, L.hitY = hitX, hitY
  L.birthCamX, L.birthCamY = camX, camY
  L.birthScale = scale
  return points, fork, (skyX < hitX) and -1 or 1
end

local function makePulses(soft)
  if soft then
    return { { 0.0, 1.0 } }, rnd(1.1, 1.6)
  end
  local pulses = { { 0.0, 1.0 } }
  local n = math.floor(rnd(1, 3.99))
  local at = 0
  for _ = 1, n do
    at = at + rnd(0.045, 0.13)
    pulses[#pulses + 1] = { at, rnd(0.35, 0.85) }
  end
  return pulses, at + rnd(0.40, 0.75)
end

local function envelope(age, pulses, soft, life)
  if soft then
    if age < 0 or age > life then return 0 end
    return 0.5 - 0.5 * math.cos(2 * math.pi * (age / life))
  end
  local v = 0
  for i = 1, #pulses do
    local dt = age - pulses[i][1]
    if dt >= 0 then
      v = v + pulses[i][2] * math.exp(-dt * 11)
    end
  end
  return math.min(1, v)
end

function L.update(dt, rate, mode, camX, camY, viewW, viewH, scale)
  mode = mode or "full"
  rate = tonumber(rate) or 0
  if rate < 0 then rate = 0 end

  if mode == "off" or rate <= 0.01 then
    L._hadRate = false
    if L.age >= 0 then
      L.age = L.age + dt
      if L.age > L.life then
        L.age = -1
        L.bolt, L.fork, L.pulses = nil, nil, nil
      end
    end
    return
  end

  -- Weather just gained strike rate: fire soon
  if not L._hadRate then
    L._hadRate = true
    L.timer = math.min(L.timer or 0.15, rnd(0.2, 0.9))
  end

  if L.age >= 0 then
    L.age = L.age + dt
    if L.age > L.life then
      L.age = -1
      L.bolt, L.fork, L.pulses = nil, nil, nil
    end
  end

  L.timer = (L.timer or 0) - dt
  if L.timer > 0 then return end

  -- Schedule next (Poisson); keep gaps reasonable for gameplay
  local mean = 60 / math.max(0.5, rate)
  local u = math.max(1e-4, rnd(0, 1))
  L.timer = math.max(0.8, math.min(12, -math.log(u) * mean))

  local soft = (mode == "soft")
  L.pulses, L.life = makePulses(soft)
  L.age = 0
  L.justStruck = true
  if soft then
    L.bolt, L.fork = nil, nil
    L.side = 0
  else
    L.bolt, L.fork, L.side = makeBolt(camX, camY, viewW, viewH, scale)
  end
end

function L.flash(mode)
  if L.age < 0 or not L.pulses then return 0 end
  return envelope(L.age, L.pulses, mode == "soft", L.life)
end

local function washColour()
  local t = L.tint
  if type(t) == "table" and t[1] then return t[1], t[2], t[3] end
  return 0.88, 0.92, 1.0
end

local function coreColour()
  local t = L.tint
  if type(t) == "table" and t[1] then
    return math.min(1, t[1] * 0.5 + 0.5), math.min(1, t[2] * 0.5 + 0.5), math.min(1, t[3] * 0.5 + 0.55)
  end
  return 0.96, 0.98, 1.0
end

local function project(points, x, y, camX, camY)
  if not points then return nil end
  local dx = (L.birthCamX - (tonumber(camX) or 0)) * (L.birthScale or 1)
  local dy = (L.birthCamY - (tonumber(camY) or 0)) * (L.birthScale or 1)
  local out = {}
  for i = 1, #points, 2 do
    out[i] = x + points[i] + dx
    out[i + 1] = y + points[i + 1] + dy
  end
  return out
end

local function drawPoly(points, width)
  if not points or #points < 4 then return end
  love.graphics.setLineWidth(width)
  -- Prefer a single polyline (more reliable on mobile GLES than many 2-point calls)
  local ok = pcall(function()
    love.graphics.line(unpack(points))
  end)
  if not ok then
    for i = 1, #points - 2, 2 do
      pcall(function()
        love.graphics.line(points[i], points[i + 1], points[i + 2], points[i + 3])
      end)
    end
  end
end

function L.draw(x, y, w, h, alpha, mode, drawBolt, camX, camY)
  local f = L.flash(mode)
  if f <= 0.001 or alpha <= 0 then return end

  local wr, wg, wb = washColour()
  -- Stronger wash so the strike is obvious even if bolt path fails
  love.graphics.setColor(wr, wg, wb, f * 0.72 * alpha)
  love.graphics.rectangle("fill", x, y, w, h)

  if mode ~= "full" then return end
  -- Always try to draw the bolt in FULL mode (ignore quality potato flag)
  if not L.bolt then return end

  local boltA = math.max(0, 1 - L.age * 6) * alpha
  if boltA <= 0.01 then return end

  local bolt = project(L.bolt, x, y, camX, camY)
  local fork = project(L.fork, x, y, camX, camY)
  if not bolt then return end

  local sc = math.max(1, h / 288)
  local cr, cg, cb = coreColour()

  love.graphics.setColor(cr, cg, cb, boltA * 0.40)
  drawPoly(bolt, 4.0 * sc)
  if fork then drawPoly(fork, 2.6 * sc) end

  love.graphics.setColor(1, 1, 1, boltA)
  drawPoly(bolt, 1.4 * sc)
  if fork then drawPoly(fork, 1.0 * sc) end

  local impactA = boltA * math.max(0, 1 - L.age * 10)
  if impactA > 0.02 then
    local dx = (L.birthCamX - (tonumber(camX) or 0)) * (L.birthScale or 1)
    local dy = (L.birthCamY - (tonumber(camY) or 0)) * (L.birthScale or 1)
    local ix = x + L.hitX + dx
    local iy = y + L.hitY + dy
    love.graphics.setColor(1, 1, 1, impactA * 0.65)
    love.graphics.circle("fill", ix, iy, 4.0 * sc)
    love.graphics.setColor(cr, cg, cb, impactA * 0.30)
    love.graphics.circle("fill", ix, iy, 8.0 * sc)
  end

  love.graphics.setLineWidth(1)
end

function L.reset()
  L.timer, L.age, L.life = 0.15, -1, 0
  L.bolt, L.fork, L.pulses = nil, nil, nil
  L.side, L.hitX, L.hitY = 0, 0, 0
  L.birthCamX, L.birthCamY, L.birthScale = 0, 0, 1
  L.tint = nil
  L.justStruck = false
  L._hadRate = false
end

return L
