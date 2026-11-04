import XCTest
@testable import CctopMenubar

final class SessionDisplayPolicyTests: XCTestCase {
    func testActiveSessionsExcludesDormantAndStaleActiveIdle() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
        ]
        let userSessions = userSessions(fromDataFixtures: sessions)

        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: userSessions, now: now).map(\.displayRecord.data.id),
            ["fresh", "waiting"]
        )
    }

    func testIdleSessionsIncludesDormantAndStaleActiveIdleOnly() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: userSessions, now: now).map(\.displayRecord.data.id),
            ["stale", "dormant"]
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
            SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.identity),
            result.map(\.identity)
        )
    }

    func testSignatureTracksDisplayBuckets() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.signature(for: userSessions, now: now),
            .init(
                activeIDs: [userSessions[0].identity],
                idleIDs: Array(userSessions[1...]).map(\.identity)
            )
        )
    }

    func testReconciledOrderUsesRecencyAcrossAllStatuses() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixtures: [(String, SessionStatus, TimeInterval)] = [
            ("permission", .waitingPermission, 600),
            ("waiting", .waitingInput, 300),
            ("working", .working, 60),
            ("idle", .idle, 10),
        ]
        let sessions = fixtures.map { id, status, age in
            var session = SessionData.mock(id: id, status: status)
            session.lastActivity = now.addingTimeInterval(-age)
            return session
        }
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: sessions), preserving: []
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["idle", "working", "waiting", "permission"])
    }

    func testReconciledOrderMovesNewActivityAheadOfPriorRows() {
        let now = Date(timeIntervalSince1970: 20_000)
        var waiting = SessionData.mock(id: "waiting", status: .waitingInput)
        waiting.lastActivity = now.addingTimeInterval(-600)
        var working = SessionData.mock(id: "working", status: .working)
        working.lastActivity = now.addingTimeInterval(-60)
        let previous = [working, waiting]
        waiting.lastActivity = now

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [working, waiting]),
            preserving: userSessions(fromDataFixtures: previous)
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["waiting", "working"])
    }

    func testEqualActivityKeepsPriorOrderAcrossStatusChangesAndAppendsNewcomers() {
        let now = Date(timeIntervalSince1970: 30_000)
        var first = SessionData.mock(id: "first", status: .working)
        var second = SessionData.mock(id: "second", status: .idle)
        var newcomer = SessionData.mock(id: "newcomer", status: .waitingPermission)
        first.lastActivity = now
        second.lastActivity = now
        newcomer.lastActivity = now
        let previous = [first, second].map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        first.status = .idle
        second.status = .waitingPermission

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
        let stale = activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 1))

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [stale, waiting, working, asleep]), preserving: []
        )
        XCTAssertEqual(result.map(\.displayRecord.data.id), ["dormant", "working", "waiting", "stale"])
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: result, now: now).map(\.displayRecord.data.id), ["working", "waiting"])
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.displayRecord.data.id), ["dormant", "stale"])
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

        XCTAssertEqual(result.map(\.displayRecord.data.pid), [300, 200])
        XCTAssertEqual(
            result.map(\.identity),
            [
                SessionIdentityPolicy.logicalIdentity(for: userSession),
                SessionIdentityPolicy.logicalIdentity(for: workingPeer),
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
