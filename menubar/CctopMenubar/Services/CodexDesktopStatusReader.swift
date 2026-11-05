import Foundation

struct CodexDesktopStatus: Equatable, Sendable {
    let runtime: CodexRuntimeStatus
    let hasPendingQuestion: Bool
    let isWaitingForAnswer: Bool

    init?(snapshot: [String: Any]) {
        guard let runtimeJSON = snapshot["threadRuntimeStatus"] as? [String: Any],
              let runtime = CodexRuntimeStatus(json: runtimeJSON),
              let requests = snapshot["requests"] as? [[String: Any]],
              let hasAsyncQuestion = Self.hasAsyncQuestion(in: snapshot) else { return nil }
        self.runtime = runtime
        isWaitingForAnswer = runtime.activeFlags.contains("waitingOnUserInput")
            || requests.contains { $0["method"] as? String == "item/tool/requestUserInput" }
        hasPendingQuestion = isWaitingForAnswer || hasAsyncQuestion
    }

    private static func hasAsyncQuestion(in snapshot: [String: Any]) -> Bool? {
        let turns: [[String: Any]]
        if let history = snapshot["turnHistory"] as? [String: Any], history["kind"] as? String == "canonical" {
            guard let canonical = history["history"] as? [String: Any],
                  let entities = canonical["entitiesByKey"] as? [String: [String: Any]] else { return nil }
            turns = Array(entities.values)
        } else {
            guard let legacy = snapshot["turns"] as? [[String: Any]] else { return nil }
            turns = legacy
        }
        return CodexAsyncQuestions.hasPending(in: turns)
    }
}

/// Reads cached Desktop state through its versioned IPC follower protocol.
/// This is a private client protocol: unrecognized snapshots remain unknown.
/// The temporary observer never takes ownership, loads history, or starts a turn.
enum CodexDesktopStatusReader {
    static func read(matching threadIDs: Set<String>, socketPath: String) throws -> [String: CodexDesktopStatus] {
        guard !threadIDs.isEmpty else { return [:] }
        return try read(matching: threadIDs, messaging: CodexDesktopIPC(path: socketPath))
    }

    static func read(matching threadIDs: Set<String>, messaging: any CodexRuntimeMessaging) throws -> [String: CodexDesktopStatus] {
        guard !threadIDs.isEmpty else { return [:] }
        let requestID = UUID().uuidString
        try messaging.send(["type": "request", "requestId": requestID, "sourceClientId": "initializing-client", "version": 0,
                            "method": "initialize", "params": ["clientType": "cctop"]])
        var clientID: String?
        while clientID == nil {
            let response = try receive(messaging)
            guard response["type"] as? String == "response", response["requestId"] as? String == requestID else { continue }
            guard response["method"] as? String == "initialize", response["resultType"] as? String == "success",
                  let result = response["result"] as? [String: Any], let id = result["clientId"] as? String, !id.isEmpty else {
                throw CodexRuntimeReadError.invalidResponse
            }
            clientID = id
        }
        guard let clientID else { throw CodexRuntimeReadError.invalidResponse }
        var subscriptions: [String] = []
        func follow(_ threadID: String, _ following: Bool) throws {
            try messaging.send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                                "sourceClientId": clientID, "params": ["hostId": "local", "conversationId": threadID, "following": following]])
        }
        defer { for threadID in subscriptions { try? follow(threadID, false) } }
        for threadID in threadIDs.sorted() {
            try follow(threadID, true)
            subscriptions.append(threadID)
        }
        var statuses: [String: CodexDesktopStatus] = [:]
        var remaining = threadIDs
        while !remaining.isEmpty {
            let response: [String: Any]
            do { response = try receive(messaging) } catch CodexRuntimeReadError.timedOut { break }
            guard response["type"] as? String == "broadcast", response["method"] as? String == "thread-stream-state-changed",
                  response["version"] as? Int == 11, let params = response["params"] as? [String: Any],
                  params["hostId"] as? String == "local", let id = params["conversationId"] as? String, remaining.contains(id),
                  let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                  let snapshot = change["conversationState"] as? [String: Any], snapshot["id"] as? String == id,
                  snapshot["hostId"] as? String == "local" else { continue }
            remaining.remove(id)
            if let status = CodexDesktopStatus(snapshot: snapshot) { statuses[id] = status }
        }
        return statuses
    }

    private static func receive(_ messaging: any CodexRuntimeMessaging) throws -> [String: Any] {
        while true {
            let message = try messaging.receive()
            guard message["type"] as? String == "client-discovery-request" else { return message }
            guard let id = message["requestId"] as? String else { throw CodexRuntimeReadError.invalidResponse }
            try messaging.send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
    }
}

private final class CodexDesktopIPC: CodexRuntimeMessaging {
    private let socket: CodexLocalSocket
    private static let maxMessageBytes = 16 * 1_048_576

    init(path: String) throws { socket = try CodexLocalSocket(path: path) }

    func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= Self.maxMessageBytes else { throw CodexRuntimeReadError.invalidResponse }
        var framed = Data((0..<4).map { UInt8(truncatingIfNeeded: data.count >> ($0 * 8)) })
        framed.append(data)
        try socket.write(framed)
    }

    func receive() throws -> [String: Any] {
        let header = try socket.read(4)
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard length > 0, length <= Self.maxMessageBytes,
              let message = try JSONSerialization.jsonObject(with: socket.read(length)) as? [String: Any] else {
            throw CodexRuntimeReadError.invalidResponse
        }
        return message
    }
}
