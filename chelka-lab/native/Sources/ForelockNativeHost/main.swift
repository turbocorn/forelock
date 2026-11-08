import Foundation
import Darwin
import ForelockMusic

// Chrome authenticates via allowed_origins; independently pin argv[1] too.
guard CommandLine.arguments.count >= 2, CommandLine.arguments[1] == ExtensionIdentity.origin else { exit(77) }
signal(SIGPIPE, SIG_IGN)
var bridge: Int32 = -1
do {
    while true {
        if bridge < 0, let fd = try? SocketIO.connect() {
            var owner: uid_t = 0; var group: gid_t = 0
            guard getpeereid(fd, &owner, &group) == 0, owner == getuid() else { Darwin.close(fd); exit(77) }
            bridge = fd
            // Ask for fresh observations, never replay an old cached track.
            try SocketIO.writeAll(MessageFramer.encode(JSONEncoder().encode(BridgeMessage(type: "poll"))), to: STDOUT_FILENO)
        }
        var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: bridge, events: Int16(POLLIN), revents: 0)]
        let status = poll(&descriptors, 2, 1000)
        if status < 0 && errno == EINTR { continue }
        guard status >= 0 else { break }
        for index in 0..<2 where descriptors[index].revents != 0 {
            if descriptors[index].revents & Int16(POLLIN) == 0 {
                if index == 0 { exit(0) }
                Darwin.close(bridge); bridge = -1; continue
            }
            guard let data = try SocketIO.readFrame(from: descriptors[index].fd) else {
                if index == 0 { exit(0) }
                Darwin.close(bridge); bridge = -1; continue
            }
            let message = try JSONDecoder().decode(BridgeMessage.self, from: data); try message.validate()
            if index == 0 {
                guard ["snapshot", "remove", "result"].contains(message.type) else { throw MusicIntegrationError.invalidMessage }
                if let payload = message.payload { _ = try payload.snapshot(id: message.source ?? "", origin: message.origin ?? "", now: Date()) }
                if bridge >= 0 {
                    do { try SocketIO.writeAll(MessageFramer.encode(data), to: bridge) }
                    catch { Darwin.close(bridge); bridge = -1 }
                }
            } else {
                guard ["command", "poll"].contains(message.type) else { throw MusicIntegrationError.invalidMessage }
                try SocketIO.writeAll(MessageFramer.encode(data), to: STDOUT_FILENO)
            }
        }
    }
} catch { exit(1) }
