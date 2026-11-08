import XCTest
@testable import ForelockMusic

final class NowPlayingTests: XCTestCase {
    private let session = "7AAEEBED-A211-461C-8149-6338AA937813"
    private let now = Date(timeIntervalSince1970: 1000)
    private func record(_ type: String, sequence: Int = 1, generation: Int = 1, fields: [String: Any] = [:]) throws -> NowPlayingEnvelope {
        var json: [String: Any] = ["v":1,"type":type,"session":session,"sequence":sequence,"generation":generation]
        fields.forEach { json[$0.key] = $0.value }
        return try JSONDecoder().decode(NowPlayingEnvelope.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func ready(_ state: inout NowPlayingSession) throws {
        try state.consume(record("ready", generation: 0, fields: ["revision":NowPlayingLimits.revision]), receivedAt: now)
    }
    private var track: [String: Any] { ["available":true,"bundleIdentifier":NowPlayingLimits.bundleID,"pid":123,"title":"Real title","artist":"Artist","album":"Album","playing":true,"duration":200,"position":30,"commands":["pause","next","previous"]] }
    func testBoundedPartialLinesAndMultipleFrames() throws {
        var framer = NowPlayingFramer()
        XCTAssertTrue(try framer.append(Data("{\"v\":".utf8)).isEmpty)
        XCTAssertEqual(try framer.append(Data("1}\n{}\n".utf8)),[Data("{\"v\":1}".utf8),Data("{}".utf8)])
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: NowPlayingLimits.messageBytes+1)))
    }
    func testForeignSourceCannotBecomeYandexEvenWithTitleAndCommands() throws {
        var state = NowPlayingSession(); try ready(&state)
        var fields = track; fields["bundleIdentifier"] = "com.apple.Music"
        XCTAssertThrowsError(try state.consume(record("state", sequence: 2, fields: fields), receivedAt: now))
        XCTAssertNil(state.snapshot)
    }
    func testQuietStreamNeedsPeriodicConfirmationButDoesNotMeanPaused() throws {
        var state = NowPlayingSession(); try ready(&state)
        try state.consume(record("state",sequence:2,fields:track),receivedAt:now)
        XCTAssertEqual(state.current(at:now.addingTimeInterval(4))?.state,.playing)
        XCTAssertNil(state.current(at:now.addingTimeInterval(5)))
        try state.consume(record("state",sequence:3,fields:track),receivedAt:now.addingTimeInterval(4))
        XCTAssertEqual(state.current(at:now.addingTimeInterval(8))?.state,.playing)
    }
    func testSessionReplayGenerationAndForeignTransitionInvalidateCommands() throws {
        var state = NowPlayingSession();try ready(&state)
        try state.consume(record("state",sequence:2,fields:track),receivedAt:now)
        XCTAssertNotNil(state.snapshot?.commandGeneration)
        XCTAssertThrowsError(try state.consume(record("state",sequence:2,fields:track),receivedAt:now))
        try state.consume(record("state",sequence:3,generation:2,fields:["available":false,"reason":"foreign-source"]),receivedAt:now)
        XCTAssertNil(state.snapshot)
        XCTAssertThrowsError(try state.consume(record("state",sequence:4,generation:1,fields:track),receivedAt:now))
        XCTAssertThrowsError(try state.consume(record("state",sequence:4,generation:2,fields:track.merging(["session":UUID().uuidString]) { _,v in v }),receivedAt:now))
    }
    func testResultsDoNotRenewLivenessAndImagesAreValidated() throws {
        var state=NowPlayingSession();try ready(&state)
        try state.consume(record("state",sequence:2,fields:track),receivedAt:now)
        try state.consume(record("result",sequence:3,fields:["requestID":UUID().uuidString,"ok":true]),receivedAt:now.addingTimeInterval(6))
        XCTAssertNil(state.current(at:now.addingTimeInterval(6)))
        var image=track;image["artwork"]=Data("not an image".utf8).base64EncodedString()
        XCTAssertThrowsError(try state.consume(record("state",sequence:4,fields:image),receivedAt:now))
        var seek=track;seek["commands"]=["seek"]
        XCTAssertThrowsError(try record("state",sequence:5,fields:seek).validate())
    }
    func testRestartCircuitBreakerAndIndependentPlayingSourcePolicy() {
        var backoff=HelperBackoff()
        XCTAssertEqual((0..<5).compactMap{_ in backoff.nextDelay()},[0.5,1,2,4,8])
        XCTAssertNil(backoff.nextDelay());backoff.reset();XCTAssertEqual(backoff.nextDelay(),0.5)
        let yandex=MusicSnapshot(id:"desktop",service:.yandexDesktop,title:"Song",artist:"Artist",album:"",state:.paused,duration:nil,position:nil,commands:[.play],updatedAt:now)
        let chrome=MusicSnapshot(id:"chrome",service:.yandexChrome,title:"Other",artist:"Artist",album:"",state:.playing,duration:nil,position:nil,commands:[.pause],updatedAt:now)
        XCTAssertTrue(NowPlayingTransportPolicy.blocked(yandex,by:[chrome],now:now))
        XCTAssertFalse(NowPlayingTransportPolicy.blocked(yandex,by:[chrome],now:now.addingTimeInterval(8)))
        XCTAssertFalse(NowPlayingTransportPolicy.blocked(yandex,by:[],now:now))
    }
}
