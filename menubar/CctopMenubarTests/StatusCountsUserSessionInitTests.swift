import XCTest
@testable import CctopMenubar

final class StatusCountsUserSessionInitTests: XCTestCase {
    func testEmptyArray_returnsZero() {
        let counts = StatusCounts(userSessions: [])
        XCTAssertEqual(counts.total, 0)
    }

    func testIdle_isExcludedFromActiveCountsRegardlessOfAge() {
        let now = Date()
        for age: TimeInterval in [0, 60, 3 * 86_400] {
            var session = SessionData.mock(status: .idle)
            session.lifecycle = .active
            session.lastActivity = now.addingTimeInterval(-age)

            let counts = StatusCounts(userSessions: userSessions(fromDataFixtures: [session]))

            XCTAssertEqual(counts.ready, 0)
            XCTAssertEqual(counts.total, 0)
        }
    }

    func testDormantSession_isExcludedFromCounts() {
        var session = SessionData.mock(status: .waitingPermission)
        session.lifecycle = .dormant

        let counts = StatusCounts(userSessions: userSessions(fromDataFixtures: [session]))

        XCTAssertEqual(counts.permission, 0)
        XCTAssertEqual(counts.total, 0)
    }

    func testWorking_countsAsWorking() {
        let userSessions = userSessions(fromDataFixtures: [.mock(status: .working)])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.working, 1)
    }

    func testCompacting_countsAsWorking() {
        let userSessions = userSessions(fromDataFixtures: [.mock(status: .compacting)])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.working, 1)
    }

    func testWaitingPermission_countsAsPermission() {
        let userSessions = userSessions(fromDataFixtures: [.mock(status: .waitingPermission)])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.permission, 1)
    }

    func testWaitingInput_countsAsAttention() {
        let userSessions = userSessions(fromDataFixtures: [.mock(status: .waitingInput)])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.attention, 1)
    }

    func testNeedsAttention_countsAsAttention() {
        let userSessions = userSessions(fromDataFixtures: [.mock(status: .needsAttention)])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.attention, 1)
    }

    func testMixedStatuses_aggregatesCorrectly() {
        let userSessions = userSessions(fromDataFixtures: [
            SessionData.mock(id: "1", status: .idle),
            SessionData.mock(id: "2", status: .idle),
            SessionData.mock(id: "3", status: .working),
            SessionData.mock(id: "4", status: .compacting),
            SessionData.mock(id: "5", status: .waitingPermission),
            SessionData.mock(id: "6", status: .waitingInput),
            SessionData.mock(id: "7", status: .needsAttention),
        ])
        let counts = StatusCounts(userSessions: userSessions)
        XCTAssertEqual(counts.ready, 0)
        XCTAssertEqual(counts.working, 2)  // working + compacting
        XCTAssertEqual(counts.permission, 1)
        XCTAssertEqual(counts.attention, 2)  // waitingInput + needsAttention
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(counts.needsAction, 3)  // permission + attention
    }

    func testRetainedRecords_countSelectedUserSessionOnce() {
        let selectedData = SessionData.mock(id: "selected", status: .working)
        let retainedData = SessionData.mock(id: "retained", status: .waitingPermission)
        let session = userSession(
            identity: .permanent(UUID()),
            display: selectedData,
            records: [selectedData, retainedData]
        )

        let counts = StatusCounts(userSessions: [session])

        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.permission, 0)
        XCTAssertEqual(counts.total, 1)
    }
}
