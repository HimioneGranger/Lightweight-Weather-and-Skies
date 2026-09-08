-- WEATHER ON THE POKEGEAR.
--
-- Two things, and the first is the one that matters:
--
--   1. An OVERLAY on the vanilla MAP card.  The real town map draws, and
--      the weather is painted on top of it at the real landmark positions.
--   2. A WEATHER strip card: a readable forecast list, for reading numbers
--      rather than shapes.
--
-- =====================================================================
-- WHY THE OVERLAY REPLACED A DRAWN GRID
-- =====================================================================
--
-- The first version of this drew its own 20x14 grid of letters using
-- coordinates invented in `Fronts.REGIONS`.  On a real Pokegear that looked
-- like what it was: symbols floating on an empty panel, in positions that
-- resembled Johto only if you already knew the shape of Johto.
--
-- The engine already knows where every place IS.  `game.data.field.townMap`
-- maps each map id to its square on the town map, and `TownMap.markerXY`
-- converts that to pixels as `x * 8 + 16, y * 8 + 8`.  So the overlay reads
-- those coordinates and paints there, over the actual drawn map, and every
-- marker lands on the town it belongs to because the engine placed it.
--
-- The invented grid survives only as a fallback for a build with no
-- townMap data, where a rough map beats no map.
--
-- =====================================================================
-- DEGRADES FIVE WAYS
-- =====================================================================
--
-- The library may be absent, disabled, or not yet loaded (`mod.find`
-- answers nil for all three); it may be an API version this does not know;
-- and the game may be Gen 1, which has no Pokegear.  Each ends with no card
-- and no error.  A weather mod that refuses to boot without an optional
-- companion would be a worse weather mod.
--
-- Both surfaces are READ-ONLY.  A card that could change the sky would be a
-- weather remote rather than a forecast, and the OPTIONS row already does
-- that job honestly.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local Fronts = V.require("Fronts")
local State = V.require("WeatherState")
local Config = V.require("Config")
local Scene = V.require("Scene")

local Gear = {}

-- How many forecast rows fit between the header and the footer.
Gear.ROWS = 7

Gear.installed = false
Gear.reason = "not attempted"

-- ------- colour per weather family
--
-- The map is drawn in the game's own palette, so a marker has to read
-- against it without a legend.  Tags rather than ids, so a new weather gets
-- a sensible colour without being listed.
local function colourFor(weatherId)
  local def = Types.get(weatherId)
  if Types.channel(def, "strike") > 0 then return { 255, 230, 90 } end   -- storm
  if def.frozen then return { 210, 235, 255 } end                        -- snow
  if def.sandy then return { 220, 170, 90 } end                          -- grit
  if Types.channel(def, "fog") > 0 then return { 190, 190, 205 } end     -- fog
  if def.wet then return { 90, 150, 255 } end                            -- rain
  if def.sunny then return { 255, 190, 60 } end                          -- sun
  return nil                                                             -- clear: nothing
end
Gear.colourFor = colourFor

-- One letter per family for the text card.
-- ONLY CHARACTERS THE GAME'S FONT HAS.
--
-- The first version used * % # ~ + and half of them came out BLANK in
-- play -- the MIST row had no glyph at all, because the GSC font has no
-- tilde.  The font is letters, digits and a short list of punctuation, so
-- these are all letters now: unambiguous, and they cannot silently vanish.
--
-- A letter also reads better than a symbol on a map drawn in four colours,
-- which is where the same glyphs are used.
local function glyphFor(weatherId)
  local def = Types.get(weatherId)
  if def.id == Types.DEFAULT then return "-" end
  if Types.channel(def, "psy") > 0 then return "P" end
  if Types.channel(def, "strike") > 0 then return "T" end   -- thunder
  if def.frozen then return "S" end                         -- snow and ice
  if def.sandy then return "D" end                          -- dust
  if Types.channel(def, "fog") > 0 then return "F" end
  if def.wet then return "R" end
  if def.sunny then return "C" end                          -- clear and bright
  if Types.channel(def, "debris") > 0 then return "W" end   -- wind
  return "?"
end
Gear.glyphFor = glyphFor

-- ------- real map coordinates
--
-- Read once and cached: the town map data does not change at runtime, and
-- this is called from a draw.

local coordCache = nil

local function townMapCoords()
  if coordCache then return coordCache end
  coordCache = {}
  pcall(function()
    local Game = require("src.core.Game")
    local field = Game and Game.data and Game.data.field
    local townMap = field and field.townMap
    if type(townMap) == "table" and type(townMap.locations) == "table" then
      townMap = townMap.locations
    end
    if type(townMap) ~= "table" then return end
    for mapId, entry in pairs(townMap) do
      local c = (type(entry) == "table" and (entry.coords or entry)) or nil
      local x = c and tonumber(c.x or c.col)
      local y = c and tonumber(c.y or c.row)
      if x and y then coordCache[mapId] = { x = x, y = y } end
    end
  end)
  return coordCache
end
Gear.townMapCoords = townMapCoords

-- Where should this region's marker go, in town-map TILE coordinates?
-- The first of its maps the town map actually knows about, so a region
-- whose primary map has no square still finds one through its routes.
function Gear.tileFor(region)
  local coords = townMapCoords()
  for _, prefix in ipairs(region.maps) do
    -- exact first, since that is the common case and cheapest
    if coords[prefix] then return coords[prefix].x, coords[prefix].y, true end
  end
  for _, prefix in ipairs(region.maps) do
    for mapId, c in pairs(coords) do
      if mapId:find(prefix, 1, true) then return c.x, c.y, true end
    end
  end
  -- no town map data: the invented grid, which is rough but placed
  return region.at[1], region.at[2], false
end

-- Which continent's page is the map showing?
--
-- The library does not document a field for this and the Gen 2 source is
-- not available to check, so several plausible names are tried before
-- falling back to the player's own continent -- which is right whenever
-- the player has not paged away from where they are, i.e. almost always.
-- A wrong guess here would put markers in the sea, so an unrecognised
-- shape answers the fallback rather than a guess.
-- The Gen 2 Pokegear answers this itself: `Pokegear:region()` returns
-- "johto" or "kanto", following the PLAYER's landmark exactly as
-- PokegearMap_CheckRegion does.  Guessing at field names was only ever a
-- stand-in for not having the source; this is the engine's own answer.
function Gear.pageLand(gear, hereRegion)
  if gear and type(gear.region) == "function" then
    local ok, land = pcall(gear.region, gear)
    if ok and type(land) == "string" then
      local low = land:lower()
      if low:find("johto") then return "johto" end
      if low:find("kanto") then return "kanto" end
    end
  end
  -- older or stubbed gears may expose it as a plain field
  local v = gear and gear.mapRegion
  if type(v) == "string" then
    local low = v:lower()
    if low:find("johto") then return "johto" end
    if low:find("kanto") then return "kanto" end
  end
  return hereRegion and hereRegion.land or nil
end

-- The engine's own conversion for the GEN 1 town map, kept for that path.
local function markerXY(tx, ty)
  return tx * 8 + 16, ty * 8 + 8
end

-- GEN 2 IS DIFFERENT, and this is why the markers never appeared where the
-- towns are.  The Gen 2 Pokegear does not use tile coordinates at all: each
-- landmark carries `x` and `y` in SCREEN PIXELS already (the landmark macro
-- stores x+8 / y+16 in OAM space and the extractor takes the offsets back
-- off), and `Pokegear:drawMap` draws the player icon straight at
-- `player.x, player.y`.
--
-- So on Gen 2 the right thing is not to convert anything: find the
-- landmark by name and use its own pixel position, exactly as the gear
-- does for its own two icons.
function Gear.landmarkXY(gear, region)
  local set = gear and gear.landmarks and gear.landmarks.landmarks
  if type(set) ~= "table" then return nil end
  for _, prefix in ipairs(region.maps) do
    local wanted = tostring(prefix):gsub("_", ""):upper()
    for _, lm in pairs(set) do
      local name = tostring(lm.name or ""):gsub("[^%a]", ""):upper()
      if name ~= "" and lm.x and lm.y
          and (name:find(wanted, 1, true) or wanted:find(name, 1, true)) then
        return lm.x, lm.y
      end
    end
  end
  return nil
end

-- ------- installation

local function coveredByGen2RivalGear()
  -- The World already exposes weather through RIVALGEAR > WEATHER TRACKER.
  -- On Gold/Silver, adding this module's forecast card and map overlay to the
  -- native Pokégear creates duplicate tabs for the same feature. Keep this
  -- module available to standalone Weather FX and to Gen 1 integrations.
  if not (mod.exports and mod.exports.integratedAIRivals) then return false end
  local ok, Host = pcall(require, "mods.the_world.reforged.core.host")
  return ok and Host and type(Host.isGen2) == "function" and Host.isGen2()
end

function Gear.install()
  if coveredByGen2RivalGear() then
    Gear.reason = "weather is already available in Gen 2 Rival Gear"
    return false
  end
  if not Config.get().pokegear.enabled then
    Gear.reason = "disabled in config"
    return false
  end

  local ok, api = pcall(function()
    local handle = mod:find("pokegear_cards")
    return handle and handle.exports or nil
  end)
  if not ok or not api then
    Gear.reason = "pokegear_cards not present"
    return false
  end
  if api.apiVersion ~= 1 then
    -- A future API is not assumed compatible: losing the card is a small
    -- cost, guessing at a changed contract inside somebody else's UI is not.
    Gear.reason = ("pokegear_cards API v%s is not v1"):format(tostring(api.apiVersion))
    return false
  end

  local okReg, err = pcall(function()
    -- ---------------------------------------------------------------
    -- 1. THE OVERLAY on the real map.  This is the feature; the card
    --    below is a convenience next to it.
    -- ---------------------------------------------------------------
    -- Recorded so a silent failure is visible: if the library ignores the
    -- host, or the map card is registered under another name, the overlay
    -- never draws and nothing else would say so.
    Gear.overlayHandle = api.append({
      host = "map",
      id = "weather_fx_fronts",
      kind = "overlay",
      draw = function(gear)
        local H = api.helpers
        local hereRegion = select(2, Fronts.weatherFor(Scene.now.mapId))
        -- ONLY THE CONTINENT ON SCREEN.
        --
        -- The Gen 2 map has a Johto page and a Kanto page, each with its
        -- own coordinate space.  Drawing all 22 regions on whichever page
        -- is showing put every Kanto marker somewhere arbitrary on Johto --
        -- the scattered dots in the sea and on the mountains.
        --
        -- The page is asked for first (several likely field names, since
        -- the library does not document one) and the player's own
        -- continent is the fallback, because the map opens on where they
        -- are.  Unknown means draw nothing rather than draw wrongly.
        local page = Gear.pageLand(gear, hereRegion)
        for _, r in ipairs(Fronts.snapshot()) do
          local region = Fronts.byId[r.id]
          local colour = colourFor(r.weather)
          local onPage = (page == nil) or (r.land == page)
          if region and colour and onPage then
            -- Gen 2 first: its landmarks carry real pixel positions.
            local px, py = Gear.landmarkXY(gear, region)
            local tx, ty = Gear.tileFor(region)
            -- A LETTER, NOT A COLOURED SQUARE.
            --
            -- The town map is a busy four-colour picture with orange
            -- landmark squares already on it, and a small coloured rect on
            -- top of that reads as "another dot" -- every marker looked
            -- the same shade in play whatever weather it stood for.  A
            -- glyph says which weather it is without the player having to
            -- distinguish blue-ish from grey-ish against green and brown,
            -- and it survives any palette the page is drawn in.
            --
            -- Text is placed in CHARACTER cells, which is the same 8-pixel
            -- grid the town map squares use, so `tx, ty` is already the
            -- right cell -- the +2/+1 offset matches markerXY's pixel nudge.
            if px and py then
              -- pixel space: a coloured marker, since text here would land
              -- on an 8-pixel grid the map does not use
              H.marker(gear, px, py, colour)
              if hereRegion and hereRegion.id == r.id then
                H.marker(gear, px - 4, py - 4, colour)
                H.marker(gear, px + 4, py - 4, colour)
              end
            else
              H.text(gear, glyphFor(r.weather), tx + 2, ty + 1)
              if hereRegion and hereRegion.id == r.id then
                H.text(gear, "[", tx + 1, ty + 1)
                H.text(gear, "]", tx + 3, ty + 1)
              end
            end
          end
        end
      end,
    })

    -- ---------------------------------------------------------------
    -- 2. THE FORECAST CARD.  A list, not a drawn map: the panel is 20x14
    --    characters and the previous attempt at a map here produced
    --    symbols floating on an empty screen.  The map overlay above is
    --    where the shape of the weather belongs; this is where the words
    --    belong.
    -- ---------------------------------------------------------------
    api.register({
      id = "the_world",
      label = "WEATHER",
      icon = api.DEFAULT_ICON,
      priority = 120,
      owner = mod.id,

      -- Card mode only: the library backs out to the strip on B unless
      -- the card is busy, so this only ever sees input while the player is
      -- reading the forecast.
      update = function(gear, input, dt)
        local st = api.state("the_world")
        st.scroll = st.scroll or 0
        local function held(name)
          if not input then return false end
          if type(input.pressed) == "function" then return input:pressed(name) end
          if type(input.isDown) == "function" then return input:isDown(name) end
          return input[name] and true or false
        end
        if held("down") then st.scroll = st.scroll + 1 end
        if held("up") then st.scroll = st.scroll - 1 end
        if held("right") then st.scroll = st.scroll + Gear.ROWS end
        if held("left") then st.scroll = st.scroll - Gear.ROWS end
        if st.scroll < 0 then st.scroll = 0 end
      end,

      draw = function(gear)
        local H = api.helpers
        H.drawStrip(gear)

        -- THE GAME'S OWN FRAMED BOX, rather than text on bare background.
        -- Every vanilla Pokegear card puts its content inside one; without
        -- it this card read as text pasted over the screen -- three
        -- separate white slabs with nothing tying them together.  One box
        -- around the list is what makes it look like it belongs.
        -- Guarded: an older build of the library has no `textbox`, and a
        -- missing frame should cost the border, not the card.
        if type(H.textbox) == "function" then
          H.textbox(gear, 0, 4, 18, Gear.ROWS + 1)
        end

        -- Row 3 collided with the strip cursor, which sits under the
        -- selected icon; row 4 is the first that is reliably clear.
        -- WHAT THE PLAYER WILL ACTUALLY SEE, not what the region's front
        -- says.  A front is only the region's own sky; a pinned rung, an
        -- ALWAYS setting, a `force`, a location override, a psystorm or a
        -- roused bird all outrank it.  Reporting the front regardless made
        -- the card say BLIZZ over a town with a clear sky, which is worse
        -- than saying nothing -- a forecast that disagrees with the window
        -- is not a forecast.
        local _, region = Fronts.weatherFor(Scene.now.mapId)
        local shown = Types.get(State.id).label
        local where = region and region.label or "HERE"
        H.text(gear, ("%-6s %s"):format(where, shown), 1, 3)

        -- EVERY region, scrollable.  The previous version listed only the
        -- six longest-running fronts and hid the rest behind "+7 MORE",
        -- which answered "is anything happening" but not "what is it doing
        -- at Blackthorn" -- and that second question is the one a forecast
        -- exists for.
        --
        -- Sorted weather-first so the interesting rows are at the top
        -- without the clear ones being unreachable, then by name so the
        -- order is stable between draws rather than shuffling as clocks
        -- tick past each other.
        local rows = {}
        for _, r in ipairs(Fronts.snapshot()) do rows[#rows + 1] = r end
        table.sort(rows, function(a, b)
          local ac = (a.weather == Types.DEFAULT)
          local bc = (b.weather == Types.DEFAULT)
          if ac ~= bc then return bc end
          return a.label < b.label
        end)
        local n = #rows

        local st = api.state("the_world")
        st.scroll = math.max(0, math.min(st.scroll or 0, math.max(0, n - Gear.ROWS)))

        for i = 1, Gear.ROWS do
          local r = rows[i + st.scroll]
          if r then
            -- 20 columns: glyph(1) space(1) label(6) space(1) weather(6)
            -- leaves two spare, so nothing can run off the right edge --
            -- the bug that printed rows over each other.
            -- inside the box: one space of padding, then glyph, region,
            -- weather, in fixed columns so the three line up down the page
            -- the region underfoot is marked, so a row that disagrees
            -- with the header is visibly the one being overridden rather
            -- than looking like a bug
            local mark = (region and region.id == r.id) and ">" or " "
            H.text(gear, ("%s%s %-6s %-6s"):format(mark,
              glyphFor(r.weather), r.label, Types.get(r.weather).label), 1, 5 + i)
          end
        end

        -- position, and which way there is more to see
        local top = st.scroll
        local bottom = math.min(n, st.scroll + Gear.ROWS)
        -- the position line sits just under the box, and uses the arrows
        -- the game's own menus use rather than caret and vee
        H.text(gear, ("%s%d-%d/%d%s"):format(
          top > 0 and "<" or " ", top + 1, bottom, n,
          bottom < n and ">" or " "), 1, 5 + Gear.ROWS + 2)
      end,
    })
  end)

  if not okReg then
    Gear.reason = "register failed: " .. tostring(err)
    mod.log:warn("pokegear weather: %s", Gear.reason)
    return false
  end

  Gear.installed = true
  Gear.reason = Gear.overlayHandle and "installed" or "card only (map overlay refused)"
  mod.log:info("pokegear weather overlay + card registered")
  return true
end

return Gear
