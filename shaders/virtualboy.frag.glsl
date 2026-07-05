// Virtual Boy: red LED display over absolute black, 384x224. The real
// console swept a column of 224 LEDs with an oscillating mirror; what
// remains here is the visual signature: red monochrome with discrete
// brightness levels and the dark gap between LED rows.
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

  // Discrete brightness levels (LED PWM), with a short gamma so the
  // midtones do not get lost in the black.
  lum = floor(pow(lum, 0.85) * (LEVELS - 0.001)) / (LEVELS - 1.0);

  // LED rows: pronounced vertical gap; horizontally it is barely hinted.
  vec2 f = fract(vUv * VB_RES);
  float row = smoothstep(0.0, 0.22, f.y) * (1.0 - smoothstep(0.78, 1.0, f.y));
  float col = smoothstep(0.0, 0.08, f.x) * (1.0 - smoothstep(0.92, 1.0, f.x));
  lum *= mix(0.12, 1.0, row) * mix(0.7, 1.0, col);

  gl_FragColor = vec4(lum, lum * 0.03, lum * 0.03, 1.0);
}
