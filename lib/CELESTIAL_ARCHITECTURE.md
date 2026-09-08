# Celestial architecture (Weather FX)

## Rule
Camera is the **observer**. It does not own celestial orientation.

```
GAME TIME → CelestialSim → world directions → NightSky / CelestialBodies → view
```

## Modules
| Module | Role |
|--------|------|
| `CelestialSim.lua` | Simulation: hour → sun/moon directions, horizon fade, layer radii |
| `CelestialBodies.lua` | Rendering helpers; uses Sim |
| `NightSky.lua` | Stars (fixed + daily vault rotation) + sun/moon 3D draw |

## Day arc
- 06:00 east horizon
- 12:00 overhead (+Y)
- 18:00 west horizon
- Night: moon opposite (+ slow drift)

## Layers (far → near)
Stars `1.00` → Sun `0.96` → Moon `0.94` of sky radius

## Stars
- Fixed celestial directions at catalog build
- Daily vault rotation about world UP (shared with solar clock)
- Soft horizon fade near altitude 0
- LOD via Quality.celestial()

## Player
- Position centers the draw sphere (parallax-free)
- Rotation never changes Sim directions
