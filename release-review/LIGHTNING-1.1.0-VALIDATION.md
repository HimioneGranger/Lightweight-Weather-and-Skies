# Lightning 1.1.0 validation

Prepared from published baseline81ddcb159dd8de999e7e743aa576b25c8246fddc.
Runtime delta limited to lib/QuestStorm.lua, lib/QuestStormBolt.lua and
compat/Controls.lua. Existing assets, credits and provenance are unchanged.

All11Lua tests and tests/release_contract.py passed against the release
checkout. Independent runtime source review found no blocking defect.
The new profile test covers all80profiles, bounded parameters, shuffle
cycles, fork reach, parent junctions and the864/1944vertex limits.

Selected GIFs were generated using tools/lightning_capture, LOVE11.5,
OpenGL3.3/NVIDIA RTX3080,960x540/4xMSAA,30fps with normal FULL brightness.
The capture camera uses negative projection Y to preserve world-up.
media/lightning-anvil.gif is anvil profile18; media/lightning-forked.gif
is ground profile17. Actual mod Lua/GLSL is loaded directly; host/weather
inputs and the fixed camera are fixtures. Not full-game or headset footage.

Captured runtime SHA256:
- QuestStorm.lua:39a8e560b89302d6f6657dc24f726b6a9aaa14521ab70b90bb02f38e47c123d7
- QuestStormBolt.lua:8c862f7f0a0a2bdba0d483c6880b04e0dc6cc3d69cb89bb5a0e2a9ee5c867308

tools/audit_release.py checks the final ZIP after committing its source:
CRC, inventory, duplicate entries, per-file exact source equality, version,
supported games, clean source tree, runtime-delta allowlist and unchanged
assets/provenance. The build output retains RELEASE-RECEIPT.json and
SHA256SUMS.txt. Receipt status is not headset or performance acceptance.
