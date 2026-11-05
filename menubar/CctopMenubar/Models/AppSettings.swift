import KeyboardShortcuts
import Foundation

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum IdleTimeoutSettings {
    static let defaultsKey = "idleTimeoutMinutes"
    static let defaultMinutes = 60
    static let defaultSeconds = TimeInterval(defaultMinutes) * 60

    static func timeout(in defaults: UserDefaults) -> TimeInterval {
        let minutes = (defaults.object(forKey: defaultsKey) as? NSNumber)?.intValue ?? defaultMinutes
        return TimeInterval(max(1, minutes)) * 60
    }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
    // Storage key is "refocus" (the old name) for backward compatibility with existing user shortcuts.
    static let navigate = Self("refocus", default: .init(.n, modifiers: [.control, .command]))
}

enum FileAccessSettings {
    static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let privacySecurityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
}
