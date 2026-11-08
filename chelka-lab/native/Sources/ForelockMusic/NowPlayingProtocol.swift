import Foundation
import ImageIO

public enum NowPlayingLimits {
    public static let revision = "0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd"
    public static let bundleID = "ru.yandex.desktop.music"
    public static let messageBytes = 1_500_000
    public static let imageBytes = 1_000_000
    public static let confirmationAge: TimeInterval = 5
    public static let commands: Set<MusicCommand> = [.play, .pause, .next, .previous]
}

public enum NowPlayingTransportPolicy {
    public static func blocked(_ yandex: MusicSnapshot?, by others: [MusicSnapshot], now: Date = Date()) -> Bool {
        guard yandex?.service == .yandexDesktop else { return false }
        return others.contains { $0.service != .yandexDesktop && $0.state == .playing && now.timeIntervalSince($0.updatedAt) >= 0 && now.timeIntervalSince($0.updatedAt) < 7 }
    }
}

/// Bounded newline JSON. stderr is separate; arbitrary fragments never reach a decoder.
public struct NowPlayingFramer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        for part in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 {
                guard !buffer.isEmpty else { throw MusicIntegrationError.invalidMessage }
                lines.append(buffer); buffer = Data()
            }
            guard buffer.count + part.element.count <= NowPlayingLimits.messageBytes else { throw MusicIntegrationError.invalidMessage }
            buffer.append(contentsOf: part.element)
        }
        return lines
    }
}

struct NowPlayingEnvelope: Decodable {
    let v: Int
    let type: String
    let session: String
    let generation: UInt64
    let sequence: UInt64
    let revision: String?
    let available: Bool?
    let reason: String?
    let bundleIdentifier: String?
    let pid: Int32?
    let title: String?
    let artist: String?
    let album: String?
    let playing: Bool?
    let duration: Double?
    let position: Double?
    let artwork: String?
    let commands: [MusicCommand]?
    let requestID: String?
    let ok: Bool?
    let code: String?
    let sent: Bool?
    func validate() throws {
        guard v == 1, ["ready", "state", "result", "fatal"].contains(type), UUID(uuidString: session) != nil,
              sequence > 0, sequence <= 9_007_199_254_740_991, generation <= 9_007_199_254_740_991,
              title.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 512 }) ?? true,
              artist.map({ $0.count <= 1024 }) ?? true, album.map({ $0.count <= 512 }) ?? true,
              requestID.map({ UUID(uuidString: $0) != nil }) ?? true,
              code.map({ $0.count <= 64 }) ?? true, reason.map({ $0.count <= 64 }) ?? true,
              duration.map({ $0.isFinite && $0 > 0 && $0 <= 604800 }) ?? true,
              position.map({ $0.isFinite && $0 >= 0 && $0 <= 604800 }) ?? true,
              artwork.map({ $0.utf8.count <= 1_333_336 }) ?? true else { throw MusicIntegrationError.invalidMessage }
        if type == "ready", revision != NowPlayingLimits.revision { throw MusicIntegrationError.invalidMessage }
        if type == "state", available == true {
            guard bundleIdentifier == NowPlayingLimits.bundleID, let pid, pid > 0, title != nil, artist != nil, album != nil,
                  playing != nil, generation > 0, let commands, Set(commands).isSubset(of: NowPlayingLimits.commands),
                  commands.count <= 4 else { throw MusicIntegrationError.invalidMessage }
            if let duration, let position, position > duration + 1 { throw MusicIntegrationError.invalidMessage }
        }
    }
}

/// Pure receipt/generation model. A result never refreshes metadata liveness.
struct NowPlayingSession {
    private(set) var session: String?
    private(set) var generation: UInt64 = 0
    private(set) var sequence: UInt64 = 0
    private(set) var snapshot: MusicSnapshot?
    private(set) var confirmedAt: Date?
    private(set) var reason = "connecting"
    mutating func consume(_ message: NowPlayingEnvelope, receivedAt: Date) throws {
        try message.validate()
        if message.type == "ready" {
            guard session == nil else { throw MusicIntegrationError.invalidMessage }
            session = message.session
        }
        guard session == message.session, message.sequence > sequence, message.generation >= generation else { throw MusicIntegrationError.invalidMessage }
        if message.generation > generation { snapshot = nil }
        sequence = message.sequence; generation = message.generation
        if message.type == "state" {
            confirmedAt = receivedAt
            guard message.available == true else { snapshot = nil; reason = message.reason ?? "unavailable"; return }
            var data: Data?
            if let encoded = message.artwork {
                guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty, decoded.count <= NowPlayingLimits.imageBytes,
                      let source = CGImageSourceCreateWithData(decoded as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? NSNumber, let h = props[kCGImagePropertyPixelHeight] as? NSNumber,
                      w.doubleValue > 0, h.doubleValue > 0, w.doubleValue <= 2048, h.doubleValue <= 2048,
                      w.doubleValue*h.doubleValue <= 4_000_000 else { throw MusicIntegrationError.invalidMessage }
                data = decoded
            }
            reason = "ready"
            snapshot = MusicSnapshot(id: "yandex-desktop/\(message.pid!)", service: .yandexDesktop, title: message.title!, artist: message.artist!, album: message.album!,
                                     artworkData: data, state: message.playing! ? .playing : .paused, duration: message.duration, position: message.position,
                                     commands: Set(message.commands!), updatedAt: receivedAt, commandGeneration: "\(message.session)/\(message.generation)")
        }
        if message.type == "fatal" { snapshot = nil; reason = message.reason ?? "unsupported-api" }
    }
    func current(at date: Date) -> MusicSnapshot? {
        guard let confirmedAt, date.timeIntervalSince(confirmedAt) >= 0, date.timeIntervalSince(confirmedAt) < NowPlayingLimits.confirmationAge else { return nil }
        return snapshot
    }
}

struct HelperBackoff {
    private(set) var attempts = 0
    mutating func nextDelay() -> Double? {
        guard attempts < 5 else { return nil }
        let delay = min(8, 0.5 * pow(2, Double(attempts))); attempts += 1; return delay
    }
    mutating func reset() { attempts = 0 }
}
