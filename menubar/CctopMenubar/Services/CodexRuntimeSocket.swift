import CryptoKit
import Foundation

/// WebSocket transport for Codex's local control socket, with one deadline for the whole read.
final class CodexRuntimeSocket: CodexRuntimeMessaging {
    private let socket: CodexLocalSocket
    private static let maxMessageBytes = 1_048_576

    init(path: String) throws {
        socket = try CodexLocalSocket(path: path)
        try handshake()
    }

    func send(_ message: [String: Any]) throws {
        try sendFrame(JSONSerialization.data(withJSONObject: message), opcode: 1)
    }

    func receive() throws -> [String: Any] {
        var message = Data()
        var continuing = false
        while true {
            let header = try socket.read(2)
            let opcode = header[0] & 0x0f
            let final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw CodexRuntimeReadError.invalidResponse }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 || length == 127 {
                length = try socket.read(length == 126 ? 2 : 8).reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard length <= UInt64(Self.maxMessageBytes) else { throw CodexRuntimeReadError.invalidResponse }
            let payload = try socket.read(Int(length))
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
        try socket.write(Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n").utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16_384 else { throw CodexRuntimeReadError.invalidResponse }
            header.append(try socket.read(1))
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
        try socket.write(frame)
    }

}
