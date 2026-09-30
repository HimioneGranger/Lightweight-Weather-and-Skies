return function(mod, settings, adapter, worldExports)
local WEATHER_ROW_ID = "pipeline:weather"
local DAYTIME_ROW_IDS = {
  ["BATTLE_ART_VOXEL_FORK:daytime"] = true,
  ["BATTLE_ART_VOXEL_GEN2:daytime"] = true,
}
local function isDaytimeRow(id)return DAYTIME_ROW_IDS[id]==true end

local function optionTable(game)
  if not game then return nil end
  if game.save and type(game.save.options)=="table" then return game.save.options end
  if type(game.options)=="table" then return game.options end
  return nil
end

local function submenu(id,label,members)
  return {id=id,label=label,group=true,members=members,
    value=function()return #members..' CONTROLS'end,
    activate=function(g)
      -- Gen2Compat's src.ui.OptionsMenu facade deliberately does not expose
      -- the private rows constructor.  The old implementation set a Gold
      -- game on the Gen 1 menu metatable and drew OptionRows directly.  That
      -- mixed two input contracts, threw while reading game.save/options and
      -- could leave movement active behind a broken menu.  Build the same
      -- native page shape Gold's own pushGroup uses instead.
      if type(g.options)=='table' then
        local OptionsMenu=require('src.ui.gen2.OptionsMenu')
        local view={}
        for i,row in ipairs(members)do view[i]=row end
        view[#view+1]={id='cancel',label='BACK',cancel=true}
        local sub=setmetatable({game=g,rows=members,view=view,options=g.options,
          index=1,scroll=0,sub=true},OptionsMenu)
        sub.onDone=function(options)
          g.options=options
          if g.save then g.save.options=options end
          if g.applyOptions then pcall(g.applyOptions,g) end
          if g.persistOptions then pcall(g.persistOptions,g) end
        end
        g.stack:push(sub)
      else
        local OptionsMenu=require('src.ui.OptionsMenu')
        -- Gen 1's OptionsMenu.new only accepts onCancel; it rebuilds the
        -- top-level rows and ignores opts.rows. Use its native screen shape
        -- directly so this page contains the requested members.
        g.stack:push(setmetatable({
          game=g,rows=members,index=1,scroll=0
        },OptionsMenu))
      end
    end}
end

local function directAtmosphereControls(out, game)
  local weatherRow, daytimeRow
  -- Take every copy out first. This both keeps the controls adjacent and
  -- makes the operation idempotent if an engine or another compatibility
  -- hook has already supplied either row.
  for i = #out, 1, -1 do
    local row = out[i]
    local id = type(row) == "table" and row.id or nil
    if id == WEATHER_ROW_ID then
      weatherRow = weatherRow or row
      table.remove(out, i)
    elseif isDaytimeRow(id) then
      daytimeRow = daytimeRow or row
      table.remove(out, i)
    end
  end

  if not weatherRow then
    local ok, Pipelines = pcall(require, "src.render.Pipelines")
    if ok and Pipelines and type(Pipelines.rows) == "function" then
      for _, row in ipairs(Pipelines.rows(game) or {}) do
        if type(row) == "table" and row.id == WEATHER_ROW_ID then
          weatherRow = row
          break
        end
      end
    end
  end

  if not daytimeRow then
    local host = adapter.exports and adapter.exports.lib
    if host and type(host.require) == "function" then
      local ok, DayNight = pcall(host.require, "DayNight")
      local setting = ok and DayNight and DayNight.setting
      if setting and type(setting.row) == "function" then
        daytimeRow = setting:row()
      end
    end
  end

  if weatherRow then out[#out + 1] = weatherRow end
  if daytimeRow then
    -- Battle Art normally categorizes its setting rows into a WORLD submenu.
    -- q90 deliberately keeps this one direct: WEATHER and DAYTIME are the two
    -- atmosphere controls a headset test needs constantly.
    daytimeRow.optionSetting = nil
    out[#out + 1] = daytimeRow
  end
  return weatherRow ~= nil, daytimeRow ~= nil
end

mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  if not mod.exports.rendererReady() then
    out[#out+1]={id=mod.id..':status',label='WEATHER COMPATIBILITY',value=function()return mod.exports.compatibilityStatus().reason end}
    return out
  end
  for i=#out,1,-1 do
    local id=out[i].id or ''
    if id:match('^quest:showcase') or id:match('^quest:lightning:') or id:match('^quest:nature:')
      or id:match('^quest:regional:') or id:match('^quest:moon:') or id=='quest:lite_weather_fx'
      or id==mod.id..':stormLightning' or id==mod.id..':stormPace'
      or id==mod.id..':stormMotion' or id==mod.id..':skyConstellations'
      or id=='quest:storm:front' or id:match('^BATTLE_ART_QUEST_COMPAT:storm')
      or id=='BATTLE_ART_QUEST_COMPAT:skyConstellations' then table.remove(out,i) end
  end
  directAtmosphereControls(out, game)
  local skyRow = settings:constellationsRow()
  local at = #out + 1
  for i, row in ipairs(out) do
    if isDaytimeRow(row.id) then at = i + 1 break end
  end
  table.insert(out, at, skyRow)
  for _,row in ipairs(settings:stormRows())do out[#out+1]=row end
  -- Retained showcase controls: grouped below by explicit release policy.
  local world=worldExports()
  if world and world.lib and world.lib.require then
    local nature=world.lib.require('QuestNature')
    local regional=world.lib.require('QuestRegional')
    out[#out+1]={id='quest:regional:enabled',label='REGIONAL WEATHER',
      help='Regional tendencies for AUTO weather and new AUTO storms. Manual weather wins.',
      value=function(g)local o=optionTable(g);return o and o.qRegionalWeather==false and 'OFF'or 'ON'end,
      step=function(g)local o=optionTable(g);if not o then return false end;o.qRegionalWeather=o.qRegionalWeather==false;return true end}
    out[#out+1]={id='quest:regional:area',label='WEATHER REGION',
      value=function()return regional.profile((world.lib.require('Scene').now or {}).mapId).label end,
      step=function()return false end}
    out[#out+1]={id='quest:nature:audio',label='NATURE AMBIENCE',
      help='Real birds and insects, with slow day/night fades and storm quieting. Also follows WEATHER SFX and SFX volume.',
      value=function(g)local o=optionTable(g)or{};return string.upper((o.qNatureAudio or 'normal'))end,
      step=function(g,d)
        local o=optionTable(g);if not o then return false end
        local choices={'off','low','normal','high'};local at=3
        for i,v in ipairs(choices)do if v==o.qNatureAudio then at=i end end
        o.qNatureAudio=choices[1+(at-1+(d or 1))%#choices];return true
      end}
    out[#out+1]={id='quest:nature:cries',label='RARE LOCAL CRIES',
      help='Occasional local species/earlier evolution calls, anime first and same-species Pokedex fallback. Quiet during storms.',
      value=function(g)local o=optionTable(g);return o and o.qNatureCalls==false and 'OFF'or 'ON'end,
      step=function(g)local o=optionTable(g);if not o then return false end;o.qNatureCalls=o.qNatureCalls==false;return true end}
    out[#out+1]={id='quest:showcase:nature_cry',label='LOCAL CRY TEST',
      help='Queue a local cry five seconds after closing all menus. Requires a land encounter table, calm weather, and nature audio ON.',
      value=function()return nature.status()end,step=function()return nature.trigger()end}
    local storm=world.lib.require('QuestStorm')
    local front=world.lib.require('QuestStormFront')
    out[#out+1]={id='quest:showcase:approaching_storm',label='APPROACHING STORM',
      help='Sets WEATHER to STORM and motion MOVING. Close all menus looking toward the desired horizon. Storm arrives with haze and distant lightning; leaves STORM selected. Respects lightning OFF/SOFT.',
      value=function()return front.status()end,
      step=function(g)
        local scene=world.lib.require('Scene').now or {}
        if not scene.outdoor or scene.indoors then return false end
        local state=world.lib.require('WeatherState')
        local level
        for i,id in ipairs(state.LEVEL_IDS)do if id=='STORM'then level=i-1;break end end
        if not level then return false end
        settings:_writeOption('stormMotion','moving')
        local pipelines=require('src.render.Pipelines')
        if pipelines.setLevel('weather',level)~=level then return false end
        local opts=optionTable(g);if opts then pipelines.syncOptions(opts)end
        state.level=level;state.setWeather('STORM','menu')
        return front.triggerApproach()
      end}
    out[#out+1]={id='quest:storm:front',label='STORM FRONT / RESTART',
      help='Storm lifecycle and local coverage. Press to restart a moving storm after closing Options. STATIC mode disables traveling cells.',
      value=function()return front.status()end,step=function()return front.trigger()end}
    out[#out+1]={id='quest:lightning:test',label='LIGHTNING TEST',
      value=function() return storm.testStatus() end,
      step=function(_,direction) return storm.triggerTest() end}
    local events=world.lib.require('QuestSkyEvents')
    out[#out+1]={id='quest:showcase:mountain_snow',label='AURORA + LIGHT SNOW',
      help='Night/outdoors: selects partly-cloudy light snow and a spicy aurora. Return WEATHER to AUTO afterward.',
      value=function()return events.status('aurora_spicy')end,
      step=function(g)
        if events.status('aurora_spicy')~='TRIGGER'then return false end
        local state=world.lib.require('WeatherState');local level
        for i,id in ipairs(state.LEVEL_IDS)do if id=='PARTLY_SNOW'then level=i-1;break end end
        if not level then return false end
        local pipelines=require('src.render.Pipelines')
        if pipelines.setLevel('weather',level)~=level then return false end
        local opts=optionTable(g);if opts then pipelines.syncOptions(opts)end
        state.level=level;state.setWeather('PARTLY_SNOW','menu')
        return events.trigger('aurora_spicy')
      end}
    out[#out+1]={id='quest:moon:phase',label='LUNAR CYCLE',
      help='Saved 30 natural in-game days. Manual time presets do not advance it.',
      value=function()return 'DAY '..((world.lib.require('NightSky').meteorStatus().day or 0)%30+1)..' / 30'end,
      step=function()return false end}
    out[#out+1]={id='quest:showcase:moon_phase',label='MOON PHASE PREVIEW',
      help='Waxing, full, waning, crescent, new, then natural. Preview does not change saved days.',
      value=function()return world.lib.require('QuestMoon').previewStatus()end,
      step=function()return world.lib.require('QuestMoon').previewNext()end}
    out[#out+1]={id='quest:lightning:spicy',label='LIGHTNING: MAKE IT SPICY',
      help='Two-minute verification showcase: high-contrast forked strikes and anvil crawlers ahead about every 6 seconds. Close all menus and keep looking forward; press again to stop. Respects SOFT/OFF. Showcase timing is separate from natural activity.',
      value=function()return storm.spicyStatus()end,
      step=function()return storm.triggerSpicy()end}
    for _,variant in ipairs({'anvil','rolling'})do
      local kind=variant
      out[#out+1]={id='quest:lightning:'..kind..'_test',
        label=kind=='anvil' and 'ANVIL CRAWLER TEST' or 'ROLLING LIGHTNING TEST',
        help='STORM only. Close menu to showcase this style ahead. Respects SOFT/OFF. Showcase control.',
        value=function()return storm.testStatus(kind)end,
        step=function()return storm.triggerTest(kind)end}
    end
    out[#out+1]={id='quest:lightning:cloud_test',label='CLOUD LIGHTNING TEST',
      help='During STORM: close menu for one distant glow in the clouds ahead, then quiet thunder 6-9 seconds later. Respects SOFT/OFF. Showcase control.',
      value=function() return storm.testStatus('cloud') end,
      step=function() return storm.triggerTest('cloud') end}
    local recovery=world.lib.require('QuestAfterStorm')
    out[#out+1]={id='quest:showcase:rain_clearing',label='RAIN CLEARING TEST',
      help='While raining: close menu to switch WEATHER to CLEAR and show rain taper, cloud breakup and daylight return. Guarantees rainbow chance, but needs low daytime sun. Leaves WEATHER on CLEAR. Showcase control.',
      value=function()return recovery.testStatus()end,
      step=function(g)
        return recovery.triggerTest(function()
          local state=world.lib.require('WeatherState')
          local clearLevel
          for i,id in ipairs(state.LEVEL_IDS)do if id=='CLEAR' then clearLevel=i-1;break end end
          if not clearLevel then return false end
          local pipelines=require('src.render.Pipelines')
          if pipelines.setLevel('weather',clearLevel)~=clearLevel then return false end
          local opts=optionTable(g)
          if opts then pipelines.syncOptions(opts)end
          state.level=clearLevel
          state.setWeather('CLEAR','menu')
          return true
        end)
      end}
    for index,kind in ipairs({'meteor','aurora'}) do
      local eventKind=kind
      table.insert(out,at+index,{
        id='quest:showcase:'..eventKind,
        label=eventKind=='meteor' and 'METEOR SHOWCASE' or 'AURORA SHOWCASE',
        value=function() return events.status(eventKind) end,
        step=function() events.trigger(eventKind); return true end,
      })
    end
    table.insert(out,at+3,{
      id='quest:showcase:aurora_spicy',label='AURORA: MAKE IT SPICY',
      help='Aurora content mode: 2 minutes of splitting curtains, pink fringes and an overhead crown. Night/outdoors only; close menu to start. Showcase control.',
      value=function() return events.status('aurora_spicy') end,
      step=function() return events.trigger('aurora_spicy') end,
    })
    table.insert(out,at+2,{
      id='quest:showcase:meteor_spicy',label='METEORS: MAKE IT SPICY',
      help='Meteor content mode: 2 minutes, one meteor every 3-6 seconds, more green and long trails. Close menu to start. Natural showers unchanged. Showcase control.',
      value=function() return events.status('meteor_spicy') end,
      step=function() return events.trigger('meteor_spicy') end,
    })
  end
  local members={}
  for i=#out,1,-1 do
    local row=out[i];local id=row.id or ''
    if id:match('^quest:showcase:') or id:match('^quest:lightning:') or id=='quest:storm:front' then
      table.insert(members,1,table.remove(out,i))
    end
  end
  if #members>0 then
    local labels={
      ['quest:storm:front']='RESTART STORM',
      ['quest:lightning:spicy']='LIGHTNING SPICY',
      ['quest:lightning:anvil_test']='ANVIL CRAWLER',
      ['quest:lightning:rolling_test']='ROLLING LIGHTNING',
      ['quest:lightning:cloud_test']='CLOUD LIGHTNING',
      ['quest:showcase:rain_clearing']='RAIN CLEARING',
      ['quest:showcase:aurora_spicy']='AURORA SPICY',
      ['quest:showcase:meteor_spicy']='METEORS SPICY',
    }
    for _,row in ipairs(members)do row.label=labels[row.id] or row.label end
    out[#out+1]=submenu('quest:showcase_controls','SHOWCASE CONTROLS',members)
  end
  local extras={}
  for i=#out,1,-1 do
    local id=out[i].id or ''
    if id==mod.id..':stormPace' or id==mod.id..':stormMotion'
      or id==mod.id..':skyConstellations' or id:match('^quest:regional:')
      or id:match('^quest:nature:') or id:match('^quest:moon:')
      or id=='quest:showcase_controls' then
      table.insert(extras,1,table.remove(out,i))
    end
  end
  if #extras>0 then
    out[#out+1]=submenu('quest:lite_weather_fx','LITE WEATHER FX',extras)
  end
  return out
end, 1000)


end
