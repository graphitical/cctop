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

    /// Orders every status by most recent activity. Equal timestamps keep their prior
    /// canonical identity order, followed by newcomers in the supplied input order.
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
            let leftActivity = left.element.displayRecord.data.lastActivity
            let rightActivity = right.element.displayRecord.data.lastActivity
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            let leftRank = priorRank[left.element.identity] ?? previousUserSessions.count + left.offset
            let rightRank = priorRank[right.element.identity] ?? previousUserSessions.count + right.offset
            return leftRank < rightRank
        }.map(\.element)
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
