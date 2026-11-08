(() => {
  const CHANNEL = "forelock-music-v1";
  let port;
  function connect() {
    try {
      port = chrome.runtime.connect({ name: "forelock-music" });
      port.onMessage.addListener(message => {
        if (message.type === "refresh" || message.type === "command") window.postMessage({ channel: CHANNEL, direction: "to-player", ...message }, location.origin);
      });
      port.onDisconnect.addListener(() => { port = null; });
    } catch { port = null; }
  }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin || event.data?.channel !== CHANNEL || event.data.direction !== "from-player") return;
    if (!port) connect();
    if (port && ["snapshot", "result"].includes(event.data.type)) {
      try { port.postMessage(event.data); } catch { port = null; }
    }
  });
  connect();
  window.addEventListener("pageshow", () => window.postMessage({ channel: CHANNEL, direction: "to-player", type: "refresh" }, location.origin));
})();
