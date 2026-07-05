// Game Boy: fine pixelation, quantized to 6 DMG green tones
// with ordered dithering (algebraically generated Bayer matrix).
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
  float pixelSize = 3.0;
  vec2 pixelUv = floor(vUv * uResolution / pixelSize) * pixelSize / uResolution;

  vec3 src = texture2D(uVideo, pixelUv).rgb;
  float lum = dot(src, vec3(0.299, 0.587, 0.114));

  vec3 palette0 = vec3(0.043, 0.161, 0.043);
  vec3 palette1 = vec3(0.098, 0.235, 0.078);
  vec3 palette2 = vec3(0.188, 0.384, 0.188);
  vec3 palette3 = vec3(0.35, 0.5, 0.118);
  vec3 palette4 = vec3(0.545, 0.675, 0.059);
  vec3 palette5 = vec3(0.608, 0.737, 0.059);

  float dither = bayer4(vUv * uResolution / pixelSize) - 0.5;
  float shaded = clamp(lum + dither * 0.19, 0.0, 1.0);

  vec3 color;
  if (shaded < 1.0 / 6.0) color = palette0;
  else if (shaded < 2.0 / 6.0) color = palette1;
  else if (shaded < 3.0 / 6.0) color = palette2;
  else if (shaded < 4.0 / 6.0) color = palette3;
  else if (shaded < 5.0 / 6.0) color = palette4;
  else color = palette5;

  gl_FragColor = vec4(color, 1.0);
}
