
  varying float vShade;
  varying float vFacadeBack;
  varying float vFog;
  varying float vWeatherFog;
  varying float vCloudLightning;
  varying float vStormFront;
  varying float vStormMass;
  varying vec3 vSun;          // this fragment's place in the sun's view
  varying vec3 vModelSun;     // optional Stadium model-shadow view
  uniform LOVE_HIGHP_OR_MEDIUMP vec4 cloudMorph; // consistent GLES precision
#ifdef VOXEL_GRID
  // model space, one unit per voxel -- see VoxelGrid. Precision matters
  // here in a way it does not for a colour: the seam is the FRACTIONAL
  // part of a coordinate that runs to a few thousand across a big route,
  // so a mediump varying would quantise the fraction away entirely.
  varying LOVE_HIGHP_OR_MEDIUMP vec3 vGrid;
#endif
#ifdef VERTEX
  uniform vec4 cloudLightning; // world X/Z, inverse radius, envelope (vertex-only)
  uniform vec4 stormFront; // world X/Z, inverse radius, storm strength (vertex-only)
  uniform vec2 stormAxis; // fixed world-space direction of travel
  uniform float stormCanopy; // local interior overcast, smoothly driven by the moving bank
  uniform vec2 stormFinish; // interior gap fill, aged regional bank readiness
  uniform mat4 vp;
  const mat4 model = mat4(1.0);
  const mat4 sunModel = mat4(1.0);      // where the SUN sees this vertex (see below)
  const mat4 sunVP = mat4(1.0);         // world -> the shadow map's unit cube
  const mat4 modelSunVP = mat4(1.0);    // Stadium-local world -> its shadow unit cube
  const vec3 modelSunOrigin = vec3(0.0);// map-world origin of Stadium's local arena
  uniform vec3 eye;
  const float pull = 0.0;
  const vec3 curve = vec3(0.0);         // xy = the focus in world XZ, z = k; 0 = off
  uniform vec4 fogInfo;       // density, start, heightK; density 0 = clear
  const float weatherHaze = 0.0;
  attribute float VertexShade;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Values below -2 encode upward-facing authored roof surfaces. The
    // ordinary negative range remains the existing south-facade marker.
    float roofSurface = step(VertexShade, -1.5);
    vShade = abs(VertexShade) - roofSurface * 2.0;
#ifdef VOXEL_GRID
    // MODEL space, deliberately: every mesh here is built a unit per
    // voxel in its own frame, so the seams ride the model however it is
    // posed rather than the world's grid sliding across a leaning sprite
    vGrid = vertex_position.xyz;
#endif
    vec4 w = model * vertex_position;
    // All four vertices of a marked facade lie on one Z plane, so this is
    // constant across its fragments. Work it out here where `eye` belongs;
    // the pixel stage only needs the yes/no result.
    float facadeSurface = step(VertexShade, -0.0001) * (1.0 - roofSurface);
    vFacadeBack = facadeSurface * step(eye.z, w.z - 0.0001)
                + roofSurface * step(eye.y, w.y - 0.0001);
    // The shadow lookup runs off `sunModel`, not `model`. For terrain the
    // two are the same matrix, but a character is drawn as a slab LEANING
    // back by the camera's pitch -- a trick played on the viewer, which
    // the sun never saw: it lit the upright card. Looking up with the
    // leaned position asks whether the sun reached a place the figure is
    // not, and since the lean tips the body north and shadows now fall
    // north, every sprite's own card fell across its front. Looking up
    // with the card's position asks the question the sun actually
    // answered. (The pull below is excluded for the same reason: it is a
    // depth trick aimed at the camera's own buffer.)
    vSun = (sunVP * (sunModel * vertex_position)).xyz;
    // Stadium owns and completes its live model shadow map before requesting
    // our environment. Translate this map-world receiver into Stadium's
    // arena-local coordinates and sample that finished map as a second light
    // layer; no cross-mod render-target or shader handoff is required.
    vModelSun = (modelSunVP * vec4(w.xyz - modelSunOrigin, 1.0)).xyz;
    // Distance haze is evaluated in the uncurved world. The cloud deck uses
    // this to disappear into the horizon instead of exposing its far edge.
    vFog = 0.0;
    vWeatherFog=0.0;
#ifndef UNLIT_ONLY
    if(cloudMorph.w<0.5 && weatherHaze>0.0){
      vWeatherFog=min(0.28,1.0-exp(-weatherHaze*max(0.0,length(w.xyz-eye)-300.0)));
    }
#endif
    if (fogInfo.x > 0.0) {
      float fogRun = max(0.0, length(w.xyz - eye) - fogInfo.y);
      vFog = (1.0 - exp(-fogInfo.x * fogRun))
             * exp(-max(w.y, 0.0) * fogInfo.z);
    }
    // The curved world (see WorldCurve): drop every vertex by the square
    // of how far its column stands from the camera's focus. Applied AFTER
    // the shadow lookup above and clear of the wireframe's model space, so
    // both are worked out on the flat world and the bend carries them
    // along -- which is why neither has to know this exists. Along Y only,
    // so a column moves as one piece: the world tips away and the
    // buildings standing on it stay upright.
    if (curve.z > 0.0 && cloudMorph.w < 0.5) {
      vec2 cd = w.xz - curve.xy;
      w.y -= dot(cd, cd) * curve.z;
    }
    // camera-ward pull: move the vertex along ITS OWN ray to the eye.
    // This is a pure depth bias -- the projection of a point moved along
    // its eye ray is bit-identical, so there is no screen drift at all.
    // (An earlier CPU version translated along the central view axis,
    // which preserved only the screen centre and made off-centre sprites
    // and grass swim against the ground while the camera scrolled.)
    if (pull > 0.0) {
      w.xyz += normalize(eye - w.xyz) * pull;
    }
    // Cloud-only, and deliberately in the vertex stage: the 40x40 deck pays
    // for a handful of sine evaluations, while its millions of eye fragments
    // retain the exact one-sample texture path. Two tile-periodic waves plus
    // a weaker second harmonic make the frozen noise banks slowly breathe.
    vCloudLightning = 0.0;
    vStormFront = 0.0;
    vStormMass = 0.0;
    if (cloudMorph.w > 0.5) {
      if (stormFront.w > 0.0) {
        vec2 delta=(w.xz-stormFront.xy)*stormFront.z;
        float along=dot(delta,stormAxis);
        float across=dot(delta,vec2(-stormAxis.y,stormAxis.x))/2.6;
        float edge=along+0.05*sin(across*7.0);
        float leading=1.0-smoothstep(0.65,1.0,edge);
        float trailing=smoothstep(-1.4,-0.6,along);
        float lateral=1.0-smoothstep(0.7,1.0,abs(across));
        vStormFront=leading*trailing*lateral*stormFront.w;
        vStormMass=smoothstep(0.90,1.0,vStormFront)*stormFinish.y;
        // Inside a substantial storm, distant gaps close across the horizon.
        // Stars remain rendered behind real opaque cloud fragments.
        vStormFront=max(vStormFront,stormCanopy);
        vStormMass=max(vStormMass,stormFinish.x);
        // Lower the existing deck into a broad shelf near its advancing lip.
        // Vertex-only, world locked, and gone completely when storm strength is zero.
        float shelf=leading*smoothstep(0.25,0.65,edge)*lateral*stormFront.w;
        w.y-=65.0*vStormFront+110.0*shelf;
      }
      if (cloudLightning.w > 0.0) {
        vec2 delta = (w.xz - cloudLightning.xy) * cloudLightning.z;
        float falloff = max(0.0, 1.0 - dot(delta, delta));
        float halo=max(0.0,1.0-dot(delta,delta)*0.25);
        vCloudLightning=(0.8*falloff*falloff+0.4*halo*halo)*cloudLightning.w;
      }
      const float TAU = 6.28318530718;
      vec2 uv = VaryingTexCoord.xy;
      vec2 primary = vec2(
        sin(uv.y * TAU + cloudMorph.x) - sin(uv.y * TAU),
        sin(uv.x * TAU - cloudMorph.x) - sin(uv.x * TAU)
      );
      vec2 detail = vec2(
        sin(uv.x * TAU * 2.0 - cloudMorph.x * 2.0)
          - sin(uv.x * TAU * 2.0),
        sin(uv.y * TAU * 2.0 + cloudMorph.x * 2.0)
          - sin(uv.y * TAU * 2.0)
      );
      uv += (primary + detail * 0.45) * cloudMorph.y;
      VaryingTexCoord = vec4(uv, 0.0, 1.0);
    }
    vec4 clip=vp*w;
    // Clouds are sky, not terrain: keep their true world-ray projection but
    // constrain only far depth. Terrain draw distance and occlusion stay put.
    // Leave behind-eye vertices untouched so ordinary near clipping works.
    if (cloudMorph.w > 0.5 && clip.w > 0.0) clip.z=min(clip.z,clip.w*0.99999);
    return clip;
  }
#endif
#ifdef PIXEL
  uniform Image sunMap;
  const float sunDark = 0.0;      // how far into black a shadow goes; 0 = off
  uniform float sunBias;
  uniform vec2 sunTexel;
  uniform Image modelSunMap;
  const float modelSunDark = 0.0;
  uniform float modelSunBias;
  uniform vec2 modelSunTexel;

  // the two-channel pack ShadowMap writes: high byte, then low
  float sunDepth(vec2 uv) {
    vec4 c = Texel(sunMap, uv);
    return c.r + c.g * (1.0 / 255.0);
  }

  // 1.0 in full sun, 1.0 - sunDark in full shadow. Four taps half a texel
  // out on the diagonals: a 2x2 box filter, which is what turns the
  // shadow map's texel staircase into a one-pixel soft edge.
  float sunlight(vec3 p) {
    if (sunDark <= 0.0) return 1.0;
    // outside the sun's frustum nothing was recorded, so nothing occludes
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) {
      return 1.0;
    }
    // Ease the shadows off at the frustum's rim. The map covers the ground
    // the camera can see out to a cap, and past the low rungs -- 75 degrees
    // especially -- the horizon is further than any box worth paying for.
    // Without this the covered region simply ENDS, drawing a hard line
    // across the middle distance where every shadow stops at once; with it
    // the far field just loses them, which reads as distance.
    vec2 e = min(p.xy, 1.0 - p.xy);
    float edge = smoothstep(0.0, 0.06, min(e.x, e.y));
    if (edge <= 0.0) return 1.0;
    float z = p.z - sunBias;
    float lit = step(z, sunDepth(p.xy + sunTexel * vec2(-0.5, -0.5)))
              + step(z, sunDepth(p.xy + sunTexel * vec2( 0.5, -0.5)))
              + step(z, sunDepth(p.xy + sunTexel * vec2(-0.5,  0.5)))
              + step(z, sunDepth(p.xy + sunTexel * vec2( 0.5,  0.5)));
    return 1.0 - sunDark * edge * (1.0 - lit * 0.25);
  }

  float modelSunDepth(vec2 uv) {
    vec4 c = Texel(modelSunMap, uv);
    return c.r + c.g * (1.0 / 255.0);
  }

  float modelSunlight(vec3 p) {
    if (modelSunDark <= 0.0) return 1.0;
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) {
      return 1.0;
    }
    float z = p.z - modelSunBias;
    float lit = step(z, modelSunDepth(p.xy + modelSunTexel * vec2(-0.5, -0.5)))
              + step(z, modelSunDepth(p.xy + modelSunTexel * vec2( 0.5, -0.5)))
              + step(z, modelSunDepth(p.xy + modelSunTexel * vec2(-0.5,  0.5)))
              + step(z, modelSunDepth(p.xy + modelSunTexel * vec2( 0.5,  0.5)));
    return 1.0 - modelSunDark * (1.0 - lit * 0.25);
  }

#ifdef VOXEL_GRID
  uniform float gridDark;     // how far toward black a seam pulls; 0 = off
  uniform float gridWidth;    // seam width, in display pixels

  // How much of this fragment a voxel seam covers, 0 to 1.
  float voxelSeam(vec3 p) {
    // how much of `p` this fragment spans on screen, per axis: the
    // conversion from model units to display pixels, measured rather than
    // derived, so it holds under any camera pitch or zoom
    vec3 w = fwidth(p);
    vec3 d = abs(fract(p + 0.5) - 0.5);      // distance to the nearest plane
    // The axis a face does not vary along is that face's own normal, and
    // its distance is a constant zero -- take it at face value and every
    // face floods solid. Push those axes out of reach instead of dividing
    // by their zero.
    vec3 live = step(1e-4, w);
    vec3 px = d / max(w, vec3(1e-6)) + (1.0 - live) * 1e6;
    float near = min(min(px.x, px.y), px.z);
    // Fade out where a voxel is too small to hold a line. Survey zoom
    // draws a world pixel at about a display pixel, and a wall seen nearly
    // edge-on squashes one to nothing at any zoom -- either way the seams
    // land closer together than they are wide, and drawn anyway they stop
    // being a wireframe and become a flat 45% dimming of the whole scene.
    // The tightest axis decides, which is the honest test of whether the
    // grid can be resolved at all.
    float span = 1.0 / max(max(w.x, max(w.y, w.z)), 1e-6);
    float fade = clamp((span - 2.0) * 0.5, 0.0, 1.0);
    // the textbook antialiased line: solid within the half-width, fading
    // over the one pixel outside it
    return fade * clamp(gridWidth * 0.5 + 0.5 - near, 0.0, 1.0);
  }
#endif

  uniform vec3 ghostColor;    // the flat silhouette colour
  const float ghost = 0.0;        // 0 = shade normally, 1 = flatten to it
  const float lightOn = 1.0;      // 1 = scene lighting, 0 = texture true-colour
  uniform vec3 dayTint;       // the hour's light on the world; 1,1,1 = noon
  uniform vec3 fogColor;
  const vec3 weatherHazeColor = vec3(0.0);
  uniform float alphaCut;
  const float texelAlpha = 1.0;
  uniform vec4 cloudShape;    // evolution A/B weights, amplitude, steps
  uniform vec2 cloudMaterial; // authored density cutoff and softness
  uniform vec3 cloudColor;    // reconstructed underside colour
  uniform vec3 cloudLight;    // time-of-day underside illumination, neutral at noon
  uniform float cloudFade;    // 0 normally; storm-only alpha reduction
  uniform float cloudOvercast; // storm mass blocks the sky behind this deck
  uniform Image glassMask;    // opaque where the atlas texel is window glass
  uniform vec2 glassSize;     // the mask's dimensions: tc -> atlas texels
  uniform float glassNight;   // 0 = daylight .. 1 = the lamps are on
  uniform float glassPhase;   // the glint's phase: advances with TRAVEL
  uniform float glassGlint;   // and its strength: 0 while standing still
  const float glassOn = 0.0;      // 0 for sprite-sheet draws (see Voxel3D.glass)

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Enterable overworld buildings carry their south/front skin as a
    // one-sided surface. During a door transition the camera can briefly
    // stand north of that skin; discard its back instead of filling the
    // lens with mirrored facade/door art. Genuine rear and side walls keep
    // ordinary positive shade values and remain double-sided.
    if (vFacadeBack > 0.5) discard;
    vec4 p = Texel(tex, tc);
    // cloudMorph is intentionally vertex-only. On GLES the vertex and
    // fragment stages can assign different default precision to an otherwise
    // identical shared uniform, and Adreno then refuses to link the program.
    // cloudShape.z is zero for every ordinary draw and positive only for the
    // cloud deck, so it is the fragment stage's independent enable flag.
    if (cloudShape.z > 0.0) {
      // The packed texel is three density fields, not a visible colour.
      // Preserve the authored field in R and let two broad fields move only
      // densities near its coverage threshold. Re-quantising to the original
      // four opacity levels retains the cloud deck's deliberate pixel look.
      float density = p.r
        + (p.g - 0.5) * cloudShape.x * cloudShape.z
        + (p.b - 0.5) * cloudShape.y * cloudShape.z;
      // Preserve the authored opacity levels as broad plateaus, but ease
      // through a narrow band around each boundary. Hard rounding made whole
      // patches pop; fully continuous alpha made the deck look soft. This
      // keeps the pixel-cloud contrast while every level change still fades.
      float rawOpacity = clamp(
        (density - mix(cloudMaterial.x,-0.20,vStormFront)) / max(cloudMaterial.y, 0.001),
        0.0, 1.0);
      float steps = max(cloudShape.w, 1.0);
      float scaledOpacity = rawOpacity * steps;
      float lowerLevel = floor(scaledOpacity);
      float betweenLevels = fract(scaledOpacity);
      float levelFade = smoothstep(0.35, 0.65, betweenLevels);
      float opacity = min(1.0, (lowerLevel + levelFade) / steps);
      float mass=max(smoothstep(0.90,1.0,cloudOvercast),vStormMass);
      // As the storm fills in, density becomes underside shading rather than
      // transparent holes. Celestial objects remain rendered behind the deck.
      vec3 underside=mix(cloudColor,vec3(0.17,0.20,0.26),vStormFront)
        *mix(1.0,0.65+0.35*clamp(density,0.0,1.0),mass);
      underside*=cloudLight;
      p = vec4(underside, mix(opacity,1.0,mass) * (1.0-clamp(cloudFade,0.0,1.0)));
    }
    // sprite sheets key GB OBJ color 0 to alpha 0; discarding rather than
    // blending keeps those texels out of the depth buffer, so a model never
    // carves a transparent hole out of whatever stands behind it
    if (p.a < alphaCut) discard;
    // UNLIT is an exact texture pass, not merely a zero-weight blend with
    // the lit result. Some GLSL drivers still evaluate both sides of mix(),
    // including the shadow lookup, and have shown pieces of that result on
    // battle cards even when lightOn was zero. Returning here guarantees an
    // UNLIT card cannot receive face light, the day tint, voxel seams, glass
    // or any cast/self shadow.
    if (lightOn < 0.5) {
      return vec4(mix(p.rgb, ghostColor, ghost), 1.0) * color;
    }
#ifdef UNLIT_ONLY
    // A separately compiled card shader. Unlike a uniform branch in the
    // scene shader, this program contains no live day/shadow calculation for
    // a driver to evaluate or fold incorrectly. Ghost remains for hit flashes.
    return vec4(mix(p.rgb, ghostColor, ghost), 1.0) * color;
#endif
    // the hour's tint multiplies like the sun terms do: it is LIGHT, the
    // same warm or moonlit cast on every surface, not a palette swap
    vec3 litRgb = p.rgb * vShade * sunlight(vSun)
                * modelSunlight(vModelSun) * dayTint;
    vec3 rgb = litRgb;
#ifdef VOXEL_GRID
    // darken what is there rather than painting a colour, so a seam across
    // dark grass and one across a white roof each stay in their own palette
    rgb *= 1.0 - gridDark * voxelSeam(vGrid);
#endif
    // WINDOW GLASS, marked per atlas texel by the mask (see GlassMask).
    // By day a thin diagonal glint crosses the panes WHILE THE VIEW MOVES
    // -- the phase is fed by the camera's own travel and the strength dies
    // within a beat of standing still, because a reflection is something
    // the viewpoint does: still camera, still glass. It lifts the texel
    // toward sky-white and leaves the art visible through it. After dark
    // the pane is LIT: the texel's own shine pattern carried into a warm
    // lamp colour, replacing the shaded answer above -- so a lit window
    // ignores the sun, every shadow and the hour's tint, exactly as a
    // window with a lamp behind it does.
    // glassOn gates the whole thing per DRAW: the mask is shaped like the
    // tileset atlas, and only meshes textured FROM that atlas may consult
    // it -- a character samples its own sprite sheet, whose coordinates
    // land on the mask's pane rectangles by accident and would stripe the
    // cast with lamplight at night.
    float glass = Texel(glassMask, tc).a * glassOn;
    if (glass > 0.0) {
      // the sweep lives in the PANE's own space (atlas texels), not the
      // screen's: a pattern anchored to the screen has the world sliding
      // through it at zoom speed whenever the camera pans, which strobed --
      // worst where the pan and the phase ran opposite ways. Anchored to
      // the glass, panning moves nothing; only the phase does, a fraction
      // of a texel per step, the same in every walking direction.
      float sweep = sin(tc.x * glassSize.x * 0.8 - glassPhase);
      float glint = pow(max(sweep, 0.0), 20.0) * 0.55 * glassGlint;
      vec3 pane = mix(rgb, vec3(0.93, 0.97, 1.0), glint * glass);
      float shine = dot(p.rgb, vec3(0.299, 0.587, 0.114));
      vec3 lamp = vec3(1.0, 0.84, 0.5) * (0.5 + 0.55 * shine);
      rgb = mix(pane, lamp, glassNight * glass);
    }
    // The hidden player is a SHAPE, not a dimmed picture of itself. Tinting
    // through `color` could only multiply the sprite's own pixels, which
    // darkens each one by its own amount and keeps the character's internal
    // detail; replacing the colour outright is what makes it read as one
    // solid silhouette. Last in the chain, so neither the sun nor a voxel
    // seam can mottle it.
    rgb = mix(rgb, fogColor, vFog);
    rgb = mix(rgb, weatherHazeColor, vWeatherFog);
    // Emissive cloud interior, not a world/sky flash. Existing density gives
    // the patch texture; alpha and cloud occlusion are deliberately unchanged.
    if (cloudShape.z > 0.0) {
      rgb += vec3(0.66, 0.77, 1.0) * vCloudLightning
           * (0.65 + 0.35 * p.r) * (1.0 - vFog);
    }
    rgb = mix(rgb, ghostColor, ghost);
    return vec4(rgb, mix(1.0, p.a, texelAlpha)) * color;
  }
#endif