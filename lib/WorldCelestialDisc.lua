-- Exact disc painter from authorized The World 6.70.27 weather_main.lua.
-- Quest adapts its output to a world-space texture; artwork math is unchanged.
local hostLove = love
local V=...
local love = hostLove

local function wxPaintCelestialDisc(body, edge, cell, w, h)
  if not (body and body.x and body.y and love and love.graphics) then return end
  local g = love.graphics
  cell = math.max(1, tonumber(cell) or 4)
  edge = tonumber(edge) or h
  local moon = body.moon and true or false
  -- Moon: cool grey pixel blocks only (no orange/warm rim).
  -- Sun: warm cells, glow only for sun and never at night (caller zeros glowAmt).
  local shades
  if moon then
    -- White moon with grey spots (no warm/orange tint).
    shades = {
      { 255, 255, 255 },  -- core white
      { 230, 232, 236 },  -- mid
      { 160, 164, 172 },  -- crater spots
      { 200, 204, 210 },  -- edge grain
    }
  else
    shades = {
      { 248, 240, 200 },
      { 248, 208, 96 },
      { 248, 144, 80 },
      { 200, 120, 48 },
    }
  end
  local DISC_FRAC, DISC_MIN = 0.028, 3
  local rCells = math.max(DISC_MIN, math.floor(h * DISC_FRAC / cell + 0.5))
  -- Never grow the disc for moon; never use glowAmt on moon (orange ring source).
  if (not moon) and (body.glowAmt or 0) > 0.25 then
    rCells = rCells + math.max(1, math.floor(rCells * 0.35))
  end
  local bx = math.floor(body.x / cell) * cell + cell / 2
  local by = math.floor(body.y / cell) * cell + cell / 2
  -- Keep disc on sky plate (never cull just because of edge math).
  if by < 0 then by = rCells * cell end
  if by > edge * 0.9 then by = edge * 0.85 end
  local sx, sy, sw, sh
  pcall(function()
    if g.getScissor then sx, sy, sw, sh = g.getScissor() end
    if g.setScissor then g.setScissor(0, 0, math.ceil(w), math.floor(edge)) end
  end)
  -- Alpha blend only — no additive halo that reads as an orange ring.
  pcall(g.setBlendMode, "alpha", "alphamultiply")
  local craterR = math.max(1, math.floor(rCells / 5))
  local MOON_CRATERS = { {-0.4,-0.2},{0.2,0.45},{0.5,-0.4},{-0.15,0.7},{0.05,0.05} }
  for dy = -rCells, rCells do
    for dx = -rCells, rCells do
      local d = math.sqrt(dx * dx + dy * dy)
      if d <= rCells + 0.05 then
        local c
        if d <= rCells * 0.45 then
          c = shades[1]
        elseif d <= rCells * 0.85 then
          c = shades[2]
        else
          -- Jagged pixel edge (checker) — grainy, not smooth rim
          if ((dx + dy) % 2) ~= 0 then
            c = shades[4]
          else
            c = shades[2]
          end
        end
        if moon then
          for _, cr in ipairs(MOON_CRATERS) do
            local cdx = dx - math.floor(cr[1] * rCells + 0.5)
            local cdy = dy - math.floor(cr[2] * rCells + 0.5)
            if cdx * cdx + cdy * cdy <= craterR * craterR then c = shades[3] end
          end
        end
        -- Drop some edge pixels for a more pixelated silhouette
        local keep = d <= rCells - 0.85 or ((dx * 3 + dy * 5) % 4) ~= 0
        if keep then
          pcall(g.setColor, c[1]/255, c[2]/255, c[3]/255, 1)
          pcall(g.rectangle, "fill", bx + dx * cell - cell/2, by + dy * cell - cell/2, cell, cell)
        end
      end
    end
  end
  pcall(g.setColor, 1, 1, 1, 1)
  pcall(function()
    if g.setScissor then
      if sx then g.setScissor(sx, sy, sw, sh) else g.setScissor() end
    end
  end)
end

local Disc = { source = "The World 6.70.27 weather_main.lua::wxPaintCelestialDisc" }
local images, meshes = {}, {}
local shader
local FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
}
local SHADER = [[
#ifdef VERTEX
uniform mat4 vp;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  return vp * vertex_position;
}
#endif
#ifdef PIXEL
uniform bool isMoon;
uniform vec3 moonLight;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  vec4 texelColor = Texel(tex, tc) * color;
  if (texelColor.a < 0.01) discard;
  if (isMoon) {
    vec2 p=tc*2.0-1.0;
    vec3 n=vec3(p.x,-p.y,sqrt(max(0.0,1.0-dot(p,p))));
    float lit=smoothstep(-0.035,0.08,dot(n,moonLight));
    float face=max(0.0,dot(n,moonLight));
    // Keep the unlit face subtle, especially at new moon.
    float earthshine=0.08*(0.55+0.45*n.z);
    texelColor.rgb*=mix(vec3(0.055,0.065,0.085),vec3(0.65+0.35*sqrt(face)),lit);
    texelColor.a*=mix(earthshine,1.0,lit);
  }
  return texelColor;
}
#endif
]]

-- Record the upstream painter's exact pixel cells into ImageData once.
-- Baking never binds/clears a Canvas inside an active stereo eye.
function Disc.image(moon)
  local key = moon and "moon" or "sun"
  if images[key] then return images[key] end
  if moon then
    local texture=hostLove.graphics.newImage(V.require('QuestMoon').imageData(hostLove.image))
    texture:setFilter('linear','linear');texture:setWrap('clamp','clamp')
    images[key]=texture;return texture
  end
  local radius, size = 16, 33
  local data = hostLove.image.newImageData(size, size)
  local red, green, blue, opacity = 1, 1, 1, 1
  local recorder = {
    getScissor = function() return nil end,
    setScissor = function() end,
    setBlendMode = function() end,
    setColor = function(r, g, b, a)
      red, green, blue, opacity = r, g, b, a
    end,
    rectangle = function(_, x, y, width, height)
      for py = math.max(0, math.floor(y)), math.min(size - 1, math.ceil(y + height) - 1) do
        for px = math.max(0, math.floor(x)), math.min(size - 1, math.ceil(x + width) - 1) do
          data:setPixel(px, py, red, green, blue, opacity)
        end
      end
    end,
  }
  love = { graphics = recorder }
  local ok, err = pcall(wxPaintCelestialDisc, {
    x = radius + 0.5, y = radius + 0.5, moon = moon, glowAmt = 0,
  }, size, 1, size, radius / 0.028)
  love = hostLove
  if not ok then error(err) end
  local texture = hostLove.graphics.newImage(data)
  texture:setFilter("nearest", "nearest")
  texture:setWrap("clamp", "clamp")
  images[key] = texture
  return texture
end

-- Body orientation belongs to the celestial sphere, not to the camera.
-- North supplies a stable texture-up tangent to the World east/zenith/west
-- orbit. Looking around changes the view matrix, never the disc vertices.
function Disc.axes(body)
  local x,y,z = body.dx,body.dy,body.dz
  local length = math.sqrt(x*x+y*y+z*z)
  x,y,z = x/length,y/length,z/length
  local rx,ry,rz = y,-x,0 -- north (0,0,-1) cross normal
  local size = math.sqrt(rx*rx+ry*ry)
  if size < 0.000001 then rx,ry,rz,size = z,0,-x,1 end
  rx,ry,rz = rx/size,ry/size,rz/size
  return {rx,ry,rz}, {y*rz-z*ry,z*rx-x*rz,x*ry-y*rx}
end

function Disc.draw(voxel, bodies, _cameraR, _cameraU, radius)
  local g = hostLove.graphics
  shader = shader or g.newShader(SHADER)
  local pushed = false
  local ok, result = pcall(function()
    -- Allocate before binding a shader; texture uploads must not disturb the
    -- pass's first draw or the host's canvas attachment.
    local sunImage = Disc.image(false)
    local moonImage = Disc.image(true)
    g.push("all")
    pushed = true
    g.setShader(shader)
    shader:send("vp", "row", voxel.vp)
    g.setDepthMode("lequal", false)
    g.setBlendMode("alpha", "alphamultiply")
    g.setMeshCullMode("none")
    local count = 0
    for _, body in ipairs({ bodies.sun, bodies.moon }) do
      if body and (body.alpha or 0) > 0.02 then
        local axisR,axisU = Disc.axes(body)
        local key = body.kind == "moon" and "moon" or "sun"
        local half = (key == "moon" and 10.5 or 22)
          * (1 + (key == "moon" and 0.10 or 0.35)
            * math.max(0, math.min(1, body.dy or 0)))
        local origin = voxel.eye
        local x = origin[1] + body.dx * radius
        local y = origin[2] + body.dy * radius
        local z = origin[3] + body.dz * radius
        local function vertex(rx, uy, u, v)
          return { x + half * (axisR[1] * rx + axisU[1] * uy),
            y + half * (axisR[2] * rx + axisU[2] * uy),
            z + half * (axisR[3] * rx + axisU[3] * uy), u, v }
        end
        local verts = {
          vertex(-1, 1, 0, 0), vertex(1, 1, 1, 0), vertex(1, -1, 1, 1),
          vertex(-1, 1, 0, 0), vertex(1, -1, 1, 1), vertex(-1, -1, 0, 1),
        }
        local mesh = meshes[key]
        if not mesh then
          mesh = g.newMesh(FORMAT, verts, "triangles", "stream")
          meshes[key] = mesh
        else
          mesh:setVertices(verts)
        end
        mesh:setTexture(key == "moon" and moonImage or sunImage)
        shader:send('isMoon',key=='moon')
        shader:send('moonLight',V.require('QuestMoon').current())
        g.setColor(1, 1, 1, body.alpha)
        g.draw(mesh)
        count = count + 1
      end
    end
    return count > 0
  end)
  if pushed then g.pop() end
  if not ok then error(result) end
  return result
end

return Disc
