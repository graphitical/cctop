import XCTest
@testable import CctopMenubar

final class SessionDisplayPolicyTests: XCTestCase {
    func testIdleStatusMovesTabsImmediatelyAndWorkMovesItBack() {
        let now = Date(timeIntervalSince1970: 100_000)
        var session = activeIdle(id: "conversation", lastActivity: now)
        var sessions = userSessions(fromDataFixtures: [session])

        XCTAssertTrue(SessionDisplayPolicy.activeSessions(from: sessions).isEmpty)
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: sessions).map(\.identity), sessions.map(\.identity))

        session.status = .working
        sessions = userSessions(fromDataFixtures: [session])

        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: sessions).map(\.identity), sessions.map(\.identity))
        XCTAssertTrue(SessionDisplayPolicy.idleSessions(from: sessions).isEmpty)
    }

    func testActiveSessionsExcludesDormantAndIdleRegardlessOfAge() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-3 * 86_400)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-3 * 86_400)),
        ]
        let userSessions = userSessions(fromDataFixtures: sessions)

        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: userSessions).map(\.displayRecord.data.id),
            ["waiting"]
        )
    }

    func testIdleSessionsIncludesDormantAndIdleRegardlessOfAge() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-3 * 86_400)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-3 * 86_400)),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: userSessions).map(\.displayRecord.data.id),
            ["fresh", "stale", "dormant"]
        )
    }

    func testReconciledOrderOwnsIdleRecencyOrder() {
        let now = Date(timeIntervalSince1970: 5_000)
        var older = dormant(id: "a-older")
        older.lastActivity = now.addingTimeInterval(-300)
        var newer = dormant(id: "z-newer")
        newer.lastActivity = now.addingTimeInterval(-10)

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [older, newer]),
            preserving: []
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["z-newer", "a-older"])
        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: result).map(\.identity),
            result.map(\.identity)
        )
    }

    func testSignatureTracksDisplayBuckets() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-3 * 86_400)),
            dormant(id: "dormant"),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.signature(for: userSessions),
            .init(
                activeIDs: [],
                idleIDs: userSessions.map(\.identity)
            )
        )
    }

    func testWorkingAndCompactingStayAboveNewerReadyTasksAcrossSources() {
        let now = Date(timeIntervalSince1970: 9_000)
        for source in [SessionData.ccSource, SessionData.codexSource, SessionData.opencodeSource, SessionData.piSource] {
            for status in [SessionStatus.working, .compacting] {
                var working = SessionData.mock(id: "working", status: status, source: source)
                working.lastActivity = now.addingTimeInterval(-600)
                var ready = SessionData.mock(id: "ready", status: .waitingInput, source: source)
                ready.lastActivity = now

                let input = userSessions(fromDataFixtures: [ready, working])
                let result = SessionDisplayPolicy.reconcilingOrder(in: input, preserving: input)

                XCTAssertEqual(result.map(\.displayRecord.data.sessionId), ["working", "ready"], "\(source): \(status)")
            }
        }
    }

    func testReconciledOrderUsesStatusPriorityThenRecency() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixtures: [(String, SessionStatus, TimeInterval)] = [
            ("blocked", .waitingAnswer, 1_200),
            ("pending", .working, 900),
            ("permission", .waitingPermission, 600),
            ("attention", .needsAttention, 500),
            ("working", .working, 400),
            ("compacting", .compacting, 300),
            ("ready", .waitingInput, 200),
            ("ready-recent", .waitingInput, 100),
            ("idle", .idle, 10),
        ]
        let sessions = fixtures.map { id, status, age in
            var session = SessionData.mock(id: id, status: status)
            session.hasPendingAsyncQuestion = id == "pending"
            session.lastActivity = now.addingTimeInterval(-age)
            return session
        }
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: sessions), preserving: []
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), [
            "blocked", "pending", "attention", "permission", "compacting", "working", "ready-recent", "ready", "idle",
        ])
    }

    func testQuestionsComeFirstWithoutChangingIdentityOrIdleMembership() {
        let now = Date(timeIntervalSince1970: 15_000)
        var working = SessionData.mock(id: "working", status: .working)
        working.lastActivity = now
        var pending = SessionData.mock(id: "pending", status: .working, source: "codex")
        pending.hasPendingAsyncQuestion = true
        pending.lastActivity = now.addingTimeInterval(-60)
        var blocked = SessionData.mock(id: "blocked", status: .waitingAnswer, source: "codex")
        blocked.lastActivity = now.addingTimeInterval(-600)
        var otherBlocked = SessionData.mock(id: "other-blocked", status: .waitingAnswer, source: "codex")
        otherBlocked.lastActivity = now.addingTimeInterval(-300)
        var asleep = dormant(id: "dormant")
        asleep.status = .waitingAnswer
        asleep.lastActivity = now.addingTimeInterval(-10)
        let input = userSessions(fromDataFixtures: [working, pending, blocked, asleep, otherBlocked])
        let result = SessionDisplayPolicy.reconcilingOrder(in: input, preserving: input)
        XCTAssertEqual(result.map(\.displayRecord.data.sessionId), ["other-blocked", "blocked", "pending", "working", "dormant"])
        XCTAssertEqual(Set(result.map(\.identity)), Set(input.map(\.identity)))
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: result).map(\.displayRecord.data.sessionId), ["dormant"])

        pending.hasPendingAsyncQuestion = false
        let answered = userSessions(fromDataFixtures: [working, pending, blocked, asleep, otherBlocked])
        let updated = SessionDisplayPolicy.reconcilingOrder(in: answered, preserving: result)
        XCTAssertEqual(updated.map(\.displayRecord.data.sessionId), ["other-blocked", "blocked", "working", "pending", "dormant"])
    }

    func testReconciledOrderMovesNewActivityAheadOfPriorRowsWithinAGroup() {
        let now = Date(timeIntervalSince1970: 20_000)
        var peer = SessionData.mock(id: "peer", status: .working)
        peer.lastActivity = now.addingTimeInterval(-600)
        var working = SessionData.mock(id: "working", status: .working)
        working.lastActivity = now.addingTimeInterval(-60)
        let previous = [working, peer]
        peer.lastActivity = now

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [working, peer]),
            preserving: userSessions(fromDataFixtures: previous)
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["peer", "working"])
    }

    func testEqualActivityKeepsPriorOrderWithinAGroupAndAppendsNewcomers() {
        let now = Date(timeIntervalSince1970: 30_000)
        var first = SessionData.mock(id: "first", status: .working)
        var second = SessionData.mock(id: "second", status: .compacting)
        var newcomer = SessionData.mock(id: "newcomer", status: .working)
        first.lastActivity = now
        second.lastActivity = now
        newcomer.lastActivity = now
        let previous = [first, second].map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        first.status = .compacting
        second.status = .working

        let input = [newcomer, second, first].map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        let result = SessionDisplayPolicy.reconcilingOrder(in: input, preserving: previous)
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["first", "second", "newcomer"])
        let initial = SessionDisplayPolicy.reconcilingOrder(
            in: input, preserving: []
        )
        XCTAssertEqual(initial.map(\.displayRecord.data.id), ["newcomer", "second", "first"])
    }

    func testRecencyOrderPreservesActiveAndIdleMembership() {
        let now = Date()
        var waiting = SessionData.mock(id: "waiting", status: .waitingInput)
        waiting.lastActivity = now.addingTimeInterval(-300)
        var working = SessionData.mock(id: "working", status: .working)
        working.lastActivity = now.addingTimeInterval(-60)
        var asleep = dormant(id: "dormant")
        asleep.lastActivity = now.addingTimeInterval(-10)
        let stale = activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-3 * 86_400))

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [stale, waiting, working, asleep]), preserving: []
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["working", "waiting", "dormant", "stale"])
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: result).map(\.displayRecord.data.id), ["working", "waiting"])
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: result).map(\.displayRecord.data.id), ["dormant", "stale"])
    }

    func testReconciledOrderUsesStableConversationIdentityAcrossDesktopPIDChange() {
        let now = Date(timeIntervalSince1970: 90_000)
        let terminal = TerminalInfo(program: "Claude", bundleId: HostAppBundleID.claudeDesktop)
        var desktop = SessionData.mock(
            id: "conversation",
            status: .working,
            pid: 100,
            terminal: terminal,
            source: SessionData.ccSource
        )
        var other = SessionData.mock(id: "other", status: .working, source: SessionData.codexSource)
        desktop.lastActivity = now
        other.lastActivity = now
        let previous = [desktop, other]

        desktop.pid = 200
        desktop.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: [other, desktop].map {
                userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
            },
            preserving: previous.map {
                userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
            }
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["200", "other"])
        XCTAssertEqual(
            SessionIdentityPolicy.stableKey(for: previous[0]),
            SessionIdentityPolicy.stableKey(for: result[0].displayRecord.data)
        )
    }

    func testReconciledOrderUsesPermanentIdentityAcrossRecordReplacementAndStatusMovement() {
        let now = Date(timeIntervalSince1970: 95_000)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var userSession = SessionData.mock(
            id: "old-record", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        var workingPeer = SessionData.mock(id: "peer", status: .working, pid: 200, source: SessionData.opencodeSource)
        userSession.lastActivity = now
        workingPeer.lastActivity = now
        let previous = [userSession, workingPeer]

        userSession = SessionData.mock(
            id: "new-record", cctopSessionId: sharedID,
            status: .waitingInput, pid: 300, source: SessionData.opencodeSource
        )
        userSession.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [workingPeer, userSession]),
            preserving: userSessions(fromDataFixtures: previous)
        )

        XCTAssertEqual(result.map(\.displayRecord.data.pid), [200, 300])
        XCTAssertEqual(
            result.map(\.identity),
            [
                SessionIdentityPolicy.logicalIdentity(for: workingPeer),
                SessionIdentityPolicy.logicalIdentity(for: userSession),
            ]
        )
    }

    func testReconciledOrderKeepsLegacySlotAfterPermanentIDStamp() {
        let now = Date(timeIntervalSince1970: 95_500)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var legacy = SessionData.mock(
            id: "same-record", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        legacy.lastActivity = now
        var stamped = legacy
        stamped.cctopSessionId = sharedID
        var peer = SessionData.mock(
            id: "peer", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .working, pid: 200, source: SessionData.opencodeSource
        )

        peer.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [peer, stamped]),
            preserving: userSessions(fromDataFixtures: [legacy, peer])
        )

        XCTAssertEqual(result.map(\.displayRecord.data.pid), [100, 200])
    }

    private func activeIdle(id: String, lastActivity: Date) -> SessionData {
        var session = SessionData.mock(id: id, status: .idle)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func activeWaiting(id: String, lastActivity: Date) -> SessionData {
        var session = SessionData.mock(id: id, status: .waitingInput)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func dormant(id: String) -> SessionData {
        var session = SessionData.mock(id: id, status: .idle)
        session.lifecycle = .dormant
        return session
    }
}
