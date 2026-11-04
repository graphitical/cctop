import XCTest
@testable import CctopMenubar

final class CodexDesktopStatusReaderTests: XCTestCase {
    func testQuestionAndApprovalFactsStayDistinct() throws {
        var value = snapshot()
        value["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnApproval"]]
        XCTAssertFalse(try XCTUnwrap(CodexDesktopStatus(snapshot: value)).hasPendingQuestion)
        value["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnUserInput"]]
        XCTAssertTrue(try XCTUnwrap(CodexDesktopStatus(snapshot: value)).hasPendingQuestion)
        value["threadRuntimeStatus"] = ["type": "active", "activeFlags": []]
        value["requests"] = [["method": "item/tool/requestUserInput"]]
        XCTAssertTrue(try XCTUnwrap(CodexDesktopStatus(snapshot: value)).hasPendingQuestion)
    }

    func testAsyncQuestionNeedsEveryAnswerFromAnAcceptedReply() throws {
        let question: [String: Any] = ["type": "agentMessage", "id": "call-1", "questions": [["title": "First?"], ["title": "Second?"]]]
        var items = [question]
        XCTAssertTrue(try status(items).hasPendingQuestion)
        items.append(["type": "userMessage", "content": [["type": "text", "text": "Continue working"]]])
        XCTAssertTrue(try status(items).hasPendingQuestion)
        items.append(try answer(index: 0))
        XCTAssertTrue(try status(items).hasPendingQuestion)
        var queued = try answer(index: 1)
        queued["status"] = "queued"
        XCTAssertTrue(try status(items + [queued]).hasPendingQuestion)
        XCTAssertFalse(try status(items + [try answer(index: 1)]).hasPendingQuestion)
        XCTAssertFalse(try status([question], turnStatus: "completed").hasPendingQuestion)
    }

    func testCanonicalHistoryAndMalformedSnapshots() throws {
        var value = snapshot()
        value["turns"] = []
        value["turnHistory"] = ["kind": "canonical", "history": ["entitiesByKey": ["turn:a": [
            "status": "inProgress", "items": [["type": "agentMessage", "id": "q", "questions": [["title": "Choose?"]]]]
        ]]]]
        XCTAssertTrue(try XCTUnwrap(CodexDesktopStatus(snapshot: value)).hasPendingQuestion)
        value["turnHistory"] = ["kind": "canonical", "history": [:]]
        XCTAssertNil(CodexDesktopStatus(snapshot: value))
        value = snapshot()
        value["threadRuntimeStatus"] = ["type": "active"]
        XCTAssertNil(CodexDesktopStatus(snapshot: value))
    }

    func testObserverOnlyReadsMatchingLocalSnapshotsAndAlwaysUnsubscribes() throws {
        let channel = DesktopMessages([
            ["type": "client-discovery-request", "requestId": "routing"],
            ["type": "request", "method": "item/tool/requestUserInput"],
            event(id: "foreign", value: snapshot()),
            event(id: "a", value: snapshot(), host: "remote"),
            event(id: "a", value: snapshot(), version: 12),
            event(id: "a", value: snapshot())
        ])
        let values = try CodexDesktopStatusReader.read(matching: ["a"], messaging: channel)
        XCTAssertEqual(values["a"]?.runtime.state, .active)
        XCTAssertEqual(channel.sent.compactMap { $0["method"] as? String }, [
            "initialize", "thread-stream-following-changed", "thread-stream-following-changed"
        ])
        let following = channel.sent.compactMap { ($0["params"] as? [String: Any])?["following"] as? Bool }
        XCTAssertEqual(following, [true, false])
        let routing = try XCTUnwrap(channel.sent.first { $0["type"] as? String == "client-discovery-response" })
        XCTAssertEqual((routing["response"] as? [String: Any])?["canHandle"] as? Bool, false)
    }

    func testTimeoutKeepsMissingThreadsUnknownAndDisconnectStillCleansUp() throws {
        let channel = DesktopMessages([event(id: "a", value: snapshot())])
        let values = try CodexDesktopStatusReader.read(matching: ["a", "missing"], messaging: channel)
        XCTAssertEqual(Set(values.keys), ["a"])
        XCTAssertEqual(channel.sent.filter { ($0["params"] as? [String: Any])?["following"] as? Bool == false }.count, 2)
        let closed = DesktopMessages([], endingWith: .connectionClosed)
        XCTAssertThrowsError(try CodexDesktopStatusReader.read(matching: ["a"], messaging: closed))
        XCTAssertEqual((closed.sent.last?["params"] as? [String: Any])?["following"] as? Bool, false)
    }

    func testEmptyRequestDoesNotConnect() throws {
        XCTAssertTrue(try CodexDesktopStatusReader.read(matching: [], socketPath: "/no-such-cctop-test-socket").isEmpty)
    }

    private func snapshot() -> [String: Any] {
        ["id": "a", "hostId": "local", "threadRuntimeStatus": ["type": "active", "activeFlags": []], "requests": [], "turns": []]
    }

    private func status(_ items: [[String: Any]], turnStatus: String = "inProgress") throws -> CodexDesktopStatus {
        var value = snapshot()
        value["turns"] = [["status": turnStatus, "turnId": "turn", "items": items]]
        return try XCTUnwrap(CodexDesktopStatus(snapshot: value))
    }

    private func answer(index: Int) throws -> [String: Any] {
        let key = try JSONSerialization.data(withJSONObject: ["request_user_input_async", "call-1", index])
        let replies = [["questionItemId": String(data: key, encoding: .utf8) ?? "", "question": "Choose?", "answer": "Yes"]]
        let data = try JSONSerialization.data(withJSONObject: replies)
        let text = "<send_user_message_question_reply>\n\(String(data: data, encoding: .utf8) ?? "")\n</send_user_message_question_reply>"
        return ["type": "steeringUserMessage", "status": "accepted", "input": [["type": "text", "text": text]]]
    }

    private func event(id: String, value: [String: Any], host: String = "local", version: Int = 11) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "version": version,
         "params": ["hostId": host, "conversationId": id, "change": ["type": "snapshot", "conversationState": value]]]
    }
}

private final class DesktopMessages: CodexRuntimeMessaging {
    var sent: [[String: Any]] = []
    private var replies: [[String: Any]]
    private let ending: CodexRuntimeReadError

    init(_ replies: [[String: Any]], endingWith ending: CodexRuntimeReadError = .timedOut) {
        self.replies = replies
        self.ending = ending
    }

    func send(_ message: [String: Any]) throws {
        sent.append(message)
        if message["method"] as? String == "initialize" {
            replies.insert(["type": "response", "method": "initialize", "requestId": message["requestId"] ?? "",
                            "resultType": "success", "result": ["clientId": "observer"]], at: 0)
        }
    }

    func receive() throws -> [String: Any] {
        guard !replies.isEmpty else { throw ending }
        return replies.removeFirst()
    }
}
