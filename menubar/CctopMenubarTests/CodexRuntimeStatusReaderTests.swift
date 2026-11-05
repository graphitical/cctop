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
            reply(4, ["thread": ["id": "c", "status": ["type": "active", "activeFlags": ["futureFlag"]]]]),
            reply(5, ["data": []])
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

    func testCLIPendingQuestionsReachTheDisplayStatusWithoutLoadingHistory() throws {
        let question: [String: Any] = ["type": "agentMessage", "id": "call-questions", "questions": [
            ["title": "When does delivery start?"], ["title": "When does the quote expire?"]
        ]]
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["cli"]]),
            reply(2, ["thread": ["id": "cli", "status": ["type": "active", "activeFlags": []]]]),
            reply(3, ["data": [["id": "turn", "status": "inProgress", "itemsView": "full", "items": [question]]]])
        ])
        let runtime = try XCTUnwrap(CodexRuntimeStatusReader.read(matching: ["cli"], messaging: channel)["cli"])
        XCTAssertEqual(CodexQuestionStatus(runtime: runtime), .runningWithQuestion)
        XCTAssertEqual(channel.sent.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "thread/loaded/list", "thread/read", "thread/turns/list"
        ])
        let params = try XCTUnwrap(channel.sent.last?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "cli")
        XCTAssertEqual(params["limit"] as? Int, 1)
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
    }

    func testCLIQuestionsRemainPendingUntilEveryAcceptedAnswer() throws {
        let question: [String: Any] = ["type": "agentMessage", "id": "call-questions", "questions": [
            ["title": "First?"], ["title": "Second?"]
        ]]
        let first = try answer(index: 0)
        let second = try answer(index: 1)
        let unrelated: [String: Any] = ["type": "steeringUserMessage", "status": "queued", "input": [["type": "text", "text": "Keep working"]]]
        XCTAssertEqual(try cliStatus(items: [question, unrelated, first]), .runningWithQuestion)
        XCTAssertEqual(try cliStatus(items: [question, first, second]), .running)
        XCTAssertEqual(try cliStatus(items: [question], turnStatus: "completed"), .running)
    }

    func testUnsupportedOrIncompleteCLIQuestionPagesPreserveActivityStatus() throws {
        let question: [String: Any] = ["type": "agentMessage", "id": "call-questions", "questions": [["title": "First?"]]]
        XCTAssertEqual(try cliStatus(items: [question], itemsView: "summary"), .running)
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["cli"]]),
            reply(2, ["thread": ["id": "cli", "status": ["type": "active", "activeFlags": []]]]),
            ["id": 3, "error": ["code": -32601, "message": "unsupported method"]]
        ])
        let runtime = try XCTUnwrap(CodexRuntimeStatusReader.read(matching: ["cli"], messaging: channel)["cli"])
        XCTAssertEqual(CodexQuestionStatus(runtime: runtime), .running)
    }

    private func cliStatus(items: [[String: Any]], turnStatus: String = "inProgress", itemsView: String = "full") throws -> CodexQuestionStatus? {
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["cli"]]),
            reply(2, ["thread": ["id": "cli", "status": ["type": "active", "activeFlags": []]]]),
            reply(3, ["data": [["id": "turn", "status": turnStatus, "itemsView": itemsView, "items": items]]])
        ])
        let runtime = try XCTUnwrap(CodexRuntimeStatusReader.read(matching: ["cli"], messaging: channel)["cli"])
        return CodexQuestionStatus(runtime: runtime)
    }

    private func answer(index: Int) throws -> [String: Any] {
        let key = try JSONSerialization.data(withJSONObject: ["request_user_input_async", "call-questions", index])
        let replies = [["questionItemId": String(data: key, encoding: .utf8) ?? "", "question": "Choose?", "answer": "Yes"]]
        let data = try JSONSerialization.data(withJSONObject: replies)
        let text = "<send_user_message_question_reply>\n\(String(data: data, encoding: .utf8) ?? "")\n</send_user_message_question_reply>"
        return ["type": "userMessage", "content": [["type": "text", "text": text]]]
    }

    func testQuestionHistoryFailureKeepsOtherSessionsBlockingStatus() throws {
        let channel = RuntimeMessages([
            reply(0, [:]), reply(1, ["data": ["active", "blocked"]]),
            reply(2, ["thread": ["id": "active", "status": ["type": "active", "activeFlags": []]]]),
            reply(3, ["thread": ["id": "blocked", "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]]]])
        ])
        let runtime = try CodexRuntimeStatusReader.read(matching: ["active", "blocked"], messaging: channel)
        XCTAssertEqual(CodexQuestionStatus(runtime: try XCTUnwrap(runtime["active"])), .running)
        XCTAssertEqual(CodexQuestionStatus(runtime: try XCTUnwrap(runtime["blocked"])), .blocked)
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
