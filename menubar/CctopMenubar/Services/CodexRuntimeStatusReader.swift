import Foundation

/// Runtime facts only. A missing entry is unknown, never evidence that a session is ready.
struct CodexRuntimeStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case active, idle, notLoaded, systemError
    }

    let state: State
    let activeFlags: Set<String>
    var questions: CodexAsyncQuestions.State?
    var hasPendingQuestion: Bool { questions?.pendingIDs.isEmpty == false }

    init?(json: [String: Any]) {
        guard let type = json["type"] as? String, let state = State(rawValue: type) else { return nil }
        guard state != .active || json["activeFlags"] is [String] else { return nil }
        self.state = state
        activeFlags = state == .active ? Set(json["activeFlags"] as? [String] ?? []) : []
    }
}

protocol CodexRuntimeMessaging {
    func send(_ message: [String: Any]) throws
    func receive() throws -> [String: Any]
}

enum CodexRuntimeReadError: Error {
    case invalidResponse, connectionClosed, timedOut
}

/// A bounded, blocking metadata read; call from a background queue.
/// Only threads already loaded in this daemon are queried. This does not attach to
/// separate Desktop app-servers, load threads, subscribe, or answer server requests.
enum CodexRuntimeStatusReader {
    static func read(matching threadIDs: Set<String>, socketPath: String) throws -> [String: CodexRuntimeStatus] {
        guard !threadIDs.isEmpty else { return [:] }
        return try read(matching: threadIDs, messaging: CodexRuntimeSocket(path: socketPath))
    }

    static func read(matching threadIDs: Set<String>, messaging: any CodexRuntimeMessaging) throws -> [String: CodexRuntimeStatus] {
        guard !threadIDs.isEmpty else { return [:] }
        guard try request(0, method: "initialize", params: [
            "clientInfo": ["name": "cctop_status_reader", "version": Config.hookVersion]
        ], messaging: messaging) != nil else { throw CodexRuntimeReadError.invalidResponse }
        try messaging.send(["method": "initialized", "params": [:]])
        let loaded = try request(1, method: "thread/loaded/list", params: [:], messaging: messaging)
        guard let loadedIDs = loaded?["data"] as? [String] else { throw CodexRuntimeReadError.invalidResponse }
        var statuses: [String: CodexRuntimeStatus] = [:]
        var requestID = 2
        for threadID in threadIDs.intersection(loadedIDs).sorted() {
            let result = try request(requestID, method: "thread/read", params: [
                "threadId": threadID, "includeTurns": false
            ], messaging: messaging)
            requestID += 1
            guard let thread = result?["thread"] as? [String: Any], thread["id"] as? String == threadID,
                  let json = thread["status"] as? [String: Any], let status = CodexRuntimeStatus(json: json) else { continue }
            statuses[threadID] = status
        }
        // Keep authoritative activity and blocking flags even if a turn exceeds
        // the transport bound or an older daemon cannot supply question history.
        for threadID in statuses.keys.sorted() {
            guard let status = statuses[threadID], status.state == .active, status.activeFlags.isEmpty else { continue }
            do {
                let page = try request(requestID, method: "thread/turns/list", params: [
                    "threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "full"
                ], messaging: messaging)
                requestID += 1
                // Summaries omit accepted replies, so only full turns can clear questions.
                if let turns = page?["data"] as? [[String: Any]], turns.count <= 1,
                   turns.allSatisfy({ $0["itemsView"] as? String == "full" }) {
                    statuses[threadID]?.questions = CodexAsyncQuestions.read(in: turns)
                }
            } catch { break }
        }
        return statuses
    }

    private static func request(
        _ id: Int, method: String, params: [String: Any], messaging: any CodexRuntimeMessaging
    ) throws -> [String: Any]? {
        try messaging.send(["id": id, "method": method, "params": params])
        while true {
            let message = try messaging.receive()
            // Notifications and server requests are not replies. Never answer a request
            // delivered to another Codex client, even if its numeric ID happens to match.
            guard message["method"] == nil, message["id"] as? Int == id else { continue }
            if message["error"] != nil { return nil }
            guard let result = message["result"] as? [String: Any] else { throw CodexRuntimeReadError.invalidResponse }
            return result
        }
    }
}
