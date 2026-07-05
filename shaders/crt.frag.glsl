// CRT realista en un solo pase, inspirado en el "crt-lottes" de Timothy
// Lottes (dominio publico) y en como funciona el hardware de verdad:
//  - la imagen se re-muestrea a una fuente virtual de baja resolucion
//    (SRC_LINES lineas de escaneo, como una senal NTSC/PAL real)
//  - cada linea se dibuja con un haz gaussiano cuyo grosor depende del
//    brillo: las zonas claras "engordan" y rellenan el gap entre lineas
//  - la senal tiene ancho de banda limitado: la luma se filtra poco y el
//    croma mucho y ademas llega tarde (sangrado composite hacia la derecha)
//  - entrelazado: el campo alterna a ~60 Hz y la trama de lineas tiembla
//  - el haz pierde foco hacia bordes y esquinas
//  - la mascara (rejilla de apertura) esta fija al vidrio, no a la imagen
//  - desconvergencia radial, halation, overscan, vineta, curvatura,
//    fosforos calidos, ruido y flicker de 60 Hz
precision highp float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

// ---- fuente virtual --------------------------------------------------------
const float SRC_LINES = 360.0;   // lineas de escaneo visibles (menos = mas marcadas)
const float H_SOFT = 0.75;       // suavizado horizontal de la senal, en px virtuales
const float CHROMA_SPREAD = 2.4; // radio del filtrado del croma, en px virtuales
const float CHROMA_BLEED = 0.8;  // cuanto del croma viene de la version borrosa
const float CHROMA_DELAY = 0.7;  // el croma se decodifica tarde: corrimiento a la derecha

// ---- haz -------------------------------------------------------------------
// Sigma del perfil gaussiano del haz, en unidades de linea. El grosor crece
// con el brillo del canal: es el "bloom" caracteristico del CRT, y hace que
// las scanlines se noten en zonas oscuras y casi desaparezcan en las claras.
const float BEAM_MIN = 0.2;
const float BEAM_MAX = 0.5;
const float EDGE_DEFOCUS = 0.8;  // perdida de foco hacia los bordes (x1.4 en la esquina)

// ---- vida analogica --------------------------------------------------------
// Apagados por defecto: en el tubo real la persistencia del fosforo fundia
// los campos y el raster se percibia estable; recreados a 60 fps en un LCD
// se leen como temblor, no como entrelazado. Subilos para el look "señal
// analogica en mal estado" (0.5-1.0 y 0.1-0.2 respectivamente).
const float INTERLACE = 0.0;     // twitter del entrelazado: la trama alterna a ~60 Hz
const float JITTER = 0.0;        // temblor horizontal por linea, en px virtuales
const float FLICKER = 0.025;     // parpadeo del refresco de 60 Hz
const float NOISE = 0.012;       // grano analogico (ademas dithered los degradados)

// ---- mascara / vidrio / geometria -------------------------------------------
const float MASK_SCALE = 2.0;    // px de pantalla por unidad de mascara (triada = 3 unidades)
const float MASK_DARK = 0.55;    // cuanto pasa por las franjas del color equivocado
const float MASK_LIGHT = 1.1;    // realce de la franja propia
const float MASK_COMP = 1.25;    // compensacion de exposicion por la mascara
const float MISCONVERGENCE = 0.004; // corrimiento radial R/B (0 en el centro, max en esquinas)
const float HALATION = 0.12;     // resplandor difundido en el vidrio: levanta negros vecinos
const float OVERSCAN = 1.04;     // las TVs recortaban ~4% del cuadro tras el bisel
const float CURVATURE_X = 0.045;
const float CURVATURE_Y = 0.035;
const float VIGNETTE = 0.28;

// Fosforos / decodificacion NTSC de TV consumer: blanco apenas calido y
// cromas un toque apagados. Sutil a proposito; no es un filtro sepia.
const float SATURATION = 0.93;
const vec3 WHITE_TINT = vec3(1.02, 1.0, 0.95);

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
vec3 tapsH(vec2 posV, vec2 srcRes, float defocus) {
  vec2 uv = posV / srcRes;
  vec2 o = vec2(H_SOFT * defocus / srcRes.x, 0.0);
  return texture2D(uVideo, uv).rgb * 0.5
       + texture2D(uVideo, uv - o).rgb * 0.25
       + texture2D(uVideo, uv + o).rgb * 0.25;
}

// Color de una linea de escaneo: luma nitida con desconvergencia por canal,
// croma tomado de una version mas borrosa y ligeramente corrida a la derecha
// (menos ancho de banda y retardo de decodificacion, como una entrada
// composite). Devuelve luz lineal, lista para el haz.
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
  // wide + (ySharp - yWide) = croma borroso pero con el brillo nitido
  vec3 mixed = mix(sharp, wide + (ySharp - yWide), CHROMA_BLEED);
  return toLinear(clamp(mixed, 0.0, 1.0));
}

// Peso del haz a distancia d (en lineas) del centro de la linea, por canal.
// Gaussiana normalizada: el area bajo la curva no depende del grosor, como
// el haz real, cuya energia total la fija la corriente y no el foco. minSig
// evita que el haz sea mas fino de lo que la resolucion de salida resuelve.
vec3 beamWeight(float d, vec3 c, float minSig, float defocus) {
  vec3 sig = max(mix(vec3(BEAM_MIN), vec3(BEAM_MAX), clamp(c, 0.0, 1.0)) * defocus, vec3(minSig));
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

void main() {
  vec2 uv = warp(vUv);

  // Overscan: la pantalla muestra un poco menos que el cuadro completo.
  vec2 srcUv = 0.5 + (uv - 0.5) / OVERSCAN;

  // Fuente virtual con pixeles cuadrados: columnas segun el aspecto real.
  vec2 srcRes = vec2(SRC_LINES * uResolution.x / uResolution.y, SRC_LINES);
  vec2 pos = srcUv * srcRes;

  // Entrelazado: cada campo (~60 Hz) la trama alterna de fase media linea,
  // pero cada linea sigue mostrando el contenido de SU posicion: la imagen
  // no se traslada, solo tiembla la estructura (el "twitter" del 480i).
  float field = step(0.5, fract(uTime * 30.0));
  float phase = (field - 0.5) * 0.5 * INTERLACE;

  // Las dos lineas de escaneo mas cercanas (centros en k + 0.5 + fase).
  float lineA = floor(pos.y - 0.5 - phase) + 0.5 + phase;
  float dA = pos.y - lineA;

  // Temblor horizontal por linea: la deflexion nunca fue perfecta.
  float tick = floor(uTime * 60.0);
  pos.x += (rand(vec2(lineA * 0.017, tick * 0.13)) - 0.5) * JITTER;

  // El foco del haz se degrada hacia bordes y esquinas.
  vec2 radial = uv - 0.5;
  float defocus = 1.0 + EDGE_DEFOCUS * dot(radial, radial);

  // Desconvergencia radial en px virtuales: crece con el cuadrado de la
  // distancia al centro, nula donde el ojo mira mas.
  vec2 convV = radial * dot(radial, radial) * MISCONVERGENCE * srcRes;

  vec3 colA = fetchLine(vec2(pos.x, lineA), convV, srcRes, defocus);
  vec3 colB = fetchLine(vec2(pos.x, lineA + 1.0), convV, srcRes, defocus);

  float minSig = 0.6 * SRC_LINES / uResolution.y;
  vec3 color = colA * beamWeight(dA, colA, minSig, defocus)
             + colB * beamWeight(1.0 - dA, colB, minSig, defocus);

  // Mascara fija al vidrio: usa el pixel fisico, no la imagen deformada.
  color *= apertureGrille(gl_FragCoord.xy / MASK_SCALE) * MASK_COMP;

  // Halation: parte de la luz rebota dentro del vidrio y vuelve difusa.
  // Se suma despues de la mascara porque ya no respeta los fosforos.
  // 8 taps en dos anillos (cruz cercana + diagonales mas lejos) para que el
  // halo sea continuo: con pocos taps lejanos, un texto blanco sobre fondo
  // oscuro se veia como copias fantasma discretas arriba y abajo.
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

  // Fosforos / decodificacion consumer: desaturar apenas y calentar el blanco.
  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = mix(vec3(luma), color, SATURATION) * WHITE_TINT;

  float vig = 1.0 - dot(radial, radial) * VIGNETTE;
  color *= vig;

  // Flicker del refresco + grano analogico vivo.
  color *= 1.0 - FLICKER * (0.5 + 0.5 * sin(uTime * 376.991));
  color += (rand(uv + fract(uTime)) - 0.5) * NOISE;

  gl_FragColor = vec4(toSrgb(clamp(color, 0.0, 1.0)), 1.0);
}
