import Foundation

enum CodexQuestionStatus: Equatable, Sendable {
    case blocked, ready, running, runningWithQuestion

    init?(runtime: CodexRuntimeStatus, hasPendingQuestion: Bool? = nil, isWaitingForAnswer: Bool = false) {
        let hasPendingQuestion = hasPendingQuestion ?? runtime.hasPendingQuestion
        if isWaitingForAnswer || runtime.activeFlags.contains("waitingOnUserInput") {
            self = .blocked
        } else if runtime.state == .idle {
            self = hasPendingQuestion ? .blocked : .ready
        } else if runtime.state == .active, runtime.activeFlags.isEmpty {
            self = hasPendingQuestion ? .runningWithQuestion : .running
        } else {
            return nil
        }
    }

    static func read(matching ids: Set<String>, codexHome: String) async -> [String: Self] {
        guard !ids.isEmpty else { return [:] }
        let daemonPath = (codexHome as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
        let desktopPath = (codexHome as NSString).appendingPathComponent("ipc/ipc.sock")
        async let daemon = Task.detached(priority: .utility) {
            try? CodexRuntimeStatusReader.read(matching: ids, socketPath: daemonPath)
        }.value
        async let desktop = Task.detached(priority: .utility) {
            try? CodexDesktopStatusReader.read(matching: ids, socketPath: desktopPath)
        }.value
        let (daemonStatuses, desktopStatuses) = await (daemon, desktop)
        var statuses = (daemonStatuses ?? [:]).compactMapValues { Self(runtime: $0) }
        for (id, status) in desktopStatuses ?? [:] {
            guard let observed = Self(runtime: status.runtime, hasPendingQuestion: status.hasPendingQuestion,
                                      isWaitingForAnswer: status.isWaitingForAnswer) else { continue }
            if observed == .blocked || statuses[id] == .blocked {
                statuses[id] = .blocked
            } else if observed == .runningWithQuestion || statuses[id] == .runningWithQuestion {
                statuses[id] = .runningWithQuestion
            } else if observed == .running || statuses[id] == .running {
                statuses[id] = .running
            } else {
                statuses[id] = .ready
            }
        }
        return statuses
    }
}

/// Shared question identity and accepted-answer rules for daemon and Desktop turn items.
enum CodexAsyncQuestions {
    static func hasPending(in turns: [[String: Any]]) -> Bool? {
        let active = turns.filter { $0["status"] as? String == "inProgress" }
        guard active.count <= 1 else { return nil }
        guard let turn = active.first else { return false }
        guard let items = turn["items"] as? [[String: Any]] else { return nil }
        var asked: Set<String> = []
        var answered: Set<String> = []
        for item in items {
            if item["type"] as? String == "agentMessage", let field = item["questions"], !(field is NSNull) {
                guard let questions = field as? [[String: Any]], questions.allSatisfy({ $0["title"] is String }),
                      let id = item["id"] as? String else { return nil }
                for index in questions.indices {
                    guard let data = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", id, index],
                                                                 options: [.withoutEscapingSlashes]),
                          let key = String(data: data, encoding: .utf8) else { return nil }
                    asked.insert(key)
                }
            }
            answered.formUnion(answeredQuestions(in: item))
        }
        return !asked.subtracting(answered).isEmpty
    }

    private static func answeredQuestions(in item: [String: Any]) -> [String] {
        let content: [[String: Any]]?
        switch item["type"] as? String {
        case "userMessage": content = item["content"] as? [[String: Any]]
        case "steeringUserMessage" where item["status"] as? String == "accepted": content = item["input"] as? [[String: Any]]
        default: return []
        }
        let text = (content ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start), text.hasSuffix(end) else { return [] }
        let data = Data(text.dropFirst(start.count).dropLast(end.count).utf8)
        let decoder = JSONDecoder()
        let replies = (try? decoder.decode([QuestionReply].self, from: data))
            ?? (try? decoder.decode(QuestionReply.self, from: data)).map { [$0] } ?? []
        return replies.map(\.questionItemId)
    }

    private struct QuestionReply: Decodable {
        let questionItemId: String
        let question: String
        let answer: String
    }
}

struct CodexQuestionObservation {
    let activity: Date
    let status: CodexQuestionStatus
}

extension SessionManager {
    func scheduleCodexQuestionRead(for sessions: [UserSession]) {
        guard monitorsRuntimeStatus, codexQuestionReadTask == nil,
              dataSources.now() >= codexQuestionReadAfter, let read = dataSources.readCodexQuestions else { return }
        var activity: [String: Date] = [:]
        for session in sessions {
            let data = session.displayRecord.data
            guard data.isCodex, data.lifecycle == .active else { continue }
            activity[data.sessionId] = data.lastActivity
        }
        guard !activity.isEmpty else { codexQuestionObservations = [:]; return }
        codexQuestionReadAfter = dataSources.now().addingTimeInterval(2)
        let requestedActivity = activity
        codexQuestionReadTask = Task { [weak self] in
            let statuses = await read(Set(requestedActivity.keys))
            guard !Task.isCancelled, let self else { return }
            self.codexQuestionReadTask = nil
            self.codexQuestionObservations = statuses.reduce(into: [:]) { observations, entry in
                guard let activity = requestedActivity[entry.key] else { return }
                observations[entry.key] = CodexQuestionObservation(activity: activity, status: entry.value)
            }
            self.loadSessions()
        }
    }

    nonisolated static func applyingCodexQuestionStatus(_ status: CodexQuestionStatus?, to session: SessionData) -> SessionData {
        guard session.isCodex, session.lifecycle == .active, session.status != .waitingPermission, let status else { return session }
        var result = session
        result.hasPendingAsyncQuestion = status == .runningWithQuestion
        switch status {
        case .blocked: result.status = .waitingAnswer
        case .ready where session.status == .working || session.status == .waitingInput || session.status == .waitingAnswer:
            result.status = .waitingInput
        case .running, .runningWithQuestion:
            if session.status == .waitingInput || session.status == .waitingAnswer { result.status = .working }
        default: break
        }
        return result
    }
}
