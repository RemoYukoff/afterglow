(() => {
  const params = new URLSearchParams(location.search);
  const shaderKey = params.get("shader") || "crt";

  const VERTEX_SHADER_URL = chrome.runtime.getURL("shaders/vertex.glsl");
  const BUILTIN = {
    crt: chrome.runtime.getURL("shaders/crt.frag.glsl"),
    thermal: chrome.runtime.getURL("shaders/thermal.frag.glsl"),
    gameboy: chrome.runtime.getURL("shaders/gameboy.frag.glsl"),
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
      console.error("[CRT viewer] Error compilando shader:", gl.getShaderInfoLog(shader));
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
      console.error("[CRT viewer] Error enlazando programa:", gl.getProgramInfoLog(prog));
      return null;
    }
    return prog;
  }

  // Recompila y activa un shader en vivo, sin reiniciar la captura. El buffer de
  // posición y la textura ya están creados/enlazados en setupGL, así que solo hay
  // que rehacer el programa y re-apuntar el atributo/uniforms al programa nuevo.
  async function applyShader(key) {
    const fragmentSrc = await loadFragmentSrc(key);
    const prog = createProgram(vertexSrc, fragmentSrc);
    if (!prog) {
      setError(`No se pudo compilar el shader "${key}".`);
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
    if (!gl) throw new Error("WebGL no disponible en este navegador.");

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

    if (!(await applyShader(shaderKey))) throw new Error("No se pudo compilar el shader inicial.");
  }

  async function buildSwitcher() {
    const builtins = [
      { key: "crt", label: "CRT" },
      { key: "thermal", label: "Térmico" },
      { key: "gameboy", label: "Game Boy" },
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

  // La barra queda oculta mientras mirás; solo aparece al acercar el mouse al
  // borde inferior (como los controles de un reproductor), así no molesta.
  const REVEAL_ZONE = 110; // px desde abajo donde se revela

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

  // Chequeo por si la captura llega negra (algunas configs sí protegen la
  // captura de la pestaña para DRM). Muestreamos el video capturado con un
  // canvas 2D chico; si esta reproduciendo y sigue negro, avisamos.
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
          "⚠ La captura llega negra: esta config protege la captura para este DRM. Probá compartir la PANTALLA en vez de la pestaña.";
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
      /* autoplay de MediaStream muteado no debería fallar */
    }

    try {
      await setupGL();
    } catch (err) {
      setError(String(err.message || err));
      stopStream();
      return;
    }

    stream.getVideoTracks()[0].addEventListener("ended", stopStream);

    startPanel.hidden = true;
    hud.hidden = false;
    const FS_HINT = "F o F11 = pantalla completa · NO maximices la ventana antes";
    hud.textContent = FS_HINT;
    setTimeout(() => {
      if (hud.textContent === FS_HINT) hud.hidden = true;
    }, 4500);
    switcherEl.hidden = false;
    await buildSwitcher();
    startTime = performance.now();
    renderFrame();
    showBar();
    scheduleHide(2500); // un vistazo inicial y se esconde
    setTimeout(warnIfBlack, 1200);
  }

  // Arranque directo (desde el popup): consume el streamId de tabCapture, sin
  // la barra "estás compartiendo" ni el selector de fuente.
  async function startTab(streamId) {
    setError("");
    let s;
    try {
      s = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
      });
    } catch (_) {
      // Si el streamId no sirve, dejamos el panel para el modo manual.
      setError('No se pudo usar la captura directa. Tocá "Iniciar captura" para elegir la fuente.');
      return;
    }
    await begin(s);
  }

  // Fallback manual: selector de Chrome (muestra la barra de compartir).
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
          ? "Cancelaste la selección. Tocá de nuevo para elegir la fuente."
          : `No se pudo iniciar la captura: ${err && err.message ? err.message : err}`
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
    setError("La captura terminó. Podés volver a iniciarla.");
  }

  startBtn.addEventListener("click", startDisplay);

  document.addEventListener("mousemove", (e) => {
    if (switcherEl.hidden) return;
    if (e.clientY >= window.innerHeight - REVEAL_ZONE) showBar();
    else scheduleHide(500);
  });

  // F = pantalla completa (Fullscreen API). También sirve F11 (nativa de la
  // ventana). Importante: la ventana NO debe estar maximizada antes, o el
  // reproductor puede quedar negro. Teclas 1-9 cambian de filtro.
  document.addEventListener("keydown", (e) => {
    if (e.key === "f" || e.key === "F") {
      if (!document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {});
      else document.exitFullscreen().catch(() => {});
    } else if (/^[1-9]$/.test(e.key)) {
      const chip = switcherEl.querySelectorAll(".chip")[parseInt(e.key, 10) - 1];
      if (chip) applyShader(chip.dataset.key);
    }
    showBar();
    scheduleHide(1800);
  });

  // Arranque directo si el popup nos pasó un streamId de tabCapture (sin barra
  // ni selector). Si no, queda el panel con el botón manual (getDisplayMedia).
  const initialStreamId = params.get("streamId");
  if (initialStreamId) startTab(initialStreamId);
})();
