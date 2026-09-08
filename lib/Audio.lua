-- WEATHER AUDIO.
--
-- A looping bed per weather family, cross-faded when the weather turns,
-- with the volume following the eased channel so a storm swells as it
-- arrives rather than snapping on -- and a thunder one-shot fired from the
-- strike scheduler so the crack lands with the flash.
--
-- =====================================================================
-- WHAT IS AND IS NOT COVERED, STATED UP FRONT
-- =====================================================================
--
-- Four beds arrived for nineteen weathers.  Rain, heavy rain, primal rain,
-- thunderstorms and gales map onto them cleanly.  Snow, blizzards, hail,
-- sleet, sandstorm, ashfall, strong winds and fog have NO audio and are
-- deliberately SILENT rather than borrowed: rain played under a blizzard
-- is worse than quiet, because it tells the player something false about
-- what is on screen.  Adding one later is a row in `Audio.BEDS` and a file.
--
-- =====================================================================
-- WHY love.audio DIRECTLY
-- =====================================================================
--
-- The engine's audio registry is built around the game's own music and
-- cries -- tracks it owns, selected through `music.select` and mixed at
-- the engine's volume.  A weather bed is neither: it plays UNDER whatever
-- music is running, follows a channel value rather than a track change,
-- and has to duck and swell continuously.  Driving `love.audio` directly
-- keeps that entirely inside this mod, where it can be switched off
-- without touching anything the engine mixes.
--
-- The cost is that the engine's own volume slider does not reach it, so
-- this carries its own -- `WEATHER SFX` in the mod manager, OFF included.
--
-- =====================================================================
-- CROSS-FADE, NOT SWAP
-- =====================================================================
--
-- Two slots, never one.  A weather change fades the outgoing bed down
-- while the incoming one comes up, over the same seconds the visual
-- transition takes, so the ear and the eye agree about when the storm
-- arrived.  Swapping the source instead would produce a click and a
-- discontinuity exactly at the moment the player is looking up.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local Config = V.require("Config")
local Settings = V.require("Settings")
local Scene = V.require("Scene")
local State = V.require("WeatherState")
local Lightning = V.require("Lightning")
local Settings = V.require("Settings")
local Legendary = V.require("Legendary")

local Audio = {}
local Variants = V.require('AudioVariants')

Audio.DIR = "assets/sounds/"

-- Which bed a weather uses, and how loud at full channel.  `nil` means
-- silent, which is most of the catalogue and is a decision rather than a
-- gap -- see the header.
--
-- Chosen by the weather's own id so the mapping is readable, with a
-- channel-driven fallback for anything unlisted (a new rain type gets rain
-- without being named here).
Audio.BEDS = {
  RAIN_LIGHT  = { file = "rain",        gain = 0.55 },
  RAIN        = { file = "rain",        gain = 0.55 },
  RAIN_HEAVY  = { file = "rain_heavy",  gain = 0.75 },
  HEAVY_RAIN  = { file = "heavy_storm", gain = 0.95 },
  STORM       = { file = "storm",       gain = 0.85 },
  GALE        = { file = "storm",       gain = 0.7 },
  SLEET       = { file = "rain",        gain = 0.4 },
  PRIMAL_RAIN = { file = "heavy_storm", gain = 1.0 },
  PSYSTORM    = { file = "storm",       gain = 0.65 },
  DRAGONSTORM = { file = "storm",       gain = 0.8 },
  THUNDERSNOW = { file = "storm",       gain = 0.7 },
  -- Clear / non-rain: no bed (wind layer may still run from gust)
  CLEAR       = nil,
  SUNNY       = nil,
  FOG         = nil,
  MIST        = nil,
}

Audio.THUNDER = { "thunder_clap", "thunder_roll" }
-- Keep all thunder under the event scheduler, not baked into a looping bed.
if V.questLitePrivate then Audio.BEDS.STORM={file='rain_heavy',gain=.78} end

-- WIND IS ITS OWN LAYER, not another bed.
--
-- A bed is chosen -- a weather has one or it has none -- and the two slots
-- cross-fade between them.  Wind is not like that: a gale and a downpour
-- happen at once, and a blizzard is nothing BUT wind.  So it plays
-- alongside whatever bed is running, at a volume taken straight from the
-- `gust` channel, which means it swells and drops with the same oscillator
-- that leans the rain and drifts the snow.
--
-- This also gives most of the previously-silent weathers a voice without
-- misrepresenting them: a blizzard, a sandstorm, an ashfall and the strong
-- winds all carry gust, and wind is what they actually sound like.  Fog
-- has none and stays silent, which is correct -- fog is quiet.
Audio.WIND = { file = "wind", gain = 0.6 }

-- Which wind.  Grit blowing across a desert does not sound like wind
-- through trees, and a sandstorm that borrowed the ordinary loop would be
-- the same lie as a blizzard borrowing the rain.
--
-- Matched by capability tag rather than by id, so a new sandy weather --
-- ashfall already, and whatever comes next -- gets the right wind without
-- being named here.
function Audio.windFileFor(def)
  if def and def.sandy then return "wind_desert" end
  return Audio.WIND.file
end

-- A weather with no entry still gets rain if it is genuinely raining:
-- the id table is for tuning, not for gatekeeping.
local function bedFor(def)
  if not def then return nil end
  local id = def.id
  if Audio.BEDS[id] ~= nil then
    return Audio.BEDS[id]  -- explicit entry (including intentional silence later)
  end
  -- Explicit silence for clear-family
  if id == "CLEAR" or id == "SUNNY" or id == "FOG" or id == "MIST" then
    return nil
  end
  if Types.channel(def, "rain") >= 0.5 then
    return { file = "rain_heavy", gain = 0.6 }
  end
  if Types.channel(def, "rain") > 0 then
    return { file = "rain", gain = 0.45 }
  end
  return nil
end
Audio.bedFor = bedFor

-- ------- loading
--
-- Once per file, and never retried after a failure: a missing sound costs
-- one log line and silence, not a stutter every frame.

local cache, failed = {}, {}
local pathTried = {}

-- ENGINE PATH (correct):
--   mod.assets:path("assets/sounds/rain.ogg") → PhysFS path the host can open
--   love.audio.newSource(path, "static"|"stream")
-- ByteData/newSource is unreliable on Gen1Recomp's sandboxed Love build.

local function assetPath(relative)
  if not mod then return nil end
  local p
  if mod.assets and type(mod.assets.path) == "function" then
    local ok, res = pcall(function() return mod.assets:path(relative) end)
    if ok and type(res) == "string" and res ~= "" then return res end
  end
  if type(mod.path) == "string" and mod.path ~= "" then
    return mod.path .. "/" .. relative
  end
  return nil
end

local function candidatePaths(name)
  local rels = {
    Audio.DIR .. name .. ".ogg",
    Audio.DIR .. name .. ".mp3",
    "assets/sounds/" .. name .. ".ogg",
    "assets/sounds/" .. name .. ".mp3",
    "sounds/" .. name .. ".ogg",
    "sounds/" .. name .. ".mp3",
    name .. ".ogg",
    name .. ".mp3",
  }
  local out = {}
  for _, rel in ipairs(rels) do
    local full = assetPath(rel)
    if full then out[#out + 1] = full end
    out[#out + 1] = rel  -- relative fallback for hosts that resolve from mod root
  end
  return out
end

local function makeSourceFromPath(path, kind)
  if not (love and love.audio and love.audio.newSource) then return nil end
  kind = kind or "static"
  local ok, src = pcall(love.audio.newSource, path, kind)
  if ok and src then return src end
  if kind == "stream" then
    ok, src = pcall(love.audio.newSource, path, "static")
    if ok and src then return src end
  end
  return nil
end

local function makeSourceFromBytes(bytes, label, kind)
  if not (love and love.audio and love.audio.newSource) then return nil end
  kind = kind or "static"
  local bd = byteData(bytes, label)
  if not bd then return nil end
  local function try(fn)
    local ok, src = pcall(fn)
    if ok and src then return src end
    return nil
  end
  if love.sound and love.sound.newDecoder then
    local src = try(function()
      return love.audio.newSource(love.sound.newDecoder(bd), kind)
    end)
    if src then return src end
  end
  local src = try(function() return love.audio.newSource(bd, kind) end)
  if src then return src end
  if love.sound and love.sound.newSoundData then
    src = try(function()
      return love.audio.newSource(love.sound.newSoundData(bd))
    end)
    if src then return src end
  end
  return nil
end

local function sourceFor(name, kind)
  -- Beds always use static + unique Source instances so looping is seamless
  -- and two slots never share one Source (shared cache caused gaps/stops).
  kind = "static"
  local key = name .. "/" .. kind
  if not (love and love.audio) then return nil end

  local function finish(src)
    if not src then return nil end
    cache[key] = src  -- template only
    failed[key] = nil
    if src.clone then
      local ok, c = pcall(function() return src:clone() end)
      if ok and c then return c end
    end
    -- No clone: build a fresh instance from path/bytes below (do not return template)
    return nil
  end

  -- Prefer cached template → clone
  if cache[key] then
    local t = cache[key]
    if t.clone then
      local ok, c = pcall(function() return t:clone() end)
      if ok and c then return c end
    end
  end

  -- 1) Path-based (preferred — matches engine Sound/Music)
  for _, path in ipairs(candidatePaths(name)) do
    local src = makeSourceFromPath(path, kind)
    local inst = finish(src)
    if inst then return inst end
    if src then
      -- clone failed; create a second independent source from path
      local src2 = makeSourceFromPath(path, kind)
      if src2 then return src2 end
      return src
    end
  end

  -- 2) mod:read bytes → Decoder/Source (fallback)
  local data, label
  for _, try in ipairs({ ".ogg", ".mp3" }) do
    for _, prefix in ipairs({ Audio.DIR, "assets/sounds/", "sounds/", "" }) do
      local ok, body = pcall(function() return mod:read(prefix .. name .. try) end)
      if ok and body and type(body) == "string" and #body > 32 then
        data, label = body, name .. try
        break
      end
    end
    if data then break end
  end
  if data then
    local src = makeSourceFromBytes(data, label, kind)
    local inst = finish(src)
    if inst then return inst end
    if src then
      local src2 = makeSourceFromBytes(data, label, kind)
      if src2 then return src2 end
      return src
    end
  end

  if not failed[key] then
    failed[key] = true
    pcall(function()
      mod.log:warn("weather sound %s could not be opened (path+bytes)", name)
    end)
  end
  return nil
end

function Audio.invalidate()
  Variants.reset()
  if V.questLitePrivate then V.require('QuestNature').reset()end
  for _,src in ipairs(Audio._oneshots or {})do pcall(function()src:stop()end)end
  Audio._oneshots={}
  for _, src in pairs(cache) do pcall(function() src:stop() end) end
  cache, failed = {}, {}
  Audio.slots = { {}, {} }
  Audio.wind = { level = 0, file = nil }
end

-- ------- the two bed slots

Audio.slots = { {}, {} }     -- { file, src, level, target }
Audio.wind = { level = 0, file = nil }   -- plays over any bed
Audio.lastStrike = -1

local function slotFor(file)
  for i = 1, 2 do
    if Audio.slots[i].file == file then return Audio.slots[i] end
  end
  return nil
end

local function freeSlot()
  local quietest, best = nil, 2
  for i = 1, 2 do
    local s = Audio.slots[i]
    if not s.file then return s end
    if (s.level or 0) < best then quietest, best = s, s.level or 0 end
  end
  return quietest
end

-- ------- volume
--
-- Two multipliers on top of the bed's own gain, both continuous so
-- nothing steps: how much of the weather is actually falling, and where
-- the player is.

-- True only when the player is in the live overworld (or battle).
-- Title screen, launcher, and pure menus have no mapId / world visibility.
local function inOverworldAudio()
  local now = Scene.now
  if not now then return false end
  -- Title / launcher: Scene has no live map. Overworld always has mapId.
  if now.visible == "battle" then return true end
  if now.mapId then return true end
  return false
end

local function contextGain()
  if not inOverworldAudio() then return 0 end
  local cfg = Config.get().audio or {}
  local vis = Scene.now and Scene.now.visible
  if vis == "battle" then
    return tonumber(cfg.battle) or 0.35
  end
  if Scene.now and Scene.now.indoors then
    return 0
  end
  return 1
end

function Audio.masterGain()
  local sfx = Settings.get("sfx")
  if sfx == "off" or sfx == false then return 0 end
  local cfg = Config.get().audio or {}
  if cfg.enabled == false then return 0 end
  local named = { low = 0.4, medium = 0.7, high = 1.0, off = 0 }
  local row = named[sfx]
  if row == nil then row = 0.85 end  -- default audible if row missing
  return row * (tonumber(cfg.volume) or 1) * contextGain()
end

-- ------- the tick


local function rainFamilyId(id)
  -- Strict rain-family. Never substring-match STORM (would match DUSTSTORM).
  if not id then return false end
  id = tostring(id):upper()
  if id == "DUSTSTORM" or id == "SANDSTORM" or id == "ASHFALL"
      or id == "FLOCKSTORM" or id == "SNOW_LIGHT" or id == "BLIZZARD"
      or id == "HAIL" or id == "CLEAR" or id == "FOG" or id == "MIST" then
    return false
  end
  if id:find("RAIN", 1, true) ~= nil then return true end
  if id == "STORM" or id == "PSYSTORM" or id == "DRAGONSTORM" then return true end
  if id == "SLEET" or id == "GALE" or id == "THUNDERSNOW" or id == "PRIMAL_RAIN"
      or id == "HEAVY_RAIN" then
    return true
  end
  return false
end

local function strikeWeatherId(id)
  if not id then return false end
  id = tostring(id):upper()
  -- Never thunder for pure dry dust/sand
  if id == "DUSTSTORM" or id == "SANDSTORM" or id == "ASHFALL"
      or id == "CLEAR" or id == "FOG" or id == "MIST"
      or id == "SUNNY" or id == "HARSH_SUN" then
    return false
  end
  if id == "STORM" or id == "PSYSTORM" or id == "DRAGONSTORM"
      or id == "THUNDERSNOW" or id == "HEAVY_RAIN" or id == "PRIMAL_RAIN"
      or id == "GALE" or id == "RAIN_HEAVY" then
    return true
  end
  if id:find("RAIN", 1, true) ~= nil then
    -- Light rain may still have low strike channel — allow if channel says so
  end
  local def = State.current and State.current()
  if def and Types.channel then
    local ok, s = pcall(Types.channel, def, "strike")
    if ok and type(s) == "number" and s > 0.05 then return true end
  end
  -- Live channel from State
  local ok2, s2 = pcall(function() return State.channel("strike") end)
  if ok2 and type(s2) == "number" and s2 > 0.05 then return true end
  return false
end

local function stopSource(src)
  if not src then return end
  pcall(function()
    if src.setVolume then src:setVolume(0) end
    if src.setLooping then src:setLooping(false) end
    if src.stop then src:stop() end
  end)
end

local function stopSlot(slot)
  if not slot then return end
  stopSource(slot.src)
  slot.file, slot.src, slot.level = nil, nil, 0
end

function Audio.stopAllBeds()
  Variants.reset()
  if V.questLitePrivate then V.require('QuestNature').reset()end
  for i = 1, 2 do stopSlot(Audio.slots[i]) end
  local w = Audio.wind
  if w then
    stopSource(w.src)
    w.src, w.file, w.level = nil, nil, 0
  end
  if Audio._oneshots then
    for _, src in ipairs(Audio._oneshots) do stopSource(src) end
    Audio._oneshots = {}
  end
  Audio._bedFile = nil
end

function Audio.update(dt)
  if not (love and love.audio) then return end
  if V.questLitePrivate then
    local storm=V.require('QuestStorm')
    local silent=not inOverworldAudio() or Audio.masterGain()<=0 or storm.preferences().mode=='off'
    local live={}
    for _,src in ipairs(Audio._oneshots or {})do
      if silent then stopSource(src)
      elseif src.isPlaying and src:isPlaying() then live[#live+1]=src end
    end
    Audio._oneshots=live
  end
  dt = tonumber(dt) or 0
  if dt <= 0 or dt > 0.25 then dt = 1 / 60 end
  if V.questLitePrivate then V.require('QuestNature').update(dt,Audio.masterGain())end

  -- Title / launcher / no map: silence everything immediately
  if not inOverworldAudio() then
    Variants.reset()
    for i = 1, 2 do
      local slot = Audio.slots[i]
      if slot and slot.src then
        pcall(function() slot.src:stop() end)
        slot.file, slot.src, slot.level = nil, nil, 0
      end
    end
    local w = Audio.wind
    if w and w.src then
      pcall(function() w.src:stop() end)
      w.src, w.file, w.level = nil, nil, 0
    end
    Audio._bedFile = nil
    return
  end

  local master = Audio.masterGain()
  local wxId = State.id or (State.current and State.current() and State.current().id) or nil
  if type(wxId) == "string" then wxId = wxId:upper() end
  -- AUTHORITY: weather id only (menu change updates State.id). Channels do not keep beds.
  local wantFile, wantGain = nil, 0
  -- Continuous rain bed: only while rain-family weather AND rain is on screen (falling).
  -- Multi-layer 60s seamless beds remove audible loop pauses.
  local rainCh = 0
  pcall(function() rainCh = tonumber(State.channel("rain")) or 0 end)
  local recoveryRain=0
  if V.questLitePrivate then recoveryRain=V.require('QuestAfterStorm').rain or 0 end
  rainCh=math.max(rainCh,recoveryRain)
  local rainOnScreen = rainCh > 0.02
  local allowRainSfx = master > 0 and (rainFamilyId(wxId) or recoveryRain>0.02) and rainOnScreen
  if allowRainSfx then
    local bed = bedFor(State.current and State.current() or nil)
    if not bed or not bed.file then
      bed = { file = "rain", gain = 0.55 }
    end
    if bed and bed.file then
      wantFile = bed.file
      local dens = math.max(0.35, rainCh)
      wantGain = (bed.gain or 0.6) * 0.8 * math.min(1.2, 0.5 + dens * 0.65)
      if recoveryRain>0 and not rainFamilyId(wxId) then wantGain=wantGain*math.min(1,recoveryRain/.8) end
    end
  else
    -- Weather changed away from rain, or no rain particles on screen: stop.
    wantFile, wantGain = nil, 0
  end

  local windFile,windGain=nil,0
  local windEnabled=master>0
  pcall(function()if (Config.get().audio or {}).wind==false then windEnabled=false end end)
  if windEnabled then
    local gust=State.channel('gust') or 0
    if gust>.05 then windFile=Audio.windFileFor(State.current());windGain=math.min(1,gust)*Audio.WIND.gain end
  end
  Variants.update(dt,wantFile,wantGain,windFile,windGain,master,sourceFor)

  -- ------- thunder one-shot on each new lightning strike
  local age = Lightning.age or -1
  local thunderOn = true
  pcall(function()
    local a = Config.get().audio
    if a and a.thunder == false then thunderOn = false end
  end)
  -- Soft/off lightning modes still allow distant thunder if strikes schedule
  local lightMode = "full"
  pcall(function() lightMode = tostring(Settings.get("lightning") or "full"):lower() end)
  -- Quest's visible mode is authoritative; the hidden legacy row must not
  -- silently veto FULL/SOFT after migration from an older build.
  if not V.questLitePrivate and lightMode == "off" then thunderOn = false end

  local canThunder = thunderOn and master > 0 and strikeWeatherId(wxId)
  local newStrike = Lightning.justStruck == true
  if newStrike then Lightning.justStruck = false end
  local thunderEvent
  if V.questLitePrivate then
    local storm=V.require('QuestStorm')
    thunderEvent=storm.consumeThunder()
    newStrike=thunderEvent~=nil
    canThunder=thunderOn and master>0 and storm.preferences().mode~='off'
  end

  if canThunder and newStrike then
    local pick = nil
    if thunderEvent then pick=thunderEvent.sound
    else pcall(function() pick = Legendary.thunderSound() end) end
    if type(pick) ~= "string" or pick == "" then
      local names = Audio.THUNDER
      local r = (love.math and love.math.random or math.random)
      pick = names[r(#names)]
    end
    pick=Variants.pick((pick and pick:find('roll',1,true)) and 'roll' or 'clap')
    local src = sourceFor(pick, "static")
    if not src and pick ~= "thunder_clap" then
      src = sourceFor("thunder_var2", "static")
    end
    if not src then
      src = sourceFor("thunder_var1", "static")
    end
    if src then
      pcall(function()
        local playSrc = src
        if not V.questLitePrivate and src.clone then
          local okC, c = pcall(function() return src:clone() end)
          if okC and c then playSrc = c end
        end
        pcall(function() playSrc:stop() end)
        local tg = 1
        pcall(function()
          tg = tonumber((Config.get().audio or {}).thunderGain) or 1
        end)
        local vol = math.min(1, math.max(0.45, master * tg))
        if thunderEvent then
          vol=math.max(0,math.min(.65,master*tg*thunderEvent.gain))
          if playSrc.setPitch then playSrc:setPitch(thunderEvent.pitch) end
        end
        playSrc:setVolume(vol)
        if playSrc.setLooping then playSrc:setLooping(false) end
        playSrc:play()
        Audio._oneshots = Audio._oneshots or {}
        Audio._oneshots[#Audio._oneshots + 1] = playSrc
        while #Audio._oneshots > 6 do
          stopSource(table.remove(Audio._oneshots, 1))
        end
      end)
    else
      pcall(function()
        mod.log:warn("weather thunder sound failed to load (clap/roll/zapdos)")
      end)
    end
  end

  Audio.lastStrike = age

end

-- Force a bed to be audible this frame (used when rain/storm is drawn).
function Audio.nudgeFromVisual(weatherId, hasRainAnim, hasLightning)
  if V.questLitePrivate and (V.require('QuestAfterStorm').rain or 0)>.02 then return end
  -- Stop immediately when weather is not rain-family or rain is not on screen.
  local id = weatherId or (State and State.id)
  if type(id) == "string" then id = id:upper() end
  if not rainFamilyId(id) or hasRainAnim == false then
    Variants.stopRain()
  end
end

function Audio.describe()
  if Variants.liveCount()>0 then return ('weather: %d voices'):format(Variants.liveCount()) end
  local playing = {}
  for i = 1, 2 do
    local s = Audio.slots[i]
    if s.file and (s.level or 0) > 0.01 then
      playing[#playing + 1] = ("%s%.0f%%"):format(s.file, s.level * 100)
    end
  end
  if (Audio.wind.level or 0) > 0.01 then
    playing[#playing + 1] = ("%s%.0f%%"):format(
      Audio.wind.file or "wind", Audio.wind.level * 100)
  end
  if #playing == 0 then return "-" end
  return table.concat(playing, "+")
end

return Audio
