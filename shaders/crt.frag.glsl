// CRT post-effect inspired by Timothy Lottes' public-domain "crt-lottes" shader
// (https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-lottes-fast.glsl),
// adapted for arbitrary video content instead of low-res pixel art.
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const float CURVATURE_X = 0.04;
const float CURVATURE_Y = 0.03;
const float SCANLINE_STRENGTH = 0.15;
const float SCANLINE_SCROLL = 2.0; // pixeles por segundo: deriva vertical tipo TV vieja
const float MASK_DARK = 0.4;
// Desconvergencia radial: los tres canones convergen bien en el centro y se
// desalinean hacia bordes y esquinas (R y B empujados en direcciones radiales
// opuestas), como un CRT real. ~1.5 px de corrimiento en la esquina a 1080p.
const float MISCONVERGENCE = 0.003;
const float NOISE_AMOUNT_PRE = 0.01; // grano antes del blur (se funde con la rejilla)
const float BLUR_SPREAD = 1.; // separacion entre muestras del blur general, en texels

// Paleta de CRT viejo: menos gama de color que una pantalla moderna.
const float COLOR_LEVELS = 6.0;                  // niveles por canal (bandeo retro; el grano lo difumina)

// Rejilla de celdas de fosforo: celdas ligeramente mas altas que anchas,
// brillantes en el centro y apagadas hacia el borde (glow suave, no un
// recorte plano con un borde duro). GRID_SIZE es el unico dial de tamano:
// el alto de la celda sale del ancho por GRID_ASPECT.
const float GRID_SIZE = 5.;   // ancho de celda en pixeles
const float GRID_ASPECT = 1.3; // alto = ancho * proporcion
const vec2 GRID_CELL = vec2(GRID_SIZE, GRID_SIZE * GRID_ASPECT);
const float GRID_DARK = .0;
const float GRID_FALLOFF = 1.;
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

// Un pixel fisico solo puede mostrar un color a la vez: el video se
// muestrea una unica vez por celda de la rejilla (en el centro de la
// celda), en vez de dejar que el contenido varie con suavidad dentro de
// una misma celda como si fuera una pantalla de resolucion infinita.
// En las celdas parciales del borde el centro puede caer algo fuera de
// [0,1]; la textura del video usa CLAMP_TO_EDGE, asi que es inocuo.
vec2 cellCenterUv(vec2 uv) {
  vec2 cell = floor(uv * uResolution / GRID_CELL) + 0.5;
  return cell * GRID_CELL / uResolution;
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
  // El contenido queda congelado al color del centro de su celda: todos
  // los fragmentos de una celda leen el mismo texel del video. La
  // desconvergencia desplaza ligeramente que parte del fotograma le toca a
  // cada canal, pero sigue habiendo un solo color por celda y canal.
  vec2 videoUv = cellCenterUv(uv);
  // Crece con el cuadrado de la distancia al centro: el area central queda
  // limpia y el corrimiento aparece recien hacia bordes y esquinas.
  vec2 radial = uv - 0.5;
  vec2 converge = radial * dot(radial, radial) * MISCONVERGENCE;
  vec3 raw = vec3(
    texture2D(uVideo, videoUv + converge).r,
    texture2D(uVideo, videoUv).g,
    texture2D(uVideo, videoUv - converge).b
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

  // Grado de color "viejo CRT": desaturar un poco, calentar el blanco y
  // reducir la profundidad de color. El grano post disimula el bandeo.
  float luma = dot(color, vec3(0.299, 0.587, 0.114));
  color = floor(clamp(color, 0.0, 1.0) * COLOR_LEVELS + 0.5) / COLOR_LEVELS;


  gl_FragColor = vec4(color, 1.0);
}
