import Foundation

public actor BrowserMusicProvider: MusicProvider {
    public nonisolated let providerID = "chrome"
    private struct Entry { let connection: UUID; let rawID: String; let snapshot: MusicSnapshot }
    private struct Pending { let source: String; let connection: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var server: BrowserBridgeServer?
    private var entries: [String: Entry] = [:]
    private var connections = Set<UUID>()
    private var pending: [String: Pending] = [:]
    private var failure: String?
    public init() {}
    public func start() {
        guard server == nil else { return }
        let server = BrowserBridgeServer(onMessage: { [weak self] id, message in Task { await self?.receive(id, message) } },
                                         onConnection: { [weak self] id, active in Task { await self?.connection(id, active) } })
        do { try server.start(); self.server = server }
        catch { failure = "Не удалось открыть локальный мост Chrome" }
    }
    private func connection(_ id: UUID, _ active: Bool) {
        if active { connections.insert(id) }
        else {
            connections.remove(id)
            entries = entries.filter { $0.value.connection != id }
            for (key, value) in pending where value.connection == id { pending.removeValue(forKey: key)?.continuation.resume(throwing: MusicIntegrationError.unavailable) }
        }
    }
    private func receive(_ connection: UUID, _ message: BridgeMessage) {
        guard connections.contains(connection), let rawID = message.source else { return }
        let id = "chrome/\(connection.uuidString)/\(rawID)"
        switch message.type {
        case "snapshot":
            guard entries[id] != nil || entries.count < 32 else { return }
            guard let snapshot = try? message.payload?.snapshot(id: id, origin: message.origin ?? "", now: Date()) else { entries[id] = nil; return }
            if snapshot.state == .stopped || snapshot.title.isEmpty { entries[id] = nil }
            else { entries[id] = Entry(connection: connection, rawID: rawID, snapshot: snapshot) }
        case "remove": entries[id] = nil
        case "result":
            guard let request = message.requestID, let waiting = pending[request], waiting.connection == connection, waiting.source == rawID else { return }
            pending[request] = nil
            if message.ok == true { waiting.continuation.resume() }
            else { waiting.continuation.resume(throwing: MusicIntegrationError.commandFailed(message.error ?? "Плеер не выполнил команду")) }
        default: break
        }
    }
    public func poll() async -> ProviderUpdate {
        // Native-port messages wake the content script even when a paused tab's
        // ordinary JavaScript timers are throttled by Chrome.
        if let server { for id in connections { try? await server.send(BridgeMessage(type: "poll"), to: id) } }
        let now = Date(); entries = entries.filter { now.timeIntervalSince($0.value.snapshot.updatedAt) < 7 }
        if let failure { return ProviderUpdate(state: .failed, detail: failure) }
        return ProviderUpdate(entries.values.map(\.snapshot), state: connections.isEmpty ? .disconnected : .ready)
    }
    public func perform(_ command: MusicCommand, sourceID: String, position: Double?) async throws {
        guard let entry = entries[sourceID], Date().timeIntervalSince(entry.snapshot.updatedAt) < 7, let server else { throw MusicIntegrationError.unavailable }
        guard entry.snapshot.commands.contains(command) else { throw MusicIntegrationError.unsupportedCommand }
        let request = UUID().uuidString
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[request] = Pending(source: entry.rawID, connection: entry.connection, continuation: continuation)
            Task {
                do { try await server.send(BridgeMessage(type: "command", source: entry.rawID, requestID: request, command: command, position: position), to: entry.connection) }
                catch { finish(request, error) }
            }
            Task { try? await Task.sleep(for: .seconds(3)); finish(request, MusicIntegrationError.commandFailed("Плеер Chrome не ответил")) }
        }
    }
    private func finish(_ request: String, _ error: Error) { pending.removeValue(forKey: request)?.continuation.resume(throwing: error) }
    public func stop() { server?.stop(); server = nil; entries.removeAll() }
}
