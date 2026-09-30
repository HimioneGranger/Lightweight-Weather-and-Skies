# Lightweight Weather & Skies 1.1.0 — Lightning update

- **80 lightning profiles:** 20 each for ground strikes, anvil crawlers,
  rolling lightning and distant cloud flashes, with shuffled variation.
- Longer, thinner anvil crawlers with winding channels, branches and smaller
  offshoots that grow from their junctions.
- Clearer descending forks on half the ground-strike profiles, with subtle
  branching retained on the others.
- More active natural storms, a ground-strike majority among nearby events,
  and stronger FULL-mode storm illumination.
- Pending thunder is protected from fast-cadence replacement. SOFT retains
  gentle flash brightness/timing; OFF continues to suppress lightning.

## Previews

Actual 1.1.0 bolt/cloud renderer, normal timing and natural FULL brightness in
an isolated desktop scene. These are sample profiles, not headset footage.

![Anvil crawler](https://raw.githubusercontent.com/HimioneGranger/Lightweight-Weather-and-Skies/v1.1.0/media/lightning-anvil.gif)

![Ground forks](https://raw.githubusercontent.com/HimioneGranger/Lightweight-Weather-and-Skies/v1.1.0/media/lightning-forked.gif)

## Install

Back up your save, disable/remove the older LWS version and other weather mods,
import the attached **Lightweight-Weather-and-Skies-1.1.0.zip**, enable it, and
restart. Battle Art and the compatible standalone Quest bridge remain separate
dependencies. Return **WEATHER → AUTO** after manual-weather showcases.

## Testing and compatibility

Automated Lua regressions, release-contract checks, independent source review
and actual desktop GPU captures passed. The new lightning has **not** had a
fresh full-game/headset performance pass. Bounded meshes and unchanged draw-call
structure are not a zero-cost guarantee; larger effects/activity may cost more.

Gen 1 remains the main track, **Gen 2 is beta**, and **non-VR Android is alpha**.
Earlier 1.0 platform checks are not new 1.1.0 acceptance. Gen 3 is not included
in this package's supported game list. PCVR/unrelated renderers are not claimed.
Flash-sensitive users should use SOFT or OFF. Preserve a 1.0.0 rollback.

Derived from The World with owner-reported permission for a lightweight
derivative; all existing third-party notices and audio credits are retained.
No ROMs, base-game assets, private Lab APKs or anime cry pack are added.

Report bugs with platform, host/Battle Art version, bridge status, mod list
and a short clip. ZIP SHA-256 is supplied in the attached checksum file.
