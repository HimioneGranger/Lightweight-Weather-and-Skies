# LWS Renderer API v1

This API lets a renderer integrate with LWS without adding its mod ID to LWS's
adapter list. It ships in LWS 1.3.0, with API contract version 1. Source
conformance tests pass. Real GPU, stereo and headset qualification
are still required for each backend.

The contract targets renderers in the Lua/LÖVE mod runtime. LWS produces its
existing cloud, celestial, lightning and weather draw packets. The renderer
implements GPU resource creation, camera information and render phases. A
different engine or shader language needs an equivalent backend/translation.

## Discover or register

When the host publishes the standard active world-pipeline owner, a renderer can
advertise its descriptor as `mod.exports.lwsRendererProvider`. LWS discovers it
only when that renderer is selected. No LWS renderer-ID patch is required.

Alternatively, once LWS has initialized, explicitly register:

```lua
local lws = assert(mod.find('YOUR_INSTALLED_LWS_MOD_ID'))
local api = assert(lws.exports.lwsRendererAPI)
assert(api.api == 1)
local registration, err = api.registerRenderer {
    api = 1,
    owner = mod.id,
    provider = provider,
}
assert(registration, err)
-- On renderer unload:
-- registration:dispose()
```

Replace the placeholder with the installed LWS mod ID. Use the host's lifecycle
events to register after both mods load; retry when LWS becomes available rather
than assuming dependency order. Owner must identify an installed mod. Register
once per owner. Replace a descriptor object, or dispose/re-register, to change
backend implementation; do not mutate an active descriptor in place.

Engines without the standard world-pipeline registry use explicit registration
and provide `provider.isActive()` returning true only while that renderer owns
the current world view. Exactly one registered provider may report true. Zero,
errors or multiple true results fail closed. Known standard pipeline ownership
takes priority. Presence alone never means active. This is cooperative routing,
not an authentication or sandbox boundary.

## Descriptor and lifetime

```lua
local provider = {
    api = 1,
    space = {unitsPerMetre=10, up='Y', east='+X', south='+Z'},
    isActive = function() return engineIsActuallySelected() end, -- optional
    register = function(callbacks)
        -- Subscribe to engine frame/invalidation/unload events here.
        -- Return one stable resource scope for this lease:
        return {
            effects = function(self) return resourceScope end,
            dispose = function(self) -- unsubscribe and destroy scope
            end,
        }
    end,
}
```

`register(callbacks)` is a dot call; resource/lease methods are colon calls.
API registry functions are dot calls; registration handle methods are colon
calls. API versions other than 1 are rejected. Breaking contract changes require
a new version. Registration does not imply frame readiness.

Callbacks are `api=1`, `id` (LWS mod ID), `prepare(frame)`, `invalidate()` and
`dispose()`. Run them on the render/main thread. Do not invoke prepare
synchronously inside register before returning the lease. Invalidate after
context loss, camera/map reset or before resetting frame IDs. Dispose on unload;
lease disposal must be idempotent and unsubscribe callbacks, clear this scope
and release its resources. Stale callbacks are ignored by LWS.

The executable [reference glue](../examples/renderer_api_v1.lua) implements these
subscriptions and partial-failure cleanup. Its `engine` argument is supplied by
the renderer author, with `createWeatherScope(id)`, `onWeatherPrepare(fn)` and
`onWeatherInvalidate(fn)`. Both subscriptions return unsubscribe functions; the
scope has `destroy()`. Optional `engine:isActive()` supplies fallback selection.
These methods describe the example's interface, not a shipped engine API. The
example is not a complete renderer or GPU backend.

## Frame and camera

Call `callbacks.prepare(frame)` once per world frame:

```lua
local frame = {
    id = frameNumber, -- nonnegative integer, increasing until invalidate
    dt = seconds,    -- finite [0,1]; LWS limits its simulation step to 0.1
    world = {
        visible = 'world', -- another string, e.g. 'menu', suppresses rendering
        outdoor = true,
        indoors = false,
        map = {id='unique-map-id'},
        neighbors = {}, -- optional entries: {map={id='...'},ox=...,oy=...}
        surfaceAt = function(x,z) return knownGroundHeightOrNil(x,z) end,
    },
    lighting = {hour=13.5, tint={1,1,1}, haze={0.6,0.7,0.8}},
}
```

Outdoor visible frames require a nonempty map ID and lighting: hour in `[0,24)`,
finite RGB tint and haze. Hidden frames still require visible/outdoor/indoors
fields but may omit map and lighting. Optional `surfaceAt(x,z)` returns a finite
height or nil. Unknown/failing samples suppress ground decals rather than
guessing a floor. Frame world context avoids engine-private Game module lookups.

All positions, vertex coordinates, ground heights and far distances use LWS
canonical space: **10 units per metre, Y up, +X east, +Z south**. Adapt native
units/axes in the renderer bridge and view matrices. Keep native terrain data in
its own format if needed. Neighbor ox/oy are connected-map offsets in the same
X/Z units; omit unverified connections. Map IDs must agree between frame and camera.

`scope:camera()` returns:

```lua
{
    available=true, eye={0,40,0}, focus={0,40,-10},
    far=4000, fov=1.2, viewportHeight=1600,
    mapId='unique-map-id', mode='first_person', skyVisible=true,
}
```

FOV is vertical radians, greater than zero and less than pi. Eye/focus are
finite distinct points. Viewport height is positive pixels. `skyVisible` is
required and controls cloud eligibility; optional mode defaults to first person.
Return `{available=false, reason='...'}` when the camera is unavailable.

Preparation uses a stable simulation camera, once before eye rendering. Repeated
IDs are ignored without advancing weather twice. Replay the prepared packets for
each eye using that eye's current view-projection and eye position. Never reuse
a previous eye's matrices. Regressing IDs are rejected until invalidation.
Start each new frame with an empty scoped packet queue and neutral scoped
atmospheric overrides, retaining resource tokens. Keep that frame's queue for
both eyes, then discard it before the next preparation. Do not append packets
across frames or clear the queue between eyes.

## Resource scope contract

`lease:effects()` returns the same scope table for the lease's lifetime. Methods
must return a truthy success/token or nil/false on failure. Tokens are opaque and
owned by this scope; LWS never directly mutates the host GL context.

| Method | Input/result |
| --- | --- |
| `camera()` | Camera table described above. |
| `material(spec)` | `{source=loveGLSL, uniforms={}, skyDepth=boolean}` → material token. |
| `mesh(spec)` | `{format=loveVertexFormat, vertices=triangleRows}` → mesh token. |
| `image(spec)` | `{width,height,rgba=rawRGBABytes,wrap='repeat'}` → image token. |
| `updateMesh(token, vertices)` | Replace mesh vertices; preserve its format. |
| `enqueue(packet)` | `{phase,material,mesh,image?,uniforms,blend?,tint?}` → success. |
| `release(token)` | Release only this scope's token; idempotent/context-loss tolerant. |
| `submitAtmosphere(state)` | Apply the atmospheric state below to this scope. |
| `clear()` | Remove this scope's queued packets and atmospheric overrides only. |

`blend` is `alpha` by default, or `add`; tint is RGBA, default white. Materials
use LÖVE shader syntax and vertex formats; preserve uniform names/types from
LWS packets. Inject `vp` and `eye` from the current eye in shaders that declare
them. Per-packet uniforms override material defaults. Validate token ownership,
texture byte lengths, bounds and shader compilation in the backend. Dynamic
mesh updates and raw RGBA image creation must preserve authored data.

Execute phases in this order:

1. `celestial_before_clouds`: LWS sun, moon and sky effects.
2. `sky_deck`: LWS cloud deck.
3. `translucent_after_actors`: weather and lightning after opaque world/actors.

Compose sky behind terrain and weather against scene depth. `skyDepth=true`
materials belong at sky/far depth, without depth writes. Translucent weather
also avoids depth writes. Preserve alpha/additive blending and restore host GL
state after the scope. Host sky must not paint over queued LWS clouds. The host
owns final phase placement relative to its sky and world renderer, and stereo
correctness; a successful mock test does not certify this placement visually.

Atmosphere state:

```lua
{
    sky={dim=0.2, flash=0.4, replaceCelestials=true},
    tint={multiplier={1,1,1}, additive={0,0,0}},
    haze={density=0.1, color={0.6,0.7,0.8}},
}
```

Apply dimming, flashes, tint and haze without permanently changing the host's
base lighting. Clear/dispose restores native state. FULL LWS SKY is the default.
NATIVE SKY retains the host sky and celestial bodies, with
`replaceCelestials=false`, **while LWS clouds, lightning and weather still draw**.
The host must honor replacement/restore instructions instead of showing both
sets of celestial bodies. LWS does not rewrite a generic host's clock or shadow
renderer; align those with the public clock if the host supports them.

## Status and weather state

`api.status(owner)` and `registration:status()` return fresh status tables:
`api`, `owner`, `registered`, `selected`, `ready`, `active`, `reason`. Selection
is separate from successful preparation. Invalid frames/render exceptions clear
LWS's own queue, invalidate its client and return `false,error` from prepare;
valid later frames can recover. An unselected provider clears its own effects.
Do not clear other mods' resources or the engine's whole effects queue.

`api.snapshot()` returns a fresh data table, or `nil,error` while unavailable:

```lua
{
    api=1, skySource='full', clouds=true,
    weather={id='RAIN', level=1, channels={rain=1,snow=0,sand=0,ash=0,
        fog=0,dim=0,gust=0,strike=0,splash=0}},
    clock={hour=13.5},
}
```

Treat snapshots as read-only input; mutation does not update LWS. Channel
strengths and level are weather state, not a replacement for the authored packet
renderer or a fixed enum of shader thresholds. No private LWS module access is
needed to read this state. A custom backend may consume it, but reproducing the
visual effects itself is that backend author's responsibility.

## Qualification checklist

Run `tests/renderer_api_v1.lua`, `tests/renderer_api_bootstrap.lua` and
`tests/renderer_api_example.lua` with the repository root as the first argument.
They cover unknown renderer IDs, registration/discovery, load-order wrappers,
selection fallback, lifecycle, frame validation, failure recovery and native sky
cloud/lightning preservation using mocks and the real packet client.

For a real integration also verify full/native sky changes; rain/snow/sand;
lightning; ground sampling; camera/map/menu transitions; renderer switching;
context loss/unload; two-eye depth/occlusion; and CPU/GPU cost on target hardware.
Do not advertise readiness based only on registration or installed mod presence.
