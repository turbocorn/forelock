import Foundation
import Darwin

public enum SocketIO {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MusicIntegrationError.unavailable }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }
    public static func configure(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    public static func connect() throws -> Int32 {
        var address = try address(BridgeRules.socketURL.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MusicIntegrationError.unavailable }
        configure(fd)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw MusicIntegrationError.unavailable }
        return fd
    }
    public static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MusicIntegrationError.unavailable }
                offset += count
            }
        }
    }
    public static func readExactly(_ length: Int, from fd: Int32) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: length); var offset = 0
        while offset < length {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), length - offset) }
            if count < 0 && errno == EINTR { continue }
            if count == 0 && offset == 0 { return nil }
            guard count > 0 else { throw MusicIntegrationError.invalidMessage }
            offset += count
        }
        return Data(bytes)
    }
    public static func readFrame(from fd: Int32) throws -> Data? {
        guard let header = try readExactly(4, from: fd) else { return nil }
        let b = Array(header); let count = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        guard count > 0, count <= BridgeRules.maxMessage, let data = try readExactly(count, from: fd) else { throw MusicIntegrationError.invalidMessage }
        return data
    }
}
