(() => {
  const VERTEX_SHADER_URL = chrome.runtime.getURL("shaders/vertex.glsl");

  const SHADERS = {
    crt: { url: chrome.runtime.getURL("shaders/crt.frag.glsl") },
    gameboy: { url: chrome.runtime.getURL("shaders/gameboy.frag.glsl") },
    gbc: { url: chrome.runtime.getURL("shaders/gbc.frag.glsl") },
    virtualboy: { url: chrome.runtime.getURL("shaders/virtualboy.frag.glsl") },
    psx: { url: chrome.runtime.getURL("shaders/psx.frag.glsl") },
  };
  const DEFAULT_SHADER = "crt";

  let vertexSrcPromise = null;
  const fragmentSrcCache = new Map();
  let activating = false;

  function loadVertexSrc() {
    if (!vertexSrcPromise) {
      vertexSrcPromise = fetch(VERTEX_SHADER_URL).then((r) => r.text());
    }
    return vertexSrcPromise;
  }

  async function getCustomShaders() {
    const { crtCustomShaders = [] } = await chrome.storage.local.get("crtCustomShaders");
    return crtCustomShaders;
  }

  function loadFragmentSrc(shaderKey) {
    if (!fragmentSrcCache.has(shaderKey)) {
      const promise = (async () => {
        if (SHADERS[shaderKey]) {
          return fetch(SHADERS[shaderKey].url).then((r) => r.text());
        }
        const custom = (await getCustomShaders()).find((s) => s.id === shaderKey);
        if (custom) return custom.source;
        console.warn(`[CRT] Shader "${shaderKey}" no encontrado, usando el default.`);
        return fetch(SHADERS[DEFAULT_SHADER].url).then((r) => r.text());
      })();
      fragmentSrcCache.set(shaderKey, promise);
    }
    return fragmentSrcCache.get(shaderKey);
  }

  let state = {
    enabled: false,
    shaderKey: DEFAULT_SHADER,
    video: null,
    canvas: null,
    gl: null,
    program: null,
    texture: null,
    uTime: null,
    uResolution: null,
    rafId: null,
    resizeObserver: null,
    bodyObserver: null,
    startTime: null,
  };

  function compileShader(gl, type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.error("[CRT] Error compilando shader:", gl.getShaderInfoLog(shader));
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  function createProgram(gl, vertexSrc, fragmentSrc) {
    const vertexShader = compileShader(gl, gl.VERTEX_SHADER, vertexSrc);
    const fragmentShader = compileShader(gl, gl.FRAGMENT_SHADER, fragmentSrc);
    if (!vertexShader || !fragmentShader) return null;

    const program = gl.createProgram();
    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      console.error("[CRT] Error enlazando programa:", gl.getProgramInfoLog(program));
      return null;
    }
    return program;
  }

  function findVideo() {
    const ytVideo = document.querySelector("video.html5-main-video") || document.querySelector("#movie_player video");
    if (ytVideo) return ytVideo;

    const videos = [...document.querySelectorAll("video")];
    if (videos.length === 0) return null;
    return videos.reduce((largest, v) =>
      v.clientWidth * v.clientHeight > largest.clientWidth * largest.clientHeight ? v : largest
    );
  }

  // DRM (Widevine, etc.) suele hacer que el frame decodificado llegue como
  // negro puro a cualquier lectura de pixeles, sin lanzar una excepcion de
  // seguridad. Probamos con un canvas 2D chico, independiente de WebGL,
  // para detectar esto antes de montar el overlay y quedarnos con un
  // rectangulo negro pegado sobre el video.
  function readVideoSample(video) {
    const probe = document.createElement("canvas");
    probe.width = 4;
    probe.height = 4;
    const ctx = probe.getContext("2d");
    try {
      ctx.drawImage(video, 0, 0, 4, 4);
      return ctx.getImageData(0, 0, 4, 4).data;
    } catch (err) {
      return null; // canvas "tainted" (CORS o DRM)
    }
  }

  function isSampleBlack(data) {
    if (!data) return true;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 8 || data[i + 1] > 8 || data[i + 2] > 8) return false;
    }
    return true;
  }

  async function canCaptureVideo(video) {
    if (!isSampleBlack(readVideoSample(video))) return true;

    const startTime = video.currentTime;
    await new Promise((resolve) => setTimeout(resolve, 700));
    if (!isSampleBlack(readVideoSample(video))) return true;

    const advanced = !video.paused && video.currentTime > startTime;
    return !advanced;
  }

  function setupOverlay(video, vertexSrc, fragmentSrc) {
    const parent = video.parentElement;
    if (!parent) return false;

    const computedPosition = getComputedStyle(parent).position;
    if (computedPosition === "static") {
      parent.style.position = "relative";
    }

    const canvas = document.createElement("canvas");
    canvas.id = "__crt_shader_canvas__";
    Object.assign(canvas.style, {
      position: "absolute",
      pointerEvents: "none",
      zIndex: "2147483647",
    });
    parent.insertBefore(canvas, video.nextSibling);

    const gl = canvas.getContext("webgl", { preserveDrawingBuffer: false, antialias: false });
    if (!gl) {
      console.error("[CRT] WebGL no disponible.");
      canvas.remove();
      return false;
    }

    const program = createProgram(gl, vertexSrc, fragmentSrc);
    if (!program) {
      canvas.remove();
      return false;
    }
    gl.useProgram(program);

    const positionBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]),
      gl.STATIC_DRAW
    );
    const aPosition = gl.getAttribLocation(program, "aPosition");
    gl.enableVertexAttribArray(aPosition);
    gl.vertexAttribPointer(aPosition, 2, gl.FLOAT, false, 0, 0);

    const texture = gl.createTexture();
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    state.video = video;
    state.canvas = canvas;
    state.gl = gl;
    state.program = program;
    state.texture = texture;
    state.uTime = gl.getUniformLocation(program, "uTime");
    state.uResolution = gl.getUniformLocation(program, "uResolution");
    state.startTime = performance.now();

    state.resizeObserver = new ResizeObserver(() => syncCanvasSize());
    state.resizeObserver.observe(video);
    syncCanvasSize();

    return true;
  }

  function syncCanvasSize() {
    if (!state.video || !state.canvas) return;
    const parent = state.video.parentElement;
    if (!parent) return;

    const videoRect = state.video.getBoundingClientRect();
    const parentRect = parent.getBoundingClientRect();
    const cssLeft = videoRect.left - parentRect.left;
    const cssTop = videoRect.top - parentRect.top;
    const cssWidth = videoRect.width;
    const cssHeight = videoRect.height;

    state.canvas.style.left = `${cssLeft}px`;
    state.canvas.style.top = `${cssTop}px`;
    state.canvas.style.width = `${cssWidth}px`;
    state.canvas.style.height = `${cssHeight}px`;

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.round(cssWidth * dpr));
    const height = Math.max(1, Math.round(cssHeight * dpr));
    if (state.canvas.width !== width || state.canvas.height !== height) {
      state.canvas.width = width;
      state.canvas.height = height;
      state.gl.viewport(0, 0, width, height);
    }
  }

  function renderFrame() {
    state.rafId = requestAnimationFrame(renderFrame);

    const { gl, video, texture, canvas } = state;
    if (!gl || !video || video.readyState < 2) return;

    syncCanvasSize();

    try {
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
    } catch (err) {
      console.warn("[CRT] No se pudo leer el frame de video (posible restricción de origen). Desactivando el shader.", err);
      teardown();
      return;
    }

    const elapsed = (performance.now() - state.startTime) / 1000;
    gl.uniform1f(state.uTime, elapsed);
    gl.uniform2f(state.uResolution, canvas.width, canvas.height);

    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  function teardown() {
    if (state.rafId) cancelAnimationFrame(state.rafId);
    if (state.resizeObserver) state.resizeObserver.disconnect();
    if (state.canvas) state.canvas.remove();
    state = { ...state, video: null, canvas: null, gl: null, program: null, texture: null, rafId: null, resizeObserver: null };
  }

  async function activate() {
    if (state.canvas || activating || !state.enabled) return;
    const video = findVideo();
    if (!video || video.readyState < 2) return;

    activating = true;
    try {
      if (!(await canCaptureVideo(video))) {
        console.warn(
          "[CRT] Este video parece protegido (DRM) y solo entrega frames negros al leerlo. Desactivando el efecto en esta pestaña."
        );
        state.enabled = false;
        return;
      }
      if (!state.enabled || state.canvas) return;

      const [vertexSrc, fragmentSrc] = await Promise.all([
        loadVertexSrc(),
        loadFragmentSrc(state.shaderKey),
      ]);
      if (!state.enabled || state.canvas) return;
      if (setupOverlay(video, vertexSrc, fragmentSrc)) {
        renderFrame();
      }
    } catch (err) {
      console.error("[CRT] No se pudieron cargar los shaders:", err);
    } finally {
      activating = false;
    }
  }

  function applySettings(enabled, shaderKey) {
    const shaderChanged = shaderKey && shaderKey !== state.shaderKey;
    state.enabled = enabled;
    if (shaderKey) state.shaderKey = shaderKey;

    if (!enabled) {
      teardown();
      return;
    }
    if (shaderChanged) teardown();
    activate();
  }

  // Simula la tecla "f" (atajo de pantalla completa de Crunchyroll) sobre la
  // página, para ver si el reproductor entra en fullscreen por sí solo. Nota:
  // el navegador puede rechazar el requestFullscreen del player porque el
  // evento es sintético (sin gesto real del usuario); esto es para probarlo.
  function maximizeVideo(on) {
    if (!on) return;
    const init = { key: "f", code: "KeyF", keyCode: 70, which: 70, bubbles: true, cancelable: true, composed: true };
    const video = findVideo();
    for (const target of [document, video, document.body].filter(Boolean)) {
      target.dispatchEvent(new KeyboardEvent("keydown", init));
      target.dispatchEvent(new KeyboardEvent("keyup", init));
    }
  }

  // Control remoto desde el viewer: reproduce en esta pagina el teclado/click
  // que hace el usuario sobre la ventana DRM. Son eventos sinteticos
  // (isTrusted:false), asi que sirven para los atajos del reproductor y el
  // play/pausa, pero no para acciones que exijan un gesto real del usuario.
  function remoteControl(msg) {
    if (msg.kind === "key") {
      const init = {
        key: msg.key,
        code: msg.code,
        keyCode: msg.keyCode,
        which: msg.keyCode,
        bubbles: true,
        cancelable: true,
        composed: true,
      };
      const video = findVideo();
      for (const target of [document, video].filter(Boolean)) {
        target.dispatchEvent(new KeyboardEvent(msg.evtype || "keydown", init));
      }
    } else if (msg.kind === "click") {
      const x = Math.round((msg.u || 0) * window.innerWidth);
      const y = Math.round((msg.v || 0) * window.innerHeight);
      const el = document.elementFromPoint(x, y) || document.body;
      const opts = { clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true, view: window };
      for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
        const Ctor = t.startsWith("pointer") ? PointerEvent : MouseEvent;
        try {
          el.dispatchEvent(new Ctor(t, opts));
        } catch (_) {
          /* algunos navegadores exigen campos extra en PointerEvent */
        }
      }
    }
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "CRT_SET_SHADER") {
      applySettings(message.enabled, message.shader);
    } else if (message?.type === "CRT_MAXIMIZE_VIDEO") {
      maximizeVideo(!!message.on);
    } else if (message?.type === "CRT_REMOTE") {
      remoteControl(message);
    }
  });

  state.bodyObserver = new MutationObserver(() => {
    if (state.enabled && !state.canvas) activate();
  });
  state.bodyObserver.observe(document.body, { childList: true, subtree: true });

  document.addEventListener("yt-navigate-finish", () => {
    teardown();
    if (state.enabled) setTimeout(activate, 500);
  });

  chrome.storage.local.get({ crtEnabled: false, crtShader: DEFAULT_SHADER }, (stored) => {
    state.enabled = stored.crtEnabled;
    state.shaderKey = stored.crtShader || DEFAULT_SHADER;
    if (state.enabled) {
      activate();
    } else {
      teardown();
    }
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (!("crtEnabled" in changes) && !("crtShader" in changes)) return;
    const enabled = "crtEnabled" in changes ? changes.crtEnabled.newValue : state.enabled;
    const shaderKey = "crtShader" in changes ? changes.crtShader.newValue : state.shaderKey;
    applySettings(enabled, shaderKey);
  });
})();
