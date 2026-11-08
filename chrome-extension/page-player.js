(() => {
  const CHANNEL = "forelock-music-v1";
  const ALLOWED = new Set(["music.yandex.ru", "music.yandex.com", "zvuk.com"]);
  if (location.protocol !== "https:" || !ALLOWED.has(location.hostname) || window.top !== window) return;
  const send = data => window.postMessage({ channel: CHANNEL, direction: "from-player", ...data }, location.origin);
  const visible = el => !!el && el.getClientRects().length > 0 && !el.disabled && el.getAttribute("aria-disabled") !== "true";
  function media() {
    const scope = playerRoot() || document;
    const elements = [...scope.querySelectorAll("audio")].filter(el => el.currentSrc || el.src);
    return elements.find(el => !el.paused && !el.ended) || (elements.length === 1 && elements[0].readyState > 0 ? elements[0] : null);
  }
  function playerRoot() {
    if (location.hostname === "zvuk.com") return document.querySelector('[class*="styles_playerContainer__"]');
    return document.querySelector('[aria-label="Плеер"],[aria-label="Player"],[class*="PlayerBarDesktop_root"],[class*="PlayerBar_root"],[data-test-id="player"],[data-testid="player"],[class*="player-bar"],[class*="Player_root"],#player');
  }
  function button(action) {
    const root = playerRoot();
    if (location.hostname === "zvuk.com" && root) {
      // Observed desktop mini-player DOM: one scoped transport group with
      // previous / toggle / next. Fail closed if its structure changes.
      const group = root.querySelector('[class*="styles_controls__"]');
      const controls = group ? [...group.querySelectorAll(':scope > button[class*="styles_btn__"]')] : [];
      if (controls.length === 3) {
        const state = navigator.mediaSession?.playbackState;
        const index = action === "previous" ? 0 : action === "next" ? 2 :
          action === "play" && state === "paused" || action === "pause" && state === "playing" ? 1 : -1;
        if (index >= 0 && visible(controls[index])) return controls[index];
      }
      return null;
    }
    const patterns = {
      play: /^(воспроизвести|воспроизведение|продолжить|играть|play|resume)( трек| track)?$/i,
      pause: /^(пауза|приостановить|pause)( трек| track)?$/i,
      next: /(следующий трек|следующая песня|следующая композиция|next track)/i,
      previous: /(предыдущий трек|предыдущая песня|предыдущая композиция|previous track)/i,
    };
    const candidates = [...(root || document).querySelectorAll('button[aria-label],button[title],[role="button"][aria-label]')];
    const matches = candidates.filter(el => visible(el) && patterns[action]?.test(el.getAttribute("aria-label") || el.getAttribute("title") || ""));
    return matches.length === 1 ? matches[0] : null;
  }
  function snapshot() {
    const element = media();
    const session = navigator.mediaSession;
    const metadata = session?.metadata;
    const root = playerRoot();
    const text = selector => root?.querySelector(selector)?.textContent?.trim() || "";
    const state = element ? (element.ended ? "stopped" : element.paused ? "paused" : "playing") : session?.playbackState === "playing" ? "playing" : session?.playbackState === "paused" ? "paused" : "stopped";
    const title = state === "stopped" ? "" : metadata?.title || text('a[href*="/track/"],[data-testid="track-title"],[data-test-id="track-title"]');
    const commands = [];
    if (element || button("play")) commands.push("play");
    if (element || button("pause")) commands.push("pause");
    if (button("next")) commands.push("next");
    if (button("previous")) commands.push("previous");
    const timeline = root?.querySelector('[aria-label="Управление таймкодом"],[role="slider"][aria-label="Позиция воспроизведения"]');
    const number = value => value !== null && value !== "" && Number.isFinite(Number(value)) ? Number(value) : null;
    const domDuration = number(timeline?.getAttribute("aria-valuemax") ?? timeline?.getAttribute("max") ?? null);
    const domPosition = number(timeline?.getAttribute("aria-valuenow") ?? timeline?.value ?? null);
    const duration = element && Number.isFinite(element.duration) && element.duration > 0 ? element.duration : domDuration > 0 ? domDuration : null;
    const position = element && Number.isFinite(element.currentTime) ? element.currentTime : domPosition;
    if (duration && element?.seekable?.length) commands.push("seek");
    return { title, artist: metadata?.artist || text('a[href*="/artist/"]'), album: metadata?.album || "",
      artwork: metadata?.artwork?.[0]?.src || root?.querySelector("img")?.src || null, state,
      duration, position, commands };
  }
  const publish = () => send({ type: "snapshot", payload: snapshot() });
  window.addEventListener("message", async event => {
    if (event.source !== window || event.origin !== location.origin || event.data?.channel !== CHANNEL || event.data.direction !== "to-player") return;
    const message = event.data;
    if (message.type === "refresh") { publish(); return; }
    if (message.type !== "command" || typeof message.requestID !== "string" || message.requestID.length > 64) return;
    try {
      const { command } = message;
      if (!snapshot().commands.includes(command)) throw new Error("Команда недоступна у этого плеера");
      const element = media();
      const control = button(command);
      if (control) control.click();
      else if (command === "play" && element) await element.play();
      else if (command === "pause" && element) element.pause();
      else if (command === "seek" && element && Number.isFinite(message.position)) element.currentTime = Math.max(0, Math.min(element.duration, message.position));
      else throw new Error("Кнопка плеера недоступна");
      send({ type: "result", requestID: message.requestID, ok: true });
      publish();
    } catch (error) { send({ type: "result", requestID: message.requestID, ok: false, error: String(error.message || error).slice(0, 256) }); }
  });
  for (const type of ["play", "pause", "ended", "loadedmetadata", "durationchange", "emptied"]) document.addEventListener(type, publish, true);
  document.addEventListener("visibilitychange", publish);
  setInterval(publish, 1000);
  window.addEventListener("pagehide", () => send({ type: "snapshot", payload: { title: "", artist: "", album: "", artwork: null, state: "stopped", duration: null, position: null, commands: [] } }));
})();
