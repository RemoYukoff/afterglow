// Game Boy Color: chunky pixels with RGB555 color (5 bits per channel,
// the console's physical palette) and a reflective TFT screen with no
// backlight: washed-out blacks, muted colors with a greenish tint and a
// clearly visible pixel grid. The grid uses more lines than the real 144
// (with 144 the video's text is unreadable) but keeps the hardware's
// point sampling: discrete pixels, no interpolation.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

const float GBC_LINES = 216.0; // grid rows; columns follow from the aspect ratio

void main() {
  vec2 res = vec2(GBC_LINES * uResolution.x / uResolution.y, GBC_LINES);
  vec2 cell = floor(vUv * res);

  // Point sampling (nearest-neighbor), like the real hardware: the LCD
  // showed its framebuffer pixel by pixel, discrete and uninterpolated.
  // The price with high-resolution video is some shimmering in motion;
  // it is part of the chosen character.
  vec3 color = texture2D(uVideo, (cell + 0.5) / res).rgb;

  // RGB555: 32 levels per channel, all the console could display.
  color = floor(color * 31.0 + 0.5) / 31.0;

  // Reflective TFT with no light of its own: short dynamic range (black is
  // gray, white never dazzles) and restrained saturation.
  float lum = dot(color, vec3(0.299, 0.587, 0.114));
  color = mix(vec3(lum), color, 0.8);
  color = color * 0.72 + 0.16;
  color *= vec3(0.98, 1.0, 0.92);

  // LCD grid: dark border around each pixel, on both axes.
  vec2 f = fract(vUv * res);
  vec2 g = smoothstep(0.0, 0.14, f) * (1.0 - smoothstep(0.86, 1.0, f));
  color *= mix(0.78, 1.0, g.x * g.y);

  gl_FragColor = vec4(color, 1.0);
}
