-- Mod-local pipeline facade and native Gen 3 options hook/page adapter.
local mod, loadModule, V, shared = ...
local nativeRequire = require
local Runtime = nativeRequire('src.core.game3.runtime')
local Profile = nativeRequire('src.core.game3.profile')
local Hooks = nativeRequire('src.mods.Runtime')
local Rows = nativeRequire('src.ui.game3.option_rows')
-- Native weather/options remain usable on hosts without visual-clock preview.
local previewOk, Preview = pcall(nativeRequire, 'src.core.game3.lighting_preview')
if not previewOk or type(Preview)~='table' or type(Preview.label)~='function'
  or type(Preview.step)~='function' or type(Preview.KEY)~='string' then Preview=nil end
local KEY = 'qGen3WeatherLevel'
local function options()
  local g = Runtime._game
  local s = Runtime.getSession()
  return g and g.options or s and s.options or {}
end
local function state()
  local lib = mod.exports and mod.exports.lib
  return lib and lib.require and lib.require('WeatherState')
end
local P = {}
mod.events:on('mod.options_changed',function(payload)
  if payload and payload.mod==mod.id and payload.key=='gen3_weather' then
    options()[KEY]=({OFF=0,AUTO=1,CYCLE=2})[payload.value] or 1
    local g=Runtime._game
    if g and g.writeOptions then g:writeOptions() end
  end
end)
function P.level(id)
  if id ~= 'weather' then return 0 end
  local saved = tonumber(options()[KEY])
  if saved then return saved end
  local raw = mod.options:get('gen3_weather')
  return ({OFF=0,AUTO=1,CYCLE=2})[raw] or 1
end
function P.levelLabels(id)
  local s = state()
  return id == 'weather' and s and s.LEVEL_LABELS or {}
end
function P.levelLabel(id, level) return P.levelLabels(id)[(level or P.level(id))+1] or 'AUTO' end
function P.setLevel(id, level)
  if id ~= 'weather' then return 0 end
  local labels = P.levelLabels(id)
  level = math.max(0, math.min(#labels-1, math.floor(tonumber(level) or 1)))
  options()[KEY] = level
  -- Keep the existing MOD OPTIONS selector coherent for its three modes.
  if level <= 2 then
    local value=({'OFF','AUTO','CYCLE'})[level+1]
    local function store(o)
      o.modOptions=o.modOptions or {};o.modOptions[mod.id]=o.modOptions[mod.id] or {}
      o.modOptions[mod.id].gen3_weather=value
    end
    store(options())
    local g=Runtime._game
    if g and g.mods then store(g.mods) end
  end
  return level
end
function P.syncOptions(o) o[KEY] = P.level('weather') end
function P.rows()
  local rows={{id='pipeline:lighting_preview',label='TIME OF DAY',
    value=function()return Preview.label(options())end,
    step=function(g,dir)
      Preview.step(options(),dir)
      g.options[Preview.KEY]=options()[Preview.KEY]
      local native=Runtime._game
      if native and native.writeOptions then native:writeOptions()end
      return true
    end}, {id='pipeline:weather',label='WEATHER',
    value=function() return P.levelLabel('weather') end,
    step=function(g,dir)
      local n = #P.levelLabels('weather')
      if n == 0 then return false end
      P.setLevel('weather', (P.level('weather') + (dir or 1)) % n)
      P.syncOptions(g.options)
      return true
    end}}
  if not Preview then table.remove(rows,1) end
  return rows
end
shared.weatherLevel = function() return P.level('weather') end

local build, group = Rows.build, Rows.group
local Font = nativeRequire('src.ui.game3.frlg_font')
local function fit(text,width)
  text=tostring(text or '')
  if type(Font.measure)~='function' then return text end
  if Font.measure(text)<=width then return text end
  while #text>0 and Font.measure(text..'...')>width do text=text:sub(1,-2) end
  return text..'...'
end
local function game(c)
  -- Hook rows expect game/save options, native rows expect a context.
  return setmetatable({options=c.options,save={options=c.options}}, {__index=c.game})
end
local function adapt(row)
  local out = {}; for k,v in pairs(row) do out[k]=v end
  out._rseWeatherTitle=row.label
  local labels={
    ['quest:showcase_controls']='SHOWCASE',
    ['quest:nature:audio']='NATURE AUDIO',
    ['quest:nature:cries']='LOCAL CRIES',
    ['quest:regional:enabled']='REGIONAL WX',
    ['quest:showcase:approaching_storm']='STORM APPROACH',
    ['quest:showcase:mountain_snow']='AURORA + SNOW',
    ['quest:showcase:moon_phase']='MOON PREVIEW',
  }
  out.label=fit(labels[row.id] or row.label,94)
  if row.members then
    out.members={}
    for i,r in ipairs(row.members) do out.members[i]=adapt(r) end
  else
    for _,key in ipairs({'value','step','activate'}) do
      local callback=row[key]
      if type(callback)=='function' then
        if key=='value' then out[key]=function(c,...) return fit(callback(game(c),...),96) end
        else out[key]=function(c,...) return callback(game(c),...) end end
      end
    end
  end
  return out
end
Rows.build=function(c)
  if Profile.family(c and c.session)~='rse' then return build(c) end
  local base=build(c); local originals={}
  for _,row in ipairs(base) do originals[row]=true end
  local rows=Hooks.call('ui.options.rows',function(_,r)return r end,game(c),base)
  local result={}
  for i,row in ipairs(rows) do result[i]=originals[row] and row or adapt(row) end
  -- Gen3 Controls imports only WEATHER from P.rows; insert the visual clock
  -- explicitly here so it is reachable in the native options page.
  if Preview then
  for i=#result,1,-1 do
    local id=result[i].id
    if id=='pipeline:lighting_preview' or id=='BATTLE_ART_VOXEL_FORK:daytime' or id=='BATTLE_ART_VOXEL_GEN2:daytime' then table.remove(result,i)end
  end
  local at=#result+1
  for i,row in ipairs(result)do if row.id=='pipeline:weather' then at=i+1;break end end
  table.insert(result,at,adapt(P.rows()[1]))
  end
  for _,row in ipairs(result) do if row.members then row._rseWeatherMembers=true end end
  return result
end
Rows.group=function(rows,openPage)
  local function bind(row)
    if row.members and row._rseWeatherMembers then
      -- Descendants are copied by adapt, so mark them for this native page tree.
      for _,member in ipairs(row.members) do if member.members then member._rseWeatherMembers=true end end
      for _,member in ipairs(row.members) do bind(member) end
      row.activate=function() openPage(row._rseWeatherTitle or row.label,row.members) end
    end
  end
  for _,row in ipairs(rows) do bind(row) end
  return group(rows,openPage)
end
return function(name)
  if name=='src.render.Pipelines' then return P end
  return nativeRequire(name)
end
