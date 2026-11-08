import Foundation
import Darwin

/// Owns exactly one direct Perl child. Synchronous shutdown also covers app quit
/// before an actor Task has time to execute. Child EOF/PPID checks cover crashes.
final class NowPlayingChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var identity: UUID?
    private var closed = false
    private let readQueue = DispatchQueue(label: "Forelock.NowPlaying.JSON")
    func launch(script: URL, framework: URL, onLine: @escaping @Sendable (Data, Date) -> Void,
                onExit: @escaping @Sendable () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, process == nil else { throw MusicIntegrationError.unavailable }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [script.path, framework.path]
        child.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8", "FORELOCK_PARENT_PID":String(ProcessInfo.processInfo.processIdentifier)]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw MusicIntegrationError.unavailable }
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        let launchIdentity = UUID()
        var framer = NowPlayingFramer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else { file.readabilityHandler = nil; return }
            self?.readQueue.async { [weak self] in
                do { for line in try framer.append(data) { onLine(line, Date()) } }
                catch { self?.stopCurrent(expectedIdentity: launchIdentity) }
            }
        }
        // Drain diagnostics, never persist them or expose arbitrary helper text.
        stderrPipe.fileHandleForReading.readabilityHandler = { file in if file.availableData.isEmpty { file.readabilityHandler = nil } }
        child.terminationHandler = { _ in onExit() }
        do { try child.run() }
        catch { stdoutPipe.fileHandleForReading.readabilityHandler = nil; stderrPipe.fileHandleForReading.readabilityHandler = nil; throw error }
        identity = launchIdentity
        process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading; errorOutput = stderrPipe.fileHandleForReading
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }
    func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, process?.isRunning == true, let input, data.count <= 4096 else { throw MusicIntegrationError.unavailable }
        try input.write(contentsOf: data + Data([10]))
    }
    func stopCurrent(expectedIdentity: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard expectedIdentity == nil || expectedIdentity == identity else { return }
        output?.readabilityHandler = nil; errorOutput?.readabilityHandler = nil
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            child.terminate()
            // SIGTERM default is installed by the host; escalation is a bounded
            // last resort for a wedged owned helper, never another process.
            let pid = child.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now()+1) { if child.isRunning && child.processIdentifier == pid { kill(pid, SIGKILL) } }
        }
        process = nil; output = nil; errorOutput = nil; identity = nil
    }
    func shutdown() { lock.lock(); closed = true; lock.unlock(); stopCurrent() }
    deinit { shutdown() }
}
