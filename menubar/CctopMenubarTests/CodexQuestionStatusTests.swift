import Combine
import XCTest
@testable import CctopMenubar

final class CodexQuestionStatusTests: XCTestCase {
    func testRuntimeFactsDistinguishQuestionsFromFinishedAndRunningTurns() throws {
        func status(_ type: String, flags: [String] = [], pending: Bool = false) throws -> CodexQuestionStatus? {
            let runtime = try XCTUnwrap(CodexRuntimeStatus(json: ["type": type, "activeFlags": flags]))
            return CodexQuestionStatus(runtime: runtime, hasPendingQuestion: pending)
        }
        XCTAssertEqual(try status("active", flags: ["waitingOnUserInput"]), .blocked)
        XCTAssertEqual(try status("active", pending: true), .runningWithQuestion)
        XCTAssertEqual(try status("idle", pending: true), .blocked)
        XCTAssertEqual(try status("idle"), .ready)
        XCTAssertEqual(try status("active"), .running)
        XCTAssertNil(try status("active", flags: ["waitingOnApproval"]))
        XCTAssertNil(try status("active", flags: ["futureFlag"]))
        XCTAssertNil(try status("notLoaded"))
        XCTAssertNil(try status("systemError"))
        XCTAssertNil(try status("notLoaded", pending: true))
        let runtime = try XCTUnwrap(CodexRuntimeStatus(json: ["type": "active", "activeFlags": []]))
        XCTAssertEqual(CodexQuestionStatus(runtime: runtime, hasPendingQuestion: true, isWaitingForAnswer: true), .blocked)
    }

    @MainActor
    func testWorkingQuestionIsAnIndependentDisplayFlag() throws {
        let working = SessionData.mock(status: .working, source: "codex")
        let pending = SessionManager.applyingCodexQuestionStatus(.runningWithQuestion, to: working)
        XCTAssertEqual(pending.status, .working)
        XCTAssertTrue(pending.hasPendingQuestion)
        XCTAssertEqual(pending.contextLine, "Still working · question pending")
        XCTAssertEqual(pending.statusAccessibilityDescription, "working, question pending")
        XCTAssertTrue(pending.shouldPostAttentionNotification)
        XCTAssertEqual(pending.notificationContent.subtitle, "Codex has a question and is still working")
        let persisted = try JSONEncoder.sessionEncoder.encode(pending)
        XCTAssertEqual(try JSONDecoder.sessionDecoder.decode(SessionData.self, from: persisted),
                       try JSONDecoder.sessionDecoder.decode(SessionData.self, from: JSONEncoder.sessionEncoder.encode(working)))
        let answered = SessionManager.applyingCodexQuestionStatus(.running, to: pending)
        XCTAssertEqual(answered.status, .working)
        XCTAssertFalse(answered.hasPendingQuestion)
        XCTAssertFalse(answered.shouldPostAttentionNotification)
        let blocked = SessionData.mock(id: "blocked", status: .waitingAnswer, source: "codex")
        let ready = SessionData.mock(id: "ready", status: .waitingInput, source: "codex")
        let sessions = userSessions(fromDataFixtures: [pending, blocked, ready])
        let counts = StatusCounts(userSessions: sessions)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.questions, 2)
        XCTAssertEqual(counts.blockedQuestions, 1)
        XCTAssertEqual(counts.idle, 1)
        XCTAssertEqual(counts.needsAction, 2)
        XCTAssertEqual(counts.questionLabel, "? 2")
        XCTAssertGreaterThan(MenubarIconRenderer.render(counts: counts).size.width, 36)
        let snapshot = DisplayStateWriter.snapshot(userSessions: sessions, theme: .codex, appRunning: false, appIdentity: nil, now: Date())
        let entry = try XCTUnwrap(snapshot.sessions.first { $0.statusLabel == "Working ?" })
        XCTAssertEqual(entry.status, "working")
        var dormant = pending
        dormant.lifecycle = .dormant
        XCTAssertEqual(StatusCounts(userSessions: userSessions(fromDataFixtures: [dormant])).questions, 0)
    }

    func testBlockedQuestionsHaveRedStatusAndTheirOwnBarSegment() {
        let blocked = SessionData.mock(id: "blocked", status: .waitingAnswer, source: "codex")
        let counts = StatusCounts(userSessions: userSessions(fromDataFixtures: [blocked]))
        XCTAssertEqual(counts.permission, 0)
        XCTAssertEqual(counts.attention, 1)
        XCTAssertEqual(counts.needsAction, 1)
        XCTAssertEqual(counts.barSegments.map(\.kind), [.question])
        for theme in AppTheme.allCases {
            XCTAssertEqual(blocked.statusColorPair(in: theme).dark, theme.statusPermission.dark)
            XCTAssertEqual(blocked.statusColorPair(in: theme).light, theme.statusPermission.light)
        }
    }

    func testOverlayPreservesPermissionLifecycleAndOtherClients() {
        let working = SessionData.mock(status: .working, source: "codex")
        let blocked = SessionManager.applyingCodexQuestionStatus(.blocked, to: working)
        XCTAssertEqual(blocked.status, .waitingAnswer)
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.running, to: blocked).status, .working)
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.ready, to: blocked).status, .waitingInput)
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(nil, to: working).status, .working)
        for status in [SessionStatus.waitingPermission, .compacting] {
            var session = working
            session.status = status
            XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.ready, to: session).status, status)
        }
        var permission = working
        permission.status = .waitingPermission
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.blocked, to: permission).status, .waitingPermission)
        var dormant = working
        dormant.lifecycle = .dormant
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.blocked, to: dormant).status, .working)
        XCTAssertEqual(SessionManager.applyingCodexQuestionStatus(.blocked, to: .mock(status: .working)).status, .working)
    }

    func testBlockedRemainsVisibleWhenTheUserHasBeenAway() {
        var blocked = SessionData.mock(status: .waitingAnswer, source: "codex")
        blocked.lastActivity = Date().addingTimeInterval(-7_200)
        XCTAssertEqual(SessionManager.adjustIdleTimeout(blocked, now: Date(), timeout: IdleTimeoutSettings.defaultSeconds).status, .waitingAnswer)
        XCTAssertTrue(blocked.status.needsAttention)
        XCTAssertEqual(StatusCounts(userSessions: userSessions(fromDataFixtures: [blocked])).attention, 1)
    }

    func testLabelsAndNotificationsExplainTheRequiredAction() {
        let blocked = SessionData.mock(status: .waitingAnswer, source: "codex")
        XCTAssertEqual(blocked.statusLabel, "Blocked")
        XCTAssertEqual(blocked.contextLine, "Waiting for your answer")
        XCTAssertEqual(blocked.notificationContent.subtitle, "Codex is waiting for your answer")
        XCTAssertEqual(blocked.notificationContent.body, "Answer the question in Codex")
        XCTAssertEqual(blocked.statusAccessibilityDescription, "blocked, waiting for your answer")
        XCTAssertEqual(SessionData.mock(status: .waitingInput, source: "codex").statusLabel, "Ready")
        XCTAssertEqual(SessionData.mock(status: .waitingInput, source: "codex").contextLine, "Ready for your next task")
        XCTAssertEqual(SessionData.mock(status: .waitingInput).statusLabel, "Waiting")
    }

    @MainActor
    func testAsyncReadUpdatesDisplayWithoutRewritingTheSession() async throws {
        var sources = try isolatedSessionDataSources(prefix: "codex-question-display")
        let id = "codex-question-fixture"
        let session = SessionData.mock(id: id, status: .working,
                                       pid: UInt32(ProcessInfo.processInfo.processIdentifier), source: "codex")
        let path = sources.sessionsDir.appendingPathComponent("\(id).json").path
        try session.writeToFile(path: path)
        let persisted = try Data(contentsOf: URL(fileURLWithPath: path))
        sources.readCodexQuestions = { ids in
            XCTAssertEqual(ids, [id])
            return [id: .runningWithQuestion]
        }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: sources.sessionsDir.appendingPathComponent("history")),
            dataSources: sources, startMonitoring: true
        )
        let identity = try XCTUnwrap(manager.userSessions.first?.identity)
        let updated = expectation(description: "Runtime question reaches the display")
        let observation = manager.$userSessions.first { $0.first?.displayRecord.data.hasPendingAsyncQuestion == true }
            .sink { _ in updated.fulfill() }
        await fulfillment(of: [updated], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(manager.userSessions.map(\.identity), [identity])
        XCTAssertEqual(manager.userSessions.first?.status, .working)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), persisted)

        manager.codexQuestionObservations[id] = CodexQuestionObservation(
            activity: session.lastActivity.addingTimeInterval(-1), status: .blocked
        )
        manager.loadSessions()
        XCTAssertEqual(manager.userSessions.first?.status, .working, "An observation cannot override newer hook activity")
        XCTAssertFalse(manager.userSessions.first?.displayRecord.data.hasPendingQuestion ?? true)
    }
}
