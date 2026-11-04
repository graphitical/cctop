import XCTest
@testable import CctopMenubar

final class CodexPermissionReviewerTests: XCTestCase {
    private func context(_ reviewer: String, turnID: String = "turn") -> String {
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(turnID)\",\"approvals_reviewer\":\"\(reviewer)\"}}\n"
    }

    private func transcript(_ body: String, sessionID: String = "session") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try ("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\"}}\n" + body)
            .write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func input(path: String?, turnID: String? = "turn") throws -> HookInput {
        var payload = ["session_id": "session", "cwd": "/tmp/project", "hook_event_name": "PermissionRequest"]
        payload["transcript_path"] = path
        payload["turn_id"] = turnID
        return try JSONDecoder().decode(HookInput.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    func testOnlyLatestContextCanSupplyReviewer() throws {
        let automatic = context("auto_review")
        let cases: [(String, CodexPermissionReviewer?)] = [
            (automatic, .autoReview),
            (context("guardian_subagent"), .autoReview),
            (automatic + context("user"), .user),
            (automatic + context("future_reviewer"), nil),
            (automatic + context("user", turnID: "different-turn"), nil),
            (automatic + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\"}}\n", nil),
            (automatic + "not valid JSON\n", nil),
            (automatic + "{\"type\":\"turn_context\",\"payload\":", nil),
        ]
        for (body, expected) in cases {
            let url = try transcript(body)
            XCTAssertEqual(CodexPermissionReviewerLookup.reviewer(for: try input(path: url.path)), expected, body)
        }
    }

    func testMissingOrMismatchedEvidenceReturnsUnknown() throws {
        let url = try transcript(context("auto_review"), sessionID: "different-session")
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: url.path)))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: nil)))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: "")))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: url.path + ".missing")))
        let matching = try transcript(context("auto_review"))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: matching.path, turnID: nil)))
    }

    func testChunkBoundariesAndScanLimit() throws {
        let event = "{\"type\":\"event_msg\",\"payload\":{\"message\":\"" + String(repeating: "x", count: 70_000) + "\"}}\n"
        let nearby = try transcript(context("auto_review") + event)
        XCTAssertEqual(CodexPermissionReviewerLookup.reviewer(for: try input(path: nearby.path)), .autoReview)
        let distant = try transcript(context("auto_review") + String(repeating: event, count: 61))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: try input(path: distant.path)))
    }

    func testPartialAppendCannotReuseAutomaticReviewer() throws {
        let url = try transcript(context("auto_review"))
        let hookInput = try input(path: url.path)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let manual = context("user")
        try writer.write(contentsOf: Data(manual.dropLast(3).utf8))
        XCTAssertNil(CodexPermissionReviewerLookup.reviewer(for: hookInput))
        try writer.write(contentsOf: Data(manual.suffix(3).utf8))
        XCTAssertEqual(CodexPermissionReviewerLookup.reviewer(for: hookInput), .user)
    }

    func testCompleteUnrelatedAppendPreservesReviewer() throws {
        let event = "{\"type\":\"token_usage_record\",\"payload\":{}}\n"
        for reviewer in [CodexPermissionReviewer.autoReview, .user] {
            let result = try reviewerAfterAppend(event, reviewer: reviewer)
            XCTAssertEqual(result, reviewer)
        }
    }

    func testAppendedContextOrIncompleteRecordKeepsReviewerUnknown() throws {
        let cases = [
            context("user"),
            context("auto_review"),
            context("auto_review", turnID: "different-turn"),
            context("future_reviewer"),
            "{\"type\":\"turn_context\",\"payload\":",
            "{\"type\":\"event_msg\",\"payload\":",
            "not valid JSON\n"
        ]
        for append in cases {
            XCTAssertNil(try reviewerAfterAppend(append), append)
        }
    }

    func testAppendBeyondScanLimitKeepsReviewerUnknown() throws {
        let event = "{\"type\":\"event_msg\",\"payload\":\"" + String(repeating: "x", count: 70_000) + "\"}\n"
        XCTAssertNil(try reviewerAfterAppend(String(repeating: event, count: 61)))
    }

    private func reviewerAfterAppend(
        _ append: String, reviewer: CodexPermissionReviewer = .autoReview
    ) throws -> CodexPermissionReviewer? {
        let url = try transcript(context(reviewer.rawValue))
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let snapshotEnd = try reader.seekToEnd()
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(append.utf8))
        return try? CodexPermissionReviewerLookup.latestReviewer(in: reader, end: snapshotEnd, turnID: "turn")
    }

    func testSuppressionPreservesOtherAttentionTransitions() {
        let working = SessionData.mock(status: .working, source: "codex")
        var permission = working
        permission.status = .waitingPermission
        permission.codexPermissionReviewer = .autoReview
        permission.lastActivity = Date(timeIntervalSinceNow: -30)
        XCTAssertTrue(permission.status.needsAttention)
        XCTAssertEqual(actions(from: working, to: permission), [])

        var manual = permission
        manual.codexPermissionReviewer = .user
        let identifier = working.cctopSessionId!
        XCTAssertEqual(actions(from: permission, to: manual), [.post(cctopSessionID: identifier)])
        for status in [SessionStatus.waitingInput, .needsAttention] {
            var attention = permission
            attention.status = status
            attention.lastPrompt = "Please review this"
            XCTAssertEqual(actions(from: permission, to: attention), [.post(cctopSessionID: identifier)])
        }
        for source in ["cc", "opencode", "pi"] {
            permission.source = source
            XCTAssertEqual(actions(from: working, to: permission), [.post(cctopSessionID: identifier)])
        }
    }

    func testLegacyAndUnknownSessionMetadataKeepsAlert() throws {
        var permission = SessionData.mock(status: .waitingPermission, source: "codex")
        XCTAssertTrue(permission.shouldPostAttentionNotification)
        permission.codexPermissionReviewer = .autoReview
        let encoded = try JSONEncoder.sessionEncoder.encode(permission)
        XCTAssertEqual(try JSONDecoder.sessionDecoder.decode(SessionData.self, from: encoded).codexPermissionReviewer, .autoReview)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for value in [nil, "future_reviewer"] as [String?] {
            object["codex_permission_reviewer"] = value
            let decoded = try JSONDecoder.sessionDecoder.decode(SessionData.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.codexPermissionReviewer)
            XCTAssertTrue(decoded.shouldPostAttentionNotification)
        }
    }

    private func actions(from source: SessionData, to target: SessionData) -> [SessionNotificationAction] {
        SessionManager.notificationActions(
            newUserSessions: userSessions(fromDataFixtures: [target]),
            oldUserSessions: userSessions(fromDataFixtures: [source]),
            notificationsEnabled: true
        )
    }
}
