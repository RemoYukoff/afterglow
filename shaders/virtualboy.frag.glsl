// Virtual Boy: display de LEDs rojos sobre negro absoluto, 384x224. La
// consola real barria una columna de 224 LEDs con un espejo oscilante;
// aca queda la firma visual: monocromo rojo con niveles discretos de
// brillo y el gap oscuro entre filas de LEDs.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const vec2 VB_RES = vec2(384.0, 224.0);
const float LEVELS = 8.0;

void main() {
  vec2 cell = floor(vUv * VB_RES);
  vec3 src = texture2D(uVideo, (cell + 0.5) / VB_RES).rgb;
  float lum = dot(src, vec3(0.299, 0.587, 0.114));

  // Niveles discretos de brillo (PWM de los LEDs), con una gamma corta
  // para que los medios tonos no se pierdan en el negro.
  lum = floor(pow(lum, 0.85) * (LEVELS - 0.001)) / (LEVELS - 1.0);

  // Filas de LEDs: gap vertical marcado; en horizontal apenas se insinua.
  vec2 f = fract(vUv * VB_RES);
  float row = smoothstep(0.0, 0.22, f.y) * (1.0 - smoothstep(0.78, 1.0, f.y));
  float col = smoothstep(0.0, 0.08, f.x) * (1.0 - smoothstep(0.92, 1.0, f.x));
  lum *= mix(0.12, 1.0, row) * mix(0.7, 1.0, col);

  gl_FragColor = vec4(lum, lum * 0.03, lum * 0.03, 1.0);
}
