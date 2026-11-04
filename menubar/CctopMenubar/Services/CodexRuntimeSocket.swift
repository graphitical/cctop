import CryptoKit
import Darwin
import Foundation

/// WebSocket transport for Codex's local control socket, with one deadline for the whole read.
final class CodexRuntimeSocket: CodexRuntimeMessaging {
    private var descriptor: Int32 = -1
    private let deadline = ProcessInfo.processInfo.systemUptime + 2
    private static let maxMessageBytes = 1_048_576

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTCONN) }
        do {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            var noSigpipe: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(.EIO)
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.utf8CString
            guard resolvedPath.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: resolvedPath.map { UInt8(bitPattern: $0) }) }
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, addressLength) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTCONN) }
                try wait(for: Int16(POLLOUT))
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw POSIXError(.ENOTCONN) }
            }
            try handshake()
        } catch {
            close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func send(_ message: [String: Any]) throws {
        try sendFrame(JSONSerialization.data(withJSONObject: message), opcode: 1)
    }

    func receive() throws -> [String: Any] {
        var message = Data()
        var continuing = false
        while true {
            let header = try read(2)
            let opcode = header[0] & 0x0f
            let final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw CodexRuntimeReadError.invalidResponse }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 || length == 127 {
                length = try read(length == 126 ? 2 : 8).reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard length <= UInt64(Self.maxMessageBytes) else { throw CodexRuntimeReadError.invalidResponse }
            let payload = try read(Int(length))
            if opcode >= 8 {
                guard final, length <= 125 else { throw CodexRuntimeReadError.invalidResponse }
                switch opcode {
                case 8: throw CodexRuntimeReadError.connectionClosed
                case 9: try sendFrame(payload, opcode: 10)
                case 10: break
                default: throw CodexRuntimeReadError.invalidResponse
                }
                continue
            }
            guard opcode == (continuing ? 0 : 1), message.count + payload.count <= Self.maxMessageBytes else {
                throw CodexRuntimeReadError.invalidResponse
            }
            message.append(payload)
            continuing = !final
            if final {
                guard let json = try JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                    throw CodexRuntimeReadError.invalidResponse
                }
                return json
            }
        }
    }

    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try write(Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n").utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16_384 else { throw CodexRuntimeReadError.invalidResponse }
            header.append(try read(1))
        }
        guard let response = String(data: header, encoding: .utf8) else { throw CodexRuntimeReadError.invalidResponse }
        let lines = response.components(separatedBy: "\r\n")
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
              lines.contains(where: { $0.lowercased().hasPrefix("sec-websocket-accept:")
                  && $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == accept }) else {
            throw CodexRuntimeReadError.invalidResponse
        }
    }

    private func sendFrame(_ payload: Data, opcode: UInt8) throws {
        guard payload.count <= Self.maxMessageBytes else { throw CodexRuntimeReadError.invalidResponse }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            let byteCount = payload.count < 65_536 ? 2 : 8
            frame.append(0x80 | (byteCount == 2 ? 126 : 127))
            for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
                frame.append(UInt8(truncatingIfNeeded: payload.count >> shift))
            }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame)
    }

    private func wait(for events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexRuntimeReadError.timedOut }
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptorState, 1, Int32(ceil(remaining * 1_000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw CodexRuntimeReadError.timedOut }
            guard descriptorState.revents & events != 0 else { throw CodexRuntimeReadError.connectionClosed }
            return
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN))
            let received = data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if received < 0, errno == EINTR || errno == EAGAIN { continue }
            guard received > 0 else { throw CodexRuntimeReadError.connectionClosed }
            offset += received
        }
        return data
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try wait(for: Int16(POLLOUT))
            let sent = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if sent < 0, errno == EINTR || errno == EAGAIN { continue }
            guard sent > 0 else { throw CodexRuntimeReadError.connectionClosed }
            offset += sent
        }
    }
}
