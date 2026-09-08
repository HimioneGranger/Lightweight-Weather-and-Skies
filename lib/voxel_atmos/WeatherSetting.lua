-- Persistent option ladder owned by Kanto Dynamic Weather.
-- Mirrors Gen1Recomp's mod-manager storage so the in-game OPTIONS row and
-- the manager page always read/write the same value.
local V = ...
local Setting = {}
Setting.__index = Setting

local function ownerId()
  return (V.mod and V.mod.id) or "kanto_dynamic_weather"
end

local function indexOf(self, value)
  for i, v in ipairs(self.values) do
    if v == value then return i end
  end
  return self.defaultIndex or 1
end

function Setting.new(key, label, values, labels, defaultIndex)
  defaultIndex = tonumber(defaultIndex) or 1
  if defaultIndex < 1 or defaultIndex > #values then defaultIndex = 1 end
  return setmetatable({
    key=key, label=label, values=values, labels=labels,
    defaultIndex=defaultIndex, index=nil,
  }, Setting)
end

function Setting:allows(i) return true end
function Setting:rungs() return #self.values end

function Setting:read()
  if self.index then return self.index end
  local value
  if V.mod and V.mod.options then
    local ok, got = pcall(V.mod.options.get, V.mod.options, self.key)
    if ok then value = got end
  end
  self.index = indexOf(self, value)
  return self.index
end

function Setting:get()
  return self.values[self:read()] or self.values[self.defaultIndex or 1]
end

function Setting:level() return self:read() - 1 end

function Setting:setIndex(i, game)
  local n = #self.values
  i = ((i - 1) % n + n) % n + 1
  self.index = i
  local value, id = self.values[i], ownerId()
  local opts = game and game.save and game.save.options
  if opts then
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[id] = opts.modOptions[id] or {}
    opts.modOptions[id][self.key] = value
  end
  local loader = game and game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[id] = loader.modOptions[id] or {}
    loader.modOptions[id][self.key] = value
  end
  if game and game.writeOptions then pcall(game.writeOptions, game) end
  return value
end

function Setting:setValue(value, game)
  return self:setIndex(indexOf(self, value), game)
end

function Setting:cycle(game, dir)
  return self:setIndex(self:read() + (dir or 1), game)
end

function Setting:sync(value)
  self.index = indexOf(self, value)
end

function Setting:row()
  local self_ = self
  return {
    id = ownerId() .. ":" .. self.key,
    label = self.label,
    value = function() return self_.labels[self_:read()] end,
    step = function(game, dir)
      self_:cycle(game, dir)
      return true
    end,
  }
end

function Setting:schema(help)
  local choices = {}
  for i, v in ipairs(self.values) do
    choices[#choices + 1] = { self.labels[i], v }
  end
  return {
    key=self.key, type="choice", label=self.label,
    choices=choices, default=self.values[self.defaultIndex or 1], help=help,
  }
end

return Setting
