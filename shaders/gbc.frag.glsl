// Game Boy Color: resolucion real de 160x144, color RGB555 (5 bits por
// canal, la paleta fisica de la consola) y pantalla TFT reflectiva sin
// backlight: negros lavados, colores apagados con tinte verdoso y la
// rejilla de pixeles bien visible.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const vec2 GBC_RES = vec2(160.0, 144.0);

void main() {
  vec2 cell = floor(vUv * GBC_RES);
  vec3 color = texture2D(uVideo, (cell + 0.5) / GBC_RES).rgb;

  // RGB555: 32 niveles por canal, todo lo que la consola podia mostrar.
  color = floor(color * 31.0 + 0.5) / 31.0;

  // TFT reflectiva sin luz propia: rango dinamico corto (el negro es gris,
  // el blanco nunca deslumbra) y saturacion contenida.
  float lum = dot(color, vec3(0.299, 0.587, 0.114));
  color = mix(vec3(lum), color, 0.8);
  color = color * 0.72 + 0.16;
  color *= vec3(0.98, 1.0, 0.92);

  // Rejilla del LCD: borde oscuro alrededor de cada pixel, en ambos ejes.
  vec2 f = fract(vUv * GBC_RES);
  vec2 g = smoothstep(0.0, 0.14, f) * (1.0 - smoothstep(0.86, 1.0, f));
  color *= mix(0.78, 1.0, g.x * g.y);

  gl_FragColor = vec4(color, 1.0);
}
