-- BATTLE BACKDROPS.
--
-- 23 scenes at 240x112, day and night variants.
--
-- CREDITS, as supplied by the packager:
--   CDRX73, DerxwnaKapsyla, http404error, Game Freak.
-- Roles were not specified, so they are listed together rather than
-- guessed at.  A wrong role is worse than no role.
--
-- NOTE FOR ANYONE REDISTRIBUTING THIS: the presence of Game Freak in that
-- list means at least some of this art derives from the official games.
-- The engine's own position is that "mods ship recipes and original
-- assets, never extracted content" -- `modkit lint` only checks for Gen 1
-- ROM data and passes, so it is not enforcing that here.  Whether these
-- may be redistributed is a question for the packager, not the linter.
--
-- ---------------------------------------------------------------------
-- WHERE THESE DRAW, AND WHY IT IS NOT BEHIND THE POKEMON
-- ---------------------------------------------------------------------
--
-- The honest version, because the limitation is structural and someone
-- will otherwise spend a day looking for the setting that fixes it.
--
-- There is NO hook between "the battle fills its field" and "the battle
-- draws its sprites".  `battle.overlay` runs at the END of the battle's
-- draw, so anything drawn there covers the Pokemon.  `drawClassic` fills
-- its own 160x144 with the paper shade before anything else, and
-- `WideBattle.draw` does the same at 304x144.
--
-- `battleBg = "world"` looks like the answer and is not.  From the
-- engine's own comment (Renderer.lua:954): "world changes what surrounds
-- the battle and leaves the battle screen alone... the classic battle
-- paints an opaque paper field over it".  It exposes the VOIDS, not the
-- space behind the sprites.
--
-- `render.compose` would work but demands the mod return true and take
-- over the ENTIRE window composite -- SGB zone recolouring, the palette
-- pass, the letterbox, GBC FX, the second-screen bridge.  Reimplementing
-- all of that to place one image would break every colour mode.
--
-- So these draw in the LETTERBOX, through `render.letterbox` -- a
-- documented hook, called after the clear and before the game canvas
-- blits, which is precisely "art behind and around the playfield".  On a
-- widescreen handheld that is most of the screen, and the battle sits in
-- the middle of it like a window onto the scene.
--
-- Drawing behind the sprites needs one new engine hook -- a
-- `battle.background` called after the field fill and before the sprites,
-- the natural sibling of the `battle.overlay` that already exists.  Four
-- lines in `drawClassic` and `WideBattle.draw`.  Until then this is the
-- honest maximum a mod can reach without patching engine internals, which
-- would also fight StadiumBattleFX and both voxel mods for the same draw.
--
-- ---------------------------------------------------------------------
-- WHICH BACKDROP
-- ---------------------------------------------------------------------
--
-- Weather wins over geography, because weather is the thing the player
-- just watched change: a blizzard puts you on the snow field wherever you
-- are, a sandstorm on the desert one.  Failing that, the map decides, by
-- id prefix rather than an exhaustive list so a mod that adds maps still
-- lands somewhere sensible.  Night variants follow this mod's own clock,
-- so they agree with the day/night grade rather than arguing with it.

local V = ...
local mod = V.mod
local TOD = V.require("TimeOfDay")
local Scene = V.require("Scene")
local State = V.require("WeatherState")
local Types = V.require("Types")
local Config = V.require("Config")

local BG = {}

BG.CREDIT = "Backdrops: CDRX73, DerxwnaKapsyla, http404error, Game Freak"
BG.DIR = "assets/backgrounds/"

-- scene -> which variants exist on disk.  `alt` is the artist's "2"
-- version, used as a stable per-map variation rather than at random, so a
-- given map always looks the same.
BG.SCENES = {
  beach      = { night = true, alt = true },
  cave       = { night = true, alt = true },
  desert     = { night = true },
  lake       = { night = true },
  mountain   = { night = true, alt = true },
  ocean      = { night = true },
  path       = { night = true, alt = true },
  snow       = { night = true },
  tall_grass = { night = true },
  underwater = {},
}

-- Weather first.  Keyed by the capability tags the catalogue already
-- carries, so a NEW weather type is covered without being added here.
-- ------- love.filesystem is sandboxed away from mods now
--
-- The updated engine hands mods a `love` facade that ERRORS on
-- `filesystem`, `thread`, `system` and `event` (src/mods/Sandbox.lua). It
-- errors on the INDEX, so the usual `love and love.filesystem` guard does not
-- protect anything -- reading the field is itself the throw. That is what
-- broke rendering: the first pipeline update raised, and a pipeline that
-- raises draws nothing.
--
-- `love.data.newByteData` is not blocked and produces something
-- `newSource`/`newImageData` accept just as happily as a FileData, so the
-- bytes still come from `mod:read` and only the wrapper changes.
local function byteData(bytes, name)
  if not (love and love.data and love.data.newByteData) then return nil end
  local ok, d = pcall(love.data.newByteData, bytes)
  if not ok or not d then return nil end
  pcall(function() d.name = name end)
  return d
end

local function sceneForWeather(def)
  if not def then return nil end
  if def.frozen then return "snow" end
  if def.sandy then return "desert" end
  return nil
end

-- Then the map, by prefix.  Ordered longest-first where prefixes overlap.
BG.MAP_RULES = {
  { "SEAFOAM", "cave" }, { "MT_MOON", "cave" }, { "ROCK_TUNNEL", "cave" },
  { "VICTORY_ROAD", "cave" }, { "CERULEAN_CAVE", "cave" },
  { "DIGLETTS_CAVE", "cave" }, { "POKEMON_MANSION", "cave" },
  { "INDIGO_PLATEAU", "mountain" }, { "ROUTE_23", "mountain" },
  { "ROUTE_22", "mountain" }, { "ROUTE_9", "mountain" },
  { "ROUTE_10", "mountain" },
  { "CINNABAR", "beach" }, { "ROUTE_19", "beach" }, { "ROUTE_20", "ocean" },
  { "ROUTE_21", "ocean" }, { "PALLET", "beach" }, { "VERMILION", "beach" },
  { "ROUTE_24", "lake" }, { "ROUTE_25", "lake" }, { "CERULEAN", "lake" },
  { "VIRIDIAN_FOREST", "tall_grass" }, { "SAFARI", "tall_grass" },
  { "ROUTE_", "tall_grass" },
  { "CITY", "path" }, { "TOWN", "path" }, { "PLATEAU", "path" },
}

function BG.sceneFor(mapId, weatherDef)
  local byWeather = sceneForWeather(weatherDef)
  if byWeather then return byWeather end
  local id = tostring(mapId or "")
  for _, rule in ipairs(BG.MAP_RULES) do
    if id:find(rule[1], 1, true) then return rule[2] end
  end
  return "path"
end

-- A stable per-map choice between the base and "2" variants: the same map
-- always looks the same, without a table naming every map.  A cheap string
-- hash rather than random, for exactly that reason.
local function wantsAlt(mapId)
  local sum = 0
  for i = 1, #tostring(mapId or "") do
    sum = sum + tostring(mapId):byte(i)
  end
  return (sum % 2) == 1
end

function BG.fileFor(mapId, weatherDef, night)
  local scene = BG.sceneFor(mapId, weatherDef)
  local info = BG.SCENES[scene] or {}
  if night and info.night then return scene .. "_night" end
  if not night and info.alt and wantsAlt(mapId) then return scene .. "_2" end
  return scene
end

-- ------- loading
--
-- Lazily, once per scene, and never again after a failure: a missing or
-- unreadable file costs one log line and a plain letterbox, not a frame
-- that throws inside a render hook.

local cache = {}
local failed = {}

local function imageFor(name)
  if cache[name] then return cache[name] end
  if failed[name] then return nil end
  local ok, image = pcall(function()
    local data = mod:read(BG.DIR .. name .. ".png")
    if not data then return nil end
    local fileData = byteData(data, name .. ".png")
    if not fileData then return nil end
    local imageData = love.image.newImageData(fileData)
    local img = love.graphics.newImage(imageData)
    img:setFilter("nearest", "nearest")
    return img
  end)
  if not ok or not image then
    failed[name] = true
    mod.log:warn("battle backdrop %s could not be loaded", name)
    return nil
  end
  cache[name] = image
  return image
end

function BG.invalidate()
  cache, failed = {}, {}
end

-- ------- the draw
--
-- `ctx` is render.letterbox's: ww/wh is the window, ox/oy/vpw/vph the game
-- rect that will blit on top of this.  The backdrop COVERS the window
-- (scaled up, centred, cropped) rather than fitting inside it, because a
-- fitted 240x112 leaves bars of its own and bars around bars look like a
-- mistake rather than a frame.

function BG.draw(ctx)
  if not Config.get().battleBackdrops then return false end
  if Scene.now.visible ~= "battle" then return false end
  -- With BEHIND active the field itself carries the art, and the bars are
  -- still worth filling -- the two compose into one continuous scene.
  if not (love and love.graphics) then return false end

  local night = (TOD.tod == "NITE" or TOD.tod == "EVE")
  local name = BG.fileFor(Scene.now.mapId, Types.get(State.id), night)
  local image = imageFor(name)
  if not image then return false end

  local ww = tonumber(ctx and ctx.ww) or 0
  local wh = tonumber(ctx and ctx.wh) or 0
  if ww <= 0 or wh <= 0 then return false end

  local iw, ih = image:getDimensions()
  local scale = math.max(ww / iw, wh / ih)
  local dx = (ww - iw * scale) * 0.5
  local dy = (wh - ih * scale) * 0.5

  local pr, pg, pb, pa = love.graphics.getColor()
  local blend, alphaMode = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(image, dx, dy, 0, scale, scale)

  -- The battle screen blits over the middle of this in a moment.  Darken
  -- the whole backdrop a little so it reads as a setting behind the fight
  -- rather than as a brighter picture competing with it.
  local dim = tonumber(Config.get().battleBackdropDim) or 0.25
  if dim > 0 then
    love.graphics.setColor(0, 0, 0, math.min(1, dim))
    love.graphics.rectangle("fill", 0, 0, ww, wh)
  end

  love.graphics.setBlendMode(blend, alphaMode)
  love.graphics.setColor(pr, pg, pb, pa)
  return true
end

-- The same picture, drawn to cover a battle SURFACE rather than the
-- window: used by lib/BattleField.lua in place of the engine's paper fill.
-- No dim here -- the battle's own sprites and HUD sit directly on this, and
-- darkening it would darken them by contrast rather than sit behind them.
-- Returns true if it drew; false means the caller must paint the paper
-- fill it was standing in for, or the field is left transparent.
function BG.drawField(w, h)
  if not (love and love.graphics) then return false end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  if w <= 0 or h <= 0 then return false end

  local night = (TOD.tod == "NITE" or TOD.tod == "EVE")
  local name = BG.fileFor(Scene.now.mapId, Types.get(State.id), night)
  local image = imageFor(name)
  if not image then return false end

  local iw, ih = image:getDimensions()
  local scale = math.max(w / iw, h / ih)
  local dx = (w - iw * scale) * 0.5
  local dy = (h - ih * scale) * 0.5

  local pr, pg, pb, pa = love.graphics.getColor()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(image, dx, dy, 0, scale, scale)
  love.graphics.setColor(pr, pg, pb, pa)
  return true
end

return BG
