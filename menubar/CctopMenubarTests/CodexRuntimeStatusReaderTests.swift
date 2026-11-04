import XCTest
@testable import CctopMenubar

final class CodexRuntimeStatusReaderTests: XCTestCase {
    func testOnlyReadsRequestedLoadedThreadsWithoutAttachingOrAnsweringRequests() throws {
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["blocked", "other"]]),
            ["id": 2, "method": "item/tool/requestUserInput", "params": [:]],
            ["method": "thread/status/changed", "params": [:]],
            reply(2, ["thread": ["id": "blocked", "status": [
                "type": "active", "activeFlags": ["waitingOnUserInput", "waitingOnApproval"]
            ]]])
        ])
        let statuses = try CodexRuntimeStatusReader.read(matching: ["blocked", "unloaded"], messaging: channel)
        XCTAssertEqual(Set(statuses.keys), ["blocked"])
        XCTAssertEqual(statuses["blocked"]?.state, .active)
        XCTAssertEqual(statuses["blocked"]?.activeFlags, ["waitingOnUserInput", "waitingOnApproval"])
        XCTAssertEqual(channel.sent.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "thread/loaded/list", "thread/read"
        ])
        let params = try XCTUnwrap(channel.sent.last?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "blocked")
        XCTAssertEqual(params["includeTurns"] as? Bool, false)
    }

    func testRetainsDistinctIdleActiveAndUnrecognizedFlagFacts() throws {
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["a", "b", "c"]]),
            reply(2, ["thread": ["id": "a", "status": ["type": "idle"]]]),
            reply(3, ["thread": ["id": "b", "status": ["type": "active", "activeFlags": []]]]),
            reply(4, ["thread": ["id": "c", "status": ["type": "active", "activeFlags": ["futureFlag"]]]])
        ])
        let statuses = try CodexRuntimeStatusReader.read(matching: ["a", "b", "c"], messaging: channel)
        XCTAssertEqual(statuses["a"]?.state, .idle)
        XCTAssertEqual(statuses["b"]?.state, .active)
        XCTAssertEqual(statuses["b"]?.activeFlags, [])
        XCTAssertEqual(statuses["c"]?.activeFlags, ["futureFlag"])
    }

    func testMalformedUnknownMismatchedAndFailedThreadReadsStayUnknown() throws {
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["a", "b", "c", "d"]]),
            reply(2, ["thread": ["id": "a", "status": ["type": "active"]]]),
            reply(3, ["thread": ["id": "b", "status": ["type": "futureState"]]]),
            reply(4, ["thread": ["id": "wrong-thread", "status": ["type": "idle"]]]),
            ["id": 5, "error": ["code": -32600, "message": "thread disappeared"]]
        ])
        XCTAssertTrue(try CodexRuntimeStatusReader.read(matching: ["a", "b", "c", "d"], messaging: channel).isEmpty)
    }

    func testConnectionFailureIsNotAnEmptySuccessfulSnapshot() {
        let channel = RuntimeMessages([reply(0, [:])])
        XCTAssertThrowsError(try CodexRuntimeStatusReader.read(matching: ["a"], messaging: channel))
        XCTAssertThrowsError(try CodexRuntimeStatusReader.read(matching: ["a"], socketPath: "/no-such-cctop-test-socket"))
    }

    func testRejectedInitializationDoesNotSendFurtherRequests() {
        let channel = RuntimeMessages([["id": 0, "error": ["code": -32600]]])
        XCTAssertThrowsError(try CodexRuntimeStatusReader.read(matching: ["a"], messaging: channel))
        XCTAssertEqual(channel.sent.count, 1)
    }

    func testEmptyRequestDoesNotConnect() throws {
        XCTAssertTrue(try CodexRuntimeStatusReader.read(matching: [], socketPath: "/no-such-cctop-test-socket").isEmpty)
    }

    private func reply(_ id: Int, _ result: [String: Any]) -> [String: Any] {
        ["id": id, "result": result]
    }
}

private final class RuntimeMessages: CodexRuntimeMessaging {
    var sent: [[String: Any]] = []
    private var replies: [[String: Any]]

    init(_ replies: [[String: Any]]) { self.replies = replies }

    func send(_ message: [String: Any]) throws { sent.append(message) }

    func receive() throws -> [String: Any] {
        guard !replies.isEmpty else { throw CodexRuntimeReadError.connectionClosed }
        return replies.removeFirst()
    }
}
