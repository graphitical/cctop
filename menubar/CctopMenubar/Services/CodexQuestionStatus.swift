import Foundation

enum CodexQuestionStatus: Equatable, Sendable {
    case blocked, ready, running, runningWithQuestion

    init?(runtime: CodexRuntimeStatus, hasPendingQuestion: Bool = false, isWaitingForAnswer: Bool = false) {
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
