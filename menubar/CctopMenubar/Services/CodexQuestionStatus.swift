import Foundation

struct CodexQuestionRead: Sendable {
    var status: CodexQuestionStatus?
    var questions: CodexAsyncQuestions.State?
    var isWaitingForAnswer = false
}

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

    static func read(matching ids: Set<String>, codexHome: String) async -> [String: CodexQuestionRead] {
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
        return merging(daemon: daemonStatuses ?? [:], desktop: desktopStatuses ?? [:])
    }

    static func merging(daemon: [String: CodexRuntimeStatus], desktop: [String: CodexDesktopStatus]) -> [String: CodexQuestionRead] {
        var statuses = daemon.mapValues {
            CodexQuestionRead(status: Self(runtime: $0), questions: $0.state == .idle ? .empty : $0.questions,
                              isWaitingForAnswer: $0.activeFlags.contains("waitingOnUserInput"))
        }
        for (id, status) in desktop {
            guard Self(runtime: status.runtime, hasPendingQuestion: status.hasPendingQuestion,
                       isWaitingForAnswer: status.isWaitingForAnswer) != nil else { continue }
            let activeDaemon = daemon[id].flatMap { $0.state == .active ? $0 : nil }
            let questions: CodexAsyncQuestions.State?
            if let activeDaemon {
                questions = activeDaemon.questions ?? (status.runtime.state == .active ? status.questions : nil)
            } else {
                questions = status.questions
            }
            let waiting = statuses[id]?.isWaitingForAnswer == true || status.isWaitingForAnswer
            statuses[id] = CodexQuestionRead(
                status: Self(runtime: activeDaemon ?? status.runtime, hasPendingQuestion: questions?.pendingIDs.isEmpty == false,
                             isWaitingForAnswer: waiting),
                questions: questions, isWaitingForAnswer: waiting
            )
        }
        return statuses
    }
}

/// Shared question identity and accepted-answer rules for daemon and Desktop turn items.
enum CodexAsyncQuestions {
    struct State: Equatable, Sendable {
        let turnID: String?
        let pendingIDs: Set<String>
        static let empty = Self(turnID: nil, pendingIDs: [])
    }

    static func read(in turns: [[String: Any]]) -> State? {
        let active = turns.filter { $0["status"] as? String == "inProgress" }
        guard active.count <= 1 else { return nil }
        guard let turn = active.first else { return .empty }
        guard let items = turn["items"] as? [[String: Any]] else { return nil }
        var asked: Set<String> = []
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
            if let content = acceptedContent(in: item) {
                if let answered = answeredQuestions(in: content) {
                    asked.subtract(answered)
                } else {
                    asked.removeAll()
                }
            }
        }
        return State(turnID: turn["id"] as? String ?? turn["turnId"] as? String, pendingIDs: asked)
    }

    private static func acceptedContent(in item: [String: Any]) -> [[String: Any]]? {
        switch item["type"] as? String {
        case "userMessage": return item["content"] as? [[String: Any]]
        case "steeringUserMessage" where item["status"] as? String == "accepted": return item["input"] as? [[String: Any]]
        default: return nil
        }
    }

    private static func answeredQuestions(in content: [[String: Any]]) -> [String]? {
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start) else { return nil }
        guard text.hasSuffix(end) else { return [] }
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
    let status: CodexQuestionStatus?
    var questions: CodexAsyncQuestions.State?
    var isWaitingForAnswer = false
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
        codexQuestionObservations = codexQuestionObservations.filter { activity[$0.key] != nil }
        guard !activity.isEmpty else { return }
        codexQuestionReadAfter = dataSources.now().addingTimeInterval(2)
        let requestedActivity = activity
        codexQuestionReadTask = Task { [weak self] in
            let statuses = await read(Set(requestedActivity.keys))
            guard !Task.isCancelled, let self else { return }
            self.codexQuestionReadTask = nil
            self.recordCodexQuestionReads(statuses, activity: requestedActivity)
            self.loadSessions()
        }
    }

    func recordCodexQuestionReads(_ reads: [String: CodexQuestionRead], activity: [String: Date]) {
        for (id, read) in reads {
            guard let activity = activity[id] else { continue }
            codexQuestionObservations[id] = CodexQuestionObservation(
                activity: activity, status: read.status,
                questions: read.questions ?? codexQuestionObservations[id]?.questions,
                isWaitingForAnswer: read.isWaitingForAnswer
            )
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
