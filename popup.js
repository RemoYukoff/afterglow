const DEFAULT_SHADER = "crt";

const screenEl = document.getElementById("screen");
const powerInput = document.getElementById("power-input");
const statusText = document.getElementById("status-text");
const channelsEl = document.getElementById("channels");
const channelButtons = [...channelsEl.querySelectorAll(".channel-btn")];

function render({ crtEnabled, crtShader }) {
  powerInput.checked = crtEnabled;
  statusText.textContent = crtEnabled ? "ON AIR" : "STANDBY";
  statusText.classList.toggle("on", crtEnabled);
  channelsEl.classList.toggle("disabled", !crtEnabled);
  channelButtons.forEach((btn) => {
    btn.classList.toggle("active", crtEnabled && btn.dataset.key === crtShader);
  });
}

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function persist(next) {
  await chrome.storage.local.set(next);
  render(next);

  const tab = await getActiveTab();
  if (!tab?.id) return;
  chrome.tabs
    .sendMessage(tab.id, { type: "CRT_SET_SHADER", enabled: next.crtEnabled, shader: next.crtShader })
    .catch(() => {
      // El content script puede no estar inyectado (pestaña distinta a youtube.com o recién abierta).
    });
}

async function loadState() {
  const stored = await chrome.storage.local.get({ crtEnabled: false, crtShader: DEFAULT_SHADER });
  render(stored);
}

powerInput.addEventListener("change", async () => {
  const crtEnabled = powerInput.checked;
  const { crtShader = DEFAULT_SHADER } = await chrome.storage.local.get("crtShader");
  if (crtEnabled) {
    screenEl.classList.remove("powering-on");
    void screenEl.offsetWidth; // reinicia la animacion si se togglea rapido
    screenEl.classList.add("powering-on");
  }
  persist({ crtEnabled, crtShader });
});

channelButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    persist({ crtEnabled: true, crtShader: btn.dataset.key });
  });
});

loadState();
