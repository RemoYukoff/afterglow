// Realistic single-pass CRT, modeled on how the real hardware works:
//  - the image is resampled to a low-resolution virtual source
//    (SRC_LINES scanlines, like a real NTSC/PAL signal)
//  - each line is drawn with a Gaussian beam whose thickness depends on
//    brightness: bright areas "fatten" and fill the gap between lines
//  - the signal is bandwidth-limited: luma is filtered lightly, chroma
//    heavily, and chroma also arrives late (composite bleed to the right)
//  - interlacing: the field alternates at ~60 Hz and the line raster jitters
//  - the beam loses focus toward edges and corners
//  - the mask (aperture grille) is fixed to the glass, not to the image
//  - radial misconvergence, halation, overscan, vignette, curvature,
//    SMPTE C phosphors with illuminant-C white, noise and 60 Hz flicker
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

// ---- virtual source --------------------------------------------------------
const float SRC_LINES = 360.0;   // visible scanlines (fewer = more pronounced)
const float H_SOFT = 0.75;       // horizontal softening of the signal, in virtual px
const float CHROMA_SPREAD = 2.4; // chroma filtering radius, in virtual px
const float CHROMA_BLEED = 0.8;  // how much of the chroma comes from the blurred version
const float CHROMA_DELAY = 0.7;  // chroma decodes late: shift to the right

// ---- beam ------------------------------------------------------------------
// Sigma of the beam's Gaussian profile, in line units. Thickness grows with
// the channel's brightness: this is the CRT's characteristic "bloom", and it
// makes scanlines stand out in dark areas and almost vanish in bright ones.
const float BEAM_MIN = 0.2;
const float BEAM_MAX = 0.5;
const float EDGE_DEFOCUS = 0.8;  // focus loss toward the edges (x1.4 at the corner)

// ---- analog life -----------------------------------------------------------
// Off by default: on a real tube, phosphor persistence blended the fields
// and the raster looked stable; recreated at 60 fps on an LCD they read as
// shaking, not as interlacing. Raise them for the "analog signal in bad
// shape" look (0.5-1.0 and 0.1-0.2 respectively).
const float INTERLACE = 0.0;     // interlace twitter: the raster alternates at ~60 Hz
const float JITTER = 0.0;        // per-line horizontal jitter, in virtual px
const float FLICKER = 0.025;     // 60 Hz refresh flicker
const float NOISE = 0.012;       // analog grain (also dithers the gradients)

// ---- mask / glass / geometry -------------------------------------------------
const float MASK_SCALE = 2.0;    // screen px per mask unit (triad = 3 units)
const float MASK_DARK = 0.55;    // how much passes through the wrong-color stripes
const float MASK_LIGHT = 1.1;    // boost of a channel's own stripe
const float MASK_COMP = 1.25;    // exposure compensation for the mask
const float MISCONVERGENCE = 0.004; // radial R/B shift (0 at center, max at corners)
const float HALATION = 0.12;     // glow diffused in the glass: lifts neighboring blacks
const float OVERSCAN = 1.04;     // TVs cropped ~4% of the frame behind the bezel
const float CURVATURE_X = 0.045;
const float CURVATURE_Y = 0.035;
const float VIGNETTE = 0.28;

// Phosphors / consumer-TV NTSC decoding: a slightly warm white and
// chromas a touch muted. Subtle on purpose; this is not a sepia filter.
const float SATURATION = 0.93;

// White point as a linear-light, luma-preserving tint. The default is
// illuminant C, the 1953 NTSC standard white, rendered unadapted on a D65
// monitor: slightly cool with a whisper of magenta. Alternatives:
//   vec3(1.02, 1.0, 0.95)      warm aged-phosphor fiction (the old default)
//   vec3(0.846, 1.011, 1.344)  9300 K — factory white of many consumer sets
const vec3 WHITE_TINT = vec3(1.051, 0.975, 1.100);

// SMPTE C phosphor colorimetry: broadcasts were mastered for SMPTE RP 145
// phosphors, not sRGB's primaries, so the same signal showed systematically
// shifted colors — reds toward orange, greens a touch less acid. Derived as
// RGB(SMPTE C) -> XYZ (D65 white) -> sRGB and applied in linear light.
// White maps to white (each math ROW sums to 1); the white point stays
// WHITE_TINT's job. Note GLSL fills mat3 by COLUMNS: the math rows are
// (0.9396, 0.0502, 0.0103) / (0.0178, 0.9658, 0.0164) / (-0.0016, -0.0044, 1.0060).
const mat3 SMPTEC_TO_SRGB = mat3(
   0.9396,  0.0178, -0.0016,
   0.0502,  0.9658, -0.0044,
   0.0103,  0.0164,  1.0060
);

// Barrel distortion stretches the corners more than the edges (the point
// (1,1) is always the one stretched the most). Dividing by that maximum
// stretch "reframes" the image so the corners touch exactly the edge of
// the frame again, leaving no black gaps and cropping no content.
const vec2 CORNER_STRETCH = vec2(1.0 + CURVATURE_X, 1.0 + CURVATURE_Y);

vec2 warp(vec2 uv) {
  vec2 pos = uv * 2.0 - 1.0;
  pos *= vec2(
    1.0 + pos.y * pos.y * CURVATURE_X,
    1.0 + pos.x * pos.x * CURVATURE_Y
  );
  pos /= CORNER_STRETCH;
  return pos * 0.5 + 0.5;
}

float toLinear1(float c) {
  return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
vec3 toLinear(vec3 c) {
  return vec3(toLinear1(c.r), toLinear1(c.g), toLinear1(c.b));
}

float toSrgb1(float c) {
  return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
vec3 toSrgb(vec3 c) {
  return vec3(toSrgb1(c.r), toSrgb1(c.g), toSrgb1(c.b));
}

float rand(vec2 co) {
  return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

// One line's signal at a point: 3 horizontal taps. The filtering happens in
// the signal (gamma) domain, just like in real analog hardware.
vec3 tapsH(vec2 posV, vec2 srcRes, float defocus) {
  vec2 uv = posV / srcRes;
  vec2 o = vec2(H_SOFT * defocus / srcRes.x, 0.0);
  return texture2D(uVideo, uv).rgb * 0.5
       + texture2D(uVideo, uv - o).rgb * 0.25
       + texture2D(uVideo, uv + o).rgb * 0.25;
}

// Color of one scanline: sharp luma with per-channel misconvergence, chroma
// taken from a blurrier version shifted slightly to the right (less
// bandwidth plus decoding delay, like a composite input). Returns linear
// light, ready for the beam.
vec3 fetchLine(vec2 posV, vec2 convV, vec2 srcRes, float defocus) {
  vec3 sharp = vec3(
    tapsH(posV + convV, srcRes, defocus).r,
    tapsH(posV, srcRes, defocus).g,
    tapsH(posV - convV, srcRes, defocus).b
  );
  vec2 spread = vec2(CHROMA_SPREAD * defocus, 0.0);
  vec2 delay = vec2(CHROMA_DELAY, 0.0);
  vec3 wide = 0.5 * (texture2D(uVideo, (posV + delay - spread) / srcRes).rgb
                   + texture2D(uVideo, (posV + delay + spread) / srcRes).rgb);
  float ySharp = dot(sharp, vec3(0.299, 0.587, 0.114));
  float yWide = dot(wide, vec3(0.299, 0.587, 0.114));
  // wide + (ySharp - yWide) = blurred chroma but with the sharp brightness
  vec3 mixed = mix(sharp, wide + (ySharp - yWide), CHROMA_BLEED);
  return toLinear(clamp(mixed, 0.0, 1.0));
}

// Beam weight at distance d (in lines) from the line center, per channel.
// Normalized Gaussian: the area under the curve does not depend on the
// thickness, like the real beam, whose total energy is set by the current
// and not by the focus. minSig keeps the beam from being thinner than the
// output resolution can resolve.
vec3 beamWeight(float d, vec3 c, float minSig, float defocus) {
  vec3 sig = max(mix(vec3(BEAM_MIN), vec3(BEAM_MAX), clamp(c, 0.0, 1.0)) * defocus, vec3(minSig));
  vec3 x = vec3(d) / sig;
  return exp(-0.5 * x * x) / (sig * 2.50662827);
}

// Aperture grille (Trinitron): continuous vertical RGB stripes, with no
// vertical structure of its own — the vertical axis is left entirely to
// the scanlines, with no interference between the two patterns. p comes
// in mask units (screen px / MASK_SCALE).
vec3 apertureGrille(vec2 p) {
  float px = fract(p.x / 3.0);
  vec3 mask = vec3(MASK_DARK);
  if (px < 1.0 / 3.0) mask.r = MASK_LIGHT;
  else if (px < 2.0 / 3.0) mask.g = MASK_LIGHT;
  else mask.b = MASK_LIGHT;
  return mask;
}

void main() {
  vec2 uv = warp(vUv);

  // Overscan: the screen shows slightly less than the full frame.
  vec2 srcUv = 0.5 + (uv - 0.5) / OVERSCAN;

  // Virtual source with square pixels: columns follow the actual aspect ratio.
  vec2 srcRes = vec2(SRC_LINES * uResolution.x / uResolution.y, SRC_LINES);
  vec2 pos = srcUv * srcRes;

  // Interlacing: each field (~60 Hz) the raster alternates phase by half a
  // line, but each line still shows the content of ITS position: the image
  // does not shift, only the structure trembles (the 480i "twitter").
  float field = step(0.5, fract(uTime * 30.0));
  float phase = (field - 0.5) * 0.5 * INTERLACE;

  // The two nearest scanlines (centers at k + 0.5 + phase).
  float lineA = floor(pos.y - 0.5 - phase) + 0.5 + phase;
  float dA = pos.y - lineA;

  // Per-line horizontal jitter: the deflection was never perfect.
  float tick = floor(uTime * 60.0);
  pos.x += (rand(vec2(lineA * 0.017, tick * 0.13)) - 0.5) * JITTER;

  // Beam focus degrades toward edges and corners.
  vec2 radial = uv - 0.5;
  float defocus = 1.0 + EDGE_DEFOCUS * dot(radial, radial);

  // Radial misconvergence in virtual px: grows with the square of the
  // distance from the center, zero where the eye looks the most.
  vec2 convV = radial * dot(radial, radial) * MISCONVERGENCE * srcRes;

  vec3 colA = fetchLine(vec2(pos.x, lineA), convV, srcRes, defocus);
  vec3 colB = fetchLine(vec2(pos.x, lineA + 1.0), convV, srcRes, defocus);

  float minSig = 0.6 * SRC_LINES / uResolution.y;
  vec3 color = colA * beamWeight(dA, colA, minSig, defocus)
             + colB * beamWeight(1.0 - dA, colB, minSig, defocus);

  // Mask fixed to the glass: uses the physical pixel, not the warped image.
  color *= apertureGrille(gl_FragCoord.xy / MASK_SCALE) * MASK_COMP;

  // Halation: some of the light bounces inside the glass and comes back
  // diffuse. Added after the mask because it no longer respects the
  // phosphors. 8 taps in two rings (near cross + farther diagonals) so the
  // halo is continuous: with few distant taps, white text on a dark
  // background looked like discrete ghost copies above and below.
  vec2 h1 = 1.6 / srcRes;
  vec2 h2 = 2.3 / srcRes;
  vec3 glow = 0.125 * (
      texture2D(uVideo, srcUv + vec2(h1.x, 0.0)).rgb
    + texture2D(uVideo, srcUv - vec2(h1.x, 0.0)).rgb
    + texture2D(uVideo, srcUv + vec2(0.0, h1.y)).rgb
    + texture2D(uVideo, srcUv - vec2(0.0, h1.y)).rgb
    + texture2D(uVideo, srcUv + h2).rgb
    + texture2D(uVideo, srcUv - h2).rgb
    + texture2D(uVideo, srcUv + vec2(h2.x, -h2.y)).rgb
    + texture2D(uVideo, srcUv + vec2(-h2.x, h2.y)).rgb);
  color += toLinear(glow) * HALATION;

  // Phosphors / consumer decoding: desaturate slightly, set the white
  // point, then map from the tube's SMPTE C phosphor space to the monitor.
  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = mix(vec3(luma), color, SATURATION) * WHITE_TINT;
  color = SMPTEC_TO_SRGB * color;

  float vig = 1.0 - dot(radial, radial) * VIGNETTE;
  color *= vig;

  // Refresh flicker + live analog grain.
  color *= 1.0 - FLICKER * (0.5 + 0.5 * sin(uTime * 376.991));
  color += (rand(uv + fract(uTime)) - 0.5) * NOISE;

  gl_FragColor = vec4(toSrgb(clamp(color, 0.0, 1.0)), 1.0);
}
