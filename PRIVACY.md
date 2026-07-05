# Afterglow — Privacy Policy

**Effective date: July 5, 2026**

Afterglow is a browser extension that applies retro display filters (CRT, Game Boy, Game Boy Color, Virtual Boy, PS1) to videos playing in your browser, rendered locally in real time with WebGL.

## Data collection

Afterglow collects **no data whatsoever**.

- No personal information, browsing history, or page content is collected.
- Nothing is transmitted to any server. The extension makes no network requests beyond loading its own bundled files.
- There are no analytics, no telemetry, no accounts, and no third-party services.

## Local processing

All video processing happens locally on your device:

- The filter overlay renders the video through a WebGL shader directly in the page.
- Capture Mode uses the browser's tab-capture API to display the current tab's video, with the selected filter, in a dedicated viewer window. The capture is processed frame by frame in memory, is **never recorded, saved, or transmitted**, and ends the moment the viewer window is closed.

## Local storage

The extension stores only your preferences on your device, using the browser's extension storage: whether the filter is enabled, which filter is selected, and any custom shaders you have written. This data never leaves your browser. Uninstalling the extension removes it.

## Changes

If this policy ever changes, the updated version will be published at this same URL with a new effective date.

## Contact

Questions about this policy: remo.yukoff@gmail.com
