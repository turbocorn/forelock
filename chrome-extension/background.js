const HOST = "com.turbocorn.forelock.music";
const ALLOWED = new Set(["https://music.yandex.ru", "https://music.yandex.com", "https://zvuk.com"]);
const COMMANDS = new Set(["play", "pause", "next", "previous", "seek"]);
const sessions = new Map();
let native = null;
let lastAttempt = 0;
let status = "Откройте Forelock и включите музыку на поддерживаемом сайте.";

function connectNative() {
  if (native || Date.now() - lastAttempt < 2000 || !sessions.size) return;
  lastAttempt = Date.now();
  const port = chrome.runtime.connectNative(HOST);
  native = port;
  port.onMessage.addListener(message => {
    if (!message || message.version !== 1) return;
    status = "Локальный мост подключён. Данные получает только Forelock.";
    if (message.type === "poll") {
      for (const session of sessions.values()) session.port.postMessage({ type: "refresh" });
    } else if (message.type === "command" && COMMANDS.has(message.command) && typeof message.requestID === "string" && message.requestID.length <= 64) {
      const session = sessions.get(message.source);
      if (session) session.port.postMessage({ type: "command", command: message.command, requestID: message.requestID, position: message.position });
      else port.postMessage({ version: 1, type: "result", source: message.source, requestID: message.requestID, ok: false, error: "Вкладка закрыта" });
    }
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (native === port) native = null;
    status = "Нет соединения с Forelock. Проверьте установку Native Messaging host.";
  });
  for (const session of sessions.values()) session.port.postMessage({ type: "refresh" });
}

function payload(value) {
  if (!value || typeof value !== "object" || !["playing", "paused", "stopped"].includes(value.state)) return null;
  const bounded = (x, n) => typeof x === "string" ? x.slice(0, n) : "";
  const seconds = x => typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= 604800 ? x : null;
  return { title: bounded(value.title, 512), artist: bounded(value.artist, 512), album: bounded(value.album, 512),
    artwork: typeof value.artwork === "string" && value.artwork.length <= 2048 ? value.artwork : null,
    state: value.state, duration: seconds(value.duration), position: seconds(value.position),
    commands: Array.isArray(value.commands) ? [...new Set(value.commands.filter(c => COMMANDS.has(c)))].slice(0, 5) : [] };
}

chrome.runtime.onConnect.addListener(port => {
  const sender = port.sender;
  let origin;
  try { origin = new URL(sender?.url).origin; } catch { port.disconnect(); return; }
  if (port.name !== "forelock-music" || sender.id !== chrome.runtime.id || !ALLOWED.has(origin) || sender.frameId !== 0 || !Number.isInteger(sender.tab?.id)) {
    port.disconnect(); return;
  }
  // Identity comes from Chrome's sender, never a page-supplied tab or origin.
  const source = `tab-${sender.tab.id}:${crypto.randomUUID()}`;
  sessions.set(source, { port, origin });
  connectNative();
  port.onMessage.addListener(message => {
    connectNative();
    if (!native || !message || typeof message !== "object") return;
    if (message.type === "snapshot") {
      const data = payload(message.payload);
      if (data) native.postMessage({ version: 1, type: "snapshot", source, origin, payload: data });
    } else if (message.type === "result" && typeof message.requestID === "string" && message.requestID.length <= 64) {
      native.postMessage({ version: 1, type: "result", source, requestID: message.requestID, ok: message.ok === true,
        error: typeof message.error === "string" ? message.error.slice(0, 256) : null });
    }
  });
  port.onDisconnect.addListener(() => {
    sessions.delete(source);
    if (native) native.postMessage({ version: 1, type: "remove", source });
    if (!sessions.size && native) { const previous = native; native = null; previous.disconnect(); }
  });
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id === chrome.runtime.id && !sender.tab && message?.type === "status") reply({ status, pages: sessions.size });
});
