-- WEATHER ON THE BATTLE SCREEN.
--
-- WHY THIS IS NOT THE PRESENT PASS.  Version 1 drew battle weather in the
-- same whole-frame pass as the overworld's, which worked but was wrong in
-- two ways at once: it drew at window resolution over a 160x144 picture
-- that had already been scaled up, so the drops were a different size in
-- battle than outside it; and it landed after the letterbox, so it had to
-- be scissored back to a rectangle the pass had to be told about.
--
-- `battle.overlay` is the hook that exists for this.  It runs at the end
-- of the battle's own draw, INSIDE the 160x144 battle canvas, in that
-- canvas's coordinates.  Drawing here means:
--
--   * one set of coordinates, whatever the window size, the zoom, or the
--     colour mode -- the battle canvas is always 160x144;
--   * the weather is scaled up with the battle, so a raindrop is the same
--     size relative to the sprites as it is relative to the tiles;
--   * it passes through every later stage the engine applies to that
--     canvas -- SGB zone colouring, the palette remap, GBC FX -- so it
--     looks like part of the game rather than like something painted on
--     the glass afterwards;
--   * and it costs nothing at all when no battle is running, because the
--     hook is not called.
--
-- IT DRAWS THE BATTLE'S WEATHER, NOT THE OVERWORLD'S -- and getting that
-- wrong is what made it rain in a gym.  Version 2.3.x read the overworld
-- channels straight off WeatherState, which meant a battle fought inside a
-- building showed whatever the sky outside was doing.  It also meant a
-- Rain Dance cast in that gym showed nothing at all, because the overworld
-- was clear.  Both are the same mistake from opposite ends.
--
-- `battle.field.weather` is the authority, exactly as it is for every
-- battle EFFECT (lib/Battle.lua).  Indoors nothing seeds it, so nothing
-- draws; a move or an ability that sets it makes weather appear wherever
-- the battle is; and the visuals and the damage multipliers can no longer
-- disagree about what the sky is doing, because they read one field.
--
-- The channels are eased locally rather than snapped, so a Rain Dance
-- landing mid-battle rolls in over a second instead of appearing between
-- two frames.
--
-- IT IS DELIBERATELY THINNER THAN THE OVERWORLD'S.  A battle screen is
-- mostly HUD, and HUD has to stay readable: the BATTLES setting scales the
-- whole pass, the particle count is a fraction of the overworld budget,
-- and the ground splashes are dropped entirely (there is no ground). What
-- is kept is what tells the player what the weather IS -- the grade, the
-- haze and the falling water -- because that is the information the battle
-- effects depend on.

local V = ...
local Types = V.require("Types")
local State = V.require("WeatherState")
local Settings = V.require("Settings")
local Config = V.require("Config")
local Quality = V.require("Quality")
local Lightning = V.require("Lightning")

local BD = {}

-- The battle canvas is NOT always 160x144.  The engine ships a wide battle
-- layout at 304x144 (WideBattle.WIDTH/HEIGHT), switched on by
-- `save.options.battleLayout == "wide"`, and BattleState:uiSize() is the
-- engine's own answer for "how big is my surface".  Hardcoding 160 covered
-- only the left half of a wide battle -- weather in a 4:3 box inside a
-- widescreen fight, which is exactly what it looked like.
--
-- Asked per frame off the battle itself rather than cached: the option can
-- change between battles, and one method call is nothing next to the draw
-- it precedes.
BD.W, BD.H = 160, 144

local function surfaceOf(battle)
  if battle and type(battle.uiSize) == "function" then
    local ok, w, h = pcall(battle.uiSize, battle)
    if ok and type(w) == "number" and type(h) == "number"
        and w > 0 and h > 0 then
      return w, h
    end
  end
  return 160, 144
end

-- The battle screen gets its own small particle field rather than sharing
-- the overworld's, because the two are in different coordinate spaces and
-- swapping the shared pool's rect every frame would rescale every particle
-- twice a frame.  It is a plain table of positions -- a few dozen at most,
-- so the pooling machinery in lib/Particles.lua would cost more than it saved.
local drops = {}
local flakes = {}
local grains = {}
local seeded = false

-- The battle's own eased channels.  Separate from WeatherState's, because
-- they follow a different authority (the field) and have a different
-- lifetime (one battle).
local ch = {}
for _, key in ipairs(Types.channels) do ch[key] = 0 end

-- Which catalogue entry the field's weather should look like.  When the
-- battle's weather matches what the overworld is doing, the OVERWORLD'S
-- entry is used rather than the generic representative -- so a battle
-- fought in a thunderstorm keeps the thunderstorm's lightning instead of
-- being flattened to plain heavy rain, which is what a reverse lookup on
-- its own would give.
local CRYSTAL_WX = {
  rain = "RAINY", sun = "SUNNY", sandstorm = "SANDSTORM",
  sand = "SANDSTORM", hail = "HAIL",
}
local function targetDef(battle)
  if not battle then return nil end
  local weather = nil
  pcall(function()
    weather = battle.field and battle.field.weather
  end)
  -- Crystal 251 stores move weather on battle.weather (lowercase).
  if (not weather or weather == "") and type(battle.weather) == "string" then
    local key = tostring(battle.weather):lower()
    weather = CRYSTAL_WX[key] or tostring(battle.weather):upper()
  end
  -- Persist overworld weather visually even if field seed was missed
  if (not weather or weather == "") and State and State.id then
    pcall(function()
      weather = Types.battleWeather(State.id)
      if not weather then
        local def0 = Types.get(State.id)
        weather = def0 and def0.battle or nil
      end
    end)
  end
  if type(weather) ~= "string" or weather == "" then return nil end
  local ok, def = pcall(function()
    if Types.battleWeather and State and State.id and Types.battleWeather(State.id) == weather then
      return Types.get(State.id)
    end
    return Types.forBattleWeather(weather)
  end)
  if ok and def then return def end
  -- Last resort: draw overworld weather type in battle
  if State and State.id then
    local ok2, d2 = pcall(Types.get, State.id)
    if ok2 and d2 then return d2 end
  end
  return nil
end

local EASE_TAU = 1.1

local function easeChannels(dt, def)
  local k = 1 - math.exp(-dt / EASE_TAU)
  local moving = false
  for _, key in ipairs(Types.channels) do
    local goal = def and Types.channel(def, key) or 0
    local cur = ch[key] or 0
    if cur ~= goal then
      local next_ = cur + (goal - cur) * k
      if math.abs(goal - next_) < 0.0005 then next_ = goal end
      ch[key] = next_
      moving = true
    end
  end
  return moving
end

local function rnd(a, b)
  if love and love.math and love.math.random then return love.math.random() * (b - a) + a end
  return math.random() * (b - a) + a
end

local function seed(list, n)
  for i = #list + 1, n do
    list[i] = { x = rnd(-20, BD.W + 20), y = rnd(-BD.H, BD.H),
                v = rnd(0.75, 1.35), s = rnd(0.7, 1.6), p = rnd(0, 6.28) }
  end
end

-- How many particles the battle screen gets: a fraction of the tier, then
-- the BATTLES setting on top.  Capped low because 160x144 is a small
-- canvas and forty drops on it is a downpour.
local function counts(scale)
  local budget = Quality.budget(1)
  local cap = math.max(6, math.floor(budget.rain / 14))
  return math.floor(cap * scale)
end

function BD.reset()
  drops, flakes, grains, seeded = {}, {}, {}, false
  BD.live = false
  for _, key in ipairs(Types.channels) do ch[key] = 0 end
end

-- The battle's channel table, for the whole-frame compositor in `screen`
-- mode.  Returned by reference and never written by the caller.
function BD.channels()
  return ch
end

-- For the test suite: what the battle screen currently believes.
function BD.channel(key)
  local v = ch[key]
  if type(v) ~= "number" or v ~= v then return 0 end
  return v
end

-- `dt` here is the battle's frame time; the overlay hook has no dt, so the
-- caller passes the one the pipeline update saw.  Motion is advanced in
-- the draw because that is the only time this system is called at all --
-- there is no point simulating a battle overlay while no battle is up.
-- Advance the battle's own eased channels.  Called EVERY battle frame,
-- whether or not this module is the thing drawing them: in `screen` mode
-- the whole-frame compositor draws from these same channels, and if the
-- easing only ran when this module rendered, a widescreen battle would
-- show weather frozen at whatever it was when the battle opened.
function BD.tick(dt, battle)
  local Battle = select(2, pcall(V.require, "Battle"))
  if type(Battle) == "table" and Battle.animEnabled and not Battle.animEnabled() then
    -- FX off: clear residual battle weather visuals immediately.
    easeChannels(1, nil)  -- goals all 0
    for _, key in ipairs(Types.channels) do ch[key] = 0 end
    BD.live = false
    return
  end
  dt = math.min(0.1, math.max(0, dt or 1 / 60))
  easeChannels(dt, targetDef(battle))
  BD.live = true
end

-- True while a battle is on screen, cleared when one ends.  The
-- whole-frame compositor asks this to decide which channel table to read.
BD.live = false

function BD.draw(dt, battle)
  local Battle = select(2, pcall(V.require, "Battle"))
  if type(Battle) == "table" and Battle.animEnabled and not Battle.animEnabled() then return end
  if not Config.visual("battleWeather") then return end
  local scale = Settings.battleScale()
  pcall(function()
    local Compat = V.require("Compat")
    if Compat and Compat.battleProfile then
      local p = Compat.battleProfile()
      if p and p.particleScale then scale = scale * p.particleScale end
    end
  end)
  if scale <= 0 then return end

  -- resize the field to the battle's real surface before anything reads it
  local sw, sh = surfaceOf(battle)
  if sw ~= BD.W or sh ~= BD.H then
    BD.W, BD.H = sw, sh
    seeded = false          -- respawn across the new width
    drops, flakes, grains = {}, {}, {}
  end

  local lightMode = Settings.get("lightning")
  if not Config.visual("lightning") then lightMode = "off" end

  local rainAmt = (ch.rain or 0) * scale
  local snowAmt = (ch.snow or 0) * scale
  local grainAmt = ((ch.hail or 0) + (ch.sand or 0)
    + (ch.ash or 0) + (ch.debris or 0)) * scale
  local dim = (ch.dim or 0) * scale
  local veil = (ch.veil or 0) * scale
  local glare = (ch.glare or 0) * scale
  local flash = Lightning.flash(lightMode)

  if rainAmt < 0.004 and snowAmt < 0.004 and grainAmt < 0.004
      and dim < 0.004 and veil < 0.004 and glare < 0.004 and flash <= 0 then
    return
  end

  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  local prevBlend, prevAlphaMode = love.graphics.getBlendMode()

  -- ------- the grade, under everything
  local lit = math.max(0, dim - flash * 0.55)
  if Config.visual("tint") and (lit > 0.002 or (ch.warm or 0) > 0.002) then
    local cool, warm = ch.cool or 0, (ch.warm or 0) * scale
    local r = 1 - lit * (1 + cool * 0.28) + warm * 0.10
    local g = 1 - lit * (1 + cool * 0.06) - warm * 0.02
    local b = 1 - lit * (1 - cool * 0.48) - warm * 0.16
    love.graphics.setBlendMode("multiply", "premultiplied")
    love.graphics.setColor(math.max(0, math.min(1, r)),
      math.max(0, math.min(1, g)), math.max(0, math.min(1, b)), 1)
    love.graphics.rectangle("fill", 0, 0, BD.W, BD.H)
    love.graphics.setBlendMode("alpha")
  end

  if Config.visual("veil") and veil > 0.004 then
    love.graphics.setColor(0.88, 0.90, 0.94, math.min(0.45, veil * 0.45))
    love.graphics.rectangle("fill", 0, 0, BD.W, BD.H)
  end

  if Config.visual("glare") and glare > 0.004 then
    love.graphics.setBlendMode("add")
    love.graphics.setColor(1.0, 0.94, 0.72, math.min(0.35, glare * 0.30))
    love.graphics.rectangle("fill", 0, 0, BD.W, BD.H)
    love.graphics.setBlendMode("alpha")
  end

  -- ------- what falls
  if Config.visual("precipitation") then
    if not seeded then
      seed(drops, 64); seed(flakes, 64); seed(grains, 64)
      seeded = true
    end

    local lean = math.tan(ch.rainAngle or 0)
    local n = counts(rainAmt)
    for i = 1, math.min(n, #drops) do
      local d = drops[i]
      d.y = d.y + 150 * (ch.rainSpeed or 1) * d.v * dt
      d.x = d.x + 150 * lean * d.v * dt
      if d.y > BD.H then d.y = rnd(-30, -2); d.x = rnd(-20, BD.W + 20) end
      love.graphics.setColor(0.74, 0.83, 0.98, 0.45)
      love.graphics.line(d.x, d.y, d.x - lean * 6 * d.s, d.y - 6 * d.s)
    end

    n = counts(snowAmt)
    for i = 1, math.min(n, #flakes) do
      local f = flakes[i]
      f.p = f.p + dt * 1.4
      f.y = f.y + 26 * (ch.snowSpeed or 1) * f.v * dt
      f.x = f.x + math.sin(f.p) * 10 * (ch.snowDrift or 0) * dt
      if f.y > BD.H then f.y = rnd(-20, -2); f.x = rnd(-10, BD.W + 10) end
      love.graphics.setColor(1, 1, 1, 0.8)
      love.graphics.rectangle("fill", f.x, f.y, math.max(1, f.s), math.max(1, f.s))
    end

    n = counts(grainAmt)
    if n > 0 then
      -- the dominant grain channel decides the look; during a change the
      -- two overlap on the overworld, but 160x144 is too small to show it
      local amounts = { ch.hail or 0, ch.sand or 0, ch.debris or 0, ch.ash or 0 }
      local kind, best = 1, -1
      for k = 1, 4 do
        if amounts[k] > best then kind, best = k, amounts[k] end
      end
      local col = ({ { 0.92, 0.96, 1.0 }, { 0.85, 0.72, 0.48 },
                     { 0.45, 0.42, 0.24 }, { 0.58, 0.55, 0.53 } })[kind]
      for i = 1, math.min(n, #grains) do
        local g = grains[i]
        if kind == 1 or kind == 4 then
          g.y = g.y + (kind == 4 and 60 or 210) * g.v * dt
          g.x = g.x + 20 * dt
        else
          g.x = g.x + 220 * g.v * dt
          g.y = g.y + 22 * g.v * dt
        end
        local falls = (kind == 1 or kind == 4)
        if g.y > BD.H or g.x > BD.W + 20 then
          g.y = rnd(-20, falls and -2 or BD.H)
          g.x = falls and rnd(-10, BD.W + 10) or rnd(-30, -4)
        end
        love.graphics.setColor(col[1], col[2], col[3], 0.75)
        if kind == 1 then
          love.graphics.rectangle("fill", g.x, g.y, 1, math.max(1, g.s * 1.4))
        elseif kind == 4 then
          love.graphics.rectangle("fill", g.x, g.y, math.max(1, g.s), math.max(1, g.s))
        else
          love.graphics.rectangle("fill", g.x, g.y, math.max(2, g.s * 2.4), 1)
        end
      end
    end
  end

  -- ------- lightning, over everything
  if flash > 0 then
    love.graphics.setColor(0.90, 0.93, 1.0, math.min(0.6, flash * 0.5 * scale))
    love.graphics.rectangle("fill", 0, 0, BD.W, BD.H)
  end

  love.graphics.setBlendMode(prevBlend, prevAlphaMode)
  love.graphics.setColor(prevR, prevG, prevB, prevA)
end

return BD
