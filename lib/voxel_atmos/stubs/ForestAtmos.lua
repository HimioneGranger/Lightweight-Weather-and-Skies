-- Minimal ForestAtmos stand-in so CinematicAtmos can run on Dramaless/Potato.
--
-- IMPORTANT: ForestAtmos.time is a continuous *animation* clock used by cloud
-- wind advection, rain phase, motes and ray shimmer. It must NOT be snapped
-- to DayNight.time() — that value is a calendar/TOD position and only advances
-- in coarse steps (or when the player pins dawn/day/dusk). Snapping it made
-- clouds jump forward every TOD tick and looked laggy/stuttery.
--
-- DayNight is still used elsewhere (ray shear, body disc, tints) via its own
-- module. Color ramps below are neutral daylight defaults for hourColors().

local V = ...

local ForestAtmos = {}
ForestAtmos.time = 0

ForestAtmos.RAMP = {
  dawn  = { fog = { 0.85, 0.72, 0.62 }, ray = { 1.00, 0.72, 0.48 } },
  day   = { fog = { 0.78, 0.86, 0.76 }, ray = { 1.00, 0.93, 0.72 } },
  dusk  = { fog = { 0.82, 0.68, 0.58 }, ray = { 1.00, 0.55, 0.32 } },
  night = { fog = { 0.40, 0.48, 0.62 }, ray = { 0.55, 0.62, 0.85 } },
}

function ForestAtmos.update(dt)
  dt = tonumber(dt) or 0
  if dt < 0 then dt = 0 end
  -- Cap a single step so a hitch cannot fling the lattice miles ahead.
  if dt > 0.25 then dt = 0.25 end
  ForestAtmos.time = (ForestAtmos.time or 0) + dt
end

return ForestAtmos
