import Foundation

/// Selects display buckets and reconciles canonical order on `UserSession` values.
/// It reads `displayRecord.data` for lifecycle, status, and activity; identity stays on the group.
enum SessionDisplayPolicy {
    struct Signature: Equatable {
        let activeIDs: [SessionIdentityPolicy.LogicalIdentity]
        let idleIDs: [SessionIdentityPolicy.LogicalIdentity]

        static let empty = Signature(activeIDs: [], idleIDs: [])
    }

    static func activeSessions(from userSessions: [UserSession]) -> [UserSession] {
        userSessions.filter {
            let session = $0.displayRecord.data
            return session.lifecycle == .active && session.status != .idle
        }
    }

    static func idleSessions(from userSessions: [UserSession]) -> [UserSession] {
        userSessions.filter {
            let session = $0.displayRecord.data
            return session.lifecycle == .dormant || (session.lifecycle == .active && session.status == .idle)
        }
    }

    /// Shows questions first, then attention, work, ready, and idle sessions.
    /// Each group uses recent activity, preserving canonical identity order for ties.
    static func reconcilingOrder(
        in userSessions: [UserSession],
        preserving previousUserSessions: [UserSession]
    ) -> [UserSession] {
        let sessionByIdentity = Dictionary(
            userSessions.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var priorRank: [SessionIdentityPolicy.LogicalIdentity: Int] = [:]
        for (rank, displayed) in previousUserSessions.enumerated() {
            guard let matched = matchingUserSession(
                for: displayed, in: userSessions, byIdentity: sessionByIdentity
            ), priorRank[matched.identity] == nil else { continue }
            priorRank[matched.identity] = rank
        }
        return userSessions.enumerated().sorted { left, right in
            let leftPriority = displayPriority(for: left.element)
            let rightPriority = displayPriority(for: right.element)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftActivity = left.element.displayRecord.data.lastActivity
            let rightActivity = right.element.displayRecord.data.lastActivity
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            let leftRank = priorRank[left.element.identity] ?? previousUserSessions.count + left.offset
            let rightRank = priorRank[right.element.identity] ?? previousUserSessions.count + right.offset
            return leftRank < rightRank
        }.map(\.element)
    }

    private static func displayPriority(for userSession: UserSession) -> Int {
        let data = userSession.displayRecord.data
        guard data.lifecycle == .active, data.status != .idle else { return 5 }
        if data.hasPendingQuestion { return data.status == .waitingAnswer ? 0 : 1 }
        switch data.status {
        case .waitingAnswer: return 0
        case .waitingPermission, .needsAttention: return 2
        case .working, .compacting: return 3
        case .waitingInput: return 4
        case .idle: return 5
        }
    }

    static func signature(for userSessions: [UserSession]) -> Signature {
        Signature(
            activeIDs: activeSessions(from: userSessions).map(\.identity),
            idleIDs: idleSessions(from: userSessions).map(\.identity)
        )
    }

    private static func matchingUserSession(
        for previous: UserSession,
        in userSessions: [UserSession],
        byIdentity sessionByIdentity: [SessionIdentityPolicy.LogicalIdentity: UserSession]
    ) -> UserSession? {
        if let exact = sessionByIdentity[previous.identity] { return exact }
        guard case .legacy(let stableKey) = previous.identity else { return nil }
        let matches = userSessions.filter { userSession in
            userSession.records.contains {
                SessionIdentityPolicy.stableKey(for: $0.data) == stableKey
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
