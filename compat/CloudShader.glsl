// Cloud-only program: every parameter is supplied by CloudPackets or the host.

  varying float vShade;
  varying float vFacadeBack;
  varying float vFog;
  varying float vCloudLightning;
  varying float vStormFront;
  varying float vStormMass;
  uniform LOVE_HIGHP_OR_MEDIUMP vec4 cloudMorph; // consistent GLES precision
#ifdef VERTEX
  uniform vec4 cloudLightning; // world X/Z, inverse radius, envelope (vertex-only)
  uniform vec4 stormFront; // world X/Z, inverse radius, storm strength (vertex-only)
  uniform vec2 stormAxis; // fixed world-space direction of travel
  uniform float stormCanopy; // local interior overcast, smoothly driven by the moving bank
  uniform vec2 stormFinish; // interior gap fill, aged regional bank readiness
  uniform mat4 vp;
  const mat4 model = mat4(1.0);
  uniform vec3 eye;
  uniform vec4 fogInfo;       // density, start, heightK; density 0 = clear
  attribute float VertexShade;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Values below -2 encode upward-facing authored roof surfaces. The
    // ordinary negative range remains the existing south-facade marker.
    float roofSurface = step(VertexShade, -1.5);
    vShade = abs(VertexShade) - roofSurface * 2.0;
    vec4 w = model * vertex_position;
    // All four vertices of a marked facade lie on one Z plane, so this is
    // constant across its fragments. Work it out here where `eye` belongs;
    // the pixel stage only needs the yes/no result.
    float facadeSurface = step(VertexShade, -0.0001) * (1.0 - roofSurface);
    vFacadeBack = facadeSurface * step(eye.z, w.z - 0.0001)
                + roofSurface * step(eye.y, w.y - 0.0001);
    // Distance haze is evaluated in the uncurved world. The cloud deck uses
    // this to disappear into the horizon instead of exposing its far edge.
    vFog = 0.0;
    if (fogInfo.x > 0.0) {
      float fogRun = max(0.0, length(w.xyz - eye) - fogInfo.y);
      vFog = (1.0 - exp(-fogInfo.x * fogRun))
             * exp(-max(w.y, 0.0) * fogInfo.z);
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
  uniform vec3 dayTint;       // the hour's light on the world; 1,1,1 = noon
  uniform vec3 fogColor;
  uniform float alphaCut;
  uniform vec4 cloudShape;    // evolution A/B weights, amplitude, steps
  uniform vec2 cloudMaterial; // authored density cutoff and softness
  uniform vec3 cloudColor;    // reconstructed underside colour
  uniform vec3 cloudLight;    // time-of-day underside illumination, neutral at noon
  uniform float cloudFade;    // 0 normally; storm-only alpha reduction
  uniform float cloudOvercast; // storm mass blocks the sky behind this deck
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
    // the hour's tint multiplies like the sun terms do: it is LIGHT, the
    // same warm or moonlit cast on every surface, not a palette swap
    vec3 litRgb = p.rgb * vShade * dayTint;
    vec3 rgb = litRgb;
    rgb = mix(rgb, fogColor, vFog);
    // Emissive cloud interior, not a world/sky flash. Existing density gives
    // the patch texture; alpha and cloud occlusion are deliberately unchanged.
    if (cloudShape.z > 0.0) {
      rgb += vec3(0.66, 0.77, 1.0) * vCloudLightning
           * (0.65 + 0.35 * p.r) * (1.0 - vFog);
    }
    return vec4(rgb, p.a) * color;
  }
#endif
