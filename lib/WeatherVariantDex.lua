-- Cross-generation Pokédex entries for all Weather FX variant species.
-- Gen 1 resolves dexEntry.text through Data.text; Gen 2 uses a separate
-- gen2Pokedex.entries table.  This module supplies both without depending on
-- Kanto Reforged internals.

local D = ...
local mod = D.mod

local Dex = { prose = {}, keys = {} }
local COLS, MAX_LINES = 18, 6

local weatherLore = {
  ["Rain"]="rainwater", ["Heavy Rain"]="torrential rain", ["Storm"]="storm clouds",
  ["Thunderstorm"]="charged clouds", ["Snow"]="fresh snow", ["Hail"]="falling hail",
  ["Blizzard"]="blinding snow", ["Wind"]="swift winds", ["Sandstorm"]="drifting sand",
  ["Dust Storm"]="dense dust", ["Ashfall"]="warm ash", ["Heatwave"]="shimmering heat",
  ["Sunny"]="bright sunlight", ["Fog"]="thick fog", ["Moonlit Fog"]="moonlit mist",
  ["Smog"]="heavy smog", ["Acid Rain"]="stinging rain", ["Static Storm"]="static clouds",
  ["Flood"]="rising water", ["Typhoon"]="spiraling winds", ["Aurora"]="aurora light",
  ["Eclipse"]="eclipse shadows", ["Heat Haze"]="wavering heat",
  ["Spring Rain"]="gentle spring rain", ["Autumn Rain"]="cool autumn rain",
  ["Moonlit Rain"]="moonlit rain", ["Seasonal"]="changing seasons",
  ["Any seasonal weather"]="changing seasons", ["Any rare weather"]="unusual weather",
}

local actions = {
  "stores %s in its body and releases the energy when threatened.",
  "appears amid %s. Its changed form vanishes when the air settles.",
  "uses %s to sharpen its senses and protect its territory.",
  "draws strength from %s, leaving a strange trail wherever it roams.",
  "has adapted to %s. Its unusual markings glow before the weather changes.",
  "gathers near %s and quietly guides others of its kind to shelter.",
}

local function title(s)
  return (tostring(s or ""):lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

function Dex.key(id) return "_WX_" .. id .. "_DexEntry" end

function Dex.makeProse(row)
  local subject = title(row.variant) .. " " .. row.baseName
  local lore = weatherLore[row.weather] or tostring(row.weather):lower()
  return subject .. " " .. actions[((row.n - 1) % #actions) + 1]:format(lore)
end

local function softLines(text)
  local words, lines, line = {}, {}, ""
  for word in tostring(text or ""):gmatch("%S+") do words[#words + 1] = word end
  for _, word in ipairs(words) do
    if line == "" then line = word
    elseif #line + #word + 1 <= COLS then line = line .. " " .. word
    else
      lines[#lines + 1] = line
      if #lines >= MAX_LINES then line = ""; break end
      line = word
    end
  end
  if line ~= "" and #lines < MAX_LINES then lines[#lines + 1] = line end
  return lines
end

function Dex.wrapGen1(text)
  local lines = softLines(text)
  local out = {}
  for i, line in ipairs(lines) do
    out[#out + 1] = line
    if i < #lines then out[#out + 1] = (i % 3 == 0) and "\f" or "\n" end
  end
  return table.concat(out)
end

function Dex.wrapGen2(text)
  local lines = softLines(text)
  local a, b = {}, {}
  for i, line in ipairs(lines) do
    local page = i <= 3 and a or b
    page[#page + 1] = line
  end
  return table.concat(a, "<NEXT>"), table.concat(b, "<NEXT>")
end

local function liveData()
  local ok, Data = pcall(require, "src.core.Data")
  if ok and Data then return Data end
  return mod and mod.game and mod.game.data
end

function Dex.attach(row, clone)
  local inherited = clone.dexEntry or {}
  local prose, key = Dex.makeProse(row), Dex.key(row.id)
  clone.dexEntry = {
    kind = title(row.variant) .. " POKéMON",
    heightFt = inherited.heightFt or 0,
    heightIn = inherited.heightIn or 0,
    weight = inherited.weight or 0,
    text = key,
  }
  Dex.prose[row.id], Dex.keys[row.id] = prose, key
  local body = Dex.wrapGen1(prose)
  local registry = mod.content and mod.content.text
  if registry and type(registry.register) == "function" then
    pcall(function() registry:register(key, body) end)
  end
  local data = liveData()
  if data then data.text = data.text or {}; data.text[key] = body end
end

function Dex.bindLive(variants, registered)
  local data = liveData()
  if not data then return 0 end
  data.text = data.text or {}
  data.gen2Pokedex = data.gen2Pokedex or {}
  data.gen2Pokedex.entries = data.gen2Pokedex.entries or {}
  local count = 0
  for _, row in ipairs(variants or {}) do
    if registered[row.id] then
      local key, prose = Dex.keys[row.id], Dex.prose[row.id]
      data.text[key] = Dex.wrapGen1(prose)
      local species = data.pokemon and data.pokemon[row.id]
      local entry = species and species.dexEntry or {}
      local text, text2 = Dex.wrapGen2(prose)
      -- Prefer the real national number (baseDex) when the record is a
      -- weather form under national_dex. Synthetic form dex numbers
      -- (30000+) must never be shown as "No. XXXXX" on a dex page.
      local shownDex = (species and species.baseDex)
        or (species and type(species.dex) == "number" and species.dex < 20000 and species.dex)
        or 0
      data.gen2Pokedex.entries[row.id] = {
        id=row.id, dex=shownDex,
        kind=title(row.variant) .. " FORM",
        height=(entry.heightFt or 0) * 100 + (entry.heightIn or 0),
        weight=entry.weight or 0, text=text, text2=text2,
      }
      count = count + 1
    end
  end
  return count
end

return Dex
