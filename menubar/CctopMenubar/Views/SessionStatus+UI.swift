import SwiftUI

extension SessionStatus {
    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            colorPair(in: ThemeManager.shared.current).resolve(appearance)
        })
    }

    func colorPair(in theme: AppTheme) -> AppTheme.ColorPair {
        switch self {
        case .waitingPermission: return theme.statusPermission
        case .waitingAnswer, .waitingInput, .needsAttention: return theme.statusAttention
        case .working: return theme.statusWorking
        case .compacting: return theme.agentBadge
        case .idle: return theme.statusIdle
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
    var isReadyForNextTask: Bool { isCodex && status == .waitingInput }

    func statusColorPair(in theme: AppTheme) -> AppTheme.ColorPair {
        isReadyForNextTask ? theme.statusIdle : status.colorPair(in: theme)
    }

    var statusColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            statusColorPair(in: ThemeManager.shared.current).resolve(appearance)
        })
    }

    private var usesGenericPermissionLabel: Bool {
        isCodex && status == .waitingPermission && codexPermissionReviewer != .user
    }

    var statusLabel: String {
        if usesGenericPermissionLabel { return "Waiting" }
        return isReadyForNextTask ? "Ready" : status.label.capitalized
    }

    var statusAccessibilityDescription: String {
        if hasPendingAsyncQuestion { return "\(status.accessibilityDescription), question pending" }
        if usesGenericPermissionLabel { return "waiting for permission review" }
        return isReadyForNextTask ? "ready for your next task" : status.accessibilityDescription
    }
}
