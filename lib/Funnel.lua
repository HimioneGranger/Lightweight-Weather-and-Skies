-- THE FUNNEL.
--
-- Until now a tornado was a warp with a log line: the screen changed and
-- the player was somewhere else, with nothing to say what had happened.
-- An event that moves you against your will should at least announce
-- itself, and the announcement is also the fairness -- a couple of seconds
-- in which it is obvious what is coming.
--
-- =====================================================================
-- WHY IT IS DRAWN AND NOT A PARTICLE WEATHER
-- =====================================================================
--
-- The obvious route is another weather type with its own channels.  It
-- would be wrong: a weather is a field over the whole sky, eased in over
-- seconds and shared by every system; a funnel is one object, in one
-- place, for two and a half seconds, with a beginning and an end.  Putting
-- it in the catalogue would mean a channel that no other weather ever uses
-- and an easing curve fighting a scripted timeline.
--
-- So it is its own pass, with its own clock, drawn over everything else
-- and owning nothing.
--
-- =====================================================================
-- THE SHAPE
-- =====================================================================
--
-- Three things read as a tornado, and none of them is a picture of one:
--
--   1. A COLUMN THAT LEANS AND NARROWS toward the bottom, so the eye reads
--      touchdown rather than a cylinder.
--   2. DEBRIS ON SPIRALS at different radii and speeds -- the same trick
--      the fog banks use for depth.  Points near the top orbit wide and
--      slow, points near the ground fast and tight.
--   3. IT ARRIVES AND LEAVES.  The whole thing scales up from nothing over
--      the first third and the screen darkens as it fills, so the warp
--      lands at the moment the screen is fullest rather than at random.
--
-- Everything is in the frame's own coordinates and scaled by the same
-- pixels-per-GB-pixel the particles use, so it is the same size on a
-- handheld as on a desktop.

local V = ...

local Funnel = {}

Funnel.active = false
Funnel.t = 0
Funnel.duration = 2.5
Funnel.onDone = nil

-- Points are generated once per funnel and then only advanced, so the
-- debris keeps its identity as it orbits rather than reshuffling.
local motes = {}
local MOTES = 90

local function rnd(a, b)
  if love and love.math then return love.math.random() * (b - a) + a end
  return math.random() * (b - a) + a
end

function Funnel.start(seconds, onDone)
  Funnel.active = true
  Funnel.t = 0
  Funnel.duration = math.max(0.4, tonumber(seconds) or 2.5)
  Funnel.onDone = onDone
  motes = {}
  for i = 1, MOTES do
    motes[i] = {
      -- `h` is height up the column, 0 at the ground and 1 at the cloud
      h = rnd(0, 1),
      a = rnd(0, math.pi * 2),        -- angle around the column
      spin = rnd(1.8, 4.2),           -- radians per second
      size = rnd(0.8, 2.4),
      rise = rnd(0.05, 0.30),         -- how fast it climbs
    }
  end
end

function Funnel.stop()
  Funnel.active = false
  Funnel.onDone = nil
end

function Funnel.update(dt)
  if not Funnel.active then return end
  dt = tonumber(dt) or 0
  if dt <= 0 or dt > 0.25 then dt = 1 / 60 end
  Funnel.t = Funnel.t + dt

  for i = 1, #motes do
    local m = motes[i]
    -- Debris spins faster the closer it is to the ground, which is what
    -- makes the column look like it is being wrung out rather than simply
    -- rotating.
    m.a = m.a + m.spin * (1.6 - m.h) * dt
    m.h = m.h + m.rise * dt
    if m.h > 1 then
      m.h = 0
      m.a = rnd(0, math.pi * 2)
    end
  end

  if Funnel.t >= Funnel.duration then
    local done = Funnel.onDone
    Funnel.active = false
    Funnel.onDone = nil
    if done then pcall(done) end
  end
end

-- 0..1, how far through the funnel is.  Used for the darkening as well as
-- the size, so the two cannot disagree.
local function progress()
  return math.min(1, Funnel.t / math.max(0.001, Funnel.duration))
end

function Funnel.draw(x, y, w, h, scale)
  if not Funnel.active then return false end
  if not (love and love.graphics) then return false end
  if w <= 1 or h <= 1 then return false end

  local p = progress()
  -- Grows over the first third, holds, then the very end pulls in: the
  -- warp lands on the fullest frame rather than at an arbitrary moment.
  local grow = math.min(1, p / 0.33)
  local pull = (p > 0.88) and (1 - (p - 0.88) / 0.12) or 1

  local px = math.max(0.5, scale or 1)
  local cx = x + w * 0.5
  local ground = y + h * 0.78
  local top = y - h * 0.05
  local height = ground - top

  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local blend, alphaMode = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha")

  -- the sky closing in, tied to the same progress as the column
  love.graphics.setColor(0.06, 0.05, 0.09, 0.55 * grow * pull)
  love.graphics.rectangle("fill", x, y, w, h)

  -- the column itself: a stack of quads that narrow and lean toward the
  -- ground, drawn dark so the debris reads against it
  local lean = 10 * px
  local steps = 14
  for i = 0, steps - 1 do
    local f = i / (steps - 1)                 -- 0 at the cloud, 1 at the ground
    local wide = (34 - 26 * f) * px * grow * pull
    local yy = top + height * f
    local off = lean * (1 - f) * math.sin(Funnel.t * 2.2 + f * 2)
    love.graphics.setColor(0.16, 0.14, 0.20, 0.55 * grow)
    love.graphics.rectangle("fill", cx + off - wide * 0.5,
      yy, wide, height / steps + 1)
  end

  -- debris on its spirals
  for i = 1, #motes do
    local m = motes[i]
    local f = 1 - m.h                                   -- 0 cloud .. 1 ground
    local radius = (30 - 22 * f) * px * grow * pull
    local yy = top + height * f
    local off = lean * (1 - f) * math.sin(Funnel.t * 2.2 + f * 2)
    local mx = cx + off + math.cos(m.a) * radius
    -- the far half of the orbit is dimmer, which is the whole depth cue
    local depth = (math.sin(m.a) + 1) * 0.5
    local s = m.size * px * (0.6 + depth * 0.6)
    love.graphics.setColor(0.55, 0.50, 0.42, (0.35 + depth * 0.5) * grow)
    love.graphics.rectangle("fill", mx - s * 0.5, yy - s * 0.5, s, s)
  end

  love.graphics.setBlendMode(blend, alphaMode)
  love.graphics.setColor(prevR, prevG, prevB, prevA)
  return true
end

return Funnel
