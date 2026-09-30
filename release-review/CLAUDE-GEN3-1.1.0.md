# Prompt for Claude — adapt the lightning update to your Gen 3 builds

Update the Gen 3 builds you maintain with the LWS 1.1.0 lightning changes:
https://github.com/HimioneGranger/Lightweight-Weather-and-Skies/releases/tag/v1.1.0

Inspect your own workspace rules, current Gen 3 architecture, build identities
and uncommitted changes first. Preserve your existing work and a verified
rollback. This LWS ZIP officially lists Gen 1/Gen 2, not Gen 3: do not blindly
install it, replace your host files or claim native Gen 3 compatibility.

Compare the v1.0.0..v1.1.0 source delta, concentrating on lib/QuestStorm.lua,
lib/QuestStormBolt.lua, compat/Controls.lua and the lightning tests. Port the
behavior through your Gen 3 weather/scene/camera/render/audio adapters:

- Twenty shuffled profiles per each of four lightning families (80 total),
  retaining parameter bounds and avoiding immediate cycle-boundary repeats.
- Longer winding anvil channels with 3–5 arms and 6–10 secondary forks;
  branch geometry and shader reveal share exact parent junctions.
- Clearer descending arms on half the ground profiles, using existing segments.
- Natural activity multiplier1.85, ground share.58, anvil share.72 of cloud-only
  nearby events, plus stronger FULL illumination. Keep one active nearby event
  and protect pending thunder from replacement.
- Preserve SOFT brightness and natural timing, OFF behavior, indoor/map/menu
  cleanup, showcase isolation, static stereo-shared meshes, and limits of
  1,944 anvil / 864 ground vertices. Keep the added profiles within existing
  width/lifetime ranges; do not add concurrent meshes for variety.

Check Gen 3 coordinate conventions, world scale, moving cloud-ceiling mapping,
camera projection, menu preferences and thunder playback before copying code.
Reuse/adapt tests/gen2_lightning_profiles.lua, gen2_lightning_variety.lua and
gen2_lightning_bolt.lua to your host. Verify all80profiles, shuffle cycles,
parent connections, budgets, SOFT/OFF and queued thunder. Capture the actual
Gen 3 renderer, not a separately drawn approximation. Desktop previews do not
prove headset FPS; preserve beta/experimental labels until target validation.

Build your updated Gen 3 candidates with your normal workflow and storage
gates. Record exact source revision, package identity, artifact SHA-256,
test/capture results and any unverified device behavior. Give me the builds,
concise changes and test steps. Do not publish, install on devices or overwrite
saves without separate approval. If a required adapter or build target is
unclear, ask instead of guessing.
