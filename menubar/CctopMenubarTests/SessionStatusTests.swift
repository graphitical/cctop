import AppKit
import XCTest
@testable import CctopMenubar

final class SessionStatusTests: XCTestCase {
    func testKnownStatusDecoding() throws {
        let json = "\"working\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .working)
    }

    func testUnknownStatusFallsBackToNeedsAttention() throws {
        let json = "\"waiting_future\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .needsAttention)
    }

    func testUnknownNonWaitingStatusFallsBackToWorking() throws {
        let json = "\"some_future_status\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .working)
    }

    func testSnakeCaseDecoding() throws {
        let json = "\"waiting_permission\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .waitingPermission)
    }

    func testCompactingDecoding() throws {
        let json = "\"compacting\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .compacting)
    }

    func testCompactingNotNeedsAttention() {
        XCTAssertFalse(SessionStatus.compacting.needsAttention)
    }

    func testNeedsAttentionFlag() {
        XCTAssertTrue(SessionStatus.waitingPermission.needsAttention)
        XCTAssertTrue(SessionStatus.waitingInput.needsAttention)
        XCTAssertTrue(SessionStatus.needsAttention.needsAttention)
        XCTAssertFalse(SessionStatus.working.needsAttention)
        XCTAssertFalse(SessionStatus.idle.needsAttention)
        XCTAssertFalse(SessionStatus.compacting.needsAttention)
    }

    func testSortOrder() {
        XCTAssertLessThan(SessionStatus.waitingPermission.sortOrder, SessionStatus.working.sortOrder)
        XCTAssertLessThan(SessionStatus.working.sortOrder, SessionStatus.compacting.sortOrder)
        XCTAssertLessThan(SessionStatus.compacting.sortOrder, SessionStatus.idle.sortOrder)
    }

    func testCodexPermissionLabelDistinguishesTheReviewer() {
        var session = SessionData.mock(status: .waitingPermission, source: "codex")
        for reviewer in [nil, .autoReview, .user] as [CodexPermissionReviewer?] {
            session.codexPermissionReviewer = reviewer
            XCTAssertEqual(session.statusLabel, reviewer == .user ? "Permission" : "Waiting")
            XCTAssertEqual(session.statusAccessibilityDescription,
                           reviewer == .user ? "waiting for permission" : "waiting for permission review")
            XCTAssertEqual(session.status, .waitingPermission)
            XCTAssertEqual(session.shouldPostAttentionNotification, reviewer != .autoReview)
        }
    }

    func testPermissionReviewerDoesNotChangeOtherClientsOrStatuses() {
        for source in ["cc", "opencode", "pi"] {
            let session = SessionData.mock(status: .waitingPermission, source: source)
            XCTAssertEqual(session.statusLabel, "Permission")
            XCTAssertEqual(session.statusAccessibilityDescription, "waiting for permission")
        }
        for (status, label) in [(SessionStatus.working, "Working"), (.waitingInput, "Ready"), (.waitingAnswer, "Blocked")] {
            var session = SessionData.mock(status: status, source: "codex")
            session.codexPermissionReviewer = .autoReview
            XCTAssertEqual(session.statusLabel, label)
        }
    }

    @MainActor
    func testAutomaticPermissionReviewStaysWorkingAcrossDisplaySurfaces() throws {
        let sources = try isolatedSessionDataSources(prefix: "automatic-review-display")
        var session = SessionData.mock(id: "automatic-review", status: .waitingPermission,
                                       pid: UInt32(ProcessInfo.processInfo.processIdentifier), source: "codex")
        session.codexPermissionReviewer = .autoReview
        let path = sources.sessionsDir.appendingPathComponent("automatic-review.json")
        try session.writeToFile(path: path.path)
        let persisted = try Data(contentsOf: path)
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: sources.sessionsDir.appendingPathComponent("history")),
            dataSources: sources, startMonitoring: false
        )
        manager.codexQuestionObservations[session.sessionId] = CodexQuestionObservation(
            activity: session.lastActivity, status: .ready
        )
        manager.loadSessions()
        let displayed = try XCTUnwrap(manager.userSessions.first?.displayRecord.data)
        XCTAssertEqual(displayed.status, .working)
        XCTAssertEqual(displayed.statusLabel, "Working")
        XCTAssertFalse(displayed.shouldPostAttentionNotification)
        XCTAssertEqual(StatusCounts(userSessions: manager.userSessions), .init(permission: 0, attention: 0, working: 1, ready: 0))
        let snapshot = DisplayStateWriter.snapshot(
            userSessions: manager.userSessions, theme: .claude,
            appRunning: true, appIdentity: nil, now: Date()
        )
        XCTAssertEqual(snapshot.sessions.first?.statusLabel, "Working")
        XCTAssertEqual(snapshot.sessions.first?.status, "working")
        XCTAssertEqual(try Data(contentsOf: path), persisted)
    }
    func testKeyboardColorMappingKeepsReadySeparateFromIdleAndInput() {
        let ready = SessionData.mock(status: .waitingInput, source: "codex")
        let waiting = SessionData.mock(status: .waitingInput, source: "cc")
        let idle = SessionData.mock(status: .idle, source: "codex")
        var pending = SessionData.mock(status: .working, source: "codex")
        pending.hasPendingAsyncQuestion = true
        for theme in AppTheme.allCases {
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let appearance = NSAppearance(named: appearance)!
                func color(_ session: SessionData) -> NSColor {
                    session.statusColorPair(in: theme).resolve(appearance)
                }
                XCTAssertEqual(color(ready), theme.statusReady.resolve(appearance))
                XCTAssertEqual(color(waiting), theme.statusAttention.resolve(appearance))
                XCTAssertEqual(color(pending), theme.statusWorking.resolve(appearance))
                XCTAssertNotEqual(color(ready), color(idle))
                XCTAssertNotEqual(color(ready), color(pending))
                for status in [SessionStatus.waitingPermission, .waitingAnswer, .needsAttention] {
                    XCTAssertEqual(color(.mock(status: status)), color(waiting))
                }
                XCTAssertEqual(color(.mock(status: .compacting)), color(pending))
            }
        }
    }

}
