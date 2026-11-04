import Darwin
import Foundation

/// Bounded local I/O shared by the daemon WebSocket and desktop IPC readers.
final class CodexLocalSocket {
    private var descriptor: Int32 = -1
    private let deadline = ProcessInfo.processInfo.systemUptime + 2

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
        } catch {
            close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func read(_ count: Int) throws -> Data {
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

    func write(_ data: Data) throws {
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
}
