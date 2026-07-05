// CRT realista en un solo pase, inspirado en el "crt-lottes" de Timothy
// Lottes (dominio publico) y en como funciona el hardware de verdad:
//  - la imagen se re-muestrea a una fuente virtual de baja resolucion
//    (SRC_LINES lineas de escaneo, como una senal NTSC/PAL real)
//  - cada linea se dibuja con un haz gaussiano cuyo grosor depende del
//    brillo: las zonas claras "engordan" y rellenan el gap entre lineas
//  - la senal tiene ancho de banda limitado: la luma se filtra poco y el
//    croma mucho (el sangrado de color de una entrada composite)
//  - la mascara de ranuras (slot mask) esta fija al vidrio, no a la imagen
//  - desconvergencia radial, halation del vidrio, vineta, curvatura y
//    esquinas redondeadas del tubo
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

// ---- fuente virtual --------------------------------------------------------
const float SRC_LINES = 400.0;   // lineas de escaneo visibles (NTSC ~480; menos = mas marcadas)
const float H_SOFT = 0.7;        // suavizado horizontal de la senal, en px virtuales
const float CHROMA_SPREAD = 2.2; // radio del filtrado del croma, en px virtuales
const float CHROMA_BLEED = 0.75; // cuanto del croma viene de la version borrosa

// ---- haz -------------------------------------------------------------------
// Sigma del perfil gaussiano del haz, en unidades de linea. El grosor crece
// con el brillo del canal: es el "bloom" caracteristico del CRT, y hace que
// las scanlines se noten en zonas oscuras y casi desaparezcan en las claras.
const float BEAM_MIN = 0.24;
const float BEAM_MAX = 0.5;

// ---- mascara / vidrio / geometria -------------------------------------------
const float MASK_SCALE = 2.0;    // px de pantalla por unidad de mascara (triada = 3 unidades)
const float MASK_DARK = 0.6;     // cuanto pasa por las franjas del color equivocado
const float MASK_LIGHT = 1.1;    // realce de la franja propia
const float MASK_COMP = 1.2;     // compensacion de exposicion por la mascara
const float MISCONVERGENCE = 0.003; // corrimiento radial R/B (0 en el centro, max en esquinas)
const float HALATION = 0.08;     // resplandor difundido en el vidrio: levanta negros vecinos
const float NOISE = 0.006;       // ruido analogico sutil
const float CURVATURE_X = 0.04;
const float CURVATURE_Y = 0.03;
const float CORNER_RADIUS = 0.035; // radio de las esquinas del tubo, en uv
const float VIGNETTE = 0.25;

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

float rand(vec2 co) {
  return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

// Senal de una linea en un punto: 3 taps horizontales. El filtrado pasa en el
// dominio de la senal (gamma), igual que en el hardware analogico real.
vec3 tapsH(vec2 posV, vec2 srcRes) {
  vec2 uv = posV / srcRes;
  vec2 o = vec2(H_SOFT / srcRes.x, 0.0);
  return texture2D(uVideo, uv).rgb * 0.5
       + texture2D(uVideo, uv - o).rgb * 0.25
       + texture2D(uVideo, uv + o).rgb * 0.25;
}

// Color de una linea de escaneo: luma nitida con desconvergencia por canal,
// croma tomado de una version mas borrosa (menos ancho de banda, como una
// entrada composite). Devuelve luz lineal, lista para el haz.
vec3 fetchLine(vec2 posV, vec2 convV, vec2 srcRes) {
  vec3 sharp = vec3(
    tapsH(posV + convV, srcRes).r,
    tapsH(posV, srcRes).g,
    tapsH(posV - convV, srcRes).b
  );
  vec2 cs = vec2(CHROMA_SPREAD, 0.0);
  vec3 wide = 0.5 * (texture2D(uVideo, (posV - cs) / srcRes).rgb
                   + texture2D(uVideo, (posV + cs) / srcRes).rgb);
  float ySharp = dot(sharp, vec3(0.299, 0.587, 0.114));
  float yWide = dot(wide, vec3(0.299, 0.587, 0.114));
  // wide + (ySharp - yWide) = croma borroso pero con el brillo nitido
  vec3 mixed = mix(sharp, wide + (ySharp - yWide), CHROMA_BLEED);
  return toLinear(clamp(mixed, 0.0, 1.0));
}

// Peso del haz a distancia d (en lineas) del centro de la linea, por canal.
// Gaussiana normalizada: el area bajo la curva no depende del grosor, como
// el haz real, cuya energia total la fija la corriente y no el foco. minSig
// evita que el haz sea mas fino de lo que la resolucion de salida resuelve.
vec3 beamWeight(float d, vec3 c, float minSig) {
  vec3 sig = max(mix(vec3(BEAM_MIN), vec3(BEAM_MAX), clamp(c, 0.0, 1.0)), vec3(minSig));
  vec3 x = vec3(d) / sig;
  return exp(-0.5 * x * x) / (sig * 2.50662827);
}

// Rejilla de apertura (Trinitron): franjas RGB verticales continuas, sin
// estructura vertical propia — el eje vertical queda solo para las lineas
// de escaneo, sin interferencia entre ambos patrones. p viene en unidades
// de mascara (px de pantalla / MASK_SCALE).
vec3 apertureGrille(vec2 p) {
  float px = fract(p.x / 3.0);
  vec3 mask = vec3(MASK_DARK);
  if (px < 1.0 / 3.0) mask.r = MASK_LIGHT;
  else if (px < 2.0 / 3.0) mask.g = MASK_LIGHT;
  else mask.b = MASK_LIGHT;
  return mask;
}

// Recorte del tubo: rectangulo de esquinas redondeadas con borde apenas
// suavizado. 1.0 dentro de la pantalla, 0.0 en el bisel.
float tubeShape(vec2 uv) {
  vec2 d = abs(uv - 0.5) - (0.5 - CORNER_RADIUS);
  float dist = length(max(d, 0.0)) - CORNER_RADIUS;
  return 1.0 - smoothstep(-0.004, 0.0, dist);
}

void main() {
  vec2 uv = warp(vUv);
  float shape = tubeShape(uv);
  if (shape <= 0.0) {
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  // Fuente virtual con pixeles cuadrados: columnas segun el aspecto real.
  vec2 srcRes = vec2(SRC_LINES * uResolution.x / uResolution.y, SRC_LINES);
  vec2 pos = uv * srcRes;

  // Desconvergencia radial en px virtuales: crece con el cuadrado de la
  // distancia al centro, nula donde el ojo mira mas.
  vec2 radial = uv - 0.5;
  vec2 convV = radial * dot(radial, radial) * MISCONVERGENCE * srcRes;

  // Las dos lineas de escaneo mas cercanas (centros en k + 0.5).
  float lineA = floor(pos.y - 0.5) + 0.5;
  float dA = pos.y - lineA;

  vec3 colA = fetchLine(vec2(pos.x, lineA), convV, srcRes);
  vec3 colB = fetchLine(vec2(pos.x, lineA + 1.0), convV, srcRes);

  float minSig = 0.6 * SRC_LINES / uResolution.y;
  vec3 color = colA * beamWeight(dA, colA, minSig)
             + colB * beamWeight(1.0 - dA, colB, minSig);

  // Mascara fija al vidrio: usa el pixel fisico, no la imagen deformada.
  color *= apertureGrille(gl_FragCoord.xy / MASK_SCALE) * MASK_COMP;

  // Halation: parte de la luz rebota dentro del vidrio y vuelve difusa.
  // Se suma despues de la mascara porque ya no respeta los fosforos.
  vec2 hr = 4.0 / srcRes;
  vec3 glow = 0.25 * (texture2D(uVideo, uv + hr).rgb
                    + texture2D(uVideo, uv - hr).rgb
                    + texture2D(uVideo, uv + vec2(hr.x, -hr.y)).rgb
                    + texture2D(uVideo, uv + vec2(-hr.x, hr.y)).rgb);
  color += toLinear(glow) * HALATION;

  float vig = 1.0 - dot(radial, radial) * VIGNETTE;
  color *= vig * shape;

  color += (rand(uv + fract(uTime)) - 0.5) * NOISE;

  gl_FragColor = vec4(toSrgb(clamp(color, 0.0, 1.0)), 1.0);
}
