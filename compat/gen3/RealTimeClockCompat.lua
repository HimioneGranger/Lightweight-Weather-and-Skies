-- RTC detection, the RTC clock object, and the rtc / rtc-os / tws mode
-- switch. DESIGN.md §2.3-2.7, §4.3 RealTimeClockCompat. Loaded from
-- Gen3Compat's mods.loaded@50 listener (hostLib = mod.exports.lib, TWS's
-- own cached-module namespace, is available by then).
--
-- Never copies RTC code, art or private field names into this file: the
-- only RTC surface this reads is the documented-by-source special 57600
-- probe (RTC:4830-4849), which RTC itself installs with no side effects
-- (Flags.setVar with a nil store writes only into the passed ctx). The
-- schedule (hours 4/10/18, 30-minute blend) is reproduced as numbers, not
-- code (R2 §8).

local mod, loadModule, hostLib, shared = ...

local RealTimeClockCompat = {}

local CYCLE, DAY_LEN = 1200, 600 -- TWS's own dial, lib/TimeOfDay.lua:148-171

-- ((h - 6) mod 24) * 50 is voxelHours()'s exact inverse when CYCLE=1200,
-- DAY_LEN=600 (dayLen is exactly half the cycle, so the two linear halves
-- of voxelHours collapse to one line); verified by hand against
-- lib/TimeOfDay.lua:148-171 at h=0,6,12,18,23 before use here.
local function hourToVoxelTime(hour)
  return (((hour or 12) - 6) % 24) * 50
end

-- ------- the probe (§2.4) ------------------------------------------------
--
-- Our own code, not RTC's: calls the special with a private context and no
-- adapters, then reads back only what RTC itself writes into ctx via
-- Flags.setVar(nil, ctx, ...) (a nil store writes only ctx.specialVars,
-- ENG core\game3\scripting\flags.lua:307-316). 0x8004-0x8007 = 32772-32775.
local function probeOnce()
  local okN, Natives = pcall(require, "src.core.game3.scripting.natives")
  if not (okN and type(Natives) == "table" and type(Natives.ALLOW) == "table") then
    return nil, "natives-unavailable"
  end
  local special = Natives.ALLOW["special:57600"]
  if type(special) ~= "function" then return nil, "special-not-registered" end
  local ctx = { specialVars = {}, stringVars = {} }
  local ok, err = pcall(special, ctx, nil)
  if not ok then return nil, "special-threw:" .. tostring(err) end
  local day, hour, minute, part =
    ctx.specialVars[32772], ctx.specialVars[32773], ctx.specialVars[32774], ctx.specialVars[32775]
  if type(hour) ~= "number" or hour < 0 or hour > 23 then return nil, "bad-hour" end
  if type(minute) ~= "number" or minute < 0 or minute > 59 then return nil, "bad-minute" end
  if type(part) ~= "number" or part < 0 or part > 2 then return nil, "bad-part" end
  return { day = day, hour = hour, minute = minute, part = part }, nil
end

-- Step 4 sanity: hour/minute must agree with os.date within 2 minutes,
-- guarding against another mod reusing special id 57600.
local function sane(probe)
  local ok, t = pcall(os.date, "*t")
  if not (ok and type(t) == "table") then return true end -- cannot check; do not fail the probe over it
  local nowMin = (t.hour or 0) * 60 + (t.min or 0)
  local probeMin = probe.hour * 60 + probe.minute
  local diff = math.abs(nowMin - probeMin)
  diff = math.min(diff, 1440 - diff)
  return diff <= 2
end

local function nowSeconds()
  return (love and love.timer and love.timer.getTime()) or os.clock()
end

-- At most once per second (RTC itself samples no faster, R1 §2); between
-- probes the hour is advanced smoothly, clamped to at most one extra
-- minute past the last probe so a stalled probe cannot run away.
local lastProbe, lastProbeAt = nil, -math.huge
local function refreshProbe()
  local now = nowSeconds()
  if lastProbe and (now - lastProbeAt) < 1.0 then return lastProbe end
  local probe = probeOnce()
  lastProbeAt = now
  if probe then
    probe.t = now
    lastProbe = probe
  else
    -- A failed attempt invalidates the cache -- found live (2026-09-28
    -- fault-injection boot, DESIGN.md 7.1 P0 (7)): without this, a
    -- throttle-window read after the special starts throwing kept
    -- serving the STALE pre-fault lastProbe object (only ever cleared by
    -- a successful probe overwriting it), so effectiveMinuteFraction()
    -- kept returning a number, readClock()'s pcall kept reporting "ok",
    -- and gen3Status never degraded past rtc even after the special had
    -- been throwing for minutes. Clearing it here makes the very next
    -- refreshProbe() call (still within the same 1s throttle window,
    -- since lastProbe is now nil) fall through to readClock()'s "no
    -- probe" failure path, which is what actually flips source to
    -- "rtc-os" (CRITIQUE B; §2.6).
    lastProbe = nil
  end
  return lastProbe
end

local function effectiveMinuteFraction()
  local p = lastProbe
  if not p then return nil end
  local elapsed = math.min(60, math.max(0, nowSeconds() - p.t))
  return (p.hour * 60 + p.minute + elapsed / 60) % 1440
end

-- Temporary diagnostic surface (fault-injection debugging, 2026-09-28) --
-- not part of the designed interface, safe to leave (read-only, no
-- gameplay effect); remove once the fault-injection proof is settled.
shared.probeDebug = function()
  local freshProbe, freshErr = probeOnce()
  return {
    hasLastProbe = lastProbe ~= nil,
    lastProbeAt = lastProbeAt,
    now = nowSeconds(),
    freshProbeOk = freshProbe ~= nil,
    freshProbeErr = freshErr,
  }
end

-- ------- rtc-os fallback: device clock + RTC's published 4/10/18 rule ---
local function osDateClock()
  local ok, t = pcall(os.date, "*t")
  local h = (ok and t and t.hour) or 12
  local m = (ok and t and t.min) or 0
  local part
  if h >= 4 and h < 10 then part = 0
  elseif h >= 10 and h < 18 then part = 1
  else part = 2 end
  return h, m, part
end

-- ------- the state machine (§2.3, §2.6) ---------------------------------
local State = { mode = nil, rtcHandle = nil, rtcVersion = nil }
local probeWasHealthy = nil -- for one-shot log lines only

-- NEVER throws. On any failure inside the "rtc" branch this degrades to
-- the device clock for THIS call only (State.mode is left alone), which
-- is what keeps a single bad frame from poisoning TimeOfDay's ds.broken
-- forever (CRITIQUE B; ds.broken is set by ONE throw from dn.time()/
-- dn.hours(), lib/TimeOfDay.lua:126-131,164-170).
local function readClock()
  if State.mode == "rtc" then
    local ok, h, m, part = pcall(function()
      local p = refreshProbe()
      if not p then error("no-probe", 0) end
      local mf = effectiveMinuteFraction()
      if not mf then error("no-fraction", 0) end
      return math.floor(mf / 60) % 24, mf % 60, p.part
    end)
    if ok then
      if probeWasHealthy == false then mod.log:info("gen3: RTC probe recovered") end
      probeWasHealthy = true
      return h, m, part, "rtc"
    end
    if probeWasHealthy ~= false then
      mod.log:warn("gen3: RTC probe unavailable at runtime (%s); following device "
        .. "clock with RTC's 4/10/18 rule", tostring(h))
    end
    probeWasHealthy = false
    -- fall through to the device-clock branch below
  end
  local h, m, part = osDateClock()
  return h, m, part, "rtc-os"
end

-- The object handed to TWS via Interop.dayNight in rtc/rtc-os mode. Only
-- what TimeOfDay/NightSky/QuestMeteorSchedule read (§2.4): time(), CYCLE,
-- DAY_LEN, hours(), isNight(), setting (fixed at "system" so the moon/
-- meteor/aurora day counter keeps advancing, NightSky.lua:1009-1017,
-- QuestMeteorSchedule.lua:46). No "cycle" in `values`, so nothing can flip
-- it to a cycle.
local ClockObject = {
  CYCLE = CYCLE,
  DAY_LEN = DAY_LEN,
  setting = { values = { "system" }, get = function() return "system" end },
}
function ClockObject.time()
  local ok, t = pcall(function()
    local h, m = readClock()
    return hourToVoxelTime(h + m / 60)
  end)
  if ok and type(t) == "number" and t == t then return t end
  return 0
end
function ClockObject.hours()
  local ok, h = pcall(function()
    local hh, mm = readClock()
    return (hh + mm / 60) % 24
  end)
  if ok and type(h) == "number" and h == h then return h end
  return 12
end
function ClockObject.isNight()
  local ok, isN = pcall(function()
    local _, _, part = readClock()
    return part == 2
  end)
  return ok and isN == true
end

-- ------- tws mode: explicit Config source + a read-only mirror (§2.6) --
local function applyTwsConfig()
  local Config = hostLib.require("Config")
  local cfg = Config and Config.get and Config.get()
  if not (cfg and cfg.time) then return end
  local raw = shared.options and shared.options.daytimeValue and shared.options.daytimeValue()
  if raw == "system" then
    cfg.time.source = "system"
  elseif raw == "off" then
    cfg.time.source = "off"
  elseif type(raw) == "string" and raw:sub(1, 6) == "fixed:" then
    cfg.time.source = "fixed"
    cfg.time.fixedPhase = raw:sub(7)
  else
    -- "cycle" for AUTO (20-MIN CYCLE), and the safe default when the
    -- option system is not ready yet or the value is unrecognised --
    -- identical to what unpatched `auto` already falls through to on
    -- Gen 3 (Config.lua:602-603, TimeOfDay.lua:215-243), just written
    -- explicitly so Config.load's one-time `auto` default is never what
    -- TimeOfDay actually reads.
    cfg.time.source = "cycle"
  end
end

local mirrorPublished = false
local function installTwsMirror()
  if mirrorPublished then return end
  local Interop, TimeOfDay = hostLib.require("Interop"), hostLib.require("TimeOfDay")
  if not (Interop and TimeOfDay) then return end
  mirrorPublished = true
  Interop.dayNight = function()
    -- Read-only: QuestNature is the only caller that matters in tws mode.
    -- TimeOfDay itself only calls Interop.dayNight on its `auto` branch
    -- (TimeOfDay.lua:215-222), and applyTwsConfig() above always writes an
    -- explicit non-auto source before this mirror is published, so
    -- TimeOfDay never reaches this function and cannot read its own hour
    -- back (CRITIQUE A).
    return {
      CYCLE = CYCLE, DAY_LEN = DAY_LEN,
      time = function() return hourToVoxelTime(TimeOfDay.hour or 12) end,
      hours = function() return TimeOfDay.hour or 12 end,
      isNight = function() return TimeOfDay.isNight and TimeOfDay.isNight() or false end,
      setting = { values = { "pinned" }, get = function() return "pinned" end },
    }, "gen3TwsMirror"
  end
end

-- ------- mode switch -----------------------------------------------------
local function applyMode(mode)
  if State.mode == mode then
    if mode == "tws" then applyTwsConfig() end -- keep polling the DAYTIME row
    return
  end
  local prior = State.mode
  State.mode = mode
  mod.log:info("clock: %s", mode)
  if shared.options and shared.options.setMode then shared.options.setMode(mode) end
  if mode == "rtc" or mode == "rtc-os" then
    local Interop = hostLib.require("Interop")
    if Interop then Interop.dayNight = function() return ClockObject, "gen3RTC" end end
  elseif mode == "tws" then
    applyTwsConfig()
    installTwsMirror()
  end
  if prior ~= nil then
    mod.log:info("gen3: clock mode changed %s -> %s", tostring(prior), tostring(mode))
  end
end

-- ------- detection (§2.3) -------------------------------------------------
local function detect()
  local handle = mod.find("RealTimeClockTest")
  if not handle then
    applyMode("tws")
    return true
  end
  if not State.rtcHandle then
    State.rtcHandle = handle
    State.rtcVersion = handle.version
    if handle.version and handle.version ~= "0.1.0" then
      mod.log:warn("gen3: RealTimeClockTest %s found, expected 0.1.0; probing anyway",
        tostring(handle.version))
    end
  end
  local probe, err = probeOnce()
  if probe and sane(probe) then
    probe.t = nowSeconds()
    lastProbe, lastProbeAt = probe, probe.t
    applyMode("rtc")
    return true
  end
  return false -- RTC found, but its special has not settled sanely yet
end

mod.events:on("game.ready", function()
  if detect() then return end
  -- RTC's own special-installing game.ready listener is priority 0, ahead
  -- of ours at -160 (ENG mods\Events.lua sorts descending), so this is
  -- normally already resolved; the lazy poll below is only for a delayed
  -- or slow-installing RTC. Gives up after 120 ticks and settles rtc-os,
  -- per DESIGN.md §2.3 step 3.
  local ticks = 0
  local unregister
  unregister = mod.hooks:wrap("input.step", function(next, game, dt)
    local result = next(game, dt)
    ticks = ticks + 1
    if detect() then
      if unregister then unregister() end
    elseif ticks >= 120 then
      applyMode("rtc-os")
      if unregister then unregister() end
    end
    return result
  end, -970)
end, -160)

-- In tws mode the player can change the DAYTIME row in MOD OPTIONS at any
-- time (§2.7); Config.get().time.source is only WRITTEN when we choose to
-- write it (§2.6 item 2), so without a periodic re-poll a mid-session
-- change would never reach TimeOfDay. Once a second is plenty -- this is a
-- handful of table field writes, not a probe.
local lastPollAt = -math.huge
mod.hooks:wrap("input.step", function(next, game, dt)
  local result = next(game, dt)
  if State.mode == "tws" then
    local now = nowSeconds()
    if now - lastPollAt >= 1.0 then
      lastPollAt = now
      applyTwsConfig()
    end
  end
  return result
end, -975)

-- ------- status export (Gen3Host's gen3Status(), §5.3) -------------------
local PERIOD_NAMES = { [0] = "morning", [1] = "day", [2] = "night" }
shared.clockStatus = function()
  if State.mode == "tws" then
    local TimeOfDay = hostLib.require("TimeOfDay")
    local hour = (TimeOfDay and TimeOfDay.hour) or 12
    local part = 1
    if TimeOfDay then
      if TimeOfDay.tod == "MORN" then part = 0
      elseif TimeOfDay.tod == "NITE" then part = 2
      else part = 1 end
    end
    return {
      hour = math.floor(hour) % 24, minute = math.floor((hour % 1) * 60),
      period = PERIOD_NAMES[part], source = "tws",
    }
  end
  local h, m, part, source = readClock()
  -- Debug fields built into the SAME literal as the rest of the return
  -- value (not added to an already-constructed table afterward) and this
  -- whole function pinned off the JIT -- added 2026-09-28 after `.debug`
  -- kept coming back nil to a live caller despite no error anywhere.
  -- lib/SaveSerializer.lua documents exactly this failure mode on this
  -- engine/LuaJIT build: "LuaJIT 2.1 can lose a just-added nested table
  -- entry when a GC step lands inside a compiled recursive serialization
  -- trace" -- a mutation added to an existing table after construction,
  -- inside a function that gets JIT-traced, can silently not take. This
  -- function is called every tick from TWS's own weather record update
  -- (via TimeOfDay -> voxelHours -> dn.time(), when RTC mode is active),
  -- so it is exactly the kind of hot, repeatedly-called function LuaJIT
  -- would trace. `jit.off` below is the engine's own documented fix for
  -- this failure mode, applied the same way SaveSerializer.lua's own
  -- writer uses it.
  return {
    hour = h, minute = m, period = PERIOD_NAMES[part] or "day", source = source,
    debug = {
      mode = State.mode,
      hasLastProbe = lastProbe ~= nil,
      lastProbeAt = lastProbeAt,
      nowSeconds = nowSeconds(),
    },
  }
end
if jit and jit.off then jit.off(shared.clockStatus, true) end

function RealTimeClockCompat.mode() return State.mode end

-- ------- best-effort vrHost.clock.register (§4.4 B, vrHost 1.2) ---------
-- HostApi 1.2's clock.register does not exist in FRLG_VOXEL as of this
-- pass (checked: HostApi.lua reports VERSION "1.1"); this is a forward-
-- looking, silent no-op until W8/the coordinator lands it. See
-- W9_NOTES.md for the exact ask.
pcall(function()
  local fv = mod.find("FRLG_VOXEL")
  local vrHost = fv and fv.exports and fv.exports.vrHost
  if vrHost and vrHost.clock and type(vrHost.clock.register) == "function" then
    vrHost.clock.register("tws-gen3-rtc", function()
      local status = shared.clockStatus()
      return { hour = status.hour + status.minute / 60, period = status.period, source = status.source }
    end, 100)
  end
end)

-- ------- developer debug acceptance line (§2.5) ---------------------------
if mod.developer then
  local lastLog = -math.huge
  mod.hooks:wrap("input.step", function(next, game, dt)
    local result = next(game, dt)
    local now = nowSeconds()
    if now - lastLog >= 1.0 then
      lastLog = now
      local _, _, part = readClock()
      local TimeOfDay = hostLib.require("TimeOfDay")
      mod.log:info("gen3: rtc part=%s TOD.hour=%.2f mode=%s",
        tostring(part), (TimeOfDay and TimeOfDay.hour) or -1, tostring(State.mode))
    end
    return result
  end, -980)
end

shared.readClock = readClock
mod.exports.gen3 = mod.exports.gen3 or {}
mod.exports.gen3.probeDebug = shared.probeDebug
return RealTimeClockCompat
