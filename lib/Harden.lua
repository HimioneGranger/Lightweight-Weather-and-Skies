-- Shared safety helpers for Weather FX.
-- Goal: one bad host/API/frame must never blank the mod menu or kill the game.

local V = ...
local H = {}

function H.num(v, fallback)
  v = tonumber(v)
  if not v or v ~= v then return fallback or 0 end
  return v
end

function H.clamp(v, lo, hi)
  v = H.num(v, lo)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function H.str(v, fallback)
  if v == nil then return fallback or "" end
  return tostring(v)
end

function H.tbl(v)
  return type(v) == "table" and v or nil
end

--- pcall with optional log; returns ok, ...
function H.call(label, fn, ...)
  if type(fn) ~= "function" then return false end
  local ok, a, b, c, d, e = pcall(fn, ...)
  if not ok then
    pcall(function()
      if V and V.mod and V.mod.log and V.mod.log.warn then
        V.mod.log:warn("wx harden[%s]: %s", tostring(label), tostring(a))
      end
    end)
    return false, a
  end
  return true, a, b, c, d, e
end

--- Require via V.require without throwing.
function H.require(name)
  if not V or not V.require then return nil end
  local ok, mod = pcall(V.require, name)
  if ok then return mod end
  return nil
end

--- Ensure a channel table has numeric keys for known list.
function H.zeroChannels(ch, keys)
  ch = H.tbl(ch) or {}
  if type(keys) == "table" then
    for i = 1, #keys do
      local k = keys[i]
      if type(ch[k]) ~= "number" or ch[k] ~= ch[k] then
        ch[k] = 0
      end
    end
  end
  return ch
end

return H
