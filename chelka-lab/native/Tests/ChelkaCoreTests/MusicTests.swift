import XCTest
import CryptoKit
@testable import ForelockMusic

final class MusicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func track(_ id: String, state: PlaybackState, at date: Date? = nil) -> MusicSnapshot {
        MusicSnapshot(id: id, service: id == "apple" ? .appleMusic : .zvukChrome, title: id, artist: "Artist", album: "Album", state: state,
                      duration: 200, position: 30, commands: [.play, .pause], updatedAt: date ?? now)
    }
    func testPlayingPriorityStableChoiceAndRemoval() {
        var registry = MusicRegistry()
        registry.apply(provider: "apple", update: ProviderUpdate([track("apple", state: .paused)]), now: now)
        registry.apply(provider: "chrome", update: ProviderUpdate([track("chrome", state: .playing)]), now: now)
        XCTAssertEqual(registry.selectedID, "chrome")
        registry.apply(provider: "apple", update: ProviderUpdate([track("apple", state: .playing)]), now: now)
        XCTAssertEqual(registry.selectedID, "chrome", "Polling order must not cause source oscillation")
        registry.select("apple")
        registry.apply(provider: "chrome", update: ProviderUpdate([track("chrome", state: .playing)]), now: now)
        XCTAssertEqual(registry.selectedID, "apple")
        registry.apply(provider: "apple", update: ProviderUpdate(), now: now)
        XCTAssertNil(registry.manualID)
        XCTAssertEqual(registry.selectedID, "chrome")
        registry.apply(provider: "chrome", update: ProviderUpdate(), now: now)
        XCTAssertNil(registry.selected)
    }
    func testStoppedAndExpiredTracksNeverRemainVisible() {
        var registry = MusicRegistry()
        registry.apply(provider: "apple", update: ProviderUpdate([track("apple", state: .playing)]), now: now)
        registry.apply(provider: "chrome", update: ProviderUpdate(), now: now.addingTimeInterval(8))
        XCTAssertNil(registry.selected)
        registry.apply(provider: "apple", update: ProviderUpdate([track("apple", state: .stopped)]), now: now)
        XCTAssertTrue(registry.sources.isEmpty)
        registry.apply(provider: "chrome", update: ProviderUpdate([track("chrome", state: .paused, at: now.addingTimeInterval(-10))]), now: now)
        XCTAssertTrue(registry.sources.isEmpty)
    }
    func testPositionOnlyAdvancesWhilePlayingAndClampsToDuration() {
        XCTAssertEqual(track("apple", state: .paused).position(at: now.addingTimeInterval(5)), 30)
        XCTAssertEqual(track("apple", state: .playing).position(at: now.addingTimeInterval(5)), 35)
        XCTAssertEqual(track("apple", state: .playing).position(at: now.addingTimeInterval(1000)), 37, "A stale snapshot must not invent ongoing progress")
    }
    func testOriginsAndArtworkAreRestricted() {
        XCTAssertEqual(BridgeRules.service(origin: "https://music.yandex.ru"), .yandexChrome)
        XCTAssertEqual(BridgeRules.service(origin: "https://zvuk.com"), .zvukChrome)
        for origin in ["https://music.yandex.ru.evil.test", "http://zvuk.com", "https://zvuk.com:9000", "https://user@zvuk.com", "https://zvuk.com/private", "https://zvuk.com?token=a"] {
            XCTAssertNil(BridgeRules.service(origin: origin))
        }
        for value in ["file:///etc/passwd", "https://127.0.0.1/a", "http://zvuk.com/a", "https://zvuk.com.evil.test/a", "https://zvuk.com:8080/a"] {
            XCTAssertFalse(BridgeRules.artworkAllowed(URL(string: value)!))
        }
    }
    func testProtocolRejectsUnknownCommandsInvalidSourcesAndMissingSeekPosition() throws {
        let unknown = Data(#"{"version":1,"type":"command","source":"a","requestID":"r","command":"runShell"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeMessage.self, from: unknown))
        var command = BridgeMessage(type: "command", source: "valid:source", requestID: "request", command: .seek)
        XCTAssertThrowsError(try command.validate())
        command.position = 42
        XCTAssertNoThrow(try command.validate())
        command.source = "../../file"
        XCTAssertThrowsError(try command.validate())
    }
    func testFramingHandlesPartialAndMultipleMessagesAndRejectsOversize() throws {
        let data = Data(#"{"version":1,"type":"poll"}"#.utf8)
        let frame = try MessageFramer.encode(data)
        var framer = MessageFramer()
        XCTAssertTrue(try framer.append(Data(frame.prefix(2))).isEmpty)
        XCTAssertEqual(try framer.append(Data(frame.dropFirst(2)) + frame), [data, data])
        XCTAssertThrowsError(try MessageFramer.encode(Data(repeating: 1, count: BridgeRules.maxMessage + 1)))
        XCTAssertThrowsError(try framer.append(Data([255, 255, 255, 127])))
    }
    func testExtensionPublicKeyMatchesPinnedHostIdentityAndMinimumPermissions() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("chrome-extension/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["key"] as? String)))
        let bytes = Array(SHA256.hash(data: key).prefix(16))
        let id = bytes.flatMap { [UnicodeScalar(97 + Int($0 >> 4))!, UnicodeScalar(97 + Int($0 & 15))!] }.map(String.init).joined()
        XCTAssertEqual(id, ExtensionIdentity.id)
        XCTAssertEqual(manifest["permissions"] as? [String], ["nativeMessaging"])
        XCTAssertEqual(Set(manifest["host_permissions"] as? [String] ?? []), Set(["https://music.yandex.ru/*", "https://music.yandex.com/*", "https://zvuk.com/*"]))
    }
}
