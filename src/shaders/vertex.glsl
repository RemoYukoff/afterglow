attribute vec2 aPosition;
varying vec2 vUv;

void main() {
  // V is flipped here, not at upload: asking for UNPACK_FLIP_Y_WEBGL when
  // uploading <video> frames can knock Chrome off its GPU-to-GPU fast path.
  vUv = vec2(aPosition.x, -aPosition.y) * 0.5 + 0.5;
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
