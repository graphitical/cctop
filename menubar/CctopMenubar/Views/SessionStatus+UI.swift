import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .waitingPermission: return Color.statusPermission
        case .waitingAnswer, .waitingInput, .needsAttention: return Color.statusAttention
        case .working: return Color.statusGreen
        case .compacting:
            return Color(nsColor: NSColor(name: nil) { appearance in
                ThemeManager.shared.current.agentBadge.resolve(appearance)
            })
        case .idle:
            return Color(nsColor: NSColor(name: nil) { appearance in
                ThemeManager.shared.current.statusIdle.resolve(appearance)
            })
        }
    }

    var label: String {
        switch self {
        case .waitingPermission: return "PERMISSION"
        case .waitingAnswer: return "BLOCKED"
        case .waitingInput, .needsAttention: return "WAITING"
        case .working: return "WORKING"
        case .compacting: return "COMPACTING"
        case .idle: return "IDLE"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .waitingPermission: return "waiting for permission"
        case .waitingAnswer: return "blocked, waiting for your answer"
        case .waitingInput: return "waiting for input"
        case .needsAttention: return "needs attention"
        case .working: return "working"
        case .compacting: return "compacting context"
        case .idle: return "idle"
        }
    }
}

extension SessionData {
    var statusLabel: String {
        isCodex && status == .waitingInput ? "Ready" : status.label.capitalized
    }

    var statusAccessibilityDescription: String {
        isCodex && status == .waitingInput ? "ready for your next task" : status.accessibilityDescription
    }
}
