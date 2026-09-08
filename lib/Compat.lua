-- Weather FX peer-mod compatibility. Never edits other mods.

local V = ...
local mod = V.mod

local Compat = {}

Compat._anime = nil

local ANIME_IDS = { "anime_realism", "Anime_Realism", "ANIME_REALISM" }

function Compat.refresh()
  Compat._anime = false
  if not (mod and mod.find) then return false end
  for i = 1, #ANIME_IDS do
    local ok, found = pcall(function() return mod.find(ANIME_IDS[i]) end)
    if ok and found then
      Compat._anime = true
      break
    end
  end
  return Compat._anime
end

function Compat.hasAnimeRealism()
  if Compat._anime == nil then Compat.refresh() end
  return Compat._anime == true
end

function Compat.battleProfile()
  if not Compat.hasAnimeRealism() then
    return {
      anime = false,
      weatherUnderUI = false,
      particleScale = 1.0,
      announceShort = false,
      skipFieldArtHijack = false,
    }
  end
  return {
    anime = true,
    weatherUnderUI = true,
    particleScale = 0.55,
    announceShort = true,
    skipFieldArtHijack = true,
  }
end

function Compat.describe()
  local p = Compat.battleProfile()
  if not p.anime then return "compat: anime_realism=off" end
  return string.format(
    "compat: anime_realism=on underUI=%s particles=%.2f shortAnnounce=%s noFieldArtHijack=%s",
    tostring(p.weatherUnderUI), p.particleScale, tostring(p.announceShort), tostring(p.skipFieldArtHijack))
end

return Compat
