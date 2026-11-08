import Foundation

public struct BrowserPayload: Codable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let artwork: String?
    public let state: PlaybackState
    public let duration: Double?
    public let position: Double?
    public let commands: [MusicCommand]
    public func snapshot(id: String, origin: String, now: Date) throws -> MusicSnapshot {
        guard let service = BridgeRules.service(origin: origin), title.count <= 512, artist.count <= 512, album.count <= 512,
              commands.count <= 5, duration.map({ $0.isFinite && $0 >= 0 && $0 <= 604800 }) ?? true,
              position.map({ $0.isFinite && $0 >= 0 && $0 <= 604800 }) ?? true else { throw MusicIntegrationError.invalidMessage }
        let artworkURL = artwork.flatMap(URL.init(string:)).flatMap { BridgeRules.artworkAllowed($0) ? $0 : nil }
        var supported = Set(commands)
        if duration == nil { supported.remove(.seek) }
        return MusicSnapshot(id: id, service: service, title: title, artist: artist, album: album, artworkURL: artworkURL,
                             state: state, duration: duration, position: position, commands: supported, updatedAt: now)
    }
}
public struct BridgeMessage: Codable, Sendable {
    public var version: Int = 1
    public var type: String
    public var source: String?
    public var origin: String?
    public var payload: BrowserPayload?
    public var requestID: String?
    public var command: MusicCommand?
    public var position: Double?
    public var ok: Bool?
    public var error: String?
    public init(type: String, source: String? = nil, requestID: String? = nil, command: MusicCommand? = nil, position: Double? = nil) {
        self.type = type; self.source = source; self.requestID = requestID; self.command = command; self.position = position
    }
    public func validate() throws {
        guard version == 1, ["snapshot", "remove", "result", "command", "poll", "status"].contains(type),
              source.map({ !$0.isEmpty && $0.count <= 128 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_:".contains($0)) } }) ?? true,
              requestID.map({ $0.count <= 64 }) ?? true, error.map({ $0.count <= 256 }) ?? true else { throw MusicIntegrationError.invalidMessage }
        if type == "snapshot" { guard source != nil, let origin, BridgeRules.service(origin: origin) != nil, payload != nil else { throw MusicIntegrationError.invalidMessage } }
        if type == "command" { guard source != nil, command != nil, requestID != nil, position.map({ $0.isFinite && $0 >= 0 && $0 <= 604800 }) ?? true else { throw MusicIntegrationError.invalidMessage } }
        if type == "command", command == .seek, position == nil { throw MusicIntegrationError.invalidMessage }
        if type == "remove" || type == "result" { guard source != nil else { throw MusicIntegrationError.invalidMessage } }
    }
}
public enum BridgeRules {
    public static let maxMessage = 65_536
    public static let hostName = "com.turbocorn.forelock.music"
    public static var socketURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Forelock/bridge.sock") }
    public static func service(origin: String) -> MusicService? {
        guard let u = URLComponents(string: origin), u.scheme == "https", u.user == nil, u.password == nil, u.port == nil,
              (u.path.isEmpty || u.path == "/"), u.query == nil, u.fragment == nil else { return nil }
        switch u.host { case "music.yandex.ru", "music.yandex.com": return .yandexChrome; case "zvuk.com": return .zvukChrome; default: return nil }
    }
    public static func artworkAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.absoluteString.count <= 2048,
              let host = url.host?.lowercased() else { return false }
        return ["music.yandex.ru", "music.yandex.com", "avatars.yandex.net", "avatars.mds.yandex.net", "zvuk.com"].contains(host) || host.hasSuffix(".zvuk.com")
    }
}

public struct MessageFramer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        guard buffer.count + data.count <= BridgeRules.maxMessage * 2 + 8 else { throw MusicIntegrationError.invalidMessage }
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let bytes = Array(buffer.prefix(4))
            let length = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
            guard length > 0, length <= BridgeRules.maxMessage else { throw MusicIntegrationError.invalidMessage }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(4 + length)
        }
        return frames
    }
    public static func encode(_ data: Data) throws -> Data {
        guard !data.isEmpty && data.count <= BridgeRules.maxMessage else { throw MusicIntegrationError.invalidMessage }
        var length = UInt32(data.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }; result.append(data); return result
    }
}
