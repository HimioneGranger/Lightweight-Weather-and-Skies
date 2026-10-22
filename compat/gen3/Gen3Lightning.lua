-- Gen 3 adapter for the Lightweight Weather & Skies 1.1.0 lightning update.
-- lib/QuestStorm.lua and lib/QuestStormBolt.lua carry the upstream 1.1.0
-- behaviour unchanged for every generation; this file only connects it to
-- the Gen 3 host. Loaded by one guarded line in Gen3Host.lua, which only
-- Gen3Compat.lua / RseCompat.lua load (mod.generation == 3); Gen 1/Gen 2
-- never see it. Three adapters plus a status export:
--
-- 1. Camera. QuestStorm aims most ground strikes (and every showcase) at
--    atan2(focus - eye). FRLG_VOXEL's WeatherHost passes no focus, so its
--    Voxel3D.focus is the eye itself and every aimed strike landed due
--    south. QuestStorm is bound to a read-through view of the same Voxel3D
--    whose focus follows the rendered camera: the last eye's view-projection
--    row 4 is the world-space forward axis (clip w grows along it).
-- 2. Pending thunder. 1.1.0 holds new nearby strikes until the previous
--    event's thunder is consumed by lib/Audio.lua. On Gen 3 Audio.update runs
--    at the end of the captured weather record's update (Gen3Tick) and
--    returns early without love.audio, so anything that stops it would stop
--    lightning for the rest of the session. Thunder left unconsumed for
--    THUNDER_VALVE_SECONDS is dropped here. Normal play consumes it in the
--    same step it becomes ready, so this never replaces live thunder.
-- 3. Emerald native authority (RSE only). While native map/header/scripted
--    weather is authoritative (RseWeather.target), natural TWS lightning is
--    can optionally be limited to the native effects that thunder themselves:
--    WEATHER_RAIN_THUNDERSTORM (5) and WEATHER_DOWNPOUR (13). User testing
--    decision 2026-09-30: keep weather and added lightning on, so the default
--    retains upstream rain/storm lightning. Native weather ownership stays
--    unchanged. Set NATIVE_THUNDER_ONLY=true for the optional strict gate.
local mod, loadModule, hostLib, shared = ...
local _ = loadModule

local M = {
  VERSION = 'lws-1.1.0-gen3',
  THUNDER_VALVE_SECONDS = 3,
  NATIVE_THUNDER_ONLY = false,
  NATIVE_THUNDER_CODES = { [5] = true, [13] = true },
  FOCUS_DISTANCE = 100,
  -- Below this share of horizontal forward (looking almost straight up or
  -- down) the heading is noise; keep the last good one.
  MIN_HORIZONTAL = 0.2,
}

if not (hostLib and type(hostLib.require) == 'function') then return M end
local okStorm, Storm = pcall(hostLib.require, 'QuestStorm')
if not (okStorm and type(Storm) == 'table' and type(Storm.bindCamera) == 'function') then
  mod.log:warn('gen3: lightning adapter skipped: QuestStorm unavailable')
  return M
end

local stats = {
  events = { forked = 0, anvil = 0, rolling = 0, cloud = 0 },
  drained = 0, focus = 'host', binds = 0,
  gate = { native = false, code = nil, rate = 1 },
}
M.stats = stats

-- ------- 1. camera focus from the rendered view ---------------------------
local function hostVoxel()
  local handle = mod.find and mod.find('FRLG_VOXEL')
  local lib = handle and handle.exports and handle.exports.lib
  if not (lib and type(lib.require) == 'function') then return nil end
  local ok, voxel = pcall(lib.require, 'Voxel3D')
  if ok and type(voxel) == 'table' then return voxel end
  return nil
end

local headingX, headingZ
local focusPoint = { 0, 0, 0 }
function M.focus()
  local voxel = M.voxel
  local eye = voxel and voxel.eye
  if type(eye) ~= 'table' then return nil end
  local vp = voxel.vp
  if type(vp) == 'table' then
    local fx, fy, fz = tonumber(vp[13]) or 0, tonumber(vp[14]) or 0, tonumber(vp[15]) or 0
    local length = math.sqrt(fx * fx + fy * fy + fz * fz)
    local horizontal = math.sqrt(fx * fx + fz * fz)
    if length > 0 and horizontal > M.MIN_HORIZONTAL * length then
      headingX, headingZ = fx / horizontal, fz / horizontal
      stats.focus = 'view'
    end
  end
  if not headingX then return voxel.focus end
  focusPoint[1] = eye[1] + headingX * M.FOCUS_DISTANCE
  focusPoint[2] = eye[2]
  focusPoint[3] = eye[3] + headingZ * M.FOCUS_DISTANCE
  return focusPoint
end
function M.heading()
  if not headingX then return nil end
  return math.atan2(headingX, headingZ)
end

-- Everything except focus reads straight through to the host's Voxel3D.
M.camera = setmetatable({}, { __index = function(_, key)
  if key == 'focus' then return M.focus() end
  local voxel = M.voxel
  if voxel then return voxel[key] end
  return nil
end })

local function bindCamera()
  M.voxel = M.voxel or hostVoxel()
  if not M.voxel then return false end
  -- Rebound before every weather update: QuestStorm.attach (lazy, from
  -- DramalessAtmos) binds the raw Voxel3D again whenever it runs.
  Storm.bindCamera(M.camera)
  stats.binds = stats.binds + 1
  return true
end
M.bindCamera = bindCamera

-- ------- 2. pending-thunder valve -----------------------------------------
local POLL = 0.25
local pollWait, readyAge, loggedDrain = POLL, nil, false
local lastEventId, lastDistantActive = nil, false

local function observe(dt)
  local event = Storm.bolt()
  if event and event.id ~= lastEventId then
    lastEventId = event.id
    local style = event.style or 'forked'
    stats.events[style] = (stats.events[style] or 0) + 1
    stats.last = { id = event.id, style = style, variant = event.variant and event.variant.id,
      branches = #(event.branches or {}), twigs = #(event.twigs or {}),
      prominentForks = event.prominentForks == true, points = #(event.points or {}),
      verification = event.verification == true }
  end
  pollWait = pollWait - dt
  if pollWait > 0 then return end
  local elapsed = POLL - pollWait
  pollWait = POLL
  local status = Storm.status()
  if status.distantActive and not lastDistantActive then
    stats.events.cloud = stats.events.cloud + 1
    stats.lastDistant = status.distantVariant
  end
  lastDistantActive = status.distantActive == true
  if status.readyThunder or status.distantReady then
    -- Counted from the first poll that saw it, so the drop is never early.
    readyAge = readyAge and readyAge + elapsed or 0
    if readyAge >= M.THUNDER_VALVE_SECONDS then
      local dropped = Storm.consumeThunder()
      readyAge = nil
      if dropped then
        stats.drained = stats.drained + 1
        if not loggedDrain then
          loggedDrain = true
          mod.log:warn('gen3: lightning thunder not consumed by audio for %ss; dropped so strikes continue',
            tostring(M.THUNDER_VALVE_SECONDS))
        end
      end
    end
  else
    readyAge = nil
  end
end
M.observe = observe

-- Outer to Gen3Tick's -950 link (which runs the weather record update) and
-- inner to Gen3SkyRse's -940 deck update: bind before, observe after.
-- Lab 52 (exports.setFrameOnce, default OFF): with the switch on, bind and observe each run once per rendered frame
-- (observe with the summed, clamped dt) from compat/FrameOnce.lua's flush, in the same relative order as the weather
-- record update (bind, record, observe, deck, atmos). With the switch off this link is the original per-tick one.
local perfOk, perf = pcall(function() return mod.exports.questPerf end)
local FO = perfOk and type(perf) == 'table' and perf.fo or nil
perf = FO and perf or {}
local take = FO and FO.take
local function runBind() pcall(bindCamera) end
local function observeOnce(dt)
  local ok, err = pcall(observe, math.max(0, math.min(.25, tonumber(dt) or 0)))
  if not ok and not M._observeError then
    M._observeError = tostring(err)
    mod.log:warn('gen3: lightning observe failed: %s', M._observeError)
  end
end
-- observe() polls every 0.25 s of ITS OWN dt and resets (overshoot included), so its timing depends on the step length: a
-- batch replays the individual tick dts (it is cheap) instead of observing once with the sum.
local function runObserve(dt, last, n, dts)
  if n and n > 1 and dts then for i = 1, n do observeOnce(dts[i]) end else observeOnce(dt) end
end
local stagePre = FO and FO.stage('lightPre', 10, runBind) or { n = 0 }
local stagePost = FO and FO.stage('lightPost', 30, runObserve) or { n = 0 }
if mod.hooks and type(mod.hooks.wrap) == 'function' then
  mod.hooks:wrap('input.step', function(next, game, dt)
    local goPre = true
    if perf.frameOnce or stagePre.n ~= 0 then goPre = take(stagePre, dt) end
    if goPre then pcall(bindCamera) end
    local result = next(game, dt)
    local go, d, last, n, dts = true, dt
    if perf.frameOnce or stagePost.n ~= 0 then go, d, last, n, dts = take(stagePost, dt) end
    if go then runObserve(d, last, n, dts) end
    return result
  end, -945)
end

-- ------- 3. Emerald native thunder gate -----------------------------------
local weather = shared and shared.weather
if shared and shared.rse and weather and type(weather.target) == 'function' then
  local okR, Regional = pcall(hostLib.require, 'QuestRegional')
  if okR and type(Regional) == 'table' and type(Regional.lightningRate) == 'function'
      and not Regional._gen3NativeThunder then
    Regional._gen3NativeThunder = true
    local original = Regional.lightningRate
    Regional.lightningRate = function(mapId, weatherId)
      local rate = original(mapId, weatherId)
      local gate = stats.gate
      local okT, id, code = pcall(weather.target)
      if okT and id ~= nil then
        gate.native, gate.code = true, tonumber(code)
        if M.NATIVE_THUNDER_ONLY and not M.NATIVE_THUNDER_CODES[gate.code or -1] then
          gate.rate = 0
          return 0
        end
      else
        gate.native, gate.code = false, nil
      end
      gate.rate = rate
      return rate
    end
    local originalUpdate = Storm.update
    Storm.update = function(dt, state, settings)
      local okT, id, code = pcall(weather.target)
      if M.NATIVE_THUNDER_ONLY and okT and id ~= nil
          and not M.NATIVE_THUNDER_CODES[tonumber(code) or -1] then
        local status = Storm.status()
        -- A same-map transition can leave a quiet-gap timer at zero while
        -- an earlier strike's thunder is still pending. Cadence zero alone
        -- cannot stop that exhausted timer from scheduling another strike.
        -- Re-arm only exhausted natural waits through the public pace seam;
        -- the zero cadence then holds them. Keep active geometry, delayed
        -- thunder and explicit test/spicy requests intact.
        if (status.wait and status.wait <= 0)
            or (status.distantWait and status.distantWait <= 0) then
          Storm.lastPace = nil
        end
      end
      return originalUpdate(dt, state, settings)
    end
  end
end

-- ------- status -------------------------------------------------------------
function M.status()
  local s = Storm.status()
  local profiles = 0
  for _, list in pairs(Storm.VARIANTS or {}) do profiles = profiles + #list end
  return {
    version = M.VERSION, profiles = profiles, serial = s.serial, active = s.active,
    pendingThunder = s.pendingThunder, readyThunder = s.readyThunder, wait = s.wait,
    flash = s.flash, strength = s.strength, heading = M.heading(), focus = stats.focus,
    events = stats.events, last = stats.last, lastDistant = stats.lastDistant,
    drained = stats.drained, binds = stats.binds,
    gate = { native = stats.gate.native, code = stats.gate.code, rate = stats.gate.rate,
      nativeThunderOnly = M.NATIVE_THUNDER_ONLY and shared ~= nil and shared.rse == true },
    activityMultiplier = Storm.ACTIVITY_MULTIPLIER, groundShare = Storm.GROUND_STRIKE_CHANCE,
    anvilShare = Storm.ANVIL_CLOUD_SHARE,
  }
end

mod.exports.gen3 = mod.exports.gen3 or {}
mod.exports.gen3.lightning = M
do
  local profiles = 0
  for _, list in pairs(Storm.VARIANTS or {}) do profiles = profiles + #list end
  mod.log:info('gen3: lightning adapter %s (%d storm profiles, %s)', M.VERSION, profiles,
    shared and shared.rse and 'emerald native gate' or 'procedural storms')
end
return M
