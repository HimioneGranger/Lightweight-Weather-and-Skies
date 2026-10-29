# LWS 1.3.0 — Your sky, LWS weather

Keep your renderer's sky or use the full LWS sky—the choice is now yours.

- **New SKY SOURCE option:** FULL LWS SKY stays the default. NATIVE SKY keeps
  your renderer's sky and sun/moon while retaining **LWS clouds, lightning and
  weather**. The choice is saved and can be changed live.
- **Renderer API v1:** renderer authors can register their own camera/resource
  backend without adding their renderer ID to LWS. Includes an integration guide,
  example bridge and copied weather/time snapshots.
- **Lifecycle safeguards:** frame/camera validation, scoped fault cleanup,
  renderer switching and unload handling, plus duplicate-draw prevention.

The rain, snow/frost, sand/dust, contextual fireflies and revised celestial
features from 1.2.0 remain included. Compatible Gen1, Gen2 and Gen3 renderer/bridge
requirements still apply. This weather ZIP does not include an engine, Lab APK
or ROM. API adoption requires the renderer author to implement the documented
backend; registering an ID alone does not make a renderer compatible.

## Install

Download **Lightweight-Weather-and-Skies-1.3.0.zip** and import it through your
compatible host's mod manager, replacing the older LWS copy. FULL LWS SKY is the
default; use SKY SOURCE in weather controls/mod settings to choose NATIVE SKY.
Keep matching renderer/bridge dependencies installed. SHA256SUMS.txt identifies
the exact release ZIP. Renderer authors: see docs/RENDERER_API.md and
examples/renderer_api_v1.lua, included in the ZIP and repository.

## Verification and scope

Source regressions and syntax checks pass, including native-sky preservation and
API registration, selection, fault recovery and lifecycle fixtures. These tests
use mocked resource backends; new 1.3.0 GPU/stereo/headset and real third-party
backend qualification remain pending. The owner's earlier Quest 2 / FireRed
build 3217 result belongs to 1.2.0 and is not a fresh 1.3.0 test. No measured FPS
gain or universal engine support is claimed. Generic clock/shadow integration
remains the host author's responsibility.

Unfinished Emerald sandstorm experiments and private cloud-profiling/lab engine
changes are outside this release delta. Puddles and god rays remain excluded.
Credits, licensed assets and third-party notices are retained.
