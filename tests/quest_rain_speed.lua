local root = assert(arg[1], 'mod root required')

local function run(quest, speed)
  math.randomseed(12345)
  local V = {
    questLitePrivate = quest,
    require = function(name)
      if name == 'DesktopWeatherProfile' then
        return {
          current = function() return {} end,
          value = function(_, _, fallback) return fallback end,
        }
      end
      if name == 'Quality' then
        return { budget = function() return { worldPrecip = 1 } end }
      end
      if name == 'Settings' then
        return { isFirstPerson = function() return false end }
      end
      error(name)
    end,
  }
  local WP = assert(loadfile(root .. '/lib/voxel_atmos/WorldPrecip.lua'))(V)
  local weather = { rainIntensity = 1, rainSpeed = speed, wxId = 'RAIN_HEAVY' }
  local function firstY()
    local entry = assert(WP.sample(1)[1], 'no rain particle')
    return assert(tonumber(entry:match('pos=%([^,]+,([^,]+),')))
  end
  WP.update(0.05, {0, 0, 0}, weather)
  local y0 = firstY()
  WP.update(0.05, {0, 0, 0}, weather)
  return y0 - firstY()
end

local desktop = run(false, 1)
local quest = run(true, 1)
assert(math.abs(quest - desktop) < 0.001,
  ('Quest and desktop rain fell at different speeds: %.2f / %.2f'):format(quest, desktop))
for _,isQuest in ipairs({false, true}) do
  local normal = run(isQuest, 1)
  local faster = run(isQuest, 1.12)
  local lighter = run(isQuest, .82)
  assert(faster > normal * 1.08,
    'storm profile rainSpeed did not increase fall speed on both hosts')
  assert(lighter < normal * .90 and lighter > normal * .78,
    'light-rain profile lost its slower relative pace')
end
print('Shared rain fall speed: PASS')
