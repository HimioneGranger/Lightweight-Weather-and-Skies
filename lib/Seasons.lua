-- SEASONS.
--
-- Gen 1/2 have none, so this mod used to answer "where does it snow" with
-- altitude and water alone.  Players still ask for a calendar, and a
-- calendar is what this file is: four seasons, a hemisphere switch that
-- reverses them, seasonal multipliers on AUTO weather weights, and a
-- short on-screen banner when the season flips.
--
-- =====================================================================
-- TWO CLOCKS, ONE ANSWER
-- =====================================================================
--
--   system   real device calendar (the same source GSC used for the clock)
--   cycle    in-game year derived from TOD.elapsed / cycleMinutes
--   auto     follows whichever clock TimeOfDay is actually on
--   fixed    still advances the in-game year so the season is not frozen
--   off      seasons stay off; weight multipliers are all 1
--
-- Hemisphere only flips the mapping from month/day-of-year to season name.
-- Northern meteorological months are the default; Southern swaps them.
--
-- =====================================================================
-- NOTIFICATIONS
-- =====================================================================
--
-- Two banners share one draw path:
--
--   1. Season change  -- queued when the computed season differs from the
--      one last written to mod.save ("WINTER has begun!").
--   2. Place + season -- queued when the player enters the overworld or
--      walks into a new map, drawn under the route/town name style:
--      "Pallet Town" on the first line, "Summer" underneath.
--
-- Both are drawn for a few seconds on the HUD pass and do not touch the
-- weather channels or the state machine.  Suppressing the banner still
-- advances the season and applies the weights.

local V = ...
local mod = V.mod
local Config = V.require("Config")
local Settings = V.require("Settings")
local TOD = V.require("TimeOfDay")
local Types = V.require("Types")

local Seasons = {}

Seasons.IDS = { "SPRING", "SUMMER", "AUTUMN", "WINTER" }
Seasons.LABELS = {
  SPRING = "SPRING",
  SUMMER = "SUMMER",
  AUTUMN = "AUTUMN",
  WINTER = "WINTER",
}
-- Title-case labels for the place banner (under the location name).
Seasons.TITLE = {
  SPRING = "Spring",
  SUMMER = "Summer",
  AUTUMN = "Autumn",
  WINTER = "Winter",
}

-- Northern meteorological months -> season index (1=SPRING .. 4=WINTER)
local NORTH_BY_MONTH = {
  [12] = 4, [1] = 4, [2] = 4,
  [3]  = 1, [4] = 1, [5] = 1,
  [6]  = 2, [7] = 2, [8] = 2,
  [9]  = 3, [10] = 3, [11] = 3,
}

-- Southern: northern summer becomes southern winter, etc.
local SOUTH_OF = { [1] = 3, [2] = 4, [3] = 1, [4] = 2 }

Seasons.id = "SPRING"
Seasons.source = "none"
Seasons.notifyT = 0
Seasons.notifyText = nil
Seasons.notifyPlace = nil   -- location line for the place+season banner
Seasons._lastPersisted = nil
Seasons._bootstrapped = false
Seasons._lastMapId = nil
Seasons._seenOverworld = false

-- Capability multipliers per season.  Keys match the tags biasFor already
-- understands (wet / frozen / sunny / sandy) plus fog.  A missing key is 1.
--
-- ZERO is a hard gate: weightOf multiplies by this after geography, so
-- frozen = 0 in summer means snow/hail/blizzard cannot roll anywhere --
-- not even on Indigo Plateau.  Hemisphere only changes which months map
-- to which season; the gates below always apply to the *current* season.
--
--   SUMMER  no frozen weather (snow, blizzard, hail, sleet, thundersnow)
--   WINTER  no sunny weather (sun, heatwave, harsh sun)
--   SPRING  light snow rare; rain favoured
--   AUTUMN  light snow possible; fog and rain favoured
local MULT = {
  SPRING = { wet = 1.50, sunny = 1.20, frozen = 0.25, sandy = 0.80, fog = 1.15 },
  SUMMER = { wet = 0.75, sunny = 1.80, frozen = 0.00, sandy = 1.40, fog = 0.55 },
  AUTUMN = { wet = 1.45, sunny = 0.70, frozen = 0.55, sandy = 0.90, fog = 1.55 },
  WINTER = { wet = 0.85, sunny = 0.00, frozen = 2.80, sandy = 0.50, fog = 1.30 },
}

local function hemisphere()
  local v = Settings.get("hemisphere")
  if v == "southern" then return "southern" end
  return "northern"
end

local function seasonsEnabled()
  if Settings.is("seasons", "off") then return false end
  local cfg = Config.get().seasons
  if cfg and cfg.enabled == false then return false end
  return true
end

-- Forward declaration: notifyEnabled is evaluated before the compatibility
-- helper's implementation below. Without this local, Lua resolves the call as
-- a missing global and the protected seasonal update silently aborts.
local otherUiOwnsBanners

local function notifyEnabled()
  if otherUiOwnsBanners() then return false end
  if Settings.is("seasonNotify", "off") then return false end
  local cfg = Config.get().seasons
  if cfg and cfg.notify == false then return false end
  return true
end

local function daysPerSeason()
  local cfg = Config.get().seasons
  local n = cfg and tonumber(cfg.daysPerSeason)
  if n and n >= 1 then return math.floor(n) end
  return 28
end

-- ROUTE_1 / PALLET_TOWN / INDIGO_PLATEAU -> "Route 1" / "Pallet Town" / ...
local function prettyMapName(mapId)
  if type(mapId) ~= "string" or mapId == "" then return nil end
  local s = mapId:gsub("_", " ")
  -- Title-case each word; keep short all-caps tokens (HM, SS) alone.
  s = s:gsub("(%S+)", function(w)
    if #w <= 2 and w == w:upper() then return w end
    return w:sub(1, 1):upper() .. w:sub(2):lower()
  end)
  return s
end


-- Presence of another UI mod does not mean it owns seasonal notifications.
-- Suppress only when an integration explicitly claims the banner channel.
otherUiOwnsBanners = function()
  return Seasons._bannerOwner == "external"
end

function Seasons.setBannerOwner(owner)
  Seasons._bannerOwner = owner == "external" and "external" or nil
end

local function placeNotifyEnabled()
  if otherUiOwnsBanners() then return false end
  if not seasonsEnabled() then return false end
  if Settings.is("seasonNotify", "off") then return false end
  local cfg = Config.get().seasons
  if cfg and cfg.notify == false then return false end
  if cfg and cfg.placeBanner == false then return false end
  return true
end

-- Called every frame with the current map id (from either pipeline).
-- Fires the place+season banner once on first overworld sighting this
-- session, and again whenever the map changes.
function Seasons.onMap(mapId)
  if type(mapId) ~= "string" or mapId == "" then return end
  local first = not Seasons._seenOverworld
  local changed = Seasons._lastMapId and Seasons._lastMapId ~= mapId
  if first or changed then
    Seasons.showPlace(mapId)
  end
  Seasons._seenOverworld = true
  Seasons._lastMapId = mapId
end

-- Queue the place+season banner shown on map entry / game entry.
-- Layout: location name on top, season underneath (or alone if no name).
-- Does not override an active "has begun" season-change headline; it only
-- attaches the place line under that message.
function Seasons.showPlace(mapId)
  if not placeNotifyEnabled() then return end
  local place = prettyMapName(mapId)
  if not place then return end
  local season = Seasons.TITLE[Seasons.id] or Seasons.id
  local changing = Seasons.notifyText
      and Seasons.notifyText:find("has begun", 1, true)
  if changing then
    Seasons.notifyPlace = place
  else
    Seasons.notifyPlace = place
    Seasons.notifyText = season
  end
  local cfg = Config.get().seasons
  local hold = (cfg and tonumber(cfg.notifySeconds)) or 3.5
  if Seasons.notifyT < hold then Seasons.notifyT = hold end
end

-- Month 1..12 -> season id, respecting hemisphere.
local function seasonFromMonth(month)
  local idx = NORTH_BY_MONTH[month] or 1
  if hemisphere() == "southern" then
    idx = SOUTH_OF[idx] or idx
  end
  return Seasons.IDS[idx]
end

-- Day-of-year 0..yearLen-1 -> season id (equal-length seasons).
local function seasonFromDayOfYear(day, yearLen)
  yearLen = math.max(4, yearLen or (daysPerSeason() * 4))
  local per = yearLen / 4
  local idx = math.floor((day % yearLen) / per) + 1
  if idx > 4 then idx = 4 end
  if hemisphere() == "southern" then
    idx = SOUTH_OF[idx] or idx
  end
  return Seasons.IDS[idx]
end

-- Resolve the current season from whichever clock TimeOfDay is using.
local function compute()
  if not seasonsEnabled() then
    return "SPRING", "off"
  end

  local cfg = Config.get().time
  local source = cfg and cfg.source or "system"

  -- Follow the live TOD source when possible so season and clock agree.
  local todSource = TOD.source
  if todSource == "system" or (source == "system" and todSource ~= "cycle"
      and todSource ~= "voxel" and todSource ~= "dramaless") then
    local ok, t = pcall(os.date, "*t")
    if ok and type(t) == "table" and type(t.month) == "number" then
      return seasonFromMonth(t.month), "system"
    end
  end

  -- In-game year from the accelerated clock (cycle / auto-fallback / fixed).
  local period = math.max(30, (cfg and cfg.cycleMinutes or 24) * 60)
  local elapsed = TOD.elapsed or 0
  local dayIndex = math.floor(elapsed / period)
  local yearLen = daysPerSeason() * 4
  return seasonFromDayOfYear(dayIndex, yearLen), "cycle"
end

function Seasons.current()
  return Seasons.id
end

function Seasons.multiplier(def)
  if not seasonsEnabled() then return 1 end
  if not def then return 1 end
  local row = MULT[Seasons.id]
  if not row then return 1 end
  local m = 1
  if def.wet and row.wet then m = m * row.wet end
  if def.frozen and row.frozen then m = m * row.frozen end
  if def.sunny and row.sunny then m = m * row.sunny end
  if def.sandy and row.sandy then m = m * row.sandy end
  -- Fog is inferred from the channel table the same way biasFor does it.
  if Types.channel(def, "fog") > 0 and row.fog then m = m * row.fog end
  return m
end

function Seasons.update(dt, mapId)
  dt = tonumber(dt) or 0
  if dt < 0 or dt ~= dt then dt = 0 end
  if dt > 0.25 then dt = 0.25 end

  local id, source = compute()
  Seasons.source = source

  if not Seasons._bootstrapped then
    -- First tick of a session: restore the last known season so a reload
    -- does not re-fire the season-change banner, then adopt the clock.
    local ok, stored = pcall(function()
      return mod.save:get("season", nil)
    end)
    if ok and type(stored) == "string" and MULT[stored] then
      Seasons._lastPersisted = stored
    end
    Seasons._bootstrapped = true
  end

  if id ~= Seasons.id then
    local previous = Seasons.id
    Seasons.id = id
    if Seasons._lastPersisted and Seasons._lastPersisted ~= id
        and notifyEnabled() and seasonsEnabled() then
      Seasons.notifyText = (Seasons.LABELS[id] or id) .. " has begun!"
      Seasons.notifyPlace = nil
      local cfg = Config.get().seasons
      Seasons.notifyT = (cfg and tonumber(cfg.notifySeconds)) or 3.5
    end
    Seasons._lastPersisted = id
    pcall(function() mod.save:set("season", id) end)
    if previous and previous ~= id then
      mod.log:info("season -> %s (%s)", id, source)
    end
  elseif not Seasons._lastPersisted then
    Seasons._lastPersisted = id
    pcall(function() mod.save:set("season", id) end)
  end

  -- Map tracking is also done from onMap (weather pipeline) so the place
  -- banner still fires when TIME is OFF.  Calling both is safe: the second
  -- pass sees the same map id and does nothing.
  if mapId then Seasons.onMap(mapId) end

  if Seasons.notifyT > 0 then
    Seasons.notifyT = Seasons.notifyT - dt
    if Seasons.notifyT <= 0 then
      Seasons.notifyT = 0
      Seasons.notifyText = nil
      Seasons.notifyPlace = nil
    end
  end
end

function Seasons.describe()
  if not seasonsEnabled() then return "OFF" end
  local hemi = (hemisphere() == "southern") and "S" or "N"
  return ("%s/%s"):format(Seasons.id, hemi)
end

-- Draw the banner.  Called from the HUD hook; returns true if it drew.
-- Two layouts:
--   place + season  ->  "Pallet Town"  (top) / "Summer" (underneath)
--   season change   ->  "WINTER has begun!"  (single line, optional place)
-- Uses the host font so it matches the debug readout and other HUD text.
function Seasons.drawNotify(viewport)
  if otherUiOwnsBanners() then return false end
  if Seasons.notifyT <= 0 then return false end
  if not Seasons.notifyText and not Seasons.notifyPlace then return false end
  if not (love and love.graphics) then return false end

  local cfg = Config.get().seasons
  local hold = (cfg and tonumber(cfg.notifySeconds)) or 3.5
  local t = Seasons.notifyT
  -- Fade in over the first 0.4s, hold, fade out over the last 0.6s.
  local alpha = 1
  local fadeIn, fadeOut = 0.4, 0.6
  if t > hold - fadeIn then
    alpha = math.max(0, (hold - t) / fadeIn)
  elseif t < fadeOut then
    alpha = math.max(0, t / fadeOut)
  end
  if alpha <= 0.02 then return false end

  local font = love.graphics.getFont()
  local nativeTh = math.max(1, tonumber(font:getHeight()) or 1)
  -- render.hud can leave a window-sized UI font active.  The viewport below
  -- is then scaled from 160x144 to the physical playfield, so using that font
  -- at full size scales it twice and produces a huge plaque.  Preserve the
  -- host font's appearance while capping it to a compact logical-pixel size.
  local textScale = math.min(1, 5 / nativeTh)
  local th = math.max(1, math.floor(nativeTh * textScale + 0.5))
  local padX, padY, gap = 5, 3, 1

  local place = Seasons.notifyPlace
  local line2 = Seasons.notifyText
  -- Place banner: location on top, season underneath.
  -- Season-change: headline on top, optional place underneath.
  local line1, sub
  if place and line2 and not line2:find("has begun", 1, true) then
    line1, sub = place, line2
  elseif line2 and line2:find("has begun", 1, true) then
    line1, sub = line2, place
  else
    line1, sub = line2 or place, nil
  end

  local vp = type(viewport) == "table" and viewport or nil
  local canvas = not vp and love.graphics.getCanvas and love.graphics.getCanvas() or nil
  local ox = vp and (tonumber(vp.gameX) or 0) or 0
  local oy = vp and (tonumber(vp.gameY) or 0) or 0
  local dpiX = vp and (tonumber(vp.dpiX) or 1) or 1
  local dpiY = vp and (tonumber(vp.dpiY) or dpiX) or dpiX
  local scaleX, scaleY = 1, 1
  if vp and tonumber(vp.gameWidth) and tonumber(vp.gameHeight)
      and vp.gameWidth > 0 and vp.gameHeight > 0 then
    scaleX, scaleY = vp.gameWidth / 160, vp.gameHeight / 144
  elseif vp and tonumber(vp.scale) and vp.scale > 0 then
    scaleX, scaleY = vp.scale / dpiX, vp.scale / dpiY
  end
  local sw = vp and 160 or (canvas and canvas.getWidth and canvas:getWidth()
    or love.graphics.getWidth())
  local sh = vp and 144 or (canvas and canvas.getHeight and canvas:getHeight()
    or love.graphics.getHeight())
  sw, sh = tonumber(sw) or 160, tonumber(sh) or 144

  local function textWidth(text)
    return font:getWidth(tostring(text or "")) * textScale
  end
  local function fit(text, maxWidth)
    text = tostring(text or "")
    if textWidth(text) <= maxWidth then return text end
    while #text > 1 and textWidth(text .. ".") > maxWidth do
      text = text:sub(1, -2)
    end
    return text .. "."
  end
  local maxTextWidth = math.max(24, math.min(76, sw - padX * 2 - 8))
  line1 = fit(line1, maxTextWidth)
  if sub then sub = fit(sub, maxTextWidth) end
  local w1 = textWidth(line1)
  local w2 = sub and textWidth(sub) or 0
  local boxW = math.ceil(math.max(w1, w2) + padX * 2)
  local lines = sub and 2 or 1
  local boxH = padY * 2 + th * lines + (lines > 1 and gap or 0)
  local x = math.floor((sw - boxW) * 0.5)
  -- Keep the location/season plaque at the top-centre of the game viewport.
  -- A small safe-area inset prevents it touching/cropping against the top edge
  -- on mobile, handheld and unusual aspect-ratio displays.
  local topInset = vp and 4 or 4
  local y = math.max(2, math.min(topInset, sh - boxH - 2))

  love.graphics.push("all")
  love.graphics.translate(ox, oy)
  love.graphics.scale(scaleX, scaleY)
  local prevR, prevG, prevB, prevA = love.graphics.getColor()
  love.graphics.setColor(0.05, 0.08, 0.14, 0.72 * alpha)
  love.graphics.rectangle("fill", x, y, boxW, boxH, 3, 3)
  love.graphics.setColor(0.85, 0.92, 1.0, 0.95 * alpha)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, boxW - 1, boxH - 1, 3, 3)

  -- Location (or season-change headline) in white; season subtitle softer.
  love.graphics.setColor(1, 1, 1, alpha)
  local function printCompact(text, tx, ty)
    love.graphics.push()
    love.graphics.translate(tx, ty)
    love.graphics.scale(textScale, textScale)
    love.graphics.print(text, 0, 0)
    love.graphics.pop()
  end
  printCompact(line1, x + math.floor((boxW - w1) * 0.5), y + padY)
  if sub then
    love.graphics.setColor(0.75, 0.88, 1.0, 0.95 * alpha)
    printCompact(sub, x + math.floor((boxW - w2) * 0.5),
      y + padY + th + gap)
  end
  love.graphics.setColor(prevR, prevG, prevB, prevA)
  love.graphics.pop()
  return true
end

return Seasons
