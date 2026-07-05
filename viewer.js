(() => {
  const params = new URLSearchParams(location.search);
  const shaderKey = params.get("shader") || "crt";
  const srcTab = params.get("srcTab") ? parseInt(params.get("srcTab"), 10) : null;

  // Forwards viewer input to the player tab (remote control).
  function remote(payload) {
    if (srcTab == null || !stream) return;
    chrome.tabs.sendMessage(srcTab, { type: "CRT_REMOTE", ...payload }).catch(() => {});
  }

  function forwardKey(evtype, e) {
    remote({ kind: "key", evtype, key: e.key, code: e.code, keyCode: e.keyCode });
  }

  const VERTEX_SHADER_URL = chrome.runtime.getURL("shaders/vertex.glsl");
  const BUILTIN = {
    crt: chrome.runtime.getURL("shaders/crt.frag.glsl"),
    gameboy: chrome.runtime.getURL("shaders/gameboy.frag.glsl"),
    gbc: chrome.runtime.getURL("shaders/gbc.frag.glsl"),
    virtualboy: chrome.runtime.getURL("shaders/virtualboy.frag.glsl"),
    psx: chrome.runtime.getURL("shaders/psx.frag.glsl"),
  };

  const canvas = document.getElementById("gl");
  const startPanel = document.getElementById("start-panel");
  const startBtn = document.getElementById("start-btn");
  const errorEl = document.getElementById("error");
  const hud = document.getElementById("hud");
  const switcherEl = document.getElementById("switcher");

  const video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;

  let gl = null;
  let program = null;
  let texture = null;
  let uTime = null;
  let uResolution = null;
  let rafId = null;
  let stream = null;
  let startTime = 0;
  let vertexSrc = null;
  let currentShaderKey = shaderKey;
  let hideTimer = null;

  function setError(msg) {
    errorEl.textContent = msg || "";
  }

  async function getCustomShaders() {
    const { crtCustomShaders = [] } = await chrome.storage.local.get("crtCustomShaders");
    return crtCustomShaders;
  }

  async function loadFragmentSrc(key) {
    if (BUILTIN[key]) return fetch(BUILTIN[key]).then((r) => r.text());
    const custom = (await getCustomShaders()).find((s) => s.id === key);
    if (custom) return custom.source;
    return fetch(BUILTIN.crt).then((r) => r.text());
  }

  function compileShader(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.error("[CRT viewer] Error compiling shader:", gl.getShaderInfoLog(shader));
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  function createProgram(vertexSrc, fragmentSrc) {
    const vs = compileShader(gl.VERTEX_SHADER, vertexSrc);
    const fs = compileShader(gl.FRAGMENT_SHADER, fragmentSrc);
    if (!vs || !fs) return null;
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      console.error("[CRT viewer] Error linking program:", gl.getProgramInfoLog(prog));
      return null;
    }
    return prog;
  }

  // Recompiles and activates a shader live, without restarting the capture. The
  // position buffer and the texture are already created/bound in setupGL, so we
  // only need to rebuild the program and re-point the attribute/uniforms at it.
  async function applyShader(key) {
    const fragmentSrc = await loadFragmentSrc(key);
    const prog = createProgram(vertexSrc, fragmentSrc);
    if (!prog) {
      setError(`Could not compile shader "${key}".`);
      return false;
    }
    if (program) gl.deleteProgram(program);
    program = prog;
    gl.useProgram(program);

    const aPosition = gl.getAttribLocation(program, "aPosition");
    gl.enableVertexAttribArray(aPosition);
    gl.vertexAttribPointer(aPosition, 2, gl.FLOAT, false, 0, 0);

    uTime = gl.getUniformLocation(program, "uTime");
    uResolution = gl.getUniformLocation(program, "uResolution");

    currentShaderKey = key;
    chrome.storage.local.set({ crtShader: key });
    markActiveChip();
    setError("");
    return true;
  }

  async function setupGL() {
    gl = canvas.getContext("webgl", { preserveDrawingBuffer: false, antialias: false });
    if (!gl) throw new Error("WebGL is not available in this browser.");

    vertexSrc = await fetch(VERTEX_SHADER_URL).then((r) => r.text());

    const positionBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

    texture = gl.createTexture();
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    if (!(await applyShader(shaderKey))) throw new Error("Could not compile the initial shader.");
  }

  async function buildSwitcher() {
    const builtins = [
      { key: "crt", label: "CRT" },
      { key: "gameboy", label: "Game Boy" },
      { key: "gbc", label: "GB Color" },
      { key: "virtualboy", label: "Virtual Boy" },
      { key: "psx", label: "PS1" },
    ];
    const custom = (await getCustomShaders()).map((s) => ({ key: s.id, label: s.name }));
    const all = [...builtins, ...custom];

    switcherEl.innerHTML = "";
    all.forEach((s, i) => {
      const btn = document.createElement("button");
      btn.className = "chip";
      btn.dataset.key = s.key;
      const num = i < 9 ? `<span class="num">${i + 1}</span>` : "";
      btn.innerHTML = `${num}${s.label}`;
      btn.addEventListener("click", () => applyShader(s.key));
      switcherEl.appendChild(btn);
    });
    markActiveChip();
  }

  function markActiveChip() {
    switcherEl.querySelectorAll(".chip").forEach((c) => {
      c.classList.toggle("active", c.dataset.key === currentShaderKey);
    });
  }

  // The bar stays hidden while you watch; it only appears when you move the
  // mouse near the bottom edge (like a player's controls), so it stays out
  // of the way.
  const REVEAL_ZONE = 110; // px from the bottom where it reveals

  function showBar() {
    if (switcherEl.hidden) return;
    switcherEl.classList.remove("faded");
    if (hideTimer) clearTimeout(hideTimer);
  }

  function scheduleHide(delay) {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(() => switcherEl.classList.add("faded"), delay);
  }

  function syncCanvasSize() {
    const w = video.videoWidth || 1280;
    const h = video.videoHeight || 720;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl.viewport(0, 0, w, h);
    }
  }

  function renderFrame() {
    rafId = requestAnimationFrame(renderFrame);
    if (video.readyState < 2) return;
    syncCanvasSize();

    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);

    const elapsed = (performance.now() - startTime) / 1000;
    gl.uniform1f(uTime, elapsed);
    gl.uniform2f(uResolution, canvas.width, canvas.height);

    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  // Check in case the capture comes back black (some configs do protect tab
  // capture for DRM). We sample the captured video with a small 2D canvas;
  // if it is playing and still black, we warn.
  function warnIfBlack() {
    const probe = document.createElement("canvas");
    probe.width = 8;
    probe.height = 8;
    const ctx = probe.getContext("2d");
    try {
      ctx.drawImage(video, 0, 0, 8, 8);
      const data = ctx.getImageData(0, 0, 8, 8).data;
      let black = true;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i] > 10 || data[i + 1] > 10 || data[i + 2] > 10) {
          black = false;
          break;
        }
      }
      if (black) {
        hud.hidden = false;
        hud.textContent =
          "⚠ The capture is coming back black: this config protects capture for this DRM. Try sharing the SCREEN instead of the tab.";
      }
    } catch (_) {
      /* ignore */
    }
  }

  async function begin(mediaStream) {
    stream = mediaStream;
    video.srcObject = stream;
    try {
      await video.play();
    } catch (_) {
      /* autoplay of a muted MediaStream should not fail */
    }

    try {
      await setupGL();
    } catch (err) {
      setError(String(err.message || err));
      stopStream();
      return;
    }

    // If the captured tab closes (or the capture stops), the track ends.
    // We close this window instead of showing the panel: going back to the
    // panel would lead to manual mode (getDisplayMedia), which does show the
    // sharing banner.
    stream.getVideoTracks()[0].addEventListener("ended", () => window.close());

    startPanel.hidden = true;
    hud.hidden = false;
    const FS_HINT = "F or F11 = fullscreen";
    hud.textContent = FS_HINT;
    setTimeout(() => {
      if (hud.textContent === FS_HINT) hud.hidden = true;
    }, 4500);
    switcherEl.hidden = false;
    await buildSwitcher();
    startTime = performance.now();
    renderFrame();
    showBar();
    scheduleHide(2500); // an initial peek, then it hides
    setTimeout(warnIfBlack, 1200);
  }

  // Direct start (from the popup): consumes the tabCapture streamId, without
  // the "you are sharing" bar or the source picker.
  async function startTab(streamId) {
    setError("");
    let s;
    try {
      s = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
      });
    } catch (_) {
      // If the streamId is no good, leave the panel up for manual mode.
      setError('Direct capture could not be used. Click "Start capture" to pick the source.');
      return;
    }
    await begin(s);
  }

  // Manual fallback: Chrome's picker (shows the sharing bar).
  async function startDisplay() {
    setError("");
    let s;
    try {
      s = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: { ideal: 60 } },
        audio: false,
      });
    } catch (err) {
      setError(
        err && err.name === "NotAllowedError"
          ? "You cancelled the selection. Click again to pick the source."
          : `Could not start the capture: ${err && err.message ? err.message : err}`
      );
      return;
    }
    await begin(s);
  }

  function stopStream() {
    if (rafId) cancelAnimationFrame(rafId);
    rafId = null;
    if (stream) stream.getTracks().forEach((t) => t.stop());
    stream = null;
    video.srcObject = null;
    startPanel.hidden = false;
    hud.hidden = true;
    switcherEl.hidden = true;
    setError("The capture ended. You can start it again.");
  }

  startBtn.addEventListener("click", startDisplay);

  document.addEventListener("mousemove", (e) => {
    if (switcherEl.hidden) return;
    if (e.clientY >= window.innerHeight - REVEAL_ZONE) showBar();
    else scheduleHide(500);
  });

  // F = fullscreen (Fullscreen API). F11 (native to the window) also works.
  // Important: the window must NOT be maximized beforehand, or the player
  // may end up black. Keys 1-9 switch filters.
  document.addEventListener("keydown", (e) => {
    if (e.key === "f" || e.key === "F") {
      if (!document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {});
      else document.exitFullscreen().catch(() => {});
    } else if (/^[1-9]$/.test(e.key)) {
      const chip = switcherEl.querySelectorAll(".chip")[parseInt(e.key, 10) - 1];
      if (chip) applyShader(chip.dataset.key);
    } else {
      // Any other key (space, arrows, etc.) goes to the player.
      forwardKey("keydown", e);
    }
    showBar();
    scheduleHide(1800);
  });

  document.addEventListener("keyup", (e) => {
    if (e.key === "f" || e.key === "F" || /^[1-9]$/.test(e.key)) return;
    forwardKey("keyup", e);
  });

  // Click on the video -> click at the same position on the player
  // (play/pause). Mapped via normalized canvas coordinates.
  canvas.addEventListener("click", (e) => {
    const w = canvas.clientWidth || 1;
    const h = canvas.clientHeight || 1;
    remote({ kind: "click", u: e.offsetX / w, v: e.offsetY / h });
  });

  // Direct start if the popup passed us a tabCapture streamId (no bar, no
  // picker). Otherwise, the panel stays with the manual button (getDisplayMedia).
  const initialStreamId = params.get("streamId");
  if (initialStreamId) startTab(initialStreamId);
})();
