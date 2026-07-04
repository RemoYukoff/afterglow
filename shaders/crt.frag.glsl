// CRT post-effect inspired by Timothy Lottes' public-domain "crt-lottes" shader
// (https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-lottes-fast.glsl),
// adapted for arbitrary video content instead of low-res pixel art.
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const float CURVATURE_X = 0.05;
const float CURVATURE_Y = 0.04;
const float SCANLINE_STRENGTH = 0.35;
const float MASK_DARK = 0.82;
const float ABERRATION = 0.0018;
const float NOISE_AMOUNT = 0.025;

vec2 warp(vec2 uv) {
  vec2 pos = uv * 2.0 - 1.0;
  pos *= vec2(
    1.0 + pos.y * pos.y * CURVATURE_X,
    1.0 + pos.x * pos.x * CURVATURE_Y
  );
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

// Aperture-grille phosphor mask (Trinitron-style RGB stripes).
vec3 apertureMask(float xPixel) {
  float m = mod(xPixel, 3.0);
  if (m < 1.0) return vec3(1.0, MASK_DARK, MASK_DARK);
  if (m < 2.0) return vec3(MASK_DARK, 1.0, MASK_DARK);
  return vec3(MASK_DARK, MASK_DARK, 1.0);
}

float rand(vec2 co) {
  return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  vec2 uv = warp(vUv);

  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  vec3 raw = vec3(
    texture2D(uVideo, uv + vec2(ABERRATION, 0.0)).r,
    texture2D(uVideo, uv).g,
    texture2D(uVideo, uv - vec2(ABERRATION, 0.0)).b
  );
  vec3 color = toLinear(raw);

  // Scanlines: cosine-windowed line profile, computed in linear light,
  // with exposure compensation so the average brightness is preserved.
  float scanPhase = fract(uv.y * uResolution.y) * 6.28318530718;
  float scan = mix(1.0, cos(scanPhase) * 0.5 + 0.5, SCANLINE_STRENGTH);
  float scanTone = 1.0 / (1.0 - SCANLINE_STRENGTH * 0.5);
  color *= scan * scanTone;

  // Aperture-grille mask, likewise exposure-compensated.
  vec3 mask = apertureMask(uv.x * uResolution.x);
  float maskTone = 3.0 / (1.0 + 2.0 * MASK_DARK);
  color *= mask * maskTone;

  vec2 vigUv = uv - 0.5;
  float vig = 1.0 - dot(vigUv, vigUv) * 0.55;
  color *= vig;

  color = toSrgb(clamp(color, 0.0, 1.0));

  float noise = (rand(uv + fract(uTime)) - 0.5) * NOISE_AMOUNT;
  color += noise;

  gl_FragColor = vec4(color, 1.0);
}
