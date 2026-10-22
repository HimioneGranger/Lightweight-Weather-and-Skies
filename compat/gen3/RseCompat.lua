-- Selected by the only RSE seam in Gen3Compat. Existing FRLG code is unchanged.
local mod,loadModule=...
-- require is this mod's sandbox field; loadstring chunks share its environment.
require=loadModule('compat/gen3/RseNativeImports.lua',mod,require)
local shared={rse=true,patchLogSha='packet-a-rse'}
local function load(name,V)return loadModule('compat/gen3/'..name,mod,loadModule,V,shared)end
require=load('RseMenuBridge.lua')
shared.tick=load('Gen3Tick.lua')
shared.options=load('Gen3Options.lua');shared.options.setMode('rtc')
mod.events:on('mods.loaded',function()
 if shared.installed then return end
 local V=mod.exports and mod.exports.lib
 if not(V and V.require)then mod.log:warn('rse: weather library unavailable');return end
 shared.installed=true
 shared.maps={OUTDOOR_MAP_TYPES={[1]=true,[2]=true,[3]=true,[6]=true}}
 shared.world=load('RseWorld.lua',V)
 shared.clock=load('RseClock.lua',V)
 shared.weather=load('RseWeather.lua',V)
 shared.host=load('Gen3Host.lua',V)
 mod.exports.gen3.rse=shared
 mod.log:info('rse: native local clock and Hoenn weather installed')
end,50)
return shared
