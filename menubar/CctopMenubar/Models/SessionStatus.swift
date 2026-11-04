import Foundation

enum SessionStatus: String, Codable {
    case idle
    case working
    case compacting
    case waitingPermission = "waiting_permission"
    case waitingAnswer = "waiting_answer"
    case waitingInput = "waiting_input"
    case needsAttention = "needs_attention"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? (raw.contains("waiting") ? .needsAttention : .working)
    }

    var needsAttention: Bool {
        switch self {
        case .waitingPermission, .waitingAnswer, .waitingInput, .needsAttention: return true
        default: return false
        }
    }

    var sortOrder: Int {
        switch self {
        case .waitingPermission: return 0
        case .waitingAnswer, .waitingInput, .needsAttention: return 1
        case .working: return 2
        case .compacting: return 3
        case .idle: return 4
        }
    }

}
