// Game Boy: pixelado grueso, cuantizado a 4 tonos de verde DMG
// con ordered dithering (matriz de Bayer generada algebraicamente).
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x / 2.0 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
  return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void main() {
  float pixelSize = 4.0;
  vec2 pixelUv = floor(vUv * uResolution / pixelSize) * pixelSize / uResolution;

  vec3 src = texture2D(uVideo, pixelUv).rgb;
  float lum = dot(src, vec3(0.299, 0.587, 0.114));

  vec3 palette0 = vec3(0.06, 0.22, 0.06);
  vec3 palette1 = vec3(0.19, 0.38, 0.19);
  vec3 palette2 = vec3(0.55, 0.67, 0.06);
  vec3 palette3 = vec3(0.61, 0.74, 0.06);

  float dither = bayer4(vUv * uResolution / pixelSize) - 0.5;
  float shaded = clamp(lum + dither * 0.28, 0.0, 1.0);

  vec3 color;
  if (shaded < 0.25) color = palette0;
  else if (shaded < 0.5) color = palette1;
  else if (shaded < 0.75) color = palette2;
  else color = palette3;

  gl_FragColor = vec4(color, 1.0);
}
