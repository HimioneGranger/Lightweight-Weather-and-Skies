-- The World <-> Wilds of Kanto compatibility bridge.
-- v5.16.43: Wilds 2.1.9 deliberately maps species names only through Gen 2 in
-- species_assets.lua.  Its actual bundled follower sheets extend through dex
-- 649.  This bridge teaches Wilds to resolve every registered species by its
-- stable National Dex number, and exposes The World's WX follower art where
-- available.  No Wilds files are modified on disk.
local C={}

local function liveDexMap(mod)
  local out={}
  local function add(id,row)
    if type(id)~='string' or type(row)~='table' then return end
    local d=tonumber(row.dex or row.nationalDex or row.national_dex)
    if d then out[id:upper()]=math.floor(d) end
  end
  local ok,data=pcall(function() return require('mods.the_world.reforged.pokemon_data') end)
  if ok and type(data)=='table' then
    for id,row in pairs(type(data.species)=='table' and data.species or {}) do add(id,row) end
  end
  pcall(function()
    local Game=require('src.core.Game')
    for id,row in pairs(Game and Game.data and Game.data.pokemon or {}) do add(id,row) end
  end)
  pcall(function()
    local reg=mod.content and mod.content.pokemon
    if reg and type(reg.each)=='function' then for id,row in reg:each() do add(id,row) end end
  end)
  return out
end

local function copy(t) local o={}; for k,v in pairs(t or {}) do o[k]=v end; return o end

function C.install(mod)
 local patchedWilds=nil
 local function patch()
  local wilds
  if mod.find then pcall(function() wilds=mod:find('overworld_wild_spawns') end) end
  if not wilds or type(wilds.exports)~='table' then return false end
  local map=liveDexMap(mod)

  -- v5.16.57: expose The World's live encounter policy on the Wilds handle.
  -- Wilds builds visible entities independently of encounter.roll, so the
  -- presentation bridge needs the same generation/WX boundary as battles.
  wilds.exports.theWorldSpeciesAllowed=function(species)
    if type(mod.exports.worldSpeciesAllowed)=='function' then
      local ok,allowed=pcall(mod.exports.worldSpeciesAllowed,species)
      if ok then return allowed ~= false end
    end
    return true
  end
  wilds.exports.theWorldWxEnabled=function()
    local v=nil
    pcall(function() v=mod.save:get('world_wx_pokemon_enabled') end)
    if v~=nil then return v==true or v=='on' end
    pcall(function() v=mod.options:get('weatherVariants') end)
    return v==true or v=='on'
  end

  -- Patch Wilds' canonical asset resolver itself. This affects visible wild
  -- entities, followers, water sprites, previews and diagnostics, rather than
  -- only the public follower export. Wilds owns sheets through #649.
  local lib=wilds.exports.lib
  if lib and type(lib.require)=='function' then
    local ok,SA=pcall(function() return lib.require('species_assets') end)
    if ok and type(SA)=='table' and type(SA.idFor)=='function' and not SA._theWorldNationalDex then
      local orig=SA.idFor
      SA.idFor=function(species)
        local got=orig(species)
        if got then return got end
        if type(species)=='string' then
          local d=liveDexMap(mod)[species:upper()]
          if d and d>=1 and d<=649 then return d end
        end
        return nil
      end
      SA._theWorldNationalDex=true
    end
  end

  -- Public follower service: translate species keys to dex for Wilds 2.1.9.
  if type(wilds.exports.resolveFollowerSprite)=='function' and not wilds.exports._tw51642_dex then
   local orig=wilds.exports.resolveFollowerSprite; wilds.exports._tw51642_dex=true
   wilds.exports.resolveFollowerSprite=function(opts)
    opts=opts or {}; local cp=copy(opts)
    if type(cp.species)=='string' then cp.species=liveDexMap(mod)[cp.species:upper()] or cp.species end
    return orig(cp)
   end
  end
  local svc=rawget(_G,'_wildsSpriteService')
  if type(svc)=='table' and type(svc.resolveFollowerSprite)=='function' and not svc._tw51642_dex then
   local orig=svc.resolveFollowerSprite; svc._tw51642_dex=true
   svc.resolveFollowerSprite=function(self,opts)
    opts=opts or {}; local cp=copy(opts)
    if type(cp.species)=='string' then cp.species=liveDexMap(mod)[cp.species:upper()] or cp.species end
    return orig(self,cp)
   end
  end

  -- 5.18.2: let registered World sprite packs outrank Wilds' own lookup.
  -- If no pack resolves the species, Wilds continues untouched and therefore
  -- remains the default provider whenever it has suitable art.
  local render=wilds.exports.render
  if type(render)=='table' and type(render.applyProviderSprite)=='function' and not render._tw5182Providers then
    local orig=render.applyProviderSprite
    render.applyProviderSprite=function(self,entity,game,...)
      local species=entity and (entity.species or entity.speciesId)
      local resolver=mod.exports and mod.exports.resolveOverworldPokemonSprite
      if species and type(resolver)=='function' then
        local ok,def,provider,baseFallback=pcall(resolver,species,game,{entity=entity,source='wilds'})
        if ok and type(def)=='table' and def.image then
          entity.sprite=entity.sprite or {}; entity.sprite.def=def
          entity.spriteProviderMeta={provider=provider,theWorld=true,wxBaseFallback=baseFallback==true}
          return true
        end
      end
      local okNative,nativeApplied=pcall(orig,self,entity,game,...)
      if okNative and nativeApplied then return nativeApplied end

      -- 5.18.3: The World itself already ships registered battle art for
      -- Gen 2/3 species.  Wilds is optional, so a Gen 3 encounter must never
      -- become invisible merely because no follower pack is installed.  Use
      -- the species front art as a one-frame last-resort overworld card.  A
      -- real Wilds/provider sprite always wins above this fallback.
      local okData,data=pcall(function() return require('mods.the_world.reforged.pokemon_data') end)
      local row=okData and data and data.species and type(species)=='string' and data.species[species:upper()] or nil
      if type(row)=='table' and type(row.spriteFront)=='string' and row.spriteFront~='' then
        entity.sprite=entity.sprite or {}
        entity.sprite.def={
          id='the_world_fallback_'..species:lower(), image=row.spriteFront,
          frameWidth=tonumber(row.spriteWidth or row.frontWidth) or 48,
          frameHeight=tonumber(row.spriteHeight or row.frontHeight) or 48,
          frames=1, directions=1, trueColor=true,
          anchorX=0.5, anchorY=1.0,
        }
        entity.spriteProviderMeta={provider='the_world_battle_fallback',theWorld=true,fallbackUsed=true}
        return true
      end
      return okNative and nativeApplied or false
    end
    render._tw5182Providers=true
  end

  -- Refresh already spawned entities after installing the resolver so a save
  -- does not need to leave/re-enter the route to replace black placeholders.
  if type(wilds.exports.refreshAllEntitySprites)=='function' then
    pcall(wilds.exports.refreshAllEntitySprites, mod.activeGame or (mod.world and mod.world.game))
  end
  patchedWilds=wilds
  return true
 end
 patch()
 if mod.events and mod.events.on then
   for _,ev in ipairs({'mods.loaded','save.loaded','world.map_changed','map.changed'}) do
     pcall(function() mod.events:on(ev,function() pcall(patch) end,9999) end)
   end
 end
end
return C
