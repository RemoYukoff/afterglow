# Afterglow

Retro display filters for any video in your browser: CRT, Game Boy, Game Boy Color, Virtual Boy, and PS1, rendered locally in real time with WebGL.

![Afterglow CRT filter](store-assets/screenshot-1-crt.jpg)

## Filters

- **CRT** — a physically modeled tube, not an overlay texture: real scanlines drawn by a Gaussian beam that blooms with brightness, a Trinitron-style aperture grille fixed to the glass, composite chroma bleed and delay, halation, radial misconvergence, edge defocus, barrel curvature, overscan, and warm consumer phosphors. Every parameter is a documented constant at the top of [`shaders/crt.frag.glsl`](shaders/crt.frag.glsl).
- **Game Boy** — 6 shades of DMG green with ordered (Bayer) dithering.
- **Game Boy Color** — RGB555 color through an unlit reflective TFT: washed blacks, muted tones, visible pixel grid, hardware-style point sampling.
- **Virtual Boy** — 384×224 red LEDs on absolute black, discrete brightness levels, LED row gaps.
- **PS1** — 320×240, 15-bit color, and the GPU's characteristic checkerboard dithering.

Custom shaders are supported too: paste any GLSL fragment shader in the popup and it becomes a new channel. Shaders receive `uVideo` (sampler2D), `uTime` (float), `uResolution` (vec2), and `vUv` (vec2).

## How it works

On regular players (YouTube and most sites), the popup injects a content script — only into the tab you invoked it on (`activeTab` + `scripting`, no broad host permissions) — which mounts a WebGL canvas over the video and renders it through the selected shader.

Players that protect their frames (DRM) yield only black pixels to any read. Afterglow detects this (including the tricky enable-while-paused case, which is re-checked once playback starts) and points you to **Capture Mode**: a dedicated viewer window that captures the tab and applies the filter there, forwarding your keyboard and clicks back to the player so space, arrows, and fullscreen keep working. Audio stays in the original tab.

Everything runs locally. Nothing is recorded, stored, or transmitted — see [PRIVACY.md](PRIVACY.md).

## Install

**From source (developer mode):**

1. Clone this repo.
2. Open `chrome://extensions`, enable **Developer mode**.
3. **Load unpacked** → select the repo folder.

**From a release:** download `afterglow-extension.zip` from the latest [Release](../../releases), unzip it, and load the folder the same way.

## Development

The repo ships a hot-reloading shader test bench so you can edit `.glsl` files and see the result instantly, without reloading the extension:

```
node test/server.js
```

Then open `http://localhost:8123/test/`. Put any frame you want to test against at `test/test.png`. The page re-reads the shaders from disk every 400 ms: save a file and it recompiles live, keeping the last good version (and showing the compiler log) on errors.

- Keys `1-9` switch shaders, `space` freezes `uTime`, `O` overlays the original image.
- `?shader=name` adds any extra shader from `shaders/` as a channel.
- `test/promo.html?shader=name` renders the store screenshots (procedural test card, exact 1280×800).

## Releases

CI packages the extension zip as an artifact on every push. Pushing a `vX.Y.Z` tag stamps that version into the manifest, attaches the zip to a GitHub Release, and — when the `CHROME_*` secrets are configured — submits it to the Chrome Web Store automatically. See [`.github/workflows/build.yml`](.github/workflows/build.yml).

## Credits

The CRT shader is inspired by Timothy Lottes' public-domain [crt-lottes](https://github.com/libretro/glsl-shaders/blob/master/crt/shaders/crt-lottes-fast.glsl), rebuilt around how the actual hardware behaves.
