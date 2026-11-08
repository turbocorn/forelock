import Foundation

public enum MusicService: String, Codable, CaseIterable, Sendable {
    case appleMusic, yandexDesktop, yandexChrome, zvukChrome
    public var name: String {
        switch self { case .appleMusic: return "Apple Music"; case .yandexDesktop: return "Яндекс Музыка"; case .yandexChrome: return "Яндекс Музыка · Chrome"; case .zvukChrome: return "Звук · Chrome" }
    }
}
public enum PlaybackState: String, Codable, Sendable { case playing, paused, stopped }
public enum MusicCommand: String, Codable, CaseIterable, Sendable { case play, pause, previous, next, seek }
public enum ProviderState: String, Sendable { case ready, notRunning, permissionRequired, permissionDenied, disconnected, unsupported, failed }

public struct MusicSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let service: MusicService
    public let title: String
    public let artist: String
    public let album: String
    public let artworkURL: URL?
    public let artworkData: Data?
    public let state: PlaybackState
    public let duration: Double?
    public let position: Double?
    public let commands: Set<MusicCommand>
    public let updatedAt: Date
    public let commandGeneration: String?
    public init(id: String, service: MusicService, title: String, artist: String, album: String, artworkURL: URL? = nil, artworkData: Data? = nil,
                state: PlaybackState, duration: Double?, position: Double?, commands: Set<MusicCommand>, updatedAt: Date = Date(), commandGeneration: String? = nil) {
        self.id = id; self.service = service; self.title = title; self.artist = artist; self.album = album
        self.artworkURL = artworkURL; self.artworkData = artworkData; self.state = state
        self.duration = duration; self.position = position; self.commands = commands; self.updatedAt = updatedAt; self.commandGeneration = commandGeneration
    }
    public func withCommands(_ commands: Set<MusicCommand>) -> MusicSnapshot {
        MusicSnapshot(id: id, service: service, title: title, artist: artist, album: album, artworkURL: artworkURL, artworkData: artworkData,
                      state: state, duration: duration, position: position, commands: commands, updatedAt: updatedAt, commandGeneration: commandGeneration)
    }
    public func position(at date: Date) -> Double? {
        guard let position else { return nil }
        let elapsed = state == .playing ? max(0, min(7, date.timeIntervalSince(updatedAt))) : 0
        return min(duration ?? .greatestFiniteMagnitude, max(0, position + elapsed))
    }
}

public struct ProviderUpdate: Sendable {
    public let snapshots: [MusicSnapshot]
    public let state: ProviderState
    public let detail: String?
    public init(_ snapshots: [MusicSnapshot] = [], state: ProviderState = .ready, detail: String? = nil) {
        self.snapshots = snapshots; self.state = state; self.detail = detail
    }
}
public protocol MusicProvider: Sendable {
    var providerID: String { get }
    func poll() async -> ProviderUpdate
    func perform(_ command: MusicCommand, sourceID: String, position: Double?) async throws
    func perform(_ command: MusicCommand, snapshot: MusicSnapshot, position: Double?) async throws
}
public extension MusicProvider {
    func perform(_ command: MusicCommand, snapshot: MusicSnapshot, position: Double?) async throws {
        try await perform(command, sourceID: snapshot.id, position: position)
    }
}

/// Selection stays stable when two sources play. Explicit choice is visible in
/// the picker; stopping, disappearing or expiring always clears stale tracks.
public struct MusicRegistry: Sendable {
    public private(set) var sources: [String: MusicSnapshot] = [:]
    public private(set) var selectedID: String?
    public private(set) var manualID: String?
    private var owners: [String: String] = [:]
    public init() {}
    public var selected: MusicSnapshot? { selectedID.flatMap { sources[$0] } }
    public mutating func apply(provider: String, update: ProviderUpdate, now: Date) {
        for id in Array(owners.keys) where owners[id] == provider { sources[id] = nil; owners[id] = nil }
        for snapshot in update.snapshots where snapshot.state != .stopped && !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard now.timeIntervalSince(snapshot.updatedAt) < 7, snapshot.updatedAt.timeIntervalSince(now) <= 1 else { continue }
            sources[snapshot.id] = snapshot; owners[snapshot.id] = provider
        }
        for (id, snapshot) in sources where now.timeIntervalSince(snapshot.updatedAt) >= 7 { sources[id] = nil; owners[id] = nil }
        choose()
    }
    public mutating func select(_ id: String?) { manualID = id.flatMap { sources[$0] == nil ? nil : $0 }; choose() }
    private mutating func choose() {
        if let manualID, sources[manualID] != nil { selectedID = manualID; return }
        manualID = nil
        if let selectedID, sources[selectedID]?.state == .playing { return }
        let ordered = sources.values.sorted { $0.id < $1.id }
        if let playing = ordered.first(where: { $0.state == .playing }) { selectedID = playing.id }
        else if let selectedID, sources[selectedID] != nil { return }
        else { selectedID = ordered.first?.id }
    }
}

public enum MusicIntegrationError: Error, LocalizedError {
    case invalidMessage, unavailable, unsupportedCommand, commandFailed(String)
    public var errorDescription: String? {
        switch self { case .invalidMessage: return "Некорректное сообщение плеера"; case .unavailable: return "Плеер недоступен";
        case .unsupportedCommand: return "Плеер не поддерживает эту команду"; case .commandFailed(let reason): return reason }
    }
}
