-- Gen 3 CPU/allocation adapter. The shared catalog, per-eye sphere build,
-- projection, fades and shader remain NightSky's original implementation.
-- Scratch axes are consumed immediately by pushQuad; never export them as
-- permanent directions or reuse completed first-eye vertices in another eye.
local M = {}
local pool = {}
local right, up = { 0, 0, 0 }, { 0, 0, 0 }

function M.tangentAxes(dx, dy, dz)
  local len = math.sqrt(dx * dx + dz * dz)
  local rx, rz = 1, 0
  if len > 1e-6 then rx, rz = -dz / len, dx / len end
  right[1], right[2], right[3] = rx, 0, rz
  up[1], up[2], up[3] = dy * rz, dz * rx - dx * rz, -dy * rx
  return right, up
end

local function corner(verts, n, cx, cy, cz, ox, oy, oz, r, g, b, a, u, vCoord)
  local v = pool[n]
  if not v then v = {}; pool[n] = v end
  v[1], v[2], v[3] = cx + ox, cy + oy, cz + oz
  v[4], v[5], v[6], v[7] = r, g, b, a
  v[8], v[9] = u, vCoord
  verts[n] = v
end

function M.pushQuad(verts, n, cx, cy, cz, half, axisR, axisU, r, g, b, a)
  local hx, hy, hz = axisR[1] * half, axisR[2] * half, axisR[3] * half
  local vx, vy, vz = axisU[1] * half, axisU[2] * half, axisU[3] * half
  corner(verts, n + 1, cx, cy, cz, -hx - vx, -hy - vy, -hz - vz, r, g, b, a, 0, 0)
  corner(verts, n + 2, cx, cy, cz,  hx - vx,  hy - vy,  hz - vz, r, g, b, a, 1, 0)
  corner(verts, n + 3, cx, cy, cz,  hx + vx,  hy + vy,  hz + vz, r, g, b, a, 1, 1)
  corner(verts, n + 4, cx, cy, cz, -hx - vx, -hy - vy, -hz - vz, r, g, b, a, 0, 0)
  corner(verts, n + 5, cx, cy, cz,  hx + vx,  hy + vy,  hz + vz, r, g, b, a, 1, 1)
  corner(verts, n + 6, cx, cy, cz, -hx + vx, -hy + vy, -hz + vz, r, g, b, a, 0, 1)
  return n + 6
end
return M
