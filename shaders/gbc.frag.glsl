// Game Boy Color: pixel gordo con color RGB555 (5 bits por canal, la
// paleta fisica de la consola) y pantalla TFT reflectiva sin backlight:
// negros lavados, colores apagados con tinte verdoso y la rejilla de
// pixeles bien visible. La grilla usa mas lineas que las 144 reales y
// promedia el area de cada celda (filtro de caja): con muestreo puntual
// a 144 lineas el texto del video se vuelve ilegible.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const float GBC_LINES = 216.0; // filas de la grilla; las columnas salen del aspecto

void main() {
  vec2 res = vec2(GBC_LINES * uResolution.x / uResolution.y, GBC_LINES);
  vec2 cell = floor(vUv * res);

  // Filtro de caja: 4 muestras en los cuartos de la celda. Un trazo fino
  // siempre cae cerca de alguna, en vez de existir solo si pasa por el centro.
  vec2 base = (cell + 0.5) / res;
  vec2 q = 0.25 / res;
  vec3 color = 0.25 * (texture2D(uVideo, base + q).rgb
                     + texture2D(uVideo, base - q).rgb
                     + texture2D(uVideo, base + vec2(q.x, -q.y)).rgb
                     + texture2D(uVideo, base + vec2(-q.x, q.y)).rgb);

  // RGB555: 32 niveles por canal, todo lo que la consola podia mostrar.
  color = floor(color * 31.0 + 0.5) / 31.0;

  // TFT reflectiva sin luz propia: rango dinamico corto (el negro es gris,
  // el blanco nunca deslumbra) y saturacion contenida.
  float lum = dot(color, vec3(0.299, 0.587, 0.114));
  color = mix(vec3(lum), color, 0.8);
  color = color * 0.72 + 0.16;
  color *= vec3(0.98, 1.0, 0.92);

  // Rejilla del LCD: borde oscuro alrededor de cada pixel, en ambos ejes.
  vec2 f = fract(vUv * res);
  vec2 g = smoothstep(0.0, 0.14, f) * (1.0 - smoothstep(0.86, 1.0, f));
  color *= mix(0.78, 1.0, g.x * g.y);

  gl_FragColor = vec4(color, 1.0);
}
