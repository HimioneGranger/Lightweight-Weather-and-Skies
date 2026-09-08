-- =====================================================================
-- AI ASSISTANTS: read AGENTS.md in this folder before editing.
--
-- It is two minutes and it covers the five ways this codebase has actually
-- broken -- all of which failed SILENTLY -- plus the tools/ suite that finds
-- them. Most relevant here: engine modules must be required at CALL time,
-- never at file scope, or you get the Gen 1 implementation on a Gold boot.
--   python3 tools/run_all.py --lua
-- =====================================================================

-- WEATHER FX -- dynamic weather for Gen1Recomp, overworld and battle.
--
-- =====================================================================
-- ARCHITECTURE
-- =====================================================================
--
-- THE PROBLEM.  Weather has to draw over whatever is rendering the world,
-- and the engine has several: the flat tile blit, the same blit under the
-- TILT mesh, the same again through the survey zoom, all of them in any of
-- the colour modes, optionally with the GBC FX grid on top -- and, if the
-- player has it, Dramatic Shape's voxel diorama, which replaces the world
-- pass entirely.  A mod that hooked one of those would break on the rest.
--
-- THE ANSWER is the render_pipelines registry, and specifically the fact
-- that ONE RECORD MAY DECLARE MORE THAN ONE STAGE.  This mod declares
-- both whole-frame stages, and uses a third hook for battles:
--
--   worldPresent(canvas, ctx)   over the finished WORLD image, before the
--                               UI composites -- but only when some
--                               pipeline produced a world image, i.e.
--                               only when a diorama-style renderer is on.
--                               Weather here lands under the dialog boxes.
--
--   present(canvas, ctx)        over the finished whole frame -- ALWAYS.
--                               This is the path for the flat renderer,
--                               tilt, zoom and every colour mode, because
--                               it runs on the finished composite and
--                               therefore cannot care how it was made.
--
--   battle.overlay(battle)      inside the battle's own 160x144 canvas.
--                               Not a pipeline stage at all: it is where
--                               battle weather belongs, because it is the
--                               only place that is in the battle's
--                               coordinates and passes through the
--                               battle's own palette handling.
--
-- Per frame exactly one whole-frame stage draws.  `worldPresent` sets a
-- flag; `present` sees it, clears it, and hands its canvas straight back.
-- Add a third-party world pipeline tomorrow and this mod supports it
-- unchanged, because NOTHING ON THE DRAW PATH NAMES ANY RENDERER.
--
-- INDEPENDENCE.  Version 1 borrowed Dramatic Shape's day/night clock,
-- which meant no night without that mod.  This one carries its own
-- (lib/TimeOfDay.lua) and defers to Dramatic Shape's only when it is
-- there -- so the Gold/Silver day/night grade, the `world.tod` value other
-- mods read, and the time-of-day weather weighting all work standalone.
--
-- THE LADDER IS THE WEATHER PICKER.  The registry hands a pipeline an
-- OFF/1/2/3 ladder with an OPTIONS row, a hotkey, persistence and a gate.
-- Rather than spend that on an intensity slider, level 1 is AUTO and
-- levels 2+ pin a weather type, so the player picks the weather from the
-- menu they already use for TILT and ZOOM.
--
-- COST WHEN NOTHING IS HAPPENING IS ZERO, and `available` enforces it.
-- The engine re-reads it every frame and only allocates the present canvas
-- when some pipeline wants the stage (Pipelines.wantsPresent), so this
-- answers false whenever there is nothing to draw -- OFF, clear skies at
-- midday, indoors, or a full-screen menu over the world -- and on those
-- frames the engine's composite is the vanilla one, byte for byte.
--
-- FAILURE IS SURVIVABLE BY CONSTRUCTION.  A pipeline callback that throws
-- is retired for the session, attributed to this mod in the manager's
-- error feed, and the frame falls back to the vanilla path.  The worst
-- case for a bug anywhere in lib/ is that the player loses the weather,
-- never the game -- which is why the draw path is allowed to be the
-- interesting part and the state machine is written to be boring.
--
-- WHAT IS NOT TOUCHED.  Collision, movement, encounters, scripts, warps,
-- saves and audio.  Battles are touched only through the documented
-- hooks, only when weather is actually in the field, and the one thing
-- that PUTS weather in a field that would otherwise be empty -- seeding
-- from the overworld -- is behind an opt-in ruleset by default.
--
-- =====================================================================

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules require each other through V rather than package.path: a
-- mod directory is not on it, and may live inside a mounted .love archive
-- that plain require cannot reach.  Each module is loaded once, with V
-- passed in as its vararg (`local V = ...`).  The same shape Dramatic
-- Shape uses, deliberately -- an author who has read one of these mods can
-- read the other.

local V = { mod = mod, path = mod.path, questLitePrivate = true }

-- LuaJIT (what LÖVE 11 runs) has both `loadstring` and a 5.2-style `load`
-- that takes a string; plain 5.1 has only the former and 5.4 only the
-- latter.  Picking here means the same file compiles under the game, under
-- the modkit's validator, and under a bare interpreter running the tests.
local loadChunk = loadstring or load

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("weather_fx: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = loadChunk(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("weather_fx: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
V.privateGraphicsEnvironment = setmetatable({graphics=love.graphics},{__index=love})
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value
  if name=="NightSky" then
    local src="local _, environment = ...; local love = environment;\n"..assert(mod:read("lib/NightSky.lua"))
    value=assert(loadChunk(src,"@weather/NightSky"))(V,V.privateGraphicsEnvironment)
  else value = chunkFor("lib/" .. name .. ".lua")(V) end
  modules[name] = value
  return value
end

local Config = V.require("Config")
Config.load()          -- first, because everything else reads it

-- The engine's own pipeline registry and the live save options, both
-- pcall'd and both optional: this is the only place in the mod that
-- WRITES engine state, and it does so on exactly one number (the weather
-- pipeline's ladder level) at the player's explicit request.
local function enginePipelines()
  local ok, P = pcall(require, "src.render.Pipelines")
  if ok then return P end
  return nil
end

local function saveOptions()
  local ok, opts = pcall(function()
    local Game = require("src.core.Game")
    return Game and Game.save and Game.save.options or nil
  end)
  if ok then return opts end
  return nil
end

local Types = V.require("Types")
local Settings = V.require("Settings")
local Scene = V.require("Scene")
local TOD = V.require("TimeOfDay")
local Seasons = V.require("Seasons")
local State = V.require("WeatherState")
local Quality = V.require("Quality")
local Particles = V.require("Particles")
local Lightning = V.require("Lightning")
local Ladder = V.require("Ladder")
local Draw = V.require("Draw")
local BattleDraw = V.require("BattleDraw")
local Compat = V.require("Compat")
local Battle = V.require("Battle")
local Interop = V.require("Interop")
local Backgrounds = V.require("Backgrounds")
local BattleField = V.require("BattleField")
local function noop() end
local Lite = {
  Follower = { update = noop },
  Encounters = { install = function() return false end },
  WeatherVariants = {
    install = function() return false end,
    bindPokedex = noop,
    installWildsCompat = noop,
    installBattleArtCompat = noop,
    variantForBase = function() return nil end,
    variantsForBase = function() return {} end,
  },
  PrimalGifts = { install = noop, update = noop, claimToday = function() return nil end },
  WeatherEncounterAPI = {
    bind = noop,
    route = function() return nil end,
    species = function() return nil end,
    public = function() return {} end,
  },
  WeatherCompanionBridge = {
    install = noop,
    status = function() return { enabled = false, reason = "quest-lite" } end,
  },
  Tornado = {
    update = noop,
    origin = function() return nil end,
    carry = function() return false end,
  },
  Pokegear = { install = noop },
}
local Follower = V.questLitePrivate and Lite.Follower or V.require("Follower")
local Encounters = V.questLitePrivate and Lite.Encounters or V.require("Encounters")
local WeatherVariants = V.questLitePrivate and Lite.WeatherVariants or V.require("WeatherVariants")
local PrimalGifts = V.questLitePrivate and Lite.PrimalGifts or V.require("PrimalGifts")
local WeatherEncounterAPI = V.questLitePrivate and Lite.WeatherEncounterAPI or V.require("WeatherEncounterAPI")
local WeatherCompanionBridge = V.questLitePrivate and Lite.WeatherCompanionBridge or V.require("WeatherCompanionBridge")
local Tornado = V.questLitePrivate and Lite.Tornado or V.require("Tornado")
local Audio = V.require("Audio")

-- WX_SFX_REGISTER: expose weather beds to the engine audio registry so
-- Sound.play / host volume tables can see them (optional; path play still works).
do
  local names = {
    rain = "assets/sounds/rain.ogg",
    rain_heavy = "assets/sounds/rain_heavy.ogg",
    heavy_storm = "assets/sounds/heavy_storm.ogg",
    storm = "assets/sounds/storm.ogg",
    wind = "assets/sounds/wind.mp3",
    wind_desert = "assets/sounds/wind_desert.mp3",
    thunder_clap = "assets/sounds/thunder_clap.mp3",
    thunder_roll = "assets/sounds/thunder_roll.mp3",
    thunder_zapdos = "assets/sounds/thunder_zapdos.mp3",
  }
  pcall(function()
    if not (mod and mod.content and mod.content.sfx and mod.content.sfx.register) then return end
    for id, file in pairs(names) do
      pcall(function()
        mod.content.sfx:register("WX_" .. id:upper(), { file = file })
      end)
    end
  end)
end

local Pokegear = V.questLitePrivate and Lite.Pokegear or V.require("Pokegear")

-- Optional 3D atmosphere bridge (Kanto path). Fail-closed at every step:
-- missing file, init failure, or incompatible voxel mod all leave a
-- no-op stub so Weather FX's normal post-process path is unchanged.
local VoxelAtmos = (function()
  local ok, bridge = pcall(V.require, "VoxelAtmosBridge")
  if ok and bridge then
    pcall(bridge.init)
    return bridge
  end
  return {
    active = function() return false end,
    handlesPrecipitation = function() return false end,
    handlesFog = function() return false end,
    handlesClouds = function() return false end,
    syncFromWeatherFx = function() end,
    update = function() end,
    invalidate = function() end,
    reason = function() return "bridge-unavailable" end,
  }
end)()

-- Optional engine APIs: a failure here must NOT prevent the mod from loading.
-- (Older builds / partial loaders have been seen without commands or rulesets.)
do
  pcall(PrimalGifts.install)
  local function ensureOptions()
    local ok, err = pcall(Settings.define)
    if not ok then
      pcall(function() mod.log:warn("settings define failed: %s", tostring(err)) end)
    end
  end
  ensureOptions()
  -- Host may rebuild option tables during boot; re-register on common events.
  pcall(function()
    if mod.hooks and mod.hooks.on then
      mod.hooks:on("game.ready", ensureOptions)
      mod.hooks:on("game.start", ensureOptions)
      mod.hooks:on("save.loaded", ensureOptions)
    end
  end)
  pcall(function()
    if mod.events and mod.events.on then
      mod.events:on("save.loaded", ensureOptions)
      mod.events:on("save.created", ensureOptions)
    end
  end)
  ensureOptions()
  -- Register Weather FX's weather-form species before encounter hooks are live.
  -- They are real merged species records, so Kanto Companion and any other
  -- read-only encounter consumer can inspect them exactly like ordinary mons.
  if not (mod.find and mod:find("CRYSTAL_251")) then
    local vok, verr = pcall(WeatherVariants.install)
    if not vok then
      pcall(function() mod.log:warn("weather variants install failed: %s", tostring(verr)) end)
    end
  end
  local ok, err = pcall(Encounters.install)
  if not ok then
    pcall(function() mod.log:warn("encounters install failed: %s", tostring(err)) end)
  end
  if not V.questLitePrivate then
    ok, err = pcall(Battle.install)
    if not ok then
      pcall(function() mod.log:warn("battle install failed: %s", tostring(err)) end)
    end
  end
end

-- ------- is there anything to draw?
--
-- The gate that keeps a clear midday free.  Any visible channel above a
-- threshold, a strike still in the air (which outlives the storm channel
-- by a fraction of a second), or a time-of-day grade that is not neutral.
-- `ash` belongs here: without it an ashfall on its own answered "nothing
-- to draw" and the pipeline was never eligible.
local VISIBLE_CHANNELS = { "rain", "snow", "hail", "sand", "ash", "debris",
                           "fog", "veil", "dim", "warm", "glare", "psy" }

local function anythingToDraw()
  local ch = Draw.channels()
  for i = 1, #VISIBLE_CHANNELS do
    local v = ch[VISIBLE_CHANNELS[i]]
    if type(v) == "number" and v > 0.004 then return true end
  end
  return Lightning.flash(Settings.get("lightning")) > 0.001
end

-- The rect the whole-frame stages draw into.  Shared by both pipelines so
-- the grade and the weather cannot disagree about where the screen is.
--
-- The engine reports two rects and hands this stage neither:
-- `gameWidth/gameHeight` from render.hud are the INTEGER-scaled 160x144
-- game rect, while the world is composited across the whole window through
-- a separate non-integer UI fit.  On a handheld the two differ a lot, so
-- the default is the whole canvas.
local function frameRect(canvas, ctx)
  local vp = Scene.viewport
  local cw, ch = canvas:getDimensions()
  local x, y, w, h
  if Config.get().coverage == "playfield" and vp then
    x, y, w, h = vp.x, vp.y, vp.w, vp.h
  else
    x, y, w, h = 0, 0, cw, ch
  end
  -- SCALE from the playfield height in canvas units, not ctx.scale: that
  -- is Sp, framebuffer PIXELS per GB pixel, and this canvas is in units,
  -- so the two differ by the DPI factor on a high-DPI panel.
  local scale = ((vp and vp.h) or h) / 144
  if not (scale > 0.05) then scale = (ctx and ctx.scale) or 1 end
  return x, y, w, h, scale
end

-- ------- the pipeline
--
-- One record, two whole-frame stages.  `drewThisFrame` is the handshake.

local drewThisFrame = false

-- A full-frame weather pass becomes paint on the floating Game Boy panel in
-- Quest VR. The private build has a deliberately small voxel bridge, so the
-- overworld compositor must stay clean even if that bridge fails. This makes
-- rendering failures obvious instead of silently putting rain back on the UI.
local function questVrWorld()
  return V.questLitePrivate and Scene.now
    and Scene.now.visible ~= "battle"
end

mod.content.render_pipelines:register("weather", {
  label = "WEATHER",
  levels = State.LEVEL_LABELS,

  -- Below Dramatic Shape's voxel (20) and tiltshift (10) so three things
  -- fall out at once: the OPTIONS rows sort mode-then-post-process-then-
  -- weather, a world pipeline keeps the world pass, and the worldPresent
  -- fold reaches this pass AFTER a tilt-shift blur -- so rain stays sharp
  -- over a blurred diorama instead of being smeared into it.
  priority = 5,

  -- 0 is free: the engine claims 1-5 and F1/F2/F10, and Dramatic Shape
  -- claims 3 and 5-9.  Declared through the registry, which is checked
  -- after the engine's own display keys, so this can never shadow one --
  -- and Dramatic Shape's keypressed wrap passes unclaimed keys through.
  hotkey = "0",

  available = function()
    if not Particles.ready() then return false end
    if (State.level or 0) <= 0 then return false end
    local alpha = Scene.drawScale(Settings)
    if alpha <= 0 then return false end
    return anythingToDraw()
  end,

  -- Ticked whatever the level and whatever is on screen, which is what a
  -- weather clock wants: a storm keeps raging while the player is in a
  -- menu, in a battle, or inside a building, and is still there when they
  -- come out.  (At level 0, State.update returns immediately.)
  update = function(dt, level)
    -- Debug rain has to move the ENGINE's ladder, not a copy of it: the
    -- engine refuses to run any stage at level 0 before it asks this mod
    -- anything, so a shadow level would pin the weather and draw nothing.
    -- Done first, and the pushed value is used for the rest of the tick,
    -- so the switch takes effect on the frame it is flipped rather than
    -- the one after.
    if Settings.debugRain(Config) or Ladder.raisedByUs() then
      local pushed = Ladder.enforce(enginePipelines(), Settings.debugRain(Config),
        saveOptions())
      if pushed then level = pushed end
    end
    Scene.sample()
    -- Seasons: compute id, fire change banners, tick notify timer, map place banner.
    -- (Was only Seasons.onMap — Seasons.update never ran, so seasons appeared "stuck".)
    if not V.questLitePrivate then
      pcall(function()
        Seasons.update(dt, Scene.now and Scene.now.mapId)
      end)
    end
    -- Clock / NightSky / building light: ticked here so TIME need not be an
    -- OPTIONS ladder row (Settings "TIME OF DAY" remains in the mod menu).
    pcall(function()
      if TOD._forceOffByHost then
        TOD.pin = nil
      end
      TOD.update(dt)
    end)
    if not V.questLitePrivate then
      pcall(function()
        local BL = V.require("BuildingLight")
        if BL and BL.update then BL.update(dt) end
      end)
    end
    pcall(function()
      local NightSky = V.require("NightSky")
      if NightSky and NightSky.update then NightSky.update(dt) end
    end)
    do
      local ok, err = pcall(function()
        local sc = Scene and Scene.now or {}
        State.update(dt, level, sc.mapId, sc.indoors)
      end)
      if not ok then
        pcall(function() mod.log:warn("State.update failed: %s", tostring(err)) end)
        if type(State.ch) == "table" then
          for k in pairs(State.ch) do State.ch[k] = 0 end
        end
      end
    end
    if V.questLitePrivate then V.require('QuestStormFront').update(dt,State,Settings) end
    if V.questLitePrivate then V.require('QuestStorm').update(dt,State,Settings) end
    if V.questLitePrivate then V.require('QuestAfterStorm').update(dt,State,Settings) end
    Draw.update(dt, level)
    -- Drive the optional 3D atmosphere from the same weather state so the
    -- two paths cannot disagree. No-op stub when the bridge is inactive.
    VoxelAtmos.syncFromWeatherFx(State, Settings)
    VoxelAtmos.update(dt)
    Follower.update(dt)
    Tornado.update(dt)
    Audio.update(dt)
    -- Calendar gifts are independent of the active weather and WX encounter
    -- rolls; WX only decides whether the awarded species is a form or base.
    PrimalGifts.update(dt)
  end,

  -- THE DIORAMA PATH.  Only reached when a world pipeline produced a world
  -- image, so reaching it at all is the signal that the flat path must not
  -- run this frame.  The incoming canvas is drawn into directly rather
  -- than copied: it is rebuilt from scratch every frame by whoever made
  -- it, and an extra full-screen canvas per frame to avoid touching it
  -- would be the most expensive thing in this mod.
  --
  -- No text-box cut here: this stage composites UNDER the UI already, so
  -- the dialog box is drawn on top of the weather by the engine.
  worldPresent = function(canvas, ctx)
    if questVrWorld() then
      drewThisFrame = true
      return canvas
    end
    local w, h = canvas:getDimensions()
    local previous = love.graphics.getCanvas()
    love.graphics.setCanvas(canvas)
    local ok = Draw.frame(0, 0, w, h, ctx and ctx.scale or 1, false)
    -- Route/season banner only in present (final composite), never here
    love.graphics.setCanvas(previous)
    drewThisFrame = ok
    return canvas
  end,

  -- THE FLAT PATH -- and every other path the engine has, because this
  -- runs on the finished composite whatever produced it.  Scissored to the
  -- playfield the render.hud hook captured, so rain falls on the game and
  -- not in the black bars, and clipped above an open dialog box so it
  -- lands behind the text rather than on it.
  present = function(canvas, ctx)
    if drewThisFrame then
      drewThisFrame = false
      return canvas
    end
    if questVrWorld() then return canvas end
    local x, y, w, h, scale = frameRect(canvas, ctx)
    local previous = love.graphics.getCanvas()
    love.graphics.setCanvas(canvas)
    Draw.frame(x, y, w, h, scale, true)
    love.graphics.setCanvas(previous)
    return canvas
  end,

  invalidate = function()
    Draw.invalidate()
    Audio.invalidate()
    BattleDraw.reset()
    Backgrounds.invalidate()
    Interop.reset()
    Quality.reset()
    VoxelAtmos.invalidate()
  end,
})

-- Seasonal notices are UI, not weather particles. Drawing them from the HUD
-- keeps them alive on clear frames where the weather present stage correctly
-- declines to allocate a compositor canvas.
mod.hooks:wrap("render.hud", function(next, game, viewport)
  local result = next(game, viewport)
  Scene.setViewport(viewport)
  if Scene.now and Scene.now.visible == "world" then
    pcall(function() Seasons.drawNotify(viewport) end)
  end
  return result
end, -1000)


-- TIME ladder removed from in-game OPTIONS (render pipeline).
-- Clock still runs from the WEATHER pipeline update above.
-- Players toggle time behaviour via mod Settings → TIME OF DAY.
-- Grade draw (Draw.grade) is optional via Settings/config only when wanted.


-- boot. What differs is who asks for them. Gen 1's options menu calls
-- `Pipelines.rows(game)` itself and splices the result in after TILT
-- (src/ui/OptionsMenu.lua). Gold's does not call it at all
-- (src/ui/gen2/OptionsMenu.lua) -- it raises `ui.options.rows` and takes
-- what comes back. So the row has to be handed to it.
--
-- GEN 2 ONLY, deliberately. On Gen 1 the engine already splices these rows;
-- adding them here as well would show WEATHER and TIME twice.
--
-- OURS ONLY, not every registered pipeline. `Pipelines.rows` returns a row
-- for every pipeline any mod registered, so appending the lot would mean two
-- mods applying this same fix each add the other's rows. Filtering to the
-- two ids this mod owns keeps the fix additive.
--
-- And it is idempotent: if a later engine build starts splicing pipeline
-- rows into Gold's options the way Gen 1 does, the ids will already be in
-- the incoming list and nothing is added. That check is why this cannot
-- become a duplicate-row bug later.
-- Gen 2 OPTIONS: additive WEATHER row only. Hardened for other UI mods:
--   * always call next_ first (preserve full chain)
--   * never mutate the table other mods returned
--   * only append our pipeline id if missing
--   * any failure → return prior rows unchanged (menu must not break)
if Battle.isGen2() and not mod._wxOptionsRowsWrapped then
  mod._wxOptionsRowsWrapped = true
  local OUR_ID = "pipeline:weather"

  mod.hooks:wrap("ui.options.rows", function(next_, game, rows)
    local out = rows
    local okNext, nextOut = pcall(function()
      if type(next_) == "function" then return next_(game, rows) end
      return rows
    end)
    if okNext then out = nextOut end
    if type(out) ~= "table" then return out end

    local ok, merged = pcall(function()
      local present = {}
      for _, row in ipairs(out) do
        if type(row) == "table" and type(row.id) == "string" then
          present[row.id] = true
        end
      end
      if present[OUR_ID] then return out end

      local addRow = nil
      pcall(function()
        local Pipelines = require("src.render.Pipelines")
        if Pipelines and type(Pipelines.rows) == "function" then
          for _, row in ipairs(Pipelines.rows(game) or {}) do
            if type(row) == "table" and row.id == OUR_ID then
              addRow = row
              break
            end
          end
        end
      end)
      -- Fallback descriptor if Pipelines is unavailable (UI mod / engine variance).
      if not addRow then
        addRow = { id = OUR_ID, label = "WEATHER", pipeline = "weather" }
      end

      local copy = {}
      for i = 1, #out do copy[i] = out[i] end
      copy[#copy + 1] = addRow
      return copy
    end)

    if ok and type(merged) == "table" then return merged end
    return out
  end)
end

-- ------- events

-- The weather is world state, so it is restored with the world.  `settle`
-- inside restore() snaps the channels to it, which is why loading into a
-- storm shows a storm on the first frame rather than fading one up.
mod.events:on("save.loaded", function() State.restore(); if V.questLitePrivate then Audio.invalidate() end end)
mod.events:on("save.created", function() State.restore(); if V.questLitePrivate then Audio.invalidate() end end)
mod.events:on("save.writing", function() State.persist() end)

-- A battle ending drops the battle overlay's own little particle field, so
-- the next battle does not open with the last one's rain already halfway
-- down the screen.
mod.events:on("battle.ended", function() BattleDraw.reset() end)


-- Stars/planets when TIME is NITE (or real night), independent of 3D atmos.
local function wxPaintCelestialDisc(body, edge, cell, w, h)
  if not (body and body.x and body.y and love and love.graphics) then return end
  local g = love.graphics
  cell = math.max(1, tonumber(cell) or 4)
  edge = tonumber(edge) or h
  local moon = body.moon and true or false
  -- Moon: cool grey pixel blocks only (no orange/warm rim).
  -- Sun: warm cells, glow only for sun and never at night (caller zeros glowAmt).
  local shades
  if moon then
    -- White moon with grey spots (no warm/orange tint).
    shades = {
      { 255, 255, 255 },  -- core white
      { 230, 232, 236 },  -- mid
      { 160, 164, 172 },  -- crater spots
      { 200, 204, 210 },  -- edge grain
    }
  else
    shades = {
      { 248, 240, 200 },
      { 248, 208, 96 },
      { 248, 144, 80 },
      { 200, 120, 48 },
    }
  end
  local DISC_FRAC, DISC_MIN = 0.028, 3
  local rCells = math.max(DISC_MIN, math.floor(h * DISC_FRAC / cell + 0.5))
  -- Never grow the disc for moon; never use glowAmt on moon (orange ring source).
  if (not moon) and (body.glowAmt or 0) > 0.25 then
    rCells = rCells + math.max(1, math.floor(rCells * 0.35))
  end
  local bx = math.floor(body.x / cell) * cell + cell / 2
  local by = math.floor(body.y / cell) * cell + cell / 2
  -- Keep disc on sky plate (never cull just because of edge math).
  if by < 0 then by = rCells * cell end
  if by > edge * 0.9 then by = edge * 0.85 end
  local sx, sy, sw, sh
  pcall(function()
    if g.getScissor then sx, sy, sw, sh = g.getScissor() end
    if g.setScissor then g.setScissor(0, 0, math.ceil(w), math.floor(edge)) end
  end)
  -- Alpha blend only — no additive halo that reads as an orange ring.
  pcall(g.setBlendMode, "alpha", "alphamultiply")
  local craterR = math.max(1, math.floor(rCells / 5))
  local MOON_CRATERS = { {-0.4,-0.2},{0.2,0.45},{0.5,-0.4},{-0.15,0.7},{0.05,0.05} }
  for dy = -rCells, rCells do
    for dx = -rCells, rCells do
      local d = math.sqrt(dx * dx + dy * dy)
      if d <= rCells + 0.05 then
        local c
        if d <= rCells * 0.45 then
          c = shades[1]
        elseif d <= rCells * 0.85 then
          c = shades[2]
        else
          -- Jagged pixel edge (checker) — grainy, not smooth rim
          if ((dx + dy) % 2) ~= 0 then
            c = shades[4]
          else
            c = shades[2]
          end
        end
        if moon then
          for _, cr in ipairs(MOON_CRATERS) do
            local cdx = dx - math.floor(cr[1] * rCells + 0.5)
            local cdy = dy - math.floor(cr[2] * rCells + 0.5)
            if cdx * cdx + cdy * cdy <= craterR * craterR then c = shades[3] end
          end
        end
        -- Drop some edge pixels for a more pixelated silhouette
        local keep = d <= rCells - 0.85 or ((dx * 3 + dy * 5) % 4) ~= 0
        if keep then
          pcall(g.setColor, c[1]/255, c[2]/255, c[3]/255, 1)
          pcall(g.rectangle, "fill", bx + dx * cell - cell/2, by + dy * cell - cell/2, cell, cell)
        end
      end
    end
  end
  pcall(g.setColor, 1, 1, 1, 1)
  pcall(function()
    if g.setScissor then
      if sx then g.setScissor(sx, sy, sw, sh) else g.setScissor() end
    end
  end)
end

local function installNightSkyWrap()
  local okLib, hostLib = pcall(function()
    return (Interop and Interop.hostLib and Interop.hostLib()) or nil
  end)
  if not okLib or not hostLib or type(hostLib.require) ~= "function" then return end
  local okSky, Sky = pcall(function() return hostLib.require("Sky") end)
  if not (okSky and Sky and type(Sky.paint) == "function") then return end
  if Sky._wxNightWrapped then return end
  local NightSky
  pcall(function() NightSky = V.require("NightSky") end)
  if not NightSky then
    pcall(function()
      local src = mod:read("lib/NightSky.lua")
      if src then NightSky = assert((loadstring or load)(src, "@NightSky"))(V) end
    end)
  end
  if not NightSky then return end
  pcall(function() NightSky._TOD = TOD end)
  local orig = Sky.paint
  function Sky.paint(w, h, sky, horizonY, cell, body, ...)
    local wxNight = (TOD and TOD.isNight and TOD.isNight())
        or (TOD and (TOD.pin == "NITE" or TOD.pin == "NIGHT" or TOD.tod == "NITE" or TOD.tod == "NIGHT"))
        or (TOD and type(TOD.hour) == "number" and ((TOD.hour % 24) >= 20 or (TOD.hour % 24) < 5))
    pcall(function()
      package.loaded._WX_NIGHT = wxNight and true or false
      if rawget(_G, "V") then V._WX_NIGHT = wxNight and true or false end
    end)

    local skyArg = sky
    if wxNight and sky and type(sky) == "table" and sky.bands then
      local copy = {}
      for k, v in pairs(sky) do copy[k] = v end
      local nightBands = {
        { 0.008, 0.010, 0.025 },
        { 0.012, 0.015, 0.035 },
        { 0.018, 0.022, 0.045 },
        { 0.005, 0.006, 0.018 },
      }
      local nb = {}
      for i = 1, #sky.bands do
        nb[i] = nightBands[((i - 1) % #nightBands) + 1]
      end
      copy.bands = nb
      skyArg = copy
    end

    local edge
    pcall(function() edge = Sky.region(h, horizonY) end)
    edge = edge or (h * 0.42)

    -- Build celestial disc from our Y-axis clock (top half of sky only).
    -- Pass this body into the HOST painter so the disc actually renders.
    local hour = 12
    pcall(function()
      if TOD and type(TOD.hour) == "number" then hour = TOD.hour % 24 end
    end)
    local wxBody = nil
    pcall(function()
      local CB = V.require("CelestialBodies")
      if CB and CB.projectBody then
        wxBody = CB.projectBody(w, h, edge, cell or 4, hour, nil)
      end
    end)
    if not wxBody then
      -- Plate mapping: sun 6–18 above horizon; moon otherwise
      local s, isMoon = nil, false
      if hour >= 6 and hour <= 18 then
        s = (hour - 6) / 12
        isMoon = false
      else
        isMoon = true
        if hour > 18 then s = (hour - 18) / 12
        else s = (hour + 6) / 12 end
      end
      if wxNight then isMoon = true end
      if s then
        local elev = math.sin(math.pi * math.max(0, math.min(1, s)))
        local theta = math.pi * math.max(0, math.min(1, s))
        local u = 0.5 + 0.40 * math.cos(theta)
        if u < 0.05 then u = 0.05 elseif u > 0.95 then u = 0.95 end
        -- elev 0 → low on sky; elev 1 → near top (over head)
        local v = 0.72 - 0.68 * elev
        if v < 0.04 then v = 0.04 elseif v > 0.78 then v = 0.78 end
        wxBody = {
          x = u * w,
          y = v * edge,
          moon = isMoon,
          glowAmt = 0,
          r = isMoon and 1 or 1,
          g = isMoon and 1 or 0.9,
          b = isMoon and 1 or 0.5,
        }
      end
    end
    if wxBody then
      wxBody.glowAmt = 0
      if wxNight then wxBody.moon = true end
      -- Clamp to top half of sky (above horizon band)
      -- Do NOT clamp overhead toward the horizon — elevation must reach the top.
      if wxBody.y < 1 then wxBody.y = 1 end
      if wxBody.y > edge * 0.85 then wxBody.y = edge * 0.85 end
    end

    -- Host paints sky + OUR body (not host DayNight body — wrong axis).
    local result
    local okPaint, paintRet = pcall(orig, w, h, skyArg, horizonY, cell, wxBody, ...)
    if okPaint then result = paintRet else result = false end

    -- Dark sky plate at NITE (under stars, over host blue if any).
    if wxNight and love and love.graphics then
      pcall(function()
        local g = love.graphics
        local prev
        pcall(function() prev = { g.getBlendMode() } end)
        pcall(g.setBlendMode, "alpha", "alphamultiply")
        pcall(g.setColor, 0.01, 0.012, 0.03, 1)
        pcall(g.rectangle, "fill", 0, 0, w, edge)
        pcall(g.setColor, 1, 1, 1, 1)
        if prev then pcall(g.setBlendMode, prev[1], prev[2]) end
      end)
    end

    local vis = 0
    pcall(function()
      if NightSky.computeNightVisibility then
        vis = NightSky.computeNightVisibility() or 0
      end
      if NightSky.update then NightSky.update(0) end
    end)
    local show = wxNight or (vis >= 0.02)
    if not show and TOD and TOD.isNight and TOD.isNight() then show = true end
    if not show and TOD and (TOD.pin == "NITE" or TOD.tod == "NITE") then show = true end
    if show or vis >= 0.02 then
      if wxNight then
        NightSky._nightVis = 1
        NightSky._nightVisRaw = 1
      end
      pcall(NightSky.draw, w, h, edge, wxBody, State.elapsed or 0)
    end

    -- Our grainy disc on top (backup if host ignored body).
    if wxBody and wxBody.x and wxBody.y then
      pcall(wxPaintCelestialDisc, wxBody, edge, cell or 4, w, h)
      pcall(function()
        local g = love.graphics
        local r = math.max(5, math.floor((h or 144) * 0.032))
        if wxBody.moon then pcall(g.setColor, 0.92, 0.94, 1.0, 1)
        else pcall(g.setColor, 1.0, 0.92, 0.4, 1) end
        pcall(g.circle, "fill", wxBody.x, wxBody.y, r)
        pcall(g.setColor, 1, 1, 1, 1)
      end)
    end

    return result
  end
  Sky._wxNightWrapped = true
end


-- 5.16.41: Wilds may initialise after The World's game.ready callback. Retry the
-- visible-spawn/sprite bridge when mods finish loading and when a save is entered,
-- so overworld Pokemon do not remain invisible because of load order.
local function retryWildsWxBridge()
  if V.questLitePrivate then return end
  -- A save can be opened after another content pack has populated its live
  -- species table. Re-run the idempotent WX registration first so caught
  -- WX_* ids are known before the summary, party, or follower code reads them.
  pcall(function()
    if mod.exports and type(mod.exports.refreshWeatherVariants) == "function" then
      mod.exports.refreshWeatherVariants()
    end
  end)
  pcall(function()
    local ok, WV = pcall(V.require, "WeatherVariants")
    if ok and WV and WV.installWildsCompat then WV.installWildsCompat() end
  end)
end
if mod.events and mod.events.on then
  pcall(function() mod.events:on("mods.loaded", retryWildsWxBridge, 9999) end)
  pcall(function() mod.events:on("save.loaded", retryWildsWxBridge, 9999) end)
  pcall(function() mod.events:on("map.changed", retryWildsWxBridge, 9999) end)
end

mod.events:on("game.ready", function()
  State.settle()

  -- Weather variants (4.10) — Pokédex/typing only; does not alter stars/sun/moon.
  pcall(function()
    if V.questLitePrivate then return end
    -- Crystal 251 ships its own type chart / 251 dex — do not overlay WX variants.
    if mod.find and mod:find("CRYSTAL_251") then return end
    -- Kanto Ascendant likewise owns the expanded species/type/sprite layer.
    -- Weather remains active, but its WX species must not be registered over
    -- Ascendant's new-game and visual registries.
    if mod.exports and mod.exports.kantoAscendantCompatibility then return end
    local ok, WV = pcall(V.require, "WeatherVariants")
    if ok and WV and WV.install then pcall(WV.install) end
    if ok and WV and WV.bindPokedex then WV.bindPokedex() end
    -- Wilds of Kanto (overworld-spawn-mod): remap WX_* follower sprites to base.
    if ok and WV and WV.installWildsCompat then pcall(WV.installWildsCompat) end
    -- Battle Art Voxel resolves animated Gen 2 art by species id. WX forms
    -- borrow their base id only while its battle texture is being generated.
    if ok and WV and WV.installBattleArtCompat then pcall(WV.installBattleArtCompat) end
    pcall(WeatherEncounterAPI.bind)
    pcall(WeatherCompanionBridge.install)
  end)

  -- The private build uses NightSky.drawWorld and CelestialBodies.drawWorld
  -- directly inside DramalessAtmos. The legacy screen-space wrapper allocates
  -- a fresh night palette every eye and paints bodies onto a flat plate, so it
  -- remains disabled in VR.
  if not V.questLitePrivate then pcall(installNightSkyWrap) end
  -- Installed once the game is up, so requiring BattleState cannot race
  -- the engine's own load order.  ALWAYS installed, not only when the row
  -- already reads BEHIND: the wrapper asks on every draw, so installing it
  -- unconditionally is what makes the row take effect immediately instead
  -- of at the next restart.
  pcall(function() if Compat and Compat.refresh then Compat.refresh() end end)
  if not V.questLitePrivate then BattleField.install() end
  -- Gen 2 only, and only when the pokegear_cards library is there.  It
  -- answers false and logs a reason on every other path.
  pcall(function() Pokegear.install() end)
  if Settings.debugRain(Config) then
    mod.log:warn("debugRain is ON: heavy rain everywhere outdoors, "
      .. "overriding the OPTIONS row. Set debugRain = false in config.lua "
      .. "when you are done testing.")
  end
  mod.log:info("weather_fx %s: %d types, %d channels, clock=%s, battle=%s, with %s",
    mod.exports.version, #Types.list, #Types.channels,
    Config.get().time.source,
    Scene.battleFullScreen() and "screen" or "canvas",
    Interop.describe())
  if #Config.problems > 0 then
    mod.log:warn("config.lua had %d problem(s): %s",
      #Config.problems, table.concat(Config.problems, "; "))
  end
end)

-- ------- developer console
--
-- `weather` in the console (backtick, developer mode) sets the sky without
-- walking the OPTIONS ladder thirteen rungs.  Costs nothing when the
-- console is never opened, and is the fastest way to check a config change.

if mod.commands and type(mod.commands.register) == "function" then
mod.commands:register("weather", function(args)
  local id = args and args[1] and tostring(args[1]):upper()
  if not id or id == "LIST" then
    return "weather ids: " .. table.concat(Types.ids(), " ")
  end
  if id == "RETURN" then
    -- The undo for the one feature that moves you.  Deliberately a
    -- command rather than a menu row: it is a repair, not a setting.
    local mapId = Tornado.origin()
    if not mapId then return "no tornado has carried you anywhere yet" end
    if Tornado.carry(mapId) then return "returned to " .. tostring(mapId) end
    return "could not return you to " .. tostring(mapId)
  end
  if id == "STATUS" then
    return ("%s | %s | battle=%s"):format(
      State.describe(), TOD.describe(), Battle.describe())
  end
  if not Types.byId[id] then
    return ("unknown weather %q -- try `weather list`"):format(id)
  end
  State.set(id, true)
  return "weather set to " .. id
end)
else
  pcall(function() mod.log:warn("mod.commands missing; console weather command skipped") end)
end

-- ------- exports
--
-- Published so a companion mod (NPC umbrellas, puddles on the ground
-- plane, a weather readout on the town map) can ask what the weather is
-- without patching this one.  `weather`, `channel`, `battleWeather` and
-- `timeOfDay` are the stable surface; `lib` is everything and carries no
-- promise.

-- Read from the manifest rather than typed here: a hardcoded copy sat at
-- "2.0.0" for twenty releases, so any companion mod checking this mod's
-- version was told the wrong one.  One source of truth, and it is the file
-- the loader already validated.
mod.exports.version = (mod.manifest and mod.manifest.version) or "unknown"
mod.exports.weather = function() return State.indoors and "CLEAR" or State.id end
mod.exports.channel = function(key) return State.channel(key) end
mod.exports.battleWeather = function()
  if State.indoors then return nil end
  return Types.battleWeather(State.id)
end
mod.exports.compat = function()
  if Compat and Compat.describe then return Compat.describe() end
  return "compat: unavailable"
end
mod.exports.timeOfDay = function() return TOD.tod, TOD.hour end
mod.exports.voxelAtmos = function()
  return {
    active = VoxelAtmos.active and VoxelAtmos.active() or false,
    reason = VoxelAtmos.reason and VoxelAtmos.reason() or "unknown",
    rain = VoxelAtmos.handlesPrecipitation
      and VoxelAtmos.handlesPrecipitation() or false,
    snow = VoxelAtmos.handlesSnow and VoxelAtmos.handlesSnow() or false,
    grains = VoxelAtmos.handlesGrains and VoxelAtmos.handlesGrains() or false,
  }
end
mod.exports.season = function() return Seasons.current(), Seasons.source end
mod.exports.setSeasonBannerOwner = function(owner)
  Seasons.setBannerOwner(owner)
end
mod.exports.worldHolidayGiftClaim = function(game)
  return PrimalGifts.claimToday(game)
end
mod.exports.types = function() return Types.list end
-- Read-only preview for a companion mod's own encounter/route display --
-- see lib/Encounters.lua's "LIVE REPORTING" section for exactly what
-- this does and does not guarantee. Never touches, and is never touched
-- by, the real encounter.roll hook above.
mod.exports.encounterOverlay = function(mapId) return WeatherEncounterAPI.route(mapId) end
mod.exports.weatherEncounters = function(mapId) return WeatherEncounterAPI.route(mapId) end
mod.exports.weatherPokemon = function(species) return WeatherEncounterAPI.species(species) end
mod.exports.refreshWeatherVariants = function()
  -- Content layers may register their species after Weather FX's first pass.
  -- Retry registration and bind the live Dex in the same transaction so an
  -- existing WX_* party member is recognised by battle, summary, and Pokédex
  -- immediately after an update or a save load.
  local installed = WeatherVariants.install()
  if WeatherVariants.bindPokedex then WeatherVariants.bindPokedex() end
  return installed
end
mod.exports.weatherVariantForBase = function(species) return WeatherVariants.variantForBase(species) end
mod.exports.weatherVariantsForBase = function(species) return WeatherVariants.variantsForBase(species) end
mod.exports.weatherEncounterAPI = WeatherEncounterAPI.public()
mod.exports.weatherCompanion = function() return WeatherCompanionBridge.status() end
mod.exports.lib = V
