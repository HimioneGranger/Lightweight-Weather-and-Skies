-- Low-detail 3D continuation terrain beyond the loaded maps.
--
-- DistantWorld is intentionally a far-horizon painter.  This module fills the
-- missing middle distance: a non-playable land apron that begins just under the
-- live map, continues beyond its hard geometry edge, inherits the same globe
-- curvature, and gradually rolls/hazes into the distant hills.  It exists only
-- to make the world LOOK continuous; it has no collision or gameplay state.
--
-- Drawn in Voxel3D.beginScene after the sky/DistantWorld and before the real
-- terrain.  It writes depth, but sits fractionally below y=0, so the real map
-- always paints over it while empty space beyond a loaded boundary is filled.

local V = ...

local HorizonApron = {}

local GRID_HALF = 3072       -- world pixels either side of the camera anchor
local GRID_STEP = 128        -- deliberately coarse: this is distant terrain
local ANCHOR_STEP = 256      -- apron follows the camera only in hidden chunks

local mesh = nil
local shader = nil
local available = nil

local VERTEX = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
}

local SHADER = [[
  varying vec3 vLandColor;

#ifdef VERTEX
  uniform mat4 vp;
  uniform vec2 anchor;
  uniform vec4 bounds;       // minX, minZ, maxX, maxZ of loaded map group
  uniform vec3 curve;        // focus XZ, curvature k
  uniform vec3 eye;
  uniform vec3 nearColor;
  uniform vec3 farColor;

  float hashHill(vec2 p) {
    return sin(p.x * 0.0061 + p.y * 0.0027) * 0.48
         + sin(p.x * 0.0023 - p.y * 0.0054 + 1.7) * 0.34
         + cos((p.x + p.y) * 0.00155 - 0.9) * 0.18;
  }

  float outsideRun(vec2 p) {
    vec2 d = max(max(bounds.xy - p, vec2(0.0)), p - bounds.zw);
    return length(d);
  }

  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 w = vertex_position;
    w.xz += anchor;

    // Exactly at the loaded map rim the continuation sits less than one world
    // pixel below the real ground.  From there it develops broad, very low
    // rolling relief before gradually settling away into the far landscape.
    float d = outsideRun(w.xz);
    float leave = smoothstep(20.0, 150.0, d);
    float farRun = smoothstep(260.0, 1900.0, d);
    float n = hashHill(w.xz);
    float rolling = leave * (2.3 + n * 4.4);
    float settle = farRun * (7.0 + 8.0 * (0.5 + 0.5 * n));
    w.y = -0.72 + rolling - settle;

    // Same Animal-Crossing/globe bend as the real voxel map.  This is the
    // crucial join: the continuation rolls over the SAME horizon instead of
    // remaining a flat background visible under the map.
    if (curve.z > 0.0) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }

    // Atmospheric perspective is based on actual camera distance, not screen
    // height.  By the time this reaches the painted mountains it is already
    // close to their haze colour, hiding the handoff between the two systems.
    float run = length(w.xz - eye.xz);
    float haze = smoothstep(420.0, 2100.0, run);
    haze = max(haze, smoothstep(500.0, 2100.0, d) * 0.72);
    vLandColor = mix(nearColor, farColor, clamp(haze, 0.0, 1.0));
    return vp * w;
  }
#endif

#ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    return vec4(vLandColor, 1.0) * color;
  }
#endif
]]

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function mix(a, b, t)
  return a + (b - a) * t
end

local function mix3(a, b, t)
  return {
    clamp01(mix(a[1], b[1], t)),
    clamp01(mix(a[2], b[2], t)),
    clamp01(mix(a[3], b[3], t)),
  }
end

local function buildMesh()
  if mesh ~= nil then return mesh or nil end
  if not (love and love.graphics and love.graphics.newMesh) then
    mesh = false
    return nil
  end

  local verts, indices = {}, {}
  local n = math.floor((GRID_HALF * 2) / GRID_STEP) + 1
  for iz = 0, n - 1 do
    local z = -GRID_HALF + iz * GRID_STEP
    for ix = 0, n - 1 do
      local x = -GRID_HALF + ix * GRID_STEP
      verts[#verts + 1] = { x, 0, z, 0, 0 }
    end
  end
  local function idx(ix, iz) return iz * n + ix + 1 end
  for iz = 0, n - 2 do
    for ix = 0, n - 2 do
      local a, b = idx(ix, iz), idx(ix + 1, iz)
      local c, d = idx(ix + 1, iz + 1), idx(ix, iz + 1)
      indices[#indices + 1] = a
      indices[#indices + 1] = b
      indices[#indices + 1] = c
      indices[#indices + 1] = a
      indices[#indices + 1] = c
      indices[#indices + 1] = d
    end
  end

  local ok, m = pcall(love.graphics.newMesh, VERTEX, verts, "triangles", "static")
  if ok and m then
    pcall(m.setVertexMap, m, indices)
    mesh = m
  else
    mesh = false
  end
  return mesh or nil
end

local function getShader()
  if shader ~= nil then return shader or nil end
  if not (love and love.graphics and love.graphics.newShader) then
    shader = false
    return nil
  end
  local ok, s = pcall(love.graphics.newShader, SHADER)
  shader = (ok and s) or false
  return shader or nil
end

function HorizonApron.ready()
  if available ~= nil then return available end
  available = buildMesh() ~= nil and getShader() ~= nil
  return available
end

-- `frame` is supplied by VoxelScene and describes the union of the loaded
-- current map + neighbours.  `sky` is the already weather/day-night-adjusted
-- sky palette for this frame.
function HorizonApron.draw(frame, vp, eye, curve, sky, cx, cy)
  if not (frame and frame.bounds and vp and eye and sky and HorizonApron.ready()) then
    return false
  end
  local g = love.graphics
  local m, sh = buildMesh(), getShader()
  if not (g and m and sh) then return false end

  local b = frame.bounds
  local anchorX = math.floor((cx or 0) / ANCHOR_STEP + 0.5) * ANCHOR_STEP
  local anchorZ = math.floor((cy or 0) / ANCHOR_STEP + 0.5) * ANCHOR_STEP

  local bands = sky.bands or {}
  local haze = bands[#bands] or { sky[1] or 0.55, sky[2] or 0.70, sky[3] or 0.82 }
  -- Near continuation is deliberately muted Kanto green, then converges on
  -- the current weather's horizon colour.  Day/night colour is already baked
  -- into `sky`, so storms and sunset naturally pull the apron with them.
  local near = mix3({ 0.20, 0.38, 0.17 }, haze, 0.24)
  local far = mix3({ 0.16, 0.29, 0.18 }, haze, 0.74)

  g.setDepthMode("lequal", true)
  g.setMeshCullMode("none")
  g.setShader(sh)
  g.setColor(1, 1, 1, 1)
  pcall(sh.send, sh, "vp", "row", vp)
  pcall(sh.send, sh, "anchor", { anchorX, anchorZ })
  pcall(sh.send, sh, "bounds", { b[1], b[2], b[3], b[4] })
  pcall(sh.send, sh, "curve", curve or { cx or 0, cy or 0, 0 })
  pcall(sh.send, sh, "eye", eye)
  pcall(sh.send, sh, "nearColor", near)
  pcall(sh.send, sh, "farColor", far)
  local ok = pcall(g.draw, m)
  g.setShader()
  g.setColor(1, 1, 1, 1)
  return ok
end

function HorizonApron.release()
  if mesh and mesh.release then pcall(mesh.release, mesh) end
  if shader and shader.release then pcall(shader.release, shader) end
  mesh, shader, available = nil, nil, nil
end

return HorizonApron
