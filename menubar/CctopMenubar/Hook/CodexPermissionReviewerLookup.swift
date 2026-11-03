import Foundation

enum CodexPermissionReviewer: String, Codable {
    case user
    case autoReview = "auto_review"
}

/// Codex's hook omits the reviewer, but its turn transcript records the effective setting.
/// This format is not a stable API: uncertain evidence must leave permission alerts enabled.
enum CodexPermissionReviewerLookup {
    static let maxScanBytes = 4 * 1024 * 1024
    private static let chunkSize = 64 * 1024

    static func reviewer(for input: HookInput) -> CodexPermissionReviewer? {
        guard let path = input.transcriptPath, !path.isEmpty,
              let turnID = input.turnId, !turnID.isEmpty else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            guard try sessionID(in: handle) == input.sessionId else { return nil }
            let reviewer = try latestReviewer(in: handle, end: end, turnID: turnID)
            // Appends or truncation during the read can make the selected context stale.
            guard try handle.seekToEnd() == end else { return nil }
            return reviewer
        } catch {
            return nil
        }
    }

    private static func sessionID(in handle: FileHandle) throws -> String? {
        try handle.seek(toOffset: 0)
        var buffer = Data()
        while buffer.count < maxScanBytes {
            guard let chunk = try handle.read(upToCount: min(chunkSize, maxScanBytes - buffer.count)),
                  !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0a) {
                let record = try JSONSerialization.jsonObject(with: Data(buffer[..<newline])) as? [String: Any]
                guard record?["type"] as? String == "session_meta",
                      let payload = record?["payload"] as? [String: Any] else { return nil }
                return payload["id"] as? String
            }
        }
        return nil
    }

    private static func latestReviewer(
        in handle: FileHandle, end: UInt64, turnID: String
    ) throws -> CodexPermissionReviewer? {
        let lowerBound = end > UInt64(maxScanBytes) ? end - UInt64(maxScanBytes) : 0
        var cursor = end
        var buffer = Data()
        while cursor > lowerBound {
            let count = Int(min(UInt64(chunkSize), cursor - lowerBound))
            try handle.seek(toOffset: cursor - UInt64(count))
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else { return nil }
            buffer.insert(contentsOf: chunk, at: 0)
            if cursor == end {
                // A partial context could change an earlier automatic reviewer to manual.
                guard buffer.last == 0x0a else { return nil }
                buffer.removeLast()
            }
            cursor -= UInt64(count)
            while let newline = buffer.lastIndex(of: 0x0a) {
                let line = Data(buffer[buffer.index(after: newline)...])
                buffer.removeSubrange(newline...)
                if line.isEmpty { continue }
                guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
                if record["type"] as? String == "turn_context" {
                    return reviewer(in: record, turnID: turnID)
                }
            }
        }
        return nil
    }

    private static func reviewer(in record: [String: Any], turnID: String) -> CodexPermissionReviewer? {
        guard let payload = record["payload"] as? [String: Any],
              payload["turn_id"] as? String == turnID else { return nil }
        switch payload["approvals_reviewer"] as? String {
        case "user": return .user
        case "auto_review", "guardian_subagent": return .autoReview
        default: return nil
        }
    }
}
