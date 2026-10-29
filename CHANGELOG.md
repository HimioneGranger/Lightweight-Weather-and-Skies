# Changelog

## 1.3.0 — Native sky and Renderer API (2026-10-28)

- Add a saved SKY SOURCE option: FULL LWS SKY remains the default; NATIVE SKY
  retains the host sky and celestial bodies with LWS clouds, lightning and weather.
- Restore host sky forwarding and LWS-owned shadow shear on live native-sky
  switches, without overwriting newer host shadow values.
- Introduce Renderer API v1: provider registration/discovery, active-renderer
  routing, copied weather snapshots, camera/world context and scoped draw packets.
- New renderers can integrate without adding their mod ID to LWS's adapter list.
  Include an integration guide and executable subscription bridge example.
- Validate frames/cameras; contain provider faults; handle switching, invalidation
  and unload; prevent duplicate legacy drawing when a packet renderer owns weather.
- Automated source tests pass. Real third-party backend, GPU and headset
  qualification remain pending; no new FPS/performance claim.
- Retain 1.2.0 weather features. Unfinished Emerald sandstorm experiments, cloud
  profiling/lab-engine changes, puddles and god rays are excluded from this delta.

## 1.2.0 — Gen3 support and weather refinement (2026-10-22)

- Rain appearance/downward-motion and bounded geometry/buffer improvements.
- Snow rendering improvements and sparse snow-only ground frost.
- Sand grains, softer dust motes and bounded low-ground wisps.
- Contextual fireflies with larger sprites and slower, softer glow.
- Revised sun and preserved redesigned moon; matching host integration for
  sun/moon-synchronized shadows is required and qualified separately.
- Carry forward lab cloud prewarming and the checked precomputed cloud field,
  allocation-light sky passes, optional frame batching, and runtime weather tiers.
- Retain Emerald native weather/showcase menus, lighting-preview synchronization
  where supported, and dawn/dusk star fades. Older hosts retain native RTC when
  the optional lighting-preview module is absent.
- Preserve fixed sun/moon heading controls used by matching baked-shadow hosts.
- Gen3 adapters for compatible FireRed/LeafGreen and Emerald hosts; keep matching
  renderer/bridge integrations installed. The ZIP does not supply a complete host.
- Owner-reported successful Quest 2 testing and publication approval. Automated
  fixtures, historical native checks and user testing are distinct evidence;
  complete exact-source per-host/frame-pacing qualification is not claimed.
- Puddles/ripples and god rays are excluded. No measured headset FPS gain claimed.

## 1.1.0 — Lightning variety update

- Doubled profiles to twenty per family, eighty total, with shuffled cycles.
- Longer, thinner, winding anvil crawlers with three to five branches and
  secondary forks that grow from their parent junctions.
- Clearer descending forks on half the ground profiles; subtler strikes remain.
- More natural activity and a ground-strike majority; stronger FULL illumination.
- Protected pending thunder against fast-cadence overwrites. SOFT keeps its
  gentle brightness/timing; OFF remains disabled, including showcases.
- Bounded static meshes: at most 1,944 anvil or 864 ground vertices. Fresh
  real-renderer GIFs, automated regressions and source review; no fresh
  headset/full-game performance acceptance. Gen 2 beta and Android alpha remain.

## 1.0.0 — first public release

- Gen 1 Quest visual and audio checks accepted by the owner. The Gen 1 PC cloud, sky and rain comparisons also passed on Gen1Recomp 0.2.24 with Battle Art 1.11.0. Gen 2 remains beta and non-VR Android is alpha; neither has a performance clearance claim.
- Clear skies have slightly less cloud cover and recover from storms without lingering near-overcast. Nearby thunder follows visible lightning sooner and more audibly.
- The moon disc is smaller, and its shadowed side and new moon are much dimmer.
- One weather ZIP routes across the supported host paths. Battle Art and Quest bridges remain separate.
- Mostly Cloudy, light rain and heavy rain now have more distinct cloud coverage; heavy rain approaches overcast without using storm-dark cloud shading.

## Earlier public-package preparation

- Clarified Gen 1 RC-candidate versus Gen 2 beta status and separated private Quest Lab APKs from the planned public LWS ZIP.
- Gen 2 private Labs 33–34 restored the approved voxel-cloud renderer and moved forked strikes into the visible storm horizon. Overall natural lightning cadence is unchanged; the cloud-only/forked style mix changed for Gen 2 testing. Physical strike and frame-rate acceptance remains open.
- Updated compatibility, release-gate, third-party cry, and showcase-control documentation. No public package or tag was published by these documentation changes.

## 0.1.0-rc.7 — candidate

- Replaced area-specific cloud heights with a game-wide outdoor base of 1920 world pixels on PC/Android packet and standalone Quest renderers.
- Raised lightning's default cloud origin to match. Quest restores the host's previous cloud altitude when its weather attachment is removed.
- Storm shelf motion and indoor visibility rules are retained. Prior encounter slowdown remains unresolved.

## 0.1.0-rc.6 — candidate

- Faint blue-gray lunar silhouettes and surface detail, using consistent shading in both renderers across all phases.
- Once-per-profile AUTO weather, regional weather ON, moving storms, and host day/night CYCLE defaults. Later manual choices are preserved.
- Packet cloud heights of 1600 in Viridian Forest/Safari and 1920 in Pewter/Routes 3–4; other areas are unchanged.
- The rc.5 clouds-only/encounter slowdown report remains unresolved; this update does not claim to fix it.

## 0.1.0-rc.5 — candidate

- Unified Windows/PC, standalone Quest, and experimental non-VR Android routing in one LWS package.
- Deferred atmosphere initialization until the platform router selects a renderer, preventing the legacy and packet renderers from installing together on PC/Android.
- Restored the Beta 6–8 lightning visibility work: rain-family eligibility, faster natural cadence, moving-cloud-ceiling alignment, stronger near thunder with brief bed ducking, and source cleanup.
- Turned LIGHTNING: MAKE IT SPICY into an unmistakable two-minute diagnostic: forward-facing forked/anvil strikes about every six seconds with wider, brighter, longer-lived geometry. Natural lightning is unchanged.
- Added independent Viridian Forest and shared Safari savannah climates; Safari storm lightning runs at 2× cadence.
- Added and documented approaching-storm, cloud-formation, and lunar-cycle renderer previews.
- Updated Battle Art compatibility guidance for 1.10.8 and companion-integrity PR #57.

## 0.1.0-rc.2 through rc.4

- Replaced unresolved inherited weather recordings with documented CC0/CC BY material.
- Added the Lite Weather FX and Showcase Controls submenus.
- Added standalone Quest routing and experimental non-VR Android packet rendering.
