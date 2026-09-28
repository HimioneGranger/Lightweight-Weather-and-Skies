-- Fallback minimal schema ensures the mod page is never empty.
-- The mod's own settings: the rows on this mod's page in the mod manager,
-- and typed readers for them.
--
-- WHY NOT THE OPTIONS MENU.  The engine gives a render pipeline a row on
-- the main OPTIONS menu for free (label + ladder + persistence), and the
-- WEATHER row is exactly that -- so the one setting the player changes
-- often is one button press from where they already are.  Everything here
-- is a set-once preference (quality, accessibility, whether battles get
-- weather), and putting seven more rows on the main menu to sit unused
-- would be worse for the player than a page in the manager they visit
-- once.  Dramatic Shape's ModSetting mirrors its two onto both menus
-- because they are per-scene settings; these are not.
--
-- Every read goes through mod.options:get, which falls back to the row's
-- declared default, so a fresh install with nothing persisted reads the
-- same values as a configured one and no caller ever needs a `or`.

local V = ...
local mod = V.mod
local Types = V.require("Types")
local WorldOptions = V.require("WorldOptions")

local Settings = {}

local LITE_VISIBLE = {
  worldWeather = true,
  always = true,
  intensity = true,
  speed = true,
  -- Battle Art's DAYTIME row is q90's single clock control. Exposing this
  -- second switch would let a stale Quest-Lite preference desynchronise the
  -- weather sky from Battle Art's body, lighting, shadows, and water.
  daytime = false,
  snowShape = true,
  sfx = true,
  debug = true,
}

local function visibleInThisBuild(row)
  return not V.questLitePrivate or (row and LITE_VISIBLE[row.key])
end

-- Row order is page order.  Choice values are the stored ones; the first
-- element of each pair is what the row shows.
Settings.SCHEMA = {
  {
    key = "worldWeather", label = "WEATHER", type = "choice", default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Master weather switch. OFF leaves AI simulation available.",
  },
  {
    key = "quality", label = "QUALITY", type = "choice", default = "auto",
    choices = { { "AUTO", "auto" }, { "HIGH", "high" },
                { "MEDIUM", "medium" }, { "LOW", "low" } },
    help = "Particle budget. AUTO picks by platform and steps down if the "
        .. "frame rate sags.",
  },
  {
    -- ALWAYS <WEATHER>: the "always snow", "always rain" switch, on the
    -- page a player can reach without a text editor.  `force` in
    -- config.lua does the same job for a folder install; this is the same
    -- setting for the .modpkg case, which is the one that has caught us
    -- out three times now.
    --
    -- ONE ROW RATHER THAN TWENTY SWITCHES, because these are mutually
    -- exclusive by nature: "always snow" and "always rain" cannot both be
    -- true, and twenty independent toggles would let a player set that and
    -- then wonder which one won.  A single-select row cannot express the
    -- contradiction in the first place.
    --
    -- The choices are built from the catalogue below, so adding a weather
    -- type adds its rung here with no second list to keep in step.
    key = "always", label = "ALWAYS", type = "choice", default = "off",
    choices = nil,          -- filled in below
    help = "Pin one weather everywhere: ALWAYS SNOW, ALWAYS RAIN, and so "
        .. "on. OFF lets the weather system run normally.",
  },
  {
    key = "intensity", label = "INTENSITY", type = "choice", default = "normal",
    choices = { { "SOFT", "soft" }, { "NORMAL", "normal" },
                { "HEAVY", "heavy" }, { "AUTO", "auto" } },
    help = "Scales weather effects (rain, snow, sand, etc.). Fog has its "
        .. "own FOG INTENSITY row. AUTO makes each family swell and ease "
        .. "on its own slow rhythm.",
  },
  {
    -- Separate from INTENSITY so players can keep storms heavy without a
    -- thick fog bank (or the reverse). Multiplies fog/veil channels only.
    key = "fogIntensity", label = "FOG INTENSITY", type = "choice", default = "100",
    choices = {
      { "OFF", "off" },
      { "10%", "10" },
      { "25%", "25" },
      { "50%", "50" },
      { "100%", "100" },
      { "150%", "150" },
      { "200%", "200" },
      { "250%", "250" },
      { "300%", "300" },
      { "350%", "350" },
      { "400%", "400" },
      { "450%", "450" },
      { "500%", "500" },
    },
    help = "Fog and haze only. OFF = none; 10%/25% = light mist; then 50% "
        .. "steps up to 500% (extreme whiteout). Does not change rain or snow.",
  },
  {
    key = "sandIntensity", label = "SAND INTENSITY", type = "choice", default = "100",
    choices = {
      { "OFF", "off" },
      { "10%", "10" },
      { "25%", "25" },
      { "50%", "50" },
      { "100%", "100" },
      { "150%", "150" },
      { "200%", "200" },
      { "250%", "250" },
      { "300%", "300" },
      { "350%", "350" },
      { "400%", "400" },
      { "450%", "450" },
      { "500%", "500" },
    },
    help = "Sandstorm particles and sand haze. Same scale as FOG INTENSITY. "
        .. "Does not raise weather caps — only scales within them.",
  },
  {
    key = "dustIntensity", label = "DUST INTENSITY", type = "choice", default = "100",
    choices = {
      { "OFF", "off" },
      { "10%", "10" },
      { "25%", "25" },
      { "50%", "50" },
      { "100%", "100" },
      { "150%", "150" },
      { "200%", "200" },
      { "250%", "250" },
      { "300%", "300" },
      { "350%", "350" },
      { "400%", "400" },
      { "450%", "450" },
      { "500%", "500" },
    },
    help = "Duststorm particles and dust haze. Same scale as FOG INTENSITY. "
        .. "Does not raise weather caps — only scales within them.",
  },
  {
    -- Snow, hail, sleet, sandstorm and ashfall are the weathers Kanto has
    -- no obvious business having, so the built-in region bias suppresses
    -- them hard away from the few maps that argue for them.  That was
    -- tuned for plausibility and it made them effectively invisible: a
    -- player could run AUTO for hours and never see snow.  This row is the
    -- dial between "plausible" and "I would like to see the thing I
    -- installed", and it defaults to the middle rather than to realism.
    key = "exotic", label = "RARE WEATHER", type = "choice", default = "normal",
    choices = { { "OFF", "off" }, { "RARE", "rare" },
                { "NORMAL", "normal" }, { "OFTEN", "often" } },
    help = "How often snow, hail, sleet, sandstorms and ashfall turn up "
        .. "away from the places that suit them. RARE is the realistic "
        .. "setting; OFF removes them from AUTO entirely.",
  },
  {
    key = "speed", label = "WEATHER ROTATION SPEED", type = "choice", default = "normal",
    choices = { { "SLOW", "slow" }, { "NORMAL", "normal" },
                { "FAST", "fast" }, { "TEST", "test" } },
    help = "How long an AUTO spell lasts. TEST changes it every few "
        .. "seconds, for looking at the effects.",
  },
  {
    key = "daytime", label = "TIME OF DAY", type = "choice", default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Weather FX day/night clock for AUTO bias and tint. OFF leaves "
        .. "time to the active voxel host. Not shown in the game OPTIONS "
        .. "ladder — only in this mod menu.",
  },
  {
    -- Seasons were left out of the first design because Gen 1/2 have none
    -- and the region bias already answers "where does it snow".  Players
    -- still asked for a calendar, so this is the opt-in layer on top: four
    -- seasons, a hemisphere flip, and seasonal weight multipliers on AUTO.
    key = "seasons", label = "SEASONS", type = "choice", default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Four seasons that lean AUTO weather (snow in winter, sun in "
        .. "summer). Uses the real calendar on SYSTEM time, or an in-game "
        .. "year on CYCLE.",
  },
  {
    key = "clouds", label = "CLOUDS", type = "choice", default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Show Weather FX cloud banks in the sky. OFF hides only the "
        .. "clouds; precipitation and other weather keep running.",
  },
  {
    key = "leafColor", label = "LEAF COLOR", type = "choice", default = "green",
    choices = { { "GREEN", "green" }, { "YELLOW", "yellow" },
                { "ORANGE", "orange" }, { "BROWN", "brown" } },
    help = "Color of wind-blown leaves in gale weather.",
  },
  {
    key = "snowShape", label = "SNOW SHAPE", type = "choice", default = "flake",
    choices = { { "FLAKE", "flake" }, { "BALL", "ball" } },
    help = "3D snow look. FLAKE is the normal crystal shape; BALL is soft round snow.",
  },
  {
    key = "hemisphere", label = "HEMISPHERE", type = "choice",
    default = "northern",
    choices = { { "NORTH", "northern" }, { "SOUTH", "southern" } },
    help = "Which hemisphere the seasons follow. SOUTH reverses them so "
        .. "December is summer. Only matters when SEASONS is ON.",
  },
  {
    key = "seasonNotify", label = "SEASON NOTE", type = "choice",
    default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Show a short on-screen banner when the season changes.",
  },
  {
    key = "battles", label = "BATTLES", type = "choice", default = "subtle",
    choices = { { "OFF", "off" }, { "SUBTLE", "subtle" }, { "FULL", "full" } },
    help = "Weather over the battle screen. SUBTLE thins it so the HUD "
        .. "stays readable.",
  },
  {
    -- Species stay registered even when this is OFF. Existing caught
    -- variants and their Pokédex/save records therefore remain valid; only
    -- new wild substitutions stop. Unregistering live species would corrupt
    -- parties and saves made while the option was ON.
    key = "weatherVariants", label = "WX POKEMON", type = "choice",
    default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Weather-form Pokémon in wild encounters. OFF keeps all visual "
        .. "weather active but stops new weather variants from appearing. "
        .. "Variants already caught remain usable.",
  },
  {
    key = "worldWxStarters", label = "WX STARTERS", type = "choice",
    default = "off",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Turn the player starter into a selectable WX form. Shared by Gen 1 and Gen 2 starter flows.",
  },
  {
    key = "battleAnim", label = "BATTLE WEATHER FX", type = "choice",
    default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Weather visuals in battle (rain, sand, fog overlays). "
        .. "OFF keeps battles looking clear while damage rules can still apply.",
  },
  {
    key = "battleDamage", label = "BATTLE WEATHER DMG", type = "choice",
    default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Weather damage and type modifiers in battle (chip, boosts, "
        .. "Weather Ball, etc.). OFF leaves move math vanilla.",
  },
{
    -- The one house rule with a menu row. `terrain` deliberately has none:
    -- it only fires on named maps and contradicts nothing, so it is a config
    -- decision rather than a thing to flip mid-run. Amplified changes how
    -- every primal sky and every sandstorm hits, which is exactly the kind
    -- of thing a player wants to try, dislike, and turn off without editing
    -- a file.
    --
    -- AUTO defers to config.lua (off unless the file says otherwise), so the
    -- row adds a way to answer without taking the file's answer away.
    key = "amplified", label = "AMPLIFIED", type = "choice", default = "auto",
    choices = { { "AUTO", "auto" }, { "OFF", "off" }, { "ON", "on" } },
    help = "House rule, not reference behaviour: harsh sun and heavy rain "
        .. "hit much harder, sandstorms power up ROCK and GROUND, and hail "
        .. "powers up ICE. Ordinary sun and rain are untouched. AUTO follows "
        .. "config.lua, which has it off.",
  },
  {
    key = "lightning", label = "LIGHTNING", type = "choice", default = "full",
    choices = { { "OFF", "off" }, { "SOFT", "soft" }, { "FULL", "full" } },
    help = "SOFT removes the sharp flash and keeps a slow glow -- the "
        .. "setting to use if flashing images are a problem.",
  },
  {
    -- OFF is the default so The World leaves the vanilla battle field untouched
    -- unless the player explicitly enables battle scenery. AROUND uses the
    -- documented render.letterbox hook. BEHIND additionally patches
    -- BattleState.draw to replace the battle's white field, which is the
    -- only engine internal this mod touches -- opt-in, and it stands down
    -- when another mod is staging battles or SGB colour mode is on.
    key = "backdrops", label = "BATTLE ART", type = "choice", default = "off",
    choices = { { "OFF", "off" }, { "AROUND", "around" }, { "BEHIND", "behind" } },
    help = "Painted scenery, picked by the weather and the map. AROUND "
        .. "fills the bars beside the battle; BEHIND also replaces the "
        .. "battle's white field. Art: CDRX73, DerxwnaKapsyla, "
        .. "http404error, Game Freak.",
  },
  {
    key = "sfx", label = "WEATHER SFX", type = "choice", default = "medium",
    choices = { { "OFF", "off" }, { "LOW", "low" },
                { "MEDIUM", "medium" }, { "HIGH", "high" } },
    help = "Rain and storm loops, and thunder on the strike. Only the rain "
        .. "weathers have sound; the rest are silent on purpose.",
  },
  {
    key = "splash", label = "SPLASHES", type = "choice", default = "on",
    choices = { { "ON", "on" }, { "OFF", "off" } },
    help = "Drops burst where they land.",
  },
  {
    -- OFF by default, and the row itself says why.  This is the only
    -- setting in the mod that MOVES THE PLAYER, and a warp does not know
    -- what the story expects: even restricted to places already visited,
    -- being carried mid-errand can strand you without the HM you set out
    -- with, or drop you the wrong side of a gate you have not opened from
    -- that direction.  None of that is fixable here, because "where the
    -- player is supposed to be right now" is a fact only the story knows.
    key = "tornado", label = "TORNADOES", type = "choice", default = "off",
    choices = { { "OFF", "off" }, { "ON", "on" } },
    help = "POST-GAME ONLY. In a gale, a tornado can carry you to a town "
        .. "you have already visited. It can strand you mid-quest and is "
        .. "not recommended during the story. Type `weather return` in the "
        .. "console to go back.",
  },
  {
    -- 2D = original Weather FX overlays (fog, rain particles, etc.).
    -- 3D = Dramaless/Potato voxel-pass weather when that host is running.
    -- AUTO = 3D when the host is available, otherwise 2D.
    key = "present", label = "WX PRESENT", type = "choice", default = "auto",
    choices = { { "AUTO", "auto" }, { "2D", "2d" }, { "3D", "3d" } },
    help = "How overworld weather is drawn. 2D is the original Weather FX "
        .. "rain and fog overlays. 3D draws inside the active voxel "
        .. "mode when available. AUTO picks 3D when it can, else 2D. "
        .. "First-person (1ST) always uses 3D weather. "
        .. "Change anytime; battles always use Weather FX.",
  },
  {
    -- The same switch as config.lua's `debugRain`, on the page a player
    -- can actually reach.  It is HERE and not only in the file because a
    -- .modpkg install has no editable config.lua at all -- so a debug
    -- switch that lived only in the file was unreachable for exactly the
    -- people most likely to need it.
    key = "debugRain", label = "DEBUG RAIN", type = "choice", default = "off",
    choices = { { "OFF", "off" }, { "ON", "on" } },
    help = "Force heavy rain everywhere outdoors, and switch the "
        .. "weather system on even if the OPTIONS row is OFF. For testing "
        .. "that the mod is working; turn it off afterwards.",
  },
  {
    key = "debug", label = "DEBUG HUD", type = "choice", default = "off",
    choices = {
      { "OFF", "off" },
      { "SIMPLE", "simple" },
      { "FULL", "full" },
      { "3D", "3d" },
      { "ON", "on" },  -- alias of FULL (older saves / habit)
    },
    help = "On-screen diagnostics. SIMPLE: weather + present + 3D status. "
        .. "FULL: detailed particle/battle/map readout. 3D: voxel bridge only. "
        .. "ON matches FULL.",
  },
}

-- Build the ALWAYS row's choices from the weather catalogue.  Done here
-- rather than typed out so a new weather type appears on the row without
-- anyone remembering to add it -- the same reason the OPTIONS ladder is
-- built from Types.PINNED.
do
  for _, row in ipairs(Settings.SCHEMA) do
    if row.key == "always" then
      local choices = { { "OFF", "off" } }
      for _, id in ipairs(Types.PINNED) do
        local def = Types.get(id)
        if def and def.label then
          choices[#choices + 1] = { def.label, id }
        end
      end
      row.choices = choices
    end
  end
end

-- Allowed values / defaults for Settings.get (must exist before define runs).
local defaults = {}
local valid = {}

local function rebuildValid()
  -- ALWAYS choices from catalogue (safe even if Types loads late).
  for _, row in ipairs(Settings.SCHEMA) do
    if row.key == "always" then
      local choices = { { "OFF", "off" } }
      if Types and Types.PINNED then
        for _, id in ipairs(Types.PINNED) do
          local def = Types.get(id)
          if def and def.label then
            choices[#choices + 1] = { def.label, id }
          end
        end
      end
      row.choices = choices
    end
  end
  for _, row in ipairs(Settings.SCHEMA) do
    defaults[row.key] = row.default
    local set = {}
    for _, choice in ipairs(row.choices or {}) do
      if type(choice) == "table" and choice[2] ~= nil then
        set[choice[2]] = true
        set[tostring(choice[2])] = true
      end
    end
    valid[row.key] = set
  end
end

rebuildValid()

if V.questLitePrivate then
  local public = {}
  for _, row in ipairs(Settings.SCHEMA) do
    if visibleInThisBuild(row) then public[#public + 1] = row end
  end
  mod.exports.theWorldSettingsSchema = public
  mod.exports.theWorldOptionRows = {}
else
  mod.exports.theWorldSettingsSchema = Settings.SCHEMA
  mod.exports.theWorldOptionRows = WorldOptions.rows()
end

function Settings.define()
  rebuildValid()
  if not mod or not mod.options or type(mod.options.define) ~= "function" then
    pcall(function() mod.log:warn("settings define skipped: mod.options unavailable") end)
    return nil
  end
  -- Build a clean row list the host UI accepts (no nil choices).
  local rows = {}
  for _, row in ipairs(Settings.SCHEMA) do
    if visibleInThisBuild(row)
        and row and row.key and row.type and row.choices and #row.choices > 0 then
      rows[#rows + 1] = {
        key = row.key,
        label = row.label or row.key,
        type = row.type,
        default = row.default,
        choices = row.choices,
        help = row.help,
        tab = row.tab,
      }
    end
  end
  if not V.questLitePrivate then
    for _,row in ipairs(WorldOptions.rows()) do
      rows[#rows+1]=row
    end
  end
  if #rows == 0 then
    pcall(function() mod.log:warn("settings define: SCHEMA produced 0 rows") end)
    return nil
  end
  local ok, result = pcall(function()
    return mod.options:define(rows)
  end)
  if not ok then
    pcall(function()
      mod.log:warn("settings define failed: %s", tostring(result))
    end)
    if V.questLitePrivate then return nil end
    -- Fallback: keep the headline The World controls available even if a
    -- host build rejects one of the detailed rows.
    pcall(function()
      mod.options:define({
        {
          key = "worldAI", label = "AI TRAINERS", type = "choice", default = "on",
          choices = { { "ON", "on" }, { "OFF", "off" } },
        },
        {
          key = "worldWeather", label = "WEATHER", type = "choice", default = "on",
          choices = { { "ON", "on" }, { "OFF", "off" } },
        },
        {
          key = "weatherVariants", label = "WX POKEMON", type = "choice", default = "on",
          choices = { { "ON", "on" }, { "OFF", "off" } },
        },
        {
          key = "worldWxStarters", label = "WX STARTERS", type = "choice", default = "off",
          choices = { { "ON", "on" }, { "OFF", "off" } },
        },
        {
          key = "worldContentScope", label = "WHICH POKEMON CAN APPEAR?", type = "choice",
          default = "gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8",
          choices = {
            { "KANTO ONLY (GEN 1)", "gen1" },
            { "KANTO + JOHTO (GEN 1-2)", "gen1_gen2" },
            { "THROUGH HOENN (GEN 1-3)", "gen1_gen2_gen3" },
            { "THROUGH SINNOH (GEN 1-4)", "gen1_gen2_gen3_gen4" },
            { "THROUGH UNOVA (GEN 1-5)", "gen1_gen2_gen3_gen4_gen5" },
            { "THROUGH KALOS (GEN 1-6)", "gen1_gen2_gen3_gen4_gen5_gen6" },
            { "THROUGH ALOLA (GEN 1-7)", "gen1_gen2_gen3_gen4_gen5_gen6_gen7" },
            { "ALL INCLUDED (GEN 1-8)", "gen1_gen2_gen3_gen4_gen5_gen6_gen7_gen8" },
          },
        },
        {
          key = "quality", label = "QUALITY", type = "choice", default = "auto",
          choices = {
            { "AUTO", "auto" }, { "HIGH", "high" },
            { "MEDIUM", "medium" }, { "LOW", "low" }, { "POTATO", "potato" },
          },
        },
        {
          key = "always", label = "ALWAYS", type = "choice", default = "off",
          choices = { { "OFF", "off" } },
        },
        {
          key = "fogIntensity", label = "FOG INTENSITY", type = "choice", default = "100",
          choices = {
            { "OFF", "off" }, { "100%", "100" }, { "300%", "300" }, { "500%", "500" },
          },
        },
        {
          key = "sandIntensity", label = "SAND INTENSITY", type = "choice", default = "100",
          choices = {
            { "OFF", "off" }, { "100%", "100" }, { "300%", "300" }, { "500%", "500" },
          },
        },
        {
          key = "dustIntensity", label = "DUST INTENSITY", type = "choice", default = "100",
          choices = {
            { "OFF", "off" }, { "100%", "100" }, { "300%", "300" }, { "500%", "500" },
          },
        },
        {
          key = "debug", label = "DEBUG HUD", type = "choice", default = "off",
          choices = { { "OFF", "off" }, { "ON", "on" } },
        },
      })
    end)
    return nil
  end
  pcall(function()
    mod.log:info("Weather FX mod menu: %d options registered", #rows)
  end)
  Settings._defined = true
  Settings._rowCount = #rows
  return result
end

function Settings.get(key)
  local ok, value = pcall(function() return mod.options:get(key) end)
  local allowed = valid[key]
  if not ok or value == nil then
    return defaults[key]
  end
  if allowed and not allowed[value] then
    return defaults[key]
  end
  return value
end


-- Overworld presentation: "2d" | "3d" | "auto"
function Settings.presentMode()
  return Settings.get("present") or "auto"
end

-- Detect host first-person (Dramaless / Potato "1ST" mode).
-- Cached module pointer; engaged() is polled every call.
Settings._fpMod = nil
Settings._fpTried = false
function Settings.isFirstPerson()
  if not Settings._fpTried then
    Settings._fpTried = true
    pcall(function()
      if not (mod and mod.find) then return end
      local hosts = {
        "BATTLE_ART_VOXEL_FORK", "DRAMATIC_SHAPE", "DRAMALESS_SHAPE", "potato_voxel", "POTATO_VOXEL", "PotatoVoxel",
        "STADIUM2_OVERWORLD_MODELS",
      }
      for i = 1, #hosts do
        local ok, host = pcall(mod.find, mod, hosts[i])
        if ok and host and host.require then
          local ok2, FP = pcall(host.require, host, "FirstPerson")
          if not ok2 then ok2, FP = pcall(function() return host.require("FirstPerson") end) end
          if ok2 and type(FP) == "table" then
            Settings._fpMod = FP
            break
          end
        end
      end
    end)
  end
  local FP = Settings._fpMod
  if type(FP) ~= "table" then return false end
  if type(FP.engaged) == "function" then
    local ok, e = pcall(FP.engaged)
    if ok and e then return true end
  elseif FP.engaged == true then
    return true
  end
  -- Soft fallback: card blend / hide player are FPV signals on Dramaless.
  if type(FP.cardBlend) == "function" then
    local ok, b = pcall(FP.cardBlend)
    if ok and type(b) == "number" and b > 0.45 then return true end
  end
  if type(FP.hidePlayer) == "function" then
    local ok, h = pcall(FP.hidePlayer)
    if ok and h then return true end
  end
  return false
end

-- True when the player wants the original Weather FX 2D overlays forced.
-- First-person always overrides: FPV must use 3D weather.
function Settings.force2dPresent()
  -- The standalone Quest adapter has no valid flat weather path: a post-process
  -- becomes paint on the floating Game Boy screen. Its deliberately small 3D
  -- bridge owns overworld presentation instead.
  if V.questLitePrivate then return false end
  if Settings.isFirstPerson and Settings.isFirstPerson() then return false end
  return Settings.presentMode() == "2d"
end

-- DEBUG HUD tier.  "on" is kept as an alias of "full" so older saves and
-- muscle memory still work.
function Settings.debugHudMode()
  local v = Settings.get("debug")
  if v == "on" then return "full" end
  if v == "simple" or v == "full" or v == "3d" then return v end
  return "off"
end

function Settings.debugHudOn()
  return Settings.debugHudMode() ~= "off"
end



-- True when the player allows 3D (auto or explicit 3d).
-- First-person always forces 3D weather presentation.
function Settings.allow3dPresent()
  if V.questLitePrivate then return true end
  if Settings.isFirstPerson and Settings.isFirstPerson() then return true end
  local m = Settings.presentMode()
  return m == "3d" or m == "auto"
end

-- The weather the ALWAYS row is pinning, or nil.  Validated against the
-- catalogue, so a value stored by a build with more weathers than this one
-- reads as "off" rather than pinning something that cannot be drawn.
function Settings.alwaysWeather()
  local v = Settings.get("always")
  if not v or v == "off" then return nil end
  if not Types.byId[v] then return nil end
  return v
end

function Settings.is(key, value)
  return Settings.get(key) == value
end

function Settings.worldWeatherEnabled()
  -- Per-save character-creation choice is authoritative. The options menu
  -- mirrors back into this same save key when the player changes WEATHER.
  if mod and mod.save then
    local ok,v=pcall(function() return mod.save:get("world_weather_enabled") end)
    if ok and v~=nil then
      return v == true or v == 1 or v == "on" or v == "true" or v == "yes" or v == "enabled"
    end
  end
  if mod and mod.options then
    local ok,v=pcall(function() return mod.options:get("worldWeather") end)
    if ok and v~=nil then
      return v == true or v == 1 or v == "on" or v == "true" or v == "yes" or v == "enabled"
    end
  end
  return true
end

function Settings.weatherVariantsOn()
  -- WX is also per-save. Do not let the global/default menu row silently
  -- turn variants back on after the player selected NO WX POKEMON.
  if mod and mod.save then
    local ok,v=pcall(function() return mod.save:get("world_wx_pokemon_enabled") end)
    if ok and v~=nil then
      local enabled = v == true or v == 1 or v == "on" or v == "true" or v == "yes" or v == "enabled"
      if not enabled then return false end
    end
  end
  if Settings.get("weatherVariants") ~= "on" then return false end
  return Settings.worldWeatherEnabled()
end

-- The debug-rain switch, from EITHER source.  Two places to set one thing
-- is normally a smell, but these two reach different people: the file is
-- for a folder install and a considered playthrough, the row is for a
-- packed .modpkg on a handheld with no text editor.
function Settings.debugRain(config)
  if config and config.get().debugRain then return true end
  return Settings.is("debugRain", "on")
end

-- ------- derived numbers the draw path wants

local INTENSITY = { soft = 0.6, normal = 1.0, heavy = 1.35 }
function Settings.intensity()
  local v = INTENSITY[Settings.get("intensity")]
  if v then return v end
  return 1                      -- "auto" scales per family instead; see below
end

-- Fog/veil only. Independent of INTENSITY so the two dials do not fight.
-- Nonlinear curve (not 1:1 with the label %): low end is a light mist,
-- 300% is intentionally extreme so you can get lost in it.
local FOG_INTENSITY = {
  off     = 0.00,
  ["10"]  = 0.06,
  ["25"]  = 0.12,
  ["50"]  = 0.35,
  ["100"] = 1.00,
  ["150"] = 2.25,
  ["200"] = 4.00,
  ["250"] = 6.50,
  ["300"] = 10.0,
  ["350"] = 12.5,
  ["400"] = 15.0,
  ["450"] = 17.5,
  ["500"] = 20.0,   -- maximum whiteout
  -- legacy keys
  low = 0.35, normal = 1.00, high = 2.25, max = 20.0,
}
function Settings.fogIntensity()
  local k = Settings.get("fogIntensity")
  if k == nil then return 1 end
  local v = FOG_INTENSITY[k]
  if v == nil then v = FOG_INTENSITY[tostring(k)] end
  -- Host UIs sometimes persist numeric choice values as numbers.
  if v == nil and type(k) == "number" then v = FOG_INTENSITY[tostring(math.floor(k))] end
  if v == nil then return 1 end
  return v
end

--- True when fog/veil should not draw at all.
function Settings.fogOff()
  return Settings.fogIntensity() <= 0
end

--- Cloud banks only. OFF does not disable precipitation.
function Settings.cloudsOn()
  return Settings.get("clouds") ~= "off"
end

function Settings.leafColor()
  local v = Settings.get("leafColor")
  if v == "yellow" or v == "orange" or v == "brown" or v == "green" then
    return v
  end
  return "green"
end

function Settings.snowShape()
  if Settings.get("snowShape") == "ball" then return "ball" end
  return "flake"
end

-- Same extreme curve as FOG_INTENSITY (shared dial feel).
local SAND_DUST_INTENSITY = FOG_INTENSITY

local function intensityFromMap(map, keyName)
  local k = Settings.get(keyName)
  if k == nil then return 1 end
  local v = map[k]
  if v == nil then v = map[tostring(k)] end
  if v == nil and type(k) == "number" then v = map[tostring(math.floor(k))] end
  if v == nil then return 1 end
  return v
end

function Settings.sandIntensity()
  return intensityFromMap(SAND_DUST_INTENSITY, "sandIntensity")
end

function Settings.dustIntensity()
  return intensityFromMap(SAND_DUST_INTENSITY, "dustIntensity")
end

function Settings.sandOff()
  return Settings.sandIntensity() <= 0
end

function Settings.dustOff()
  return Settings.dustIntensity() <= 0
end

-- Map sand/dust intensity dial → remaining scene visibility (1 = clear, 0.25 = 25%).
-- Uses the menu % label so 500% is exactly 25% visibility.
local VIS_PCT = {
  off = 0, ["10"] = 10, ["25"] = 25, ["50"] = 50, ["100"] = 100,
  ["150"] = 150, ["200"] = 200, ["250"] = 250, ["300"] = 300,
  ["350"] = 350, ["400"] = 400, ["450"] = 450, ["500"] = 500,
  low = 50, normal = 100, high = 150, max = 500,
}

local function visibilityFromKey(keyName)
  local k = Settings.get(keyName)
  if k == nil then return 1.0 end
  local pct = VIS_PCT[k] or VIS_PCT[tostring(k)]
  if pct == nil and type(k) == "number" then pct = VIS_PCT[tostring(math.floor(k))] end
  if pct == nil then
    -- Fallback from intensity multiplier curve
    local mul = intensityFromMap(SAND_DUST_INTENSITY, keyName)
    if mul <= 0 then return 1.0 end
    return 1.0 - math.min(1.0, mul / 20.0) * 0.75
  end
  if pct <= 0 then return 1.0 end
  -- Linear: 0%→100% vis, 500%→25% vis
  return 1.0 - (pct / 500.0) * 0.75
end

function Settings.sandVisibility()
  return visibilityFromKey("sandIntensity")
end

function Settings.dustVisibility()
  return visibilityFromKey("dustIntensity")
end

-- Haze strength for dens/veil: 0 at OFF, 1 at 500% (25% visibility).
function Settings.sandHaze()
  return 1.0 - Settings.sandVisibility()
end

function Settings.dustHaze()
  return 1.0 - Settings.dustVisibility()
end

-- ------- AUTO intensity
--
-- Real weather is not a constant.  A downpour has heavier and lighter
-- minutes inside it, and a storm's strikes cluster and then go quiet.  On
-- the fixed settings this mod picks one number and holds it for the whole
-- spell, which is the single thing that most gives away that the sky is a
-- particle system.
--
-- AUTO fixes that WITHOUT touching the weather itself: the type still says
-- "heavy rain", the state machine still eases toward the same targets, and
-- only the final multiplier breathes.  So nothing downstream -- the battle
-- layer, the AUTO scheduler, the save -- can tell the difference.
--
-- EACH FAMILY GETS ITS OWN RHYTHM, which is the part that matters.  If one
-- oscillator drove everything, the rain, the fog and the lightning would
-- swell and fade in lockstep and read as the brightness being turned up
-- and down.  Five families on unrelated periods, with different phases,
-- never line up for long:
--
--   wet     rain and its splashes
--   frozen  snow
--   grain   hail, sand, blown debris
--   haze    fog banks and the flat veil
--   light   lightning strike rate
--
-- Two sines per family at incommensurable periods -- so the pattern does
-- not repeat on any timescale a player would notice -- mapped into the
-- configured min..max range.

local AUTO_FAMILIES = {
  wet    = { p1 = 37.0, p2 = 13.7, phase = 0.0 },
  frozen = { p1 = 43.0, p2 = 17.3, phase = 1.3 },
  grain  = { p1 = 29.0, p2 = 11.1, phase = 2.6 },
  haze   = { p1 = 61.0, p2 = 23.9, phase = 3.9 },
  light  = { p1 = 23.0, p2 =  8.3, phase = 5.2 },
}

Settings.AUTO_FAMILIES = AUTO_FAMILIES

-- Which family a channel belongs to.  Channels absent from this map do not
-- breathe at all -- deliberately: the grade channels (dim, cool, warm,
-- glare) drive a full-screen multiply, and a full-screen multiply that
-- pulses does not read as weather, it reads as a fault.
Settings.CHANNEL_FAMILY = {
  rain = "wet", splash = "wet",
  snow = "frozen",
  hail = "grain", sand = "grain", debris = "grain",
  fog = "haze", veil = "haze",
  strike = "light",
}

-- `t` is the weather clock in seconds.  Returns the multiplier for one
-- family, or 1 when AUTO is not selected -- so the caller needs no branch.
function Settings.autoScale(family, t, config)
  if Settings.get("intensity") ~= "auto" then return 1 end
  local f = AUTO_FAMILIES[family or ""]
  if not f then return 1 end
  local cfg = config and config.get().autoIntensity
  local lo = (cfg and cfg.min) or 0.5
  local hi = (cfg and cfg.max) or 1.4
  local rate = (cfg and cfg.seconds) or 1
  if rate <= 0 then rate = 1 end
  t = (tonumber(t) or 0) / rate
  -- 0.7/0.3 weighting: a long swell with a shorter ripple on top, rather
  -- than two equal waves, which would read as a beat frequency
  local a = math.sin((t / f.p1) * 2 * math.pi + f.phase) * 0.7
  local b = math.sin((t / f.p2) * 2 * math.pi + f.phase * 1.7) * 0.3
  local unit = (a + b + 1) * 0.5          -- -1..1 -> 0..1
  if unit < 0 then unit = 0 elseif unit > 1 then unit = 1 end
  return lo + (hi - lo) * unit
end

-- Minutes an AUTO spell lasts, as a multiplier on the type's own range.
local SPEED = { slow = 2.2, normal = 1.0, fast = 0.45, test = 0.02 }
function Settings.speedScale()
  return SPEED[Settings.get("speed")] or 1
end

-- How much the region bias is allowed to suppress an out-of-place
-- weather.  1 means "no suppression at all"; the built-in bias multiplies
-- by 0.2, so this is blended against that rather than replacing it, which
-- keeps the geography meaningful at every setting except OFTEN.
local EXOTIC = { off = 0, rare = 1.0, normal = 3.0, often = 7.0 }
function Settings.exoticScale()
  local v = EXOTIC[Settings.get("exotic")]
  if v == nil then return 3.0 end
  return v
end

-- 0 = no weather in battle, 1 = the same as the overworld.
local BATTLE = { off = 0, subtle = 0.5, full = 1 }
function Settings.battleAnimOn()
  -- Explicit ON/OFF from mod menu. Default ON if unset.
  local v = Settings.get("battleAnim")
  if v == "off" then return false end
  if v == "on" then return true end
  -- Legacy single-row saves.
  local legacy = nil
  pcall(function() legacy = mod.options:get("battlerules") end)
  if legacy == "off" then return false end
  return true
end

function Settings.battleDamageOn()
  local v = Settings.get("battleDamage")
  if v == "off" then return false end
  if v == "on" then return true end
  local legacy = nil
  pcall(function() legacy = mod.options:get("battlerules") end)
  if legacy == "off" then return false end
  return true
end

function Settings.battleScale()
  return BATTLE[Settings.get("battles")] or 0.5
end

function Settings.set(key, value)
  -- Soft write into live config for host-driven defaults (e.g. daytime off on Dramaless).
  pcall(function()
    local Config = V.require("Config")
    local c = Config.get()
    if not c then return end
    if key == "daytime" and c.time then
      c.time.source = (value == "off") and "off" or (c.time.source or "auto")
    end
  end)
end

return Settings
