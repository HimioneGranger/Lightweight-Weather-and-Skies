-- Holiday house gifts, based on Weather FX 4.3.1's calendar. The World
-- resolves every gift against the save's generation scope and WX setting.
local V = ...
local mod = V.mod
local Scene = V.require("Scene")

local Gifts = {}

local PRIMARY = {
  {month=12,day=25,form="WX_1001_MEW_PRIMALWEATHER",base="MEW",holiday="Christmas Day",g1="MEW",g2="MEW"},
  {month=2,day=14,form="WX_1002_RAYQUAZA_PRIMALWEATHER",base="RAYQUAZA",holiday="Valentine's Day",g1="MEW",g2="LUGIA"},
  {month=2,day=16,form="WX_1003_GROUDON_PRIMALWEATHER",base="GROUDON",holiday="Christopher's Birthday",g1="MOLTRES",g2="ENTEI"},
  {month=3,day=14,form="WX_1004_KYOGRE_PRIMALWEATHER",base="KYOGRE",holiday="Pi Day",g1="ARTICUNO",g2="SUICUNE"},
}

local SEEDED = {
  {month=1,day=1,form="WX_1005_ARTICUNO_PRIMALWEATHER",base="ARTICUNO",holiday="New Year's Day"},
  {month=2,day=14,form="WX_1006_ZAPDOS_PRIMALWEATHER",base="ZAPDOS",holiday="Valentine's Day"},
  {month=2,day=16,form="WX_1007_MOLTRES_PRIMALWEATHER",base="MOLTRES",holiday="Christopher's Birthday"},
  {month=3,day=17,form="WX_1008_MEWTWO_PRIMALWEATHER",base="MEWTWO",holiday="St. Patrick's Day"},
  {month=4,day=1,form="WX_1009_RAIKOU_PRIMALWEATHER",base="RAIKOU",holiday="April Fools' Day",g1="ZAPDOS"},
  {month=5,day=1,form="WX_1010_ENTEI_PRIMALWEATHER",base="ENTEI",holiday="May Day",g1="MOLTRES"},
  {month=6,day=21,form="WX_1011_SUICUNE_PRIMALWEATHER",base="SUICUNE",holiday="June Solstice",g1="ARTICUNO"},
  {month=7,day=4,form="WX_1012_HO_OH_PRIMALWEATHER",base="HO_OH",holiday="Independence Day",g1="MOLTRES"},
  {month=8,day=15,form="WX_1013_LUGIA_PRIMALWEATHER",base="LUGIA",holiday="Mid-August Holiday",g1="ARTICUNO"},
  {month=9,day=22,form="WX_1014_CELEBI_PRIMALWEATHER",base="CELEBI",holiday="September Equinox",g1="MEW"},
  {month=10,day=31,form="WX_1015_REGICE_PRIMALWEATHER",base="REGICE",holiday="Halloween",g1="ARTICUNO",g2="SUICUNE"},
  {month=11,day=5,form="WX_1016_REGIROCK_PRIMALWEATHER",base="REGIROCK",holiday="Guy Fawkes Night",g1="MOLTRES",g2="ENTEI"},
  {month=11,day=11,form="WX_1017_REGISTEEL_PRIMALWEATHER",base="REGISTEEL",holiday="Armistice Day",g1="MEWTWO",g2="RAIKOU"},
  {month=12,day=21,form="WX_1018_LATIOS_PRIMALWEATHER",base="LATIOS",holiday="December Solstice",g1="MEWTWO",g2="LUGIA"},
  {month=12,day=24,form="WX_1019_LATIAS_PRIMALWEATHER",base="LATIAS",holiday="Christmas Eve",g1="MEW",g2="HO_OH"},
  {month=12,day=31,form="WX_1020_JIRACHI_PRIMALWEATHER",base="JIRACHI",holiday="New Year's Eve",g1="MEW",g2="CELEBI"},
  {month=2,day=16,form="WX_1021_DEOXYS_PRIMALWEATHER",base="DEOXYS",holiday="Christopher's Birthday",g1="MEWTWO",g2="MEWTWO"},
}

local PRIMAL_BY_BASE = {}
for _, gift in ipairs(PRIMARY) do PRIMAL_BY_BASE[gift.base] = gift.form end
for _, gift in ipairs(SEEDED) do PRIMAL_BY_BASE[gift.base] = gift.form end

local BASE_GENERATION = {
  MEW=1, ARTICUNO=1, ZAPDOS=1, MOLTRES=1, MEWTWO=1,
  RAIKOU=2, ENTEI=2, SUICUNE=2, HO_OH=2, LUGIA=2, CELEBI=2,
  RAYQUAZA=3, GROUDON=3, KYOGRE=3, REGICE=3, REGIROCK=3,
  REGISTEEL=3, LATIOS=3, LATIAS=3, JIRACHI=3, DEOXYS=3,
}

local function saved(key, fallback)
  if mod.save then
    local ok, value = pcall(function() return mod.save:get(key) end)
    if ok and value ~= nil then return value end
  end
  return fallback
end

local function scope()
  local value = saved("world_content_scope", nil)
  if value == nil and mod.options then
    pcall(function() value = mod.options:get("worldContentScope") end)
  end
  if value == "gen1" or value == "gen1_gen2" then return value end
  return "gen1_gen2_gen3"
end

local function wxEnabled()
  local value = saved("world_wx_pokemon_enabled", nil)
  if value == nil and mod.options then
    pcall(function() value = mod.options:get("weatherVariants") end)
  end
  if value == nil then return true end
  return value == true or value == "on"
end

local currentGame
local function gameNow()
  return currentGame or mod.activeGame
end

local function speciesExists(game, species)
  return game and game.data and game.data.pokemon
    and type(game.data.pokemon[species]) == "table"
end

local function resolveGift(game, gift)
  local selectedScope = scope()
  local base = gift.base
  local generation = BASE_GENERATION[gift.base] or 3
  if selectedScope == "gen1" and generation > 1 then
    base = gift.g1 or gift.base
  elseif selectedScope == "gen1_gen2" and generation > 2 then
    base = gift.g2 or gift.g1 or gift.base
  end
  if not speciesExists(game, base) then
    base = selectedScope == "gen1" and "MEW"
      or selectedScope == "gen1_gen2" and "CELEBI" or gift.base
  end

  local species = base
  local primal = false
  local form = PRIMAL_BY_BASE[base]
  if wxEnabled() and form and speciesExists(game, form) then
    species, primal = form, true
  end
  return species, base, primal, selectedScope
end

local HOUSE_MAPS = {
  REDS_HOUSE_1F=true, REDS_HOUSE_2F=true,
  PLAYERS_HOUSE_1F=true, PLAYERS_HOUSE_2F=true,
  KRIS_HOUSE_1F=true, KRIS_HOUSE_2F=true,
  J2_PLAYERS_HOUSE_1F=true, J2_PLAYERS_HOUSE_2F=true,
  JOHTO_NEW_BARK_HOME_A=true, JOHTO_NEW_BARK_HOME_UP=true,
  SEVII_ONE_ISLAND_PLAYER_HOME_1F=true, SEVII_ONE_ISLAND_PLAYER_HOME_2F=true,
  ALMIA_CHICOLE_VILLAGE_HOUSE_A=true, ALMIA_CHICOLE_VILLAGE_HOUSE_A_2F=true,
  SINNOH_TWINLEAF_TOWN_HOUSE_A=true, SINNOH_TWINLEAF_TOWN_HOUSE_A_2F=true,
  HOENN_LITTLEROOT_TOWN_HOUSE_A=true, HOENN_LITTLEROOT_TOWN_HOUSE_A_2F=true,
}

local function houseMap(mapId)
  if not mapId then return false end
  local id = tostring(mapId):upper():gsub("-", "_"):gsub(" ", "_")
  return HOUSE_MAPS[id] == true
end

local function today()
  local ok, date = pcall(os.date, "*t")
  if not ok or type(date) ~= "table" then return nil end
  return tonumber(date.year), tonumber(date.month), tonumber(date.day)
end

local function claims(game)
  local save = game and game.save
  if not save then return nil end
  save.theWorldHolidayGifts = save.theWorldHolidayGifts or {}
  return save.theWorldHolidayGifts
end

local function claimKey(gift, year)
  return string.format("%02d-%02d:%s:%d", gift.month, gift.day, gift.form, year)
end

local function pending(game, year, month, day)
  local flags = claims(game)
  if not flags then return nil end
  for _, list in ipairs({PRIMARY, SEEDED}) do
    for _, gift in ipairs(list) do
      if gift.month == month and gift.day == day
          and not flags[claimKey(gift, year)] then
        return gift
      end
    end
  end
end

local function makePokemon(game, species, level)
  local mon
  local ok, Pokemon = pcall(require, "src.pokemon.Pokemon")
  if ok and Pokemon and type(Pokemon.new) == "function" then
    local attempts = {
      function() return Pokemon.new(game.data, species, level) end,
      function() return Pokemon.new(game.data.pokemon[species], level) end,
      function() return Pokemon.new(species, level) end,
    }
    for _, create in ipairs(attempts) do
      local made, candidate = pcall(create)
      if made and type(candidate) == "table" then mon = candidate; break end
    end
  end
  if not mon then
    local gen2ok, Gen2Mon = pcall(require, "src.battle.gen2.Mon")
    if gen2ok and Gen2Mon and type(Gen2Mon.new) == "function" then
      local made, candidate = pcall(Gen2Mon.new, game.data, species, level)
      if made and type(candidate) == "table" then mon = candidate end
    end
  end
  return mon
end

local function makePerfectShiny(mon, game, species, level)
  mon.dvs = {attack=15, defense=15, speed=15, special=15, hp=15}
  mon.shiny = true
  local ok, Stats = pcall(require, "src.pokemon.Stats")
  if not ok or not Stats or type(Stats.calc) ~= "function" then return end
  local def = game.data.pokemon[species]
  for _, calc in ipairs({
    function() return Stats.calc(def, level, mon.dvs, mon.statExp) end,
    function() return Stats.calc(game.data, species, level, mon.dvs, mon.statExp) end,
  }) do
    local made, stats = pcall(calc)
    if made and type(stats) == "table" and stats.hp then
      mon.stats, mon.hp = stats, stats.hp
      return
    end
  end
end

local function placePokemon(game, mon)
  local ok, Party = pcall(require, "src.pokemon.Party")
  if ok and Party and type(Party.add) == "function"
      and Party.add(game.save.party, mon) then
    return "party"
  end
  local boxOk, Boxes = pcall(require, "src.pokemon.Boxes")
  if boxOk and Boxes and type(Boxes.deposit) == "function" then
    local deposited, box = pcall(Boxes.deposit, game.save, mon)
    if deposited and box then return "PC" end
  end
  return nil
end

local function show(game, text)
  if not (game and game.stack and game.stack.push) then return end
  local ok, TextBox = pcall(require, "src.render.TextBox")
  if not ok or not TextBox or type(TextBox.new) ~= "function" then return end
  local made, box = pcall(TextBox.new, game, text)
  if made and box then game.stack:push(box) end
end

local lastMap, lastDay
local handledVisit = false

local function deliver(game, gift, year)
  local species, base, primal, selectedScope = resolveGift(game, gift)
  if not speciesExists(game, species) then
    return false, "The holiday parcel is delayed.\nIts Pokemon record is not ready."
  end

  local mon = makePokemon(game, species, 50)
  if not mon then
    mod.log:warn("holiday gift: could not construct %s", tostring(species))
    return false, "The holiday parcel could not\nbe prepared. Please try again."
  end
  mon.immuneToWeather = primal or mon.immuneToWeather
  mon.ot = mon.ot or "PRIMAL MAN"
  if selectedScope == "gen1" then makePerfectShiny(mon, game, species, 50) end

  local destination = placePokemon(game, mon)
  local def = game.data.pokemon[species] or game.data.pokemon[base] or {}
  local name = def.name or base
  if not destination then
    return false, "Your party and PC are full!\nMake room, then speak to me again."
  end

  claims(game)[claimKey(gift, year)] = true
  local quality = selectedScope == "gen1" and "\nIt's shiny with max DVs!" or ""
  mod.log:info("holiday gift: gave %s for %s (%s)", species, gift.holiday, destination)
  return true, string.format("A holiday gift arrived\nfor %s!\fReceived %s!%s\nSent to the %s.",
    gift.holiday, name, quality, destination)
end

function Gifts.claimToday(game)
  game = game or gameNow()
  if not (game and game.save and type(game.save.party) == "table") then
    return false, "I cannot reach your delivery\nrecord yet. Please try again."
  end
  if #game.save.party == 0 then
    return false, "Begin your journey with a\nstarter, then I can deliver gifts."
  end
  local year, month, day = today()
  if not year then return false, "The calendar is unavailable.\nPlease try again later." end
  local gift = pending(game, year, month, day)
  if not gift then
    return false, "No holiday parcel is due today.\nCome home on a special date!"
  end
  return deliver(game, gift, year)
end

function Gifts.update()
  local game = gameNow()
  if not (game and game.save and type(game.save.party) == "table") then return end
  -- Do not alter the new-game/Oak starter flow. The gift waits until the
  -- player has a Pokémon and next enters their house.
  if #game.save.party == 0 then return end

  local mapId = Scene and Scene.now and Scene.now.mapId
  if not mapId and game.overworld and game.overworld.map then
    mapId = game.overworld.map.id
  end
  if not houseMap(mapId) then
    handledVisit, lastMap = false, mapId
    return
  end
  -- Current World builds place a visible delivery man in every regional home.
  -- Suppress automatic entry delivery only on a map where that NPC actually
  -- installed; other/modified homes retain the legacy compatibility fallback.
  local giftHomes = mod.exports and mod.exports.theWorldHolidayGiftHomes
  local normalizedMap = tostring(mapId or ""):upper():gsub("-", "_"):gsub(" ", "_")
  if type(giftHomes) == "table" and giftHomes[normalizedMap] then return end

  local year, month, day = today()
  if not year then return end
  local dayKey = year * 10000 + month * 100 + day
  if lastMap ~= mapId or lastDay ~= dayKey then
    handledVisit, lastMap, lastDay = false, mapId, dayKey
  end
  if handledVisit then return end

  local gift = pending(game, year, month, day)
  if not gift then return end
  handledVisit = true
  local _, message = deliver(game, gift, year)
  show(game, message)
end

function Gifts.install()
  local function capture(ev)
    if ev and ev.game then currentGame, mod.activeGame = ev.game, ev.game end
  end
  pcall(function()
    if mod.hooks and mod.hooks.on then
      mod.hooks:on("game.ready", capture)
      mod.hooks:on("game.start", capture)
      mod.hooks:on("save.loaded", capture)
    end
  end)
  pcall(function()
    if mod.events and mod.events.on then
      mod.events:on("game.ready", capture)
      mod.events:on("save.loaded", capture)
    end
  end)
end

Gifts.PRIMARY = PRIMARY
Gifts.SEEDED = SEEDED
Gifts.resolveGift = resolveGift

return Gifts
