import Foundation
import Combine

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    static let defaultsKey = "colorTheme"

    @Published private(set) var current: AppTheme

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.defaultsKey) ?? "codex"
        self.current = AppTheme(rawValue: saved) ?? .codex
    }

    var themeId: String { current.rawValue }

    func setTheme(_ theme: AppTheme) {
        current = theme
        defaults.set(theme.rawValue, forKey: Self.defaultsKey)
        defaults.synchronize()
    }
}
