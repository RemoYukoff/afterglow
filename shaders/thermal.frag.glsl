// Vision termica estilo Predator: la luminancia se mapea a una rampa
// de color azul -> violeta -> rojo -> naranja -> amarillo -> blanco.
precision mediump float;

varying vec2 vUv;
uniform sampler2D uVideo;
uniform float uTime;
uniform vec2 uResolution;

vec3 thermalRamp(float t) {
  t = clamp(t, 0.0, 1.0);
  vec3 c0 = vec3(0.0, 0.0, 0.15);
  vec3 c1 = vec3(0.35, 0.0, 0.55);
  vec3 c2 = vec3(0.85, 0.0, 0.35);
  vec3 c3 = vec3(1.0, 0.35, 0.0);
  vec3 c4 = vec3(1.0, 0.85, 0.0);
  vec3 c5 = vec3(1.0, 1.0, 0.9);

  if (t < 0.2) return mix(c0, c1, t / 0.2);
  if (t < 0.45) return mix(c1, c2, (t - 0.2) / 0.25);
  if (t < 0.7) return mix(c2, c3, (t - 0.45) / 0.25);
  if (t < 0.88) return mix(c3, c4, (t - 0.7) / 0.18);
  return mix(c4, c5, (t - 0.88) / 0.12);
}

float rand(vec2 co) {
  return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  vec3 src = texture2D(uVideo, vUv).rgb;
  float lum = dot(src, vec3(0.299, 0.587, 0.114));

  lum = clamp((lum - 0.15) / 0.7, 0.0, 1.0);
  lum = pow(lum, 0.85);

  vec3 color = thermalRamp(lum);

  float scan = sin(vUv.y * uResolution.y * 1.0) * 0.03;
  color -= scan;

  float noise = (rand(vUv * uResolution + uTime) - 0.5) * 0.02;
  color += noise;

  gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
