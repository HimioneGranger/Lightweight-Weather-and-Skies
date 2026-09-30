# Changelog

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
