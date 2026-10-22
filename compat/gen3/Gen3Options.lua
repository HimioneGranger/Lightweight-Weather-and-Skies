-- Gen 3 MOD OPTIONS rows. DESIGN.md §2.7, §4.3 Gen3Options, §5.2.
-- Loaded EARLY (synchronously, from Gen3Compat's top level), before
-- compat/Bootstrap.lua calls Preferences:define() -- ENG mods\Loader.lua's
-- options.define REPLACES the whole schema on every call, so this file
-- wraps mod.options.define itself and appends the Gen 3 rows to whatever
-- schema the next caller passes, rather than trying to call define twice.
--
-- New keys are prefixed gen3_ (verify-gameplay #6): mod options are not
-- scoped per game, so this keeps Gen 3 values apart from any Gen 1/Gen 2
-- option of the same short name.

local mod, loadModule, hostLib, shared = ...

local Gen3Options = {}

-- ------- the WEATHER and NATURE AMBIENCE rows never change shape -------
local WEATHER_ROW = {
  key = "gen3_weather", type = "choice", label = "WEATHER", default = "AUTO",
  choices = { { "OFF", "OFF" }, { "AUTO", "AUTO" }, { "CYCLE", "CYCLE" } },
}
local NATURE_ROW = {
  key = "gen3_nature", type = "toggle", label = "NATURE AMBIENCE", default = true,
}

-- ------- the DAYTIME row changes shape with the clock mode -------------
--
-- rtc / rtc-os: single fixed value, no hold, no cycle -- holding would
-- split the sky from the Pokemon (DESIGN.md §2.7). tws: TWS's own sources.
local TWS_DAYTIME_CHOICES = {
  { "AUTO (20-MIN CYCLE)", "cycle" },
  { "DEVICE CLOCK", "system" },
  { "HOLD MORNING", "fixed:MORN" },
  { "HOLD DAY", "fixed:DAY" },
  { "HOLD EVENING", "fixed:EVE" },
  { "HOLD NIGHT", "fixed:NITE" },
  { "OFF", "off" },
}

-- rtc-os shares rtc's UI meaning (one clock, no hold, no cycle -- the
-- fallback still follows the device with RTC's 4/10/18 rule, DESIGN.md
-- §2.6), so it reuses the same single-value row; only the mode string
-- differs internally. Not specified verbatim in DESIGN.md as separate UI
-- copy, so this reuses the one string DESIGN.md does give rather than
-- inventing new label text.
local RTC_DAYTIME_CHOICES = {
  { "REAL TIME (RTC)", "rtc" },
}

local currentMode = "tws" -- until RealTimeClockCompat calls setMode
local lastFullSchema = nil -- the last schema TWS itself asked to define

local function daytimeRow()
  local choices = (currentMode == "rtc" or currentMode == "rtc-os")
    and RTC_DAYTIME_CHOICES or TWS_DAYTIME_CHOICES
  return {
    key = "gen3_daytime", type = "choice", label = "DAYTIME",
    default = choices[1][2], choices = choices,
  }
end

local origDefine = mod.options and mod.options.define
-- LWS 1.1.0 port: Preferences.lua defines LIGHTNING / STORM PACE / STORM
-- MOTION / CONSTELLATIONS, then lib/Settings.lua re-defines its own rows on
-- game.ready/game.start/save.loaded, and each define replaces the schema.
-- Gen 1/2 re-add the storm rows through ui.options.rows (compat/Controls.lua);
-- Gen 3 has only this schema, so without this the in-game MOD OPTIONS lost
-- LIGHTNING FULL/SOFT/OFF. Keep the last storm rows seen in any define.
local STORM_KEYS = { stormLightning = true, stormPace = true, stormMotion = true, skyConstellations = true }
local stormRows = nil
local function buildSchema(twsSchema)
  local out = {}
  local found = {}
  for _, row in ipairs(twsSchema or {}) do
    if type(row) == "table" and STORM_KEYS[row.key] then found[#found + 1] = row end
  end
  if #found > 0 then stormRows = found end
  for _, row in ipairs(twsSchema or {}) do out[#out + 1] = row end
  if #found == 0 and stormRows then
    for _, row in ipairs(stormRows) do out[#out + 1] = row end
  end
  -- "Hide rows that do nothing on Gen 3": nothing in this pass identified
  -- a TWS row that must be dropped outright (Preferences.lua's own four --
  -- LIGHTNING, STORM PACE, STORM MOTION, CONSTELLATIONS -- all still mean
  -- something on Gen 3 per §4.3). Left as a pass-through; flagged as an
  -- open item in TWS_LAB_PATCHES.md rather than guessing.
  out[#out + 1] = WEATHER_ROW
  out[#out + 1] = daytimeRow()
  out[#out + 1] = NATURE_ROW
  return out
end

if mod.options then
  mod.options.define = function(self, schema)
    lastFullSchema = schema
    return origDefine(self, buildSchema(schema))
  end
end

-- Called by RealTimeClockCompat when the clock mode settles or changes
-- (rtc / rtc-os / tws, DESIGN.md §2.3). Redefines the schema so the
-- DAYTIME row's choices match; a no-op the first time nothing has called
-- define() yet (lastFullSchema is nil until Bootstrap's Preferences:define()
-- runs, which happens after this file loads but still before mods.loaded).
function Gen3Options.setMode(mode)
  if mode == currentMode then return end
  currentMode = mode
  if lastFullSchema and mod.options and origDefine then
    local ok, err = pcall(origDefine, mod.options, buildSchema(lastFullSchema))
    if not ok then mod.log:warn("gen3: options redefine failed: %s", tostring(err)) end
  end
end

function Gen3Options.mode()
  return currentMode
end

-- What RealTimeClockCompat polls to drive Config.get().time in tws mode
-- (DESIGN.md §2.6 item 2). Returns the raw option value (e.g. "cycle",
-- "system", "fixed:MORN", "off") or nil if the option system is not ready.
function Gen3Options.daytimeValue()
  local ok, value = pcall(function()
    return mod.options and mod.options.get and mod.options:get("gen3_daytime")
  end)
  if ok then return value end
  return nil
end

function Gen3Options.natureOn()
  local ok, value = pcall(function()
    return mod.options and mod.options.get and mod.options:get("gen3_nature")
  end)
  if ok and value ~= nil then return value end
  return true
end

-- ------- developer-only debug surface -----------------------------------
-- DESIGN.md §4.3: "Developer builds only: exports.gen3Debug.setWeather(id)
-- via State.set/setWeather (lib\WeatherState.lua:101, 362)".
if mod.developer then
  mod.exports.gen3Debug = mod.exports.gen3Debug or {}
  mod.exports.gen3Debug.setWeather = function(id)
    -- Looked up at CALL time, not captured at load time: this file loads
    -- early (before Weather.install() sets mod.exports.lib), but a
    -- developer only calls this after boot has finished.
    local lib = mod.exports and mod.exports.lib
    if not (lib and lib.require) then return false, "TWS exports.lib not ready" end
    local ok, State = pcall(lib.require, "WeatherState")
    if not ok or not State then return false, "WeatherState unavailable" end
    if type(State.setWeather) == "function" then
      local sok, serr = pcall(State.setWeather, id, "gen3Debug")
      return sok, serr
    end
    if type(State.set) == "function" then
      local sok, serr = pcall(State.set, id)
      return sok, serr
    end
    return false, "no setter on WeatherState"
  end
end

shared.options = Gen3Options

return Gen3Options
