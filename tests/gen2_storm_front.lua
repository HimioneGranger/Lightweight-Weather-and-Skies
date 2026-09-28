local root = assert(arg[1])
local scene = { now = { mapId = "ROUTE_29", playerX = 160, playerZ = 160,
  outdoor = true, indoors = false, visible = "world" } }
local maps = { ROUTE_29 = { width = 40, height = 20 } }
local front
local modules = {
  Scene = scene,
  OutdoorWeatherAreas = { position = function(_, id, x, z) return id, x, z, 0, 0 end },
  QuestStorm = { preferences = function() return { motion = "moving" } end },
}
local V = {
  mod = { game = { data = { maps = maps } }, events = { on = function() end } },
  require = function(name) return assert(modules[name], name) end,
}
front = assert(loadfile(root .. "/lib/QuestStormFront.lua"))(V)
local state = { id = "STORM", level = 1, LEVEL_IDS = { false, "AUTO" }, pinnedBy = "menu" }
local settings = { worldWeatherEnabled = function() return true end }
front.update(1 / 60, state, settings)
assert(front.managed and front.cell, "Gen2 public game map did not start a moving storm")
assert(front.coverage < 0.01, "moving storm appeared at full strength on first tick")
for _ = 1, 6000 do front.update(1 / 60, state, settings) end
assert(front.coverage > 0.1, "moving storm never reached the player")
local initialStrength = front.cell.strength
state.id = "CLEAR"
front.update(1 / 60, state, settings)
assert(front.managed and front.cell and front.cloudField(),
  "Clear erased the storm bank on its first frame")
assert(front.cell.strength > initialStrength * .99,
  "Clear visibly cut storm cloud strength on its first frame")
for _ = 1, 1800 do front.update(1 / 60, state, settings) end
assert(front.cell and front.cell.strength < initialStrength,
  "storm bank did not dissipate during clearing")
for _ = 1, 2400 do front.update(1 / 60, state, settings) end
assert(not front.cell and not front.managed,
  "storm bank did not finish clearing")
print("Gen2 storm front: PASS")
