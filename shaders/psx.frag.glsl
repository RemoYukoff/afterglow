// PlayStation 1: 320x240, color de 15 bits (RGB555) y el ordered dithering
// que el GPU metia para disimular el bandeo — la textura de tablerito
// caracteristica de la consola, visible sobre todo en degradados.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const vec2 PSX_RES = vec2(320.0, 240.0);

float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x / 2.0 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
  return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void main() {
  vec2 cell = floor(vUv * PSX_RES);
  vec3 color = texture2D(uVideo, (cell + 0.5) / PSX_RES).rgb;

  // Dither fijo por pixel (una LSB de amplitud) y truncado a RGB555.
  float dither = bayer4(cell) - 0.5;
  color = floor(clamp(color + dither / 31.0, 0.0, 1.0) * 31.0 + 0.5) / 31.0;

  gl_FragColor = vec4(color, 1.0);
}
