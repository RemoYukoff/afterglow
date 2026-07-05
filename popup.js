const DEFAULT_SHADER = "crt";
const BUILTIN_COUNT = 5;

const screenEl = document.getElementById("screen");
const powerInput = document.getElementById("power-input");
const statusText = document.getElementById("status-text");
const channelsEl = document.getElementById("channels");
const builtinButtons = [...channelsEl.querySelectorAll(".channel-btn[data-key]")];
const customChannelsEl = document.getElementById("custom-channels");

const captureBtn = document.getElementById("capture-btn");

const addShaderBtn = document.getElementById("add-shader-btn");
const customForm = document.getElementById("custom-form");
const customNameInput = document.getElementById("custom-name");
const customSourceInput = document.getElementById("custom-source");
const customErrorEl = document.getElementById("custom-error");
const customSaveBtn = document.getElementById("custom-save");
const customCancelBtn = document.getElementById("custom-cancel");

let vertexSrcCache = null;

async function loadVertexSrc() {
  if (!vertexSrcCache) {
    vertexSrcCache = await fetch(chrome.runtime.getURL("shaders/vertex.glsl")).then((r) => r.text());
  }
  return vertexSrcCache;
}

function compileAndLink(gl, vertexSrc, fragmentSrc) {
  const vs = gl.createShader(gl.VERTEX_SHADER);
  gl.shaderSource(vs, vertexSrc);
  gl.compileShader(vs);
  if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) {
    return `Internal error in the vertex shader:\n${gl.getShaderInfoLog(vs)}`;
  }

  const fs = gl.createShader(gl.FRAGMENT_SHADER);
  gl.shaderSource(fs, fragmentSrc);
  gl.compileShader(fs);
  if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
    return gl.getShaderInfoLog(fs);
  }

  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    return gl.getProgramInfoLog(program);
  }
  return null;
}

async function validateShaderSource(source) {
  const vertexSrc = await loadVertexSrc();
  const canvas = document.createElement("canvas");
  const gl = canvas.getContext("webgl");
  if (!gl) return "WebGL is not available in this browser.";
  return compileAndLink(gl, vertexSrc, source);
}

function render({ crtEnabled, crtShader }) {
  powerInput.checked = crtEnabled;
  statusText.textContent = crtEnabled ? "ON AIR" : "STANDBY";
  statusText.classList.toggle("on", crtEnabled);
  channelsEl.classList.toggle("disabled", !crtEnabled);
  channelsEl.querySelectorAll(".channel-btn[data-key]").forEach((btn) => {
    btn.classList.toggle("active", crtEnabled && btn.dataset.key === crtShader);
  });
}

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function persist(next) {
  await chrome.storage.local.set(next);
  const stored = await chrome.storage.local.get({ crtEnabled: false, crtShader: DEFAULT_SHADER });
  render(stored);

  const tab = await getActiveTab();
  if (!tab?.id) return;
  chrome.tabs
    .sendMessage(tab.id, { type: "CRT_SET_SHADER", enabled: stored.crtEnabled, shader: stored.crtShader })
    .catch(() => {
      // The content script may not be injected yet (freshly opened tab).
    });
}

function renderCustomChannels(customShaders, crtEnabled, crtShader) {
  customChannelsEl.innerHTML = "";
  customShaders.forEach((shader, index) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "channel-btn";
    btn.dataset.key = shader.id;
    if (crtEnabled && shader.id === crtShader) btn.classList.add("active");

    const led = document.createElement("span");
    led.className = "led";

    const num = document.createElement("span");
    num.className = "ch-num";
    num.textContent = String(BUILTIN_COUNT + index + 1);

    const label = document.createElement("span");
    label.className = "ch-label";
    label.textContent = shader.name;

    const del = document.createElement("span");
    del.className = "ch-delete";
    del.textContent = "×";
    del.title = "Delete";
    del.addEventListener("click", (event) => {
      event.stopPropagation();
      deleteCustomShader(shader.id);
    });

    btn.append(led, num, label, del);
    btn.addEventListener("click", () => persist({ crtEnabled: true, crtShader: shader.id }));
    customChannelsEl.appendChild(btn);
  });
}

async function refresh() {
  const stored = await chrome.storage.local.get({
    crtEnabled: false,
    crtShader: DEFAULT_SHADER,
    crtCustomShaders: [],
  });
  renderCustomChannels(stored.crtCustomShaders, stored.crtEnabled, stored.crtShader);
  render(stored);
}

async function deleteCustomShader(id) {
  const stored = await chrome.storage.local.get({
    crtCustomShaders: [],
    crtShader: DEFAULT_SHADER,
    crtEnabled: false,
  });
  const crtCustomShaders = stored.crtCustomShaders.filter((s) => s.id !== id);
  const patch = { crtCustomShaders };
  if (stored.crtShader === id) {
    patch.crtShader = DEFAULT_SHADER;
    patch.crtEnabled = false;
  }
  await persist(patch);
  await refresh();
}

function toggleCustomForm(show) {
  customForm.hidden = !show;
  customErrorEl.textContent = "";
  if (show) {
    customNameInput.value = "";
    customSourceInput.value = "";
    customNameInput.focus();
  }
}

powerInput.addEventListener("change", async () => {
  const crtEnabled = powerInput.checked;
  const { crtShader = DEFAULT_SHADER } = await chrome.storage.local.get("crtShader");
  if (crtEnabled) {
    screenEl.classList.remove("powering-on");
    void screenEl.offsetWidth; // restarts the animation when toggled quickly
    screenEl.classList.add("powering-on");
  }
  persist({ crtEnabled, crtShader });
});

builtinButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    persist({ crtEnabled: true, crtShader: btn.dataset.key });
  });
});

captureBtn.addEventListener("click", async () => {
  const { crtShader = DEFAULT_SHADER } = await chrome.storage.local.get("crtShader");
  const tab = await getActiveTab();

  // Maximizes the tab's video via CSS (not native fullscreen, which would
  // capture as black) so the capture is almost entirely video.
  if (tab?.id) {
    chrome.tabs.sendMessage(tab.id, { type: "CRT_MAXIMIZE_VIDEO", on: true }).catch(() => {});
  }

  // tabCapture: captures the tab without the "you are sharing" bar or the
  // picker. If it fails, the viewer falls back to manual mode (getDisplayMedia).
  let streamId = null;
  try {
    if (tab?.id && chrome.tabCapture?.getMediaStreamId) {
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
    }
  } catch (_) {
    streamId = null;
  }

  let url = `${chrome.runtime.getURL("viewer.html")}?shader=${encodeURIComponent(crtShader)}`;
  if (streamId) url += `&streamId=${encodeURIComponent(streamId)}`;
  if (tab?.id != null) url += `&srcTab=${tab.id}`; // so the viewer can forward keyboard/clicks to it
  // New window (not a tab): that way it's a separate alt-tab target and you
  // can put it in fullscreen with F11 without touching the Crunchyroll window.
  // "normal" state (floating, NOT maximized): if it starts maximized, F11
  // doesn't pick up the capture properly.
  await chrome.windows.create({ url, focused: true, state: "normal", width: 1280, height: 760 });
  window.close();
});

addShaderBtn.addEventListener("click", () => toggleCustomForm(true));
customCancelBtn.addEventListener("click", () => toggleCustomForm(false));

customSaveBtn.addEventListener("click", async () => {
  const name = customNameInput.value.trim().slice(0, 24) || "CUSTOM";
  const source = customSourceInput.value;

  if (!source.trim()) {
    customErrorEl.textContent = "Paste the fragment shader code.";
    return;
  }

  customErrorEl.textContent = "Validating...";
  const error = await validateShaderSource(source);
  if (error) {
    customErrorEl.textContent = error;
    return;
  }

  const { crtCustomShaders = [] } = await chrome.storage.local.get("crtCustomShaders");
  const id = `custom-${crypto.randomUUID()}`;
  await chrome.storage.local.set({ crtCustomShaders: [...crtCustomShaders, { id, name, source }] });

  toggleCustomForm(false);
  await refresh();
  persist({ crtEnabled: true, crtShader: id });
});

refresh();
