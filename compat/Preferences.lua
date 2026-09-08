local P = {}
P.__index = P
local choices={stormLightning={'full','soft','off'},stormPace={'calm','rare','active'},stormMotion={'moving','static'}}
function P.new(mod,engine) return setmetatable({mod=mod,engine=engine or require},P) end
function P:define()
  self.mod.options:define({
    {key='stormLightning',type='choice',label='LIGHTNING',default='full',choices={{'FULL','full'},{'SOFT','soft'},{'OFF','off'}}},
    {key='stormPace',type='choice',label='STORM PACE',default='calm',choices={{'CALM','calm'},{'RARE','rare'},{'ACTIVE','active'}}},
    {key='stormMotion',type='choice',label='STORM MOTION',default='moving',choices={{'MOVING','moving'},{'STATIC','static'}}},
    {key='skyConstellations',type='toggle',label='CONSTELLATIONS',default=false},
  })
end
function P:read(key)
  local ok,value=pcall(self.mod.options.get,self.mod.options,key)
  if key=='skyConstellations' then return ok and value==true end
  local list=assert(choices[key],'Unknown preference')
  if ok then for _,v in ipairs(list)do if v==value then return value end end end
  return list[1]
end
function P:_writeOption(key,value)
  local allowed=key=='skyConstellations' and type(value)=='boolean'
  for _,v in ipairs(choices[key]or {})do if v==value then allowed=true end end
  assert(allowed,'Invalid weather preference')
  local ok,game=pcall(self.engine,'src.core.Game')
  if ok and game then
    local opts=game.save and game.save.options
    if opts then
      opts.modOptions=opts.modOptions or {}
      opts.modOptions[self.mod.id]=opts.modOptions[self.mod.id]or {}
      opts.modOptions[self.mod.id][key]=value
    end
    if game.mods then
      game.mods.modOptions=game.mods.modOptions or {}
      game.mods.modOptions[self.mod.id]=game.mods.modOptions[self.mod.id]or {}
      game.mods.modOptions[self.mod.id][key]=value
    end
    if self.mod.options.values then self.mod.options.values[key]=value end
    if game.writeOptions then pcall(game.writeOptions,game)end
  elseif self.mod.options.values then self.mod.options.values[key]=value end
  return value
end
function P:stormPreferences()return {mode=self:read('stormLightning'),pace=self:read('stormPace'),motion=self:read('stormMotion')}end
function P:readConstellations()return self:read('skyConstellations')end
function P:stormRows()
  local rows={}
  for _,entry in ipairs({{'stormLightning','LIGHTNING'},{'stormPace','STORM PACE'},{'stormMotion','STORM MOTION'}})do
    local key,label=entry[1],entry[2]
    rows[#rows+1]={id=self.mod.id..':'..key,label=label,value=function()return self:read(key):upper()end,
      step=function(_,direction)
        local list,at=choices[key],1
        for i,v in ipairs(list)do if v==self:read(key)then at=i end end
        self:_writeOption(key,list[1+(at-1+((tonumber(direction)or 1)<0 and -1 or 1))%#list]);return true
      end}
  end
  return rows
end
function P:constellationsRow()
  return {id=self.mod.id..':skyConstellations',label='CONSTELLATIONS',
    value=function()return self:readConstellations()and 'ON'or 'OFF'end,
    step=function()self:_writeOption('skyConstellations',not self:readConstellations());return true end}
end
return P
