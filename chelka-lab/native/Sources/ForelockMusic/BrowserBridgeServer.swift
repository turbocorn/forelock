import Foundation
import Darwin

/// Private per-user Unix socket, no TCP listener or web endpoint.
public final class BrowserBridgeServer: @unchecked Sendable {
    private struct Client { let fd: Int32; let read: DispatchSourceRead; var framer = MessageFramer() }
    private let queue = DispatchQueue(label: "Forelock.browser-bridge")
    private var listener: DispatchSourceRead?
    private var clients: [UUID: Client] = [:]
    private let onMessage: @Sendable (UUID, BridgeMessage) -> Void
    private let onConnection: @Sendable (UUID, Bool) -> Void
    public init(onMessage: @escaping @Sendable (UUID, BridgeMessage) -> Void, onConnection: @escaping @Sendable (UUID, Bool) -> Void) {
        self.onMessage = onMessage; self.onConnection = onConnection
    }
    public func start() throws {
        try queue.sync {
            let url = BridgeRules.socketURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(url.deletingLastPathComponent().path, 0o700)
            var existing = stat()
            if lstat(url.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw MusicIntegrationError.unavailable }
                unlink(url.path)
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MusicIntegrationError.unavailable }
            SocketIO.configure(fd); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var address = try SocketIO.address(url.path)
            let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw MusicIntegrationError.unavailable }
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self] in self?.acceptClients(fd) }
            read.setCancelHandler { Darwin.close(fd) }
            listener = read; read.resume()
        }
    }
    private func acceptClients(_ listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard clients.count < 4, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); continue }
            SocketIO.configure(fd); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let id = UUID(); let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self] in self?.receive(id) }
            read.setCancelHandler { Darwin.close(fd) }
            clients[id] = Client(fd: fd, read: read); read.resume(); onConnection(id, true)
        }
    }
    private func receive(_ id: UUID) {
        guard var client = clients[id] else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(client.fd, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { disconnect(id); return }
        do {
            let frames = try client.framer.append(Data(bytes.prefix(count)))
            clients[id] = client
            for frame in frames {
                let message = try JSONDecoder().decode(BridgeMessage.self, from: frame)
                try message.validate()
                guard ["snapshot", "remove", "result"].contains(message.type) else { throw MusicIntegrationError.invalidMessage }
                onMessage(id, message)
            }
        } catch { disconnect(id) }
    }
    public func send(_ message: BridgeMessage, to id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let client = self.clients[id] else { throw MusicIntegrationError.unavailable }
                    try SocketIO.writeAll(MessageFramer.encode(JSONEncoder().encode(message)), to: client.fd)
                    continuation.resume()
                } catch { self.disconnect(id); continuation.resume(throwing: error) }
            }
        }
    }
    private func disconnect(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.read.cancel(); onConnection(id, false)
    }
    public func stop() {
        queue.sync {
            for id in Array(clients.keys) { disconnect(id) }
            listener?.cancel(); listener = nil
            unlink(BridgeRules.socketURL.path)
        }
    }
}
