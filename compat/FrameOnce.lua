-- FrameOnce (Lab 52): run the smooth-time weather updates once per rendered frame instead of once per logic tick.
-- Game-neutral and OFF by default: with exports.setFrameOnce(false) (the default) no stage defers anything and every
-- input.step hook behaves exactly as before. The state lives on mod.exports.questPerf (the table setFrameHoist uses).
--
--   stage = FO.stage(name, order, run)   register one hook body; run(dt, lastTickDt, nTicks, tickDts) executes it
--   go, dt, last, n, dts = FO.take(stage, tickDt)  called from the stage's input.step link on EVERY tick when
--                                        (perf.frameOnce or stage.n ~= 0). go=false: the tick was deferred (summed into
--                                        stage.pending). go=true: run now with dt (summed dt, or the tick dt itself).
--   FO.frameBegin()                      host calls once per rendered frame BEFORE the frame reads weather state: runs every
--                                        stage that has pending ticks, once, in stage order, with the summed dt.
--   FO.flush()                           same without the frame bookkeeping (map change, invalidate, switch off)
-- Rules: summed dt of a batch of 2+ ticks is capped at CAP (0.1 s; the excess is counted in stats.lost); a single tick passes
-- through uncapped exactly as the per-tick hook would have delivered it. If the host stops signalling (more than FAILSAFE
-- ticks without frameBegin) the stage runs every tick again. Bad dt (NaN, negative, inf) counts as 0 for the sum.
local mod = ...
local ex = mod.exports
if type(ex) ~= 'table' then ex = {}; mod.exports = ex end
local perf = ex.questPerf
if type(perf) ~= 'table' then perf = { hoist = true, tier = 'full' }; ex.questPerf = perf end
if perf.fo then return perf.fo end

local HUGE = math.huge
local CAP, FAILSAFE = 0.1, 3
local FO = { CAP = CAP, FAILSAFE = FAILSAFE, perf = perf }
local stats = { frames = 0, flushes = 0, batches = 0, deferred = 0, failsafe = 0, capped = 0, lost = 0, errors = 0, ran = 0 }
FO.stats = stats
if perf.frameOnce == nil then perf.frameOnce = false end
perf.frameSerial, perf.tickSerial = 0, 0
perf.fo = FO
local stages, flushing = {}, false

function FO.stage(name, order, run)
  for i = 1, #stages do
    if stages[i].name == name then
      stages[i].run, stages[i].order = run, order
      return stages[i]
    end
  end
  local st = { name = name, order = order, run = run, pending = 0, n = 0, ticks = 0, last = 0, dts = {} }
  local at = #stages + 1
  for i = 1, #stages do if order < stages[i].order then at = i; break end end
  table.insert(stages, at, st)
  return st
end

local function warn(message)
  local log = mod.log
  if log and log.warn then pcall(log.warn, log, 'frameOnce: %s', message) end
end

local function fault(st, err)
  stats.errors = stats.errors + 1
  if stats.lastError ~= tostring(err) then
    stats.lastError = tostring(err)
    warn(st.name .. ' failed: ' .. stats.lastError)
  end
end

-- Called from a stage's input.step link when (perf.frameOnce or st.n ~= 0).
function FO.take(st, dt)
  local d = tonumber(dt) or 0
  if d ~= d or d < 0 or d == HUGE then d = 0 end
  if not perf.frameOnce then
    -- switched off with work still pending: deliver it together with this tick, nothing is lost
    local pending, n = st.pending, st.n
    st.pending, st.n, st.ticks = 0, 0, 0
    if n == 0 then return true, dt, dt end
    return true, pending + d, d
  end
  perf.tickSerial = perf.tickSerial + 1
  st.pending = st.pending + d
  st.n = st.n + 1
  st.dts[st.n] = d -- the individual tick dts of the batch (at most FAILSAFE + 1), for stages that must replay them
  st.ticks = st.ticks + 1
  st.last = d
  if st.ticks > FAILSAFE then
    -- the host is not signalling frames (menu, flat mode, battle, host missing): behave per tick
    local sum, n = st.pending, st.n
    st.pending, st.n = 0, 0
    stats.failsafe = stats.failsafe + 1
    if n > 1 and sum > CAP then stats.capped = stats.capped + 1; stats.lost = stats.lost + (sum - CAP); sum = CAP end
    return true, sum, d, n, st.dts
  end
  stats.deferred = stats.deferred + 1
  return false
end

local function flushAll()
  if flushing then return 0 end
  flushing = true
  local ran = 0
  for i = 1, #stages do
    local st = stages[i]
    if st.n ~= 0 then
      local sum, n, last = st.pending, st.n, st.last
      st.pending, st.n = 0, 0
      if n > 1 then
        stats.batches = stats.batches + 1
        if sum > CAP then stats.capped = stats.capped + 1; stats.lost = stats.lost + (sum - CAP); sum = CAP end
      end
      ran = ran + 1
      local ok, err = pcall(st.run, sum, last, n, st.dts)
      if not ok then fault(st, err) end
    end
  end
  flushing = false
  if ran > 0 then perf.tickSerial = perf.tickSerial + 1; stats.ran = stats.ran + ran end
  return ran
end

function FO.flush()
  stats.flushes = stats.flushes + 1
  return flushAll()
end

function FO.frameBegin()
  if not perf.frameOnce then return false end
  flushAll()
  for i = 1, #stages do stages[i].ticks = 0 end
  perf.frameSerial = perf.frameSerial + 1
  stats.frames = stats.frames + 1
  return true
end

function FO.setOn(on)
  on = on == true
  if on == (perf.frameOnce == true) then return on end
  if on then
    perf.frameOnce = true
    for i = 1, #stages do stages[i].ticks = 0 end
    perf.tickSerial = perf.tickSerial + 1
  else
    flushAll()
    perf.frameOnce = false
    perf.tickSerial = perf.tickSerial + 1
  end
  return perf.frameOnce
end

-- test and diagnostics only
function FO.status()
  local out = { on = perf.frameOnce == true, frameSerial = perf.frameSerial, tickSerial = perf.tickSerial, stages = {} }
  for k, v in pairs(stats) do out[k] = v end
  for i = 1, #stages do
    local st = stages[i]
    out.stages[#out.stages + 1] = { name = st.name, order = st.order, pending = st.pending, n = st.n, ticks = st.ticks }
  end
  return out
end

return FO
