local V = ...
local Mat4 = {}

function Mat4.identity()
  return { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 }
end

function Mat4.translate(x, y, z)
  return { 1,0,0,x or 0, 0,1,0,y or 0, 0,0,1,z or 0, 0,0,0,1 }
end

function Mat4.scale(x, y, z)
  x, y, z = x or 1, y or 1, z or 1
  return { x,0,0,0, 0,y,0,0, 0,0,z,0, 0,0,0,1 }
end

function Mat4.rotateX(a)
  local c, s = math.cos(a), math.sin(a)
  return { 1,0,0,0, 0,c,-s,0, 0,s,c,0, 0,0,0,1 }
end

function Mat4.rotateY(a)
  local c, s = math.cos(a), math.sin(a)
  return { c,0,s,0, 0,1,0,0, -s,0,c,0, 0,0,0,1 }
end

function Mat4.mul(a, b)
  local r = {}
  for row = 0, 3 do
    for col = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s = s + a[row * 4 + k + 1] * b[k * 4 + col + 1]
      end
      r[row * 4 + col + 1] = s
    end
  end
  return r
end

function Mat4.lookAt(eye, center, up)
  local function sub(a, b) return { a[1]-b[1], a[2]-b[2], a[3]-b[3] } end
  local function cross(a, b)
    return { a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1] }
  end
  local function norm(v)
    local l = math.sqrt(v[1]*v[1]+v[2]*v[2]+v[3]*v[3])
    if l < 1e-9 then return {0,1,0} end
    return { v[1]/l, v[2]/l, v[3]/l }
  end
  local f = norm(sub(center, eye))
  local s = norm(cross(f, up))
  local u = cross(s, f)
  local m = {
    s[1], s[2], s[3], 0,
    u[1], u[2], u[3], 0,
   -f[1],-f[2],-f[3], 0,
    0,0,0,1,
  }
  return Mat4.mul(m, Mat4.translate(-eye[1], -eye[2], -eye[3]))
end

function Mat4.perspective(fovy, aspect, near, far)
  local t = math.tan((fovy or 60) * math.pi / 360)
  local ys = 1 / t
  local xs = ys / (aspect > 0 and aspect or 1)
  local nmf = near - far
  return {
    xs, 0, 0, 0,
    0, ys, 0, 0,
    0, 0, (far + near) / nmf, (2 * far * near) / nmf,
    0, 0, -1, 0,
  }
end

function Mat4.ortho(l, r, b, t, n, f)
  return {
    2/(r-l), 0, 0, -(r+l)/(r-l),
    0, 2/(t-b), 0, -(t+b)/(t-b),
    0, 0, -2/(f-n), -(f+n)/(f-n),
    0, 0, 0, 1,
  }
end

return Mat4
