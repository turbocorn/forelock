import AppKit

public actor YandexDesktopMusicProvider: MusicProvider {
    public nonisolated let providerID = "yandex-desktop"
    private let script: URL?
    private let framework: URL?
    private nonisolated let child = NowPlayingChild()
    private var enabled = false
    private var run: UUID?
    private var model = NowPlayingSession()
    private var backoff = HelperBackoff()
    private var restart: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var launchedAt = Date()
    private var failure: String?
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    public init(bundle: Bundle = .main) {
        script = bundle.resourceURL?.appendingPathComponent("MediaRemote/forelock-nowplaying.pl")
        framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
    }
    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; restart?.cancel(); restart = nil; reader?.cancel(); reader = nil; run = nil
        child.stopCurrent(); clearPending(); model = NowPlayingSession(); failure = nil; backoff.reset()
        if value { launch() }
    }
    private func launch() {
        guard enabled, !child.isRunning, let script, let framework,
              FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: framework.path) else {
            failure = "MediaRemote helper отсутствует в сборке"; return
        }
        let token = UUID(); run = token; model = NowPlayingSession(); launchedAt = Date()
        enum Event { case line(Data, Date), exit }
        let (events, output) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        do {
            try child.launch(script: script, framework: framework,
                             onLine: { data, date in output.yield(.line(data,date)) },
                             onExit: { output.yield(.exit); output.finish() })
            reader?.cancel()
            reader = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self else { return }
                    switch event { case .line(let data, let date): await self.receive(data, at: date, run: token)
                    case .exit: await self.exited(token) }
                }
            }
        } catch { exited(token) }
    }
    private func receive(_ data: Data, at date: Date, run token: UUID) {
        guard run == token, enabled else { return }
        do {
            let message = try JSONDecoder().decode(NowPlayingEnvelope.self, from: data)
            try model.consume(message, receivedAt: date)
            if message.type == "result", let id = message.requestID, let continuation = pending.removeValue(forKey: id) {
                if message.ok == true { continuation.resume() }
                else { continuation.resume(throwing: MusicIntegrationError.commandFailed(Self.message(for: message.code ?? "unavailable"))) }
            }
            if message.type == "fatal" { failure = "MediaRemote недоступен на этой macOS"; child.stopCurrent() }
        } catch {
            failure = "Некорректный ответ MediaRemote helper"; child.stopCurrent(); exited(token)
        }
    }
    private func exited(_ token: UUID) {
        guard run == token else { return }
        run = nil; model = NowPlayingSession(); clearPending(); child.stopCurrent()
        guard enabled else { return }
        guard let delay = backoff.nextDelay() else { failure = "Helper остановлен после пяти сбоев. Выключите и включите эксперимент в настройках."; return }
        failure = "Перезапуск MediaRemote helper…"
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, await self.enabled else { return }; await self.launch()
        }
    }
    public func poll() -> ProviderUpdate {
        guard enabled else { return ProviderUpdate(state: .disconnected, detail: "Экспериментальная интеграция выключена") }
        guard child.isRunning else { return ProviderUpdate(state: .failed, detail: failure ?? "MediaRemote helper не запущен") }
        if let snapshot = model.current(at: Date()) {
            guard let pidText = snapshot.id.split(separator: "/").last, let pid = Int32(pidText),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.bundleIdentifier == NowPlayingLimits.bundleID else {
                return ProviderUpdate(state: .notRunning)
            }
            return ProviderUpdate([snapshot])
        }
        if Date().timeIntervalSince(model.confirmedAt ?? launchedAt) >= NowPlayingLimits.confirmationAge {
            failure = "Helper не подтверждает состояние"; child.stopCurrent(); if let run { exited(run) }
            return ProviderUpdate(state: .failed, detail: failure)
        }
        return ProviderUpdate(state: model.reason == "not-running" ? .notRunning : .disconnected, detail: Self.message(for: model.reason))
    }
    // Calls without a captured generation are deliberately rejected.
    public func perform(_ command: MusicCommand, sourceID: String, position: Double?) throws { throw MusicIntegrationError.unavailable }
    public func perform(_ command: MusicCommand, snapshot: MusicSnapshot, position: Double?) async throws {
        guard enabled, NowPlayingLimits.commands.contains(command), let current = model.current(at: Date()),
              current.id == snapshot.id, current.commandGeneration == snapshot.commandGeneration,
              snapshot.commands.contains(command), current.commands.contains(command), let session = model.session,
              let pid = Int32(current.id.split(separator: "/").last ?? ""),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.bundleIdentifier == NowPlayingLimits.bundleID,
              pending.isEmpty else { throw MusicIntegrationError.commandFailed("Источник или состояние изменились. Команда заблокирована.") }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["v":1,"type":"command","requestID":id,"session":session,"generation":model.generation,"pid":pid,"command":command.rawValue])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[id] = continuation
            do { try child.send(data) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.timeout(id)
            }
        }
    }
    private func timeout(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: MusicIntegrationError.commandFailed("Нет подтверждения команды MediaRemote")) }
    private func clearPending() { let all = pending.values; pending.removeAll(); for continuation in all { continuation.resume(throwing: MusicIntegrationError.unavailable) } }
    public nonisolated func stopImmediately() { child.shutdown() }
    static func message(for code: String) -> String {
        switch code {
        case "foreign-source", "source-unverified", "source-changed": return "Система выбрала другой плеер. Управление Яндексом недоступно."
        case "not-running": return "Яндекс Музыка закрыта"
        case "stale-generation": return "Состояние изменилось. Команда заблокирована."
        case "not-confirmed": return "Яндекс не подтвердил команду"
        case "ready": return ""
        default: return "Ожидание подтверждённого источника Яндекс Музыки"
        }
    }
}
