-- Pure selection. Installed mod presence never determines the active renderer.
local R={}
local profiles={BATTLE_ART_VOXEL_FORK='battle_art',BATTLE_ART_VOXEL_GEN2='battle_art_gen2',DRAMATIC_SHAPE='dramatic',
  DRAMALESS_SHAPE='dramaless',potato_voxel='potato',POTATO_VOXEL='potato',
  PotatoVoxel='potato',STADIUM2_OVERWORLD_MODELS='stadium2'}
function R.select(pipeline,owner,platform,standalone)
  if not pipeline then return 'flat',nil end
  if type(owner)~='string' then return 'unknown',nil end
  local kind=profiles[owner]
  if not kind then return 'unsupported',owner end
  if kind=='battle_art_gen2' and platform=='Android' and standalone then
    kind='battle_art_quest'
  end
  if kind=='battle_art' then
    if platform=='Android' then kind=standalone and 'battle_art_quest' or 'battle_art_android'
    else kind='battle_art_pc'end
  end
  return kind,owner
end
function R.new(adapters)
  local self={key=nil,owner=nil,adapter=nil,reason='not-selected'}
  function self:update(pipeline,owner,platform,standalone)
    local key,id=R.select(pipeline,owner,platform,standalone)
    if key==self.key and id==self.owner then return self.adapter end
    if self.adapter and self.adapter.detach then self.adapter:detach()end
    self.adapter=nil;self.key=key;self.owner=id
    local factory=adapters[key]
    if not factory then self.reason=key..'-renderer-unavailable';return nil end
    local ok,value=pcall(factory,id)
    if not ok or type(value)~='table' then self.reason='adapter-load-failed';return nil end
    self.adapter=value;self.reason=value.reason or 'selected'
    return value
  end
  function self:ready()
    return self.adapter and self.adapter.ready==true or false,(self.adapter and self.adapter.reason)or self.reason
  end
  return self
end
return R
