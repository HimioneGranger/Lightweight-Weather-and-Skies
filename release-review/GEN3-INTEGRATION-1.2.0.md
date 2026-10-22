# LWS 1.2.0 integration and verification

## Included changes

- Rain streak appearance/downward motion and reusable bounded particle buffers.
- Snow rendering and sparse snow-only frost; no puddle or ripple implementation.
- Sand grains, dust motes and bounded ground wisps.
- Contextual firefly populations and larger, soft six-to-nine-second glow cycles.
- Redesigned sun and cratered moon, with companion-host shadow synchronization.
- Lab cloud prewarming and a checked, precomputed procedural density field;
  missing/incompatible assets fall back to the original generator.
- Allocation-light sky/cloud passes and runtime full/lite/off tiers.
- Optional frame batching, OFF by default. Hosts enabling it must signal
  `exports.frameBegin()` once per rendered frame; missing signals fall back to
  tick updates. Map changes and switch-off flush pending work. Lightning preserves
  individual tick timing inside a batch.
- Optional fixed sun/moon heading controls for matching baked-shadow hosts.
- Emerald native weather/showcase menus, optional native lighting-preview clock,
  and dawn/dusk star visibility. Older hosts without lighting preview keep their
  native RTC and weather controls.

These weather-only changes were reconciled against the current FireRed 3216
candidate and Emerald 3807 runtime, preserving each lab's newer performance and
native-clock fixes. Host geometry, buildings, controls, startup/Oak intro, caves,
saves and ROM material are not included or replaced by the LWS package.

## Host requirements

Gen3 uses the existing `FRLG_VOXEL` weather facade and per-eye VP/eye data.
Surface-aware ground frost requires the matching native surface sampler; water
rejection uses the optional native `world.isWater` capability. Tree-density
sampling uses the native `world.vegetationAt` provider when available; otherwise
the habitat helper falls back to the map context.

Synchronized shadows are NOT provided by a weather ZIP alone: the companion
renderer must consume the same celestial sample through its `SolarShadows` /
`WeatherHostLib` integration. The current labs have target-specific integration;
do not replace an arbitrary newer host with an old complete renderer tree.

The checked cloud image is generated procedural data, not imported game artwork.
Its SHA-256 is
`240d6714c99064f27531e4f73cbc7ed0c9a236d0841ce09c03e07d7325f93c2f`.
The asset loader verifies both the bytes and normalized generator source before
using it; it never suppresses the original generator on a failed check.

## Evidence and release status

The source fixtures cover rain buffers, sand/dust, snow-only frost, production
firefly glow and habitat behavior. Additional fixtures cover frame batching and
native-clock/menu behavior with and without the optional preview module. Gen1/2,
PC packet sky, existing lightning and shared rain-speed regressions also pass.

The October 8 Weather Lab2 native/GLES checks are historical evidence for that
earlier exact payload, not acceptance of every newly merged source path. On
October 22, 2026 the owner reported that FRLFG Lab / FireRed build 3217 worked on Quest 2 and
explicitly approved publishing 1.2.0. Record that as owner-reported testing, not
an automated benchmark or universal hardware certification. Exhaustive fresh
exact-source per-host rendering and frame-pacing qualification remains open;
publication does not convert unrun checks into passed checks.

Puddles and god rays remain excluded. No measured headset FPS gain is claimed.
