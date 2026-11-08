import AppKit
import Carbon

/// Public Music.sdef Apple Events, addressed only to an already-running PID.
/// Synchronous IPC and the potentially unbounded consent prompt stay on this actor.
public actor AppleMusicProvider: MusicProvider {
    public nonisolated let providerID = "apple"
    private var artworkKey: String?
    private var artwork: Data?
    public init() {}
    private func target() -> NSAppleEventDescriptor? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first, !app.isTerminated else { return nil }
        return NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
    }
    private func authorization(_ target: NSAppleEventDescriptor, ask: Bool) -> OSStatus {
        guard let address = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
    public func requestAuthorization() -> ProviderState {
        guard let target = target() else { return .notRunning }
        return permissionState(authorization(target, ask: true))
    }
    private func permissionState(_ status: OSStatus) -> ProviderState {
        switch status { case noErr: return .ready; case OSStatus(errAEEventWouldRequireUserConsent): return .permissionRequired;
        case OSStatus(errAEEventNotPermitted): return .permissionDenied; case OSStatus(procNotFound): return .notRunning; default: return .failed }
    }
    private func code(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }
    private func firstArtwork(of track: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code("cArt")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(int32: 1), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(track, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }
    private func event(_ eventClass: String, _ eventID: String, target: NSAppleEventDescriptor,
                       object: NSAppleEventDescriptor? = nil, value: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID), targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: AEKeyword(keyDirectObject)) }
        if let value { event.setParam(value, forKeyword: AEKeyword(keyAEData)) }
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord,
                                                           .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let reply = try event.sendEvent(options: options, timeout: 0.75)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw MusicIntegrationError.commandFailed("Music.app: Apple Event \(error.int32Value)")
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }
    private func get(_ object: NSAppleEventDescriptor, target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try event("core", "getd", target: target, object: object)
    }
    public func poll() -> ProviderUpdate {
        guard let target = target() else { artwork = nil; artworkKey = nil; return ProviderUpdate(state: .notRunning) }
        let permission = permissionState(authorization(target, ask: false))
        guard permission == .ready else { artwork = nil; artworkKey = nil; return ProviderUpdate(state: permission) }
        do {
            let stateCode = try get(property("pPlS"), target: target).enumCodeValue
            guard stateCode != code("kPSS") else { artwork = nil; artworkKey = nil; return ProviderUpdate() }
            let state: PlaybackState = stateCode == code("kPSp") ? .paused : .playing
            let track = property("pTrk")
            let title = try get(property("pnam", of: track), target: target).stringValue ?? ""
            guard !title.isEmpty else { return ProviderUpdate() }
            let artist = try get(property("pArt", of: track), target: target).stringValue ?? ""
            let album = try get(property("pAlb", of: track), target: target).stringValue ?? ""
            let durationValue = try get(property("pDur", of: track), target: target).doubleValue
            let positionValue = try get(property("pPos"), target: target).doubleValue
            let key = [title, artist, album].joined(separator: "\u{1F}")
            if key != artworkKey {
                artworkKey = key; artwork = nil
                if let data = try? get(property("pRaw", of: firstArtwork(of: track)), target: target).data,
                   !data.isEmpty, data.count <= 2_000_000 { artwork = data }
            }
            let duration = durationValue.isFinite && durationValue > 0 ? durationValue : nil
            let position = positionValue.isFinite && positionValue >= 0 ? positionValue : nil
            var commands: Set<MusicCommand> = [.play, .pause, .previous, .next]
            if duration != nil { commands.insert(.seek) }
            return ProviderUpdate([MusicSnapshot(id: "apple/music", service: .appleMusic, title: title, artist: artist, album: album,
                                                  artworkData: artwork, state: state, duration: duration, position: position, commands: commands)])
        } catch {
            // Any failed observation removes the old track; never report cached
            // metadata as current after Music exits, stops or becomes unreachable.
            artwork = nil; artworkKey = nil
            return ProviderUpdate(state: .failed, detail: error.localizedDescription)
        }
    }
    public func perform(_ command: MusicCommand, sourceID: String, position: Double?) throws {
        guard sourceID == "apple/music", let target = target(), authorization(target, ask: false) == noErr else { throw MusicIntegrationError.unavailable }
        if command == .seek {
            guard let position, position.isFinite, position >= 0, position <= 604800 else { throw MusicIntegrationError.invalidMessage }
            _ = try event("core", "setd", target: target, object: property("pPos"), value: .init(double: position))
        } else {
            let id: String
            switch command { case .play: id = "Play"; case .pause: id = "Paus"; case .previous: id = "Prev"; case .next: id = "Next"; case .seek: return }
            _ = try event("hook", id, target: target)
        }
    }
}
