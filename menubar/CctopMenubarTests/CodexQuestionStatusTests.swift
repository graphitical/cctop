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
        XCTAssertEqual(try status("active", pending: true), .blocked)
        XCTAssertEqual(try status("idle"), .ready)
        XCTAssertEqual(try status("active"), .running)
        XCTAssertNil(try status("active", flags: ["waitingOnApproval"]))
        XCTAssertNil(try status("active", flags: ["futureFlag"]))
        XCTAssertNil(try status("notLoaded"))
        XCTAssertNil(try status("systemError"))
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
            return [id: .blocked]
        }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: sources.sessionsDir.appendingPathComponent("history")),
            dataSources: sources, startMonitoring: true
        )
        let identity = try XCTUnwrap(manager.userSessions.first?.identity)
        let updated = expectation(description: "Runtime question reaches the display")
        let observation = manager.$userSessions.first { $0.first?.status == .waitingAnswer }.sink { _ in updated.fulfill() }
        await fulfillment(of: [updated], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(manager.userSessions.map(\.identity), [identity])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), persisted)

        manager.codexQuestionObservations[id] = CodexQuestionObservation(
            activity: session.lastActivity.addingTimeInterval(-1), status: .blocked
        )
        manager.loadSessions()
        XCTAssertEqual(manager.userSessions.first?.status, .working, "An observation cannot override newer hook activity")
    }
}
