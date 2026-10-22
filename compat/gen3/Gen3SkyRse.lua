-- Persistent Gen3 cloud transport shared by FR/LG and Emerald. Family-specific
-- weather selection remains in Gen3Tick/RseCompat; this only owns the deck.
local mod, loadModule, hostLib, shared = ...
local M = {}
local records = setmetatable({}, {__mode='k'})
local target, elapsed = nil, 0
local stats = {constructions=0, updates=0, draws=0, errors=0}
local function fault(stage, why)
  stats.errors=stats.errors+1
  local message=stage..': '..tostring(why)
  if stats.lastError~=message and mod.log and mod.log.info then
    pcall(mod.log.info,mod.log,'gen3: cloud transport %s',message)
  end
  stats.lastError=message
end
-- Lab 60 (fixes60 item 2): precomputed cloud field + first-use timing + prewarm. Everything below
-- that touches the deck is active only while VRITK_FRLG_HOST is installed (vritkOn); without it the
-- deck is the stock one and none of the Gen3CloudAsset wrappers exist. The shared generator
-- (compat/CloudsSource.lua) and lib/Gen2VoxelClouds.lua are not modified.
local Asset = nil -- compat/gen3/Gen3CloudAsset.lua, loaded on first use (false = failed)
local function loadAsset()
  if Asset ~= nil then return Asset or nil end
  Asset = false
  local ok, m = pcall(loadModule, 'compat/gen3/Gen3CloudAsset.lua', mod, loadModule, hostLib, shared)
  if ok and type(m) == 'table' then Asset = m else fault('asset module', m) end
  return Asset or nil
end
local function logInfo(fmt, ...)
  if mod.log and mod.log.info then pcall(mod.log.info, mod.log, fmt, ...) end
end
local function vritkOn()
  if type(mod.find) ~= 'function' then return false end
  local ok, h = pcall(mod.find, 'VRITK_FRLG_HOST')
  return ok and h ~= nil and h ~= false
end
local function readAsset(path) return mod:read(path) end
local function nowMs() return love.timer.getTime() end
-- Runtime-only performance switch (mod.exports.questPerf, see main.lua).
local function perfState()
  local e = mod.exports
  if type(e) ~= 'table' then return { hoist = true, tier = 'full' } end
  local p = e.questPerf
  if type(p) ~= 'table' then p = { hoist = true, tier = 'full' }; e.questPerf = p end
  return p
end
local perf = perfState()
-- Original per-eye form (frame hoist OFF).
local function sceneAndSettingsLegacy()
  local ok,scene,settings=pcall(function() return hostLib.require('Scene').now or {},hostLib.require('Settings') end)
  if not ok then fault('context',scene);return nil end
  if type(scene)~='table' or type(settings)~='table' or type(settings.cloudsOn)~='function' then
    fault('context','missing scene/settings');return nil
  end
  local okS,on=pcall(settings.cloudsOn)
  if not okS then fault('settings',on);return nil end
  return scene,on~=false
end
local function worldLegacy()
  local ok,ow=pcall(function() return mod.world:overworld() end)
  return ok and ow or nil
end
-- Hoisted form: predefined functions, no per-eye closure or table.
local EMPTY = {}
local function readContext()
  local now = hostLib.require('Scene').now
  return now or EMPTY, hostLib.require('Settings')
end
local function callOverworld() return mod.world:overworld() end
local function sceneAndSettingsFast()
  local ok,scene,settings=pcall(readContext)
  if not ok then fault('context',scene);return nil end
  if type(scene)~='table' or type(settings)~='table' or type(settings.cloudsOn)~='function' then
    fault('context','missing scene/settings');return nil
  end
  local okS,on=pcall(settings.cloudsOn)
  if not okS then fault('settings',on);return nil end
  return scene,on~=false
end
local function worldFast()
  local ok,ow=pcall(callOverworld)
  return ok and ow or nil
end
local function ensure(voxel)
  local r=records[voxel]
  if r.deck then return r.deck end
  if elapsed<(r.retryAt or 0) then return nil end
  local tNew=nowMs()
  local ok,deck=pcall(function()
    return hostLib.require('Gen2VoxelClouds').new(hostLib,voxel,{depthTest=true})
  end)
  tNew=(nowMs()-tNew)*1000
  if not (ok and type(deck)=='table' and type(deck.draw)=='function' and type(deck.update)=='function') then
    r.retryAt=elapsed+5;fault('construction',ok and 'invalid cloud deck' or deck);return nil
  end
  r.deck=deck;stats.constructions=stats.constructions+1
  if vritkOn() then
    local A=loadAsset()
    if A then
      r.stage={new=tNew}
      local okA,whyA=pcall(A.attach,deck,{log=logInfo,read=readAsset,stage=r.stage,now=nowMs})
      if not okA then fault('asset attach',whyA) end
    end
  end
  return deck
end
-- Prewarm: build the deck, image, mesh and shader ahead of the first outdoor eye frame, so the
-- cost lands behind a loading screen or while the player is indoors. One stage per call:
-- 'deck' -> 'image' -> 'mesh' -> 'shader'. Returns done(boolean), stageName|reason. Idempotent:
-- once warm it returns true,'warm' at no cost. Never throws. The shader stage draws the deck once
-- into a cached 1x1 canvas (push/pop 'all' restores the caller's canvas and state) with a dummy
-- eye; voxel.eye/vp are restored afterwards. It does not touch cloud placement or weather state.
local DUMMY_EYE={0,0,0}
local DUMMY_VP={1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}
local tinyCanvas=nil
local function dummyDraw(g,deck,r)
  g.setCanvas(tinyCanvas)
  if Asset and r.stage then
    local okD,res=Asset.timedCall(r.stage,deck.clouds.draw,DUMMY_EYE)
    if not okD then error(res,0) end
    if res==false then error('cloud draw declined',0) end
  else
    local res=deck.clouds.draw(DUMMY_EYE)
    if res==false then error('cloud draw declined',0) end
  end
end
local function prewarmShader(voxel,deck,r)
  local g=love.graphics
  if not (g and g.newCanvas and g.setCanvas and g.push and g.pop) then return false,'no graphics' end
  tinyCanvas=tinyCanvas or g.newCanvas(1,1)
  local oldEye,oldVp=voxel.eye,voxel.vp
  voxel.eye,voxel.vp=DUMMY_EYE,DUMMY_VP
  deck.clouds.hoist=perf.hoist
  g.push('all')
  local okD,errD=pcall(dummyDraw,g,deck,r)
  g.pop()
  voxel.eye,voxel.vp=oldEye,oldVp
  if not okD then return false,tostring(errD) end
  return true
end
local function prewarmStepInner(phase)
  local voxel=target
  local r=voxel and records[voxel]
  if not r then return true,'not installed' end
  if r.warm then return true,'warm' end
  if not vritkOn() then return true,'vritk off' end
  if r.warmFailed then return true,'failed' end
  local ok,scene,on
  if perf.hoist then scene,on=sceneAndSettingsFast() else scene,on=sceneAndSettingsLegacy() end
  if not scene or not on or perf.tier=='off' then return true,'clouds off' end
  local deck=ensure(voxel)
  if not deck then return true,'no deck' end
  local stage=r.warmStage
  if not stage then r.warmStage='image'; return false,'deck' end
  if stage=='image' then
    local okI,img=pcall(deck.clouds.image)
    if not okI or not img then r.warmFailed=true; fault('prewarm image',img); return true,'no image' end
    r.warmStage='mesh'; return false,'image'
  elseif stage=='mesh' then
    local okM,m=pcall(deck.clouds.mesh)
    if not okM or not m then r.warmFailed=true; fault('prewarm mesh',m); return true,'no mesh' end
    r.warmStage='shader'; return false,'mesh'
  end
  local okP,okS,whyS=pcall(prewarmShader,voxel,deck,r)
  if not okP then okS,whyS=false,okS end
  if not okS then r.warmFailed=true; fault('prewarm shader',whyS); return true,'no shader' end
  r.warm=true
  if r.stage and r.stage.report then r.stage.warmed=true; r.stage.report(' prewarm') end
  return true,'warm'
end
-- prewarmStep(phase): one stage per call. Elapsed time is summed per stage; when the deck is warm,
-- logs once: 'cloud deck warmed at <phase> in N ms'. phase is a label string from the caller
-- ('boot', 'prepare', 'loading', 'idle', ...).
local function prewarmStep(phase)
  local t0=nowMs()
  local done,info=prewarmStepInner(phase)
  local voxel=target
  local r=voxel and records[voxel]
  if r then
    r.warmMs=(r.warmMs or 0)+(nowMs()-t0)*1000
    if done and info=='warm' and not r.warmLogged then
      r.warmLogged=true
      logInfo('cloud deck warmed at %s in %.1f ms',tostring(phase or '?'),r.warmMs)
    end
  end
  return done,info
end
function M.prewarmStep(phase) return prewarmStep(phase) end
function M.prewarm(phase)
  local done,info=false,nil
  local guard=0
  while not done and guard<8 do done,info=prewarmStep(phase); guard=guard+1 end
  return done,info
end
function M.install(handle,voxel)
  if not voxel then return false end
  target=voxel
  if records[voxel] then return true end
  records[voxel]={}
  voxel._rseSkyOwner=M -- retained compatibility marker
  -- Lab 60: FRLG_VOXEL's WeatherHost:prewarm(phase, oneStep) calls this.
  voxel.questCloudPrewarm=function(phase,oneStep)
    if oneStep then return prewarmStep(phase) end
    return M.prewarm(phase)
  end
  voxel.afterCelestial=function(map,neighbors,outdoor)
    local fast=perf.hoist
    local scene,on
    if fast then scene,on=sceneAndSettingsFast() else scene,on=sceneAndSettingsLegacy() end
    if not scene or not on then return end
    if outdoor==nil then outdoor=scene.outdoor==true end
    if not outdoor or scene.outdoor==false or scene.indoors==true or scene.visible=='hidden' then return end
    local ow
    if fast then ow=worldFast() else ow=worldLegacy() end
    map=map or (ow and ow.map);neighbors=neighbors or (ow and ow.neighbors)
    if not map then return end
    local deck=ensure(voxel)
    if not deck then return end
    local ok,result=pcall(deck.draw,deck,map,neighbors,true)
    if not ok or result==false then fault('draw',result);return end
    stats.draws=stats.draws+1
  end
  return true
end
-- The weather pipeline runs at -950. Advance the shared cloud state once
-- after that pipeline, never from either eye's draw callback.
-- Lab 52 (exports.setFrameOnce, default OFF): the deck update runs once per rendered frame with the summed dt
-- (compat/FrameOnce.lua flush, after the weather record update); the OFF path is the original per-tick one.
local FO=perf.fo
local fperf=FO and perf or {}
local take=FO and FO.take
local function runDeck(dt)
  local delta=tonumber(dt) or 0
  if delta~=delta or delta<0 or delta==math.huge then delta=0 end
  elapsed=elapsed+delta
  local r=target and records[target]
  if r and r.deck then
    local ok,why=pcall(r.deck.update,r.deck,delta)
    if ok then stats.updates=stats.updates+1 else fault('update',why) end
  end
end
local stage=FO and FO.stage('deck',40,runDeck) or {n=0}
mod.hooks:wrap('input.step',function(next,game,dt)
  local result=next(game,dt)
  local go,d=true,dt
  if fperf.frameOnce or stage.n~=0 then go,d=take(stage,dt) end
  if go then runDeck(d) end
  return result
end,-940)
function M.status()
  local r=target and records[target]
  return {constructions=stats.constructions,updates=stats.updates,draws=stats.draws,
    errors=stats.errors,lastError=stats.lastError,cached=r and r.deck~=nil or false}
end
return M
