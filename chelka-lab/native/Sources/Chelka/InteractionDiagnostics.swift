import Foundation

/// Temporary 0.3.2 diagnostics. Local coordinates/state only, no file contents.
final class InteractionDiagnostics {
    let url: URL
    private let file: FileHandle?
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Forelock-interaction-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }
    func record(_ reason: String, snapshot: [String: Any]) {
        var entry = snapshot
        entry["reason"] = reason
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        entry["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? file?.write(contentsOf: data)
    }
    deinit { try? file?.close() }
}
