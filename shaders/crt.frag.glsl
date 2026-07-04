// CRT post-effect inspired by Timothy Lottes' public-domain "crt-lottes" shader
// (https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-lottes-fast.glsl),
// adapted for arbitrary video content instead of low-res pixel art.
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const float CURVATURE_X = 0.03;
const float CURVATURE_Y = 0.02;
const float SCANLINE_STRENGTH = 0.08;
const float SCANLINE_SCROLL = 1.0; // pixeles por segundo: deriva vertical tipo TV vieja
const float MASK_DARK = 0.82;
const float ABERRATION = 0.0011;
const float NOISE_AMOUNT_PRE = 0.045; // grano antes del blur (se funde con la rejilla)
const float NOISE_AMOUNT_POST = 0.025; // grano despues del blur (queda nitido encima)
const float BLUR_SPREAD = 1.4; // separacion entre muestras del blur general, en texels

// Rejilla de celdas de fosforo: celdas ligeramente mas altas que anchas,
// brillantes en el centro y apagadas hacia el borde (glow suave, no un
// recorte plano con un borde duro).
const vec2 GRID_CELL = vec2(7.2, 9.9);
const float GRID_DARK = 0.02;
const float GRID_FALLOFF = 2.6;
const float GRID_TONE = 2.0 / (1.0 + GRID_DARK);

// La distorsion de barril estira mas las esquinas que los bordes (el punto
// (1,1) es siempre el que mas se estira). Dividiendo por ese estiramiento
// maximo "reencuadramos" la imagen para que las esquinas vuelvan a tocar
// justo el borde del cuadro, sin dejar huecos negros ni recortar contenido.
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

// Aperture-grille phosphor mask (Trinitron-style RGB stripes).
vec3 apertureMask(float xPixel) {
  float m = mod(xPixel, GRID_CELL.x);
  if (m < GRID_CELL.x / 3.0) return vec3(1.0, MASK_DARK, MASK_DARK);
  if (m < GRID_CELL.x * 2.0 / 3.0) return vec3(MASK_DARK, 1.0, MASK_DARK);
  return vec3(MASK_DARK, MASK_DARK, 1.0);
}

float rand(vec2 co) {
  return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

// Brillo por celda: coseno alzado en cada eje (1.0 en el centro, 0.0 en el
// borde) combinado en un glow rectangular, sin corte plano ni borde duro.
float pixelGrid(vec2 pixelCoord) {
  vec2 cellUv = fract(pixelCoord / GRID_CELL) * 2.0 - 1.0;
  vec2 falloff = cos(clamp(cellUv, -1.0, 1.0) * 1.5707963);
  float shade = pow(falloff.x * falloff.y, GRID_FALLOFF);
  return mix(GRID_DARK, 1.0, shade);
}

// Calcula scanline + mascara + rejilla de fosforo para un uv puntual.
// Se llama varias veces con pequenos desplazamientos (ver main) para
// fundir cada celda con sus vecinas, como el desenfoque optico de una
// pantalla CRT real que no existe al renderizar en pantallas nuevas.
vec3 shadeAt(vec2 uv) {
  vec3 raw = vec3(
    texture2D(uVideo, uv + vec2(ABERRATION, 0.0)).r,
    texture2D(uVideo, uv).g,
    texture2D(uVideo, uv - vec2(ABERRATION, 0.0)).b
  );
  vec3 color = toLinear(raw);

  // Scanlines: cosine-windowed line profile, computed in linear light,
  // with exposure compensation so the average brightness is preserved.
  float scanPhase = fract(uv.y * uResolution.y - uTime * SCANLINE_SCROLL) * 6.28318530718;
  float scan = mix(1.0, cos(scanPhase) * 0.5 + 0.5, SCANLINE_STRENGTH);
  float scanTone = 1.0 / (1.0 - SCANLINE_STRENGTH * 0.5);
  color *= scan * scanTone;

  // Aperture-grille mask, likewise exposure-compensated.
  vec3 mask = apertureMask(uv.x * uResolution.x);
  float maskTone = 3.0 / (1.0 + 2.0 * MASK_DARK);
  color *= mask * maskTone;

  // Gap oscuro entre cada celda de fosforo, horizontal y vertical.
  float grid = pixelGrid(uv * uResolution);
  color *= grid * GRID_TONE;

  // El grano pre-blur se suma despues de la rejilla para que el propio
  // blur lo funda con ella, rompiendo su regularidad en vez de quedar
  // como una capa de ruido nitida encima de un patron perfecto.
  float noisePre = (rand(uv + fract(uTime)) - 0.5) * NOISE_AMOUNT_PRE;
  color += noisePre;

  return color;
}

void main() {
  vec2 uv = clamp(warp(vUv), 0.0, 1.0);
  vec2 texel = 1.0 / uResolution;
  vec2 dx = vec2(texel.x * BLUR_SPREAD, 0.0);
  vec2 dy = vec2(0.0, texel.y * BLUR_SPREAD);

  vec3 color = shadeAt(uv) * 0.4
    + shadeAt(uv + dx) * 0.15
    + shadeAt(uv - dx) * 0.15
    + shadeAt(uv + dy) * 0.15
    + shadeAt(uv - dy) * 0.15;

  vec2 vigUv = uv - 0.5;
  float vig = 1.0 - dot(vigUv, vigUv) * 0.55;
  color *= vig;

  color = toSrgb(clamp(color, 0.0, 1.0));

  float noisePost = (rand(uv * 1.37 + fract(uTime) * 1.7) - 0.5) * NOISE_AMOUNT_POST;
  color += noisePost;

  gl_FragColor = vec4(color, 1.0);
}
