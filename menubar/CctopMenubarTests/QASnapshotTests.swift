import XCTest
@testable import CctopMenubar
import SwiftUI

/// QA snapshot tests that render PopupView with various session configurations.
///
/// Each test saves a PNG to /tmp/cctop-qa/<scenario>.png for visual inspection.
/// Run all QA snapshots:
///   make snapshots
@MainActor
final class QASnapshotTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            atPath: "/tmp/cctop-qa",
            withIntermediateDirectories: true
        )
    }

    // MARK: - Session count scenarios

    func testManualPanelHeights() throws {
        for height: CGFloat in [280, 540] {
            let view = PopupView(userSessions: userSessions(fromDataFixtures: SessionData.qaEightSessions),
                                 updater: DisabledUpdater(), pluginManager: inertPluginManager(), panelHeight: height)
            for colorScheme in [ColorScheme.light, .dark] {
                let size = try renderPanelScreenshot(
                    view: view, colorScheme: colorScheme, directoryName: "cctop-qa",
                    filename: "panel-height-\(Int(height))-\(colorScheme).png"
                )
                XCTAssertEqual(size.width, 320)
                XCTAssertEqual(size.height, height)
            }
        }
    }

    func testSessionDensity() throws {
        let suite = "cctop-density-snapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for compact in [false, true] {
            defaults.set(compact, forKey: "compactSessionRows")
            let view = PopupView(userSessions: userSessions(fromDataFixtures: SessionData.qaFiveSessions),
                                 updater: DisabledUpdater(), pluginManager: inertPluginManager())
                .defaultAppStorage(defaults)
            for colorScheme in [ColorScheme.light, .dark] {
                try renderPanelScreenshot(view: view, colorScheme: colorScheme, directoryName: "cctop-qa",
                                          filename: "session-density-\(compact ? "compact" : "comfortable")-\(colorScheme).png")
            }
        }
    }

    func testEmpty() throws {
        try renderSnapshot(sessions: [], name: "01-empty")
    }

    func testSingleSession() throws {
        try renderSnapshot(sessions: SessionData.qaSingle, name: "02-single")
    }

    func testFourSessions() throws {
        try renderSnapshot(sessions: SessionData.mockSessions, name: "03-four-sessions")
    }

    func testFiveSessions() throws {
        try renderSnapshot(sessions: SessionData.qaFiveSessions, name: "04-five-sessions")
    }

    func testSixSessions() throws {
        try renderSnapshot(sessions: SessionData.qaSixSessions, name: "05-six-sessions")
    }

    func testEightSessions() throws {
        try renderSnapshot(sessions: SessionData.qaEightSessions, name: "06-eight-sessions")
    }

    // MARK: - Badge count scenarios

    func testAllAttention() throws {
        try renderSnapshot(sessions: SessionData.qaAllAttention, name: "07-all-attention")
    }

    func testCodexQuestionStatuses() throws {
        var pending = SessionData.mock(id: "pending", project: "cctop", sessionName: "Add chat statuses", status: .working, source: "codex")
        pending.hasPendingAsyncQuestion = true
        var sessions = [
            pending,
            SessionData.mock(id: "question", project: "cctop", sessionName: "Choose a status label",
                             status: .waitingAnswer, source: "codex"),
            SessionData.mock(id: "ready", project: "api", sessionName: "Review the changes",
                             status: .waitingInput, source: "codex"),
            SessionData.mock(id: "permission", project: "website", sessionName: "Install dependencies",
                             status: .waitingPermission, source: "codex"),
            SessionData.mock(id: "working", project: "cctop", sessionName: "Run the focused tests",
                             status: .working, source: "codex"),
            SessionData.mock(id: "compacting", project: "api", sessionName: "Compact the context",
                             status: .compacting, source: "codex"),
            SessionData.mock(id: "idle", project: "website", sessionName: "Idle conversation",
                             status: .idle, source: "codex")
        ]
        sessions[3].codexPermissionReviewer = .user
        let ordered = SessionDisplayPolicy.reconcilingOrder(in: userSessions(fromDataFixtures: sessions), preserving: [])
        sessions = ordered.map(\.displayRecord.data)
        let selectedTheme = ThemeManager.shared.current
        defer { ThemeManager.shared.setTheme(selectedTheme) }
        for theme in AppTheme.allCases {
            ThemeManager.shared.setTheme(theme)
            for colorScheme in [ColorScheme.light, .dark] {
                let view = PopupView(userSessions: ordered,
                                     updater: DisabledUpdater(), pluginManager: inertPluginManager())
                try renderPanelScreenshot(view: view, colorScheme: colorScheme, directoryName: "cctop-qa",
                                          filename: "codex-question-status-\(theme.rawValue)-\(colorScheme).png")
                let navigationView = VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.sessionId) { entry in
                        SessionCardView(session: entry.element, navigateIndex: entry.offset + 1)
                    }
                }
                .padding(.vertical, 8)
                try renderPanelScreenshot(view: navigationView, colorScheme: colorScheme, directoryName: "cctop-qa",
                                          filename: "codex-question-status-\(theme.rawValue)-navigate-\(colorScheme).png")
            }
        }
        let counts = StatusCounts(userSessions: userSessions(fromDataFixtures: sessions))
        let bars = VStack(spacing: 16) {
            Image(nsImage: MenubarIconRenderer.render(counts: counts))
            NotchStatusView(counts: counts).frame(width: 100)
        }.padding(16)
        try renderPanelScreenshot(view: bars, colorScheme: .dark, directoryName: "cctop-qa", filename: "question-bars.png")
    }

    func testAnsweredCodexQuestionHasNoQuestionBadge() throws {
        let sources = try isolatedSessionDataSources(prefix: "answered-question-snapshot")
        let session = SessionData.mock(id: "factory", sessionName: "factory quoting", status: .working,
                                       pid: UInt32(ProcessInfo.processInfo.processIdentifier), source: "codex")
        try session.writeToFile(path: sources.sessionsDir.appendingPathComponent("factory.json").path)
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: sources.sessionsDir.appendingPathComponent("history")),
            dataSources: sources, startMonitoring: false
        )
        let questions = try XCTUnwrap(CodexAsyncQuestions.read(in: [["id": "turn", "status": "inProgress", "items": [
            ["type": "agentMessage", "id": "split", "questions": [["title": "Split the changes?"]]],
            ["type": "userMessage", "content": [["type": "text", "text": "keep them together"]]]
        ]]]))
        manager.recordCodexQuestionReads(["factory": CodexQuestionRead(status: .running, questions: questions)],
                                        activity: ["factory": session.lastActivity])
        manager.loadSessions()
        XCTAssertFalse(try XCTUnwrap(manager.userSessions.first).displayRecord.data.hasPendingQuestion)
        let view = PopupView(userSessions: manager.userSessions, updater: DisabledUpdater(), pluginManager: inertPluginManager())
        try renderPanelScreenshot(view: view, colorScheme: .dark, directoryName: "cctop-qa", filename: "answered-codex-question.png")
    }

    func testCodexPermissionReviewerLabels() throws {
        let sources = try isolatedSessionDataSources(prefix: "permission-review-snapshot")
        let sessions = ([CodexPermissionReviewer.autoReview, .user, nil] as [CodexPermissionReviewer?])
            .enumerated().map { index, reviewer in
                var session = SessionData.mock(
                    id: "permission-\(index)", project: "cctop",
                    sessionName: ["Automatic permission review", "Your permission needed", "Unknown permission reviewer"][index],
                    status: .waitingPermission, pid: UInt32(ProcessInfo.processInfo.processIdentifier), source: "codex"
                )
                session.codexPermissionReviewer = reviewer
                session.notificationMessage = "Bash: npm install"
                return session
            }
        for session in sessions {
            try session.writeToFile(path: sources.sessionsDir.appendingPathComponent("\(session.sessionId).json").path)
        }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: sources.sessionsDir.appendingPathComponent("history")),
            dataSources: sources, startMonitoring: false
        )
        for colorScheme in [ColorScheme.light, .dark] {
            let view = PopupView(userSessions: manager.userSessions,
                                 updater: DisabledUpdater(), pluginManager: inertPluginManager())
            try renderPanelScreenshot(view: view, colorScheme: colorScheme, directoryName: "cctop-qa",
                                      filename: "codex-permission-reviewer-\(colorScheme).png")
        }
    }

    func testAllIdle() throws {
        try renderSnapshot(sessions: SessionData.qaAllIdle, name: "08-all-idle")
    }

    func testFreshIdleSessionAppearsInIdleTab() throws {
        let sessions = userSessions(fromDataFixtures: [
            .mock(id: "idle", project: "cctop", sessionName: "Review recent changes", status: .idle),
            .mock(id: "working", project: "cctop", sessionName: "Run the checks", status: .working)
        ])
        for tab in [PopupTab.active, .idle] {
            for colorScheme in [ColorScheme.light, .dark] {
                let view = PopupView(
                    userSessions: sessions,
                    updater: DisabledUpdater(), pluginManager: inertPluginManager(),
                    initialTab: tab
                )
                try renderPanelScreenshot(
                    view: view, colorScheme: colorScheme, directoryName: "cctop-qa",
                    filename: "idle-status-\(tab.label.lowercased())-\(colorScheme).png"
                )
            }
        }
    }

    // MARK: - Edge cases

    func testLongNames() throws {
        try renderSnapshot(sessions: SessionData.qaLongNames, name: "09-long-names")
    }

    func testLongSessionNames() throws {
        try renderSnapshot(sessions: SessionData.qaLongSessionNames, name: "09b-long-session-names")
    }

    func testDesktopProjectNames() throws {
        try renderSnapshot(sessions: SessionData.qaShowcase, name: "09c-desktop-project-names")
    }

    // MARK: - Dark mode

    func testFiveSessionsDark() throws {
        try renderSnapshot(sessions: SessionData.qaFiveSessions, name: "10-five-sessions-dark", colorScheme: .dark)
    }

    // MARK: - Update UI scenarios

    func testFooterUpdateAvailable() throws {
        let updater = DisabledUpdater()
        updater.pendingUpdateVersion = "0.7.0"
        try renderSnapshot(sessions: SessionData.qaShowcase, updater: updater, name: "11b-footer-update-available")
    }

    func testFooterUpdateDownloading() throws {
        let updater = DisabledUpdater()
        updater.downloadingUpdateVersion = "0.7.0"
        try renderSnapshot(sessions: SessionData.qaShowcase, updater: updater, name: "11c-footer-update-downloading")
    }

    func testSettingsUpdateAvailable() throws {
        let updater = DisabledUpdater()
        updater.pendingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "12-settings-update-available")
    }

    func testSettingsUpdateAvailableDark() throws {
        let updater = DisabledUpdater()
        updater.pendingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "13-settings-update-available-dark", colorScheme: .dark)
    }

    func testSettingsUpdateDownloading() throws {
        let updater = DisabledUpdater()
        updater.downloadingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "13b-settings-update-downloading")
    }

    func testSettingsUpdateDownloadingDark() throws {
        let updater = DisabledUpdater()
        updater.downloadingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "13c-settings-update-downloading-dark", colorScheme: .dark)
    }

    func testSettingsUpToDate() throws {
        try renderSettingsSnapshot(updater: MockQAUpdater(), name: "14-settings-up-to-date")
    }

    func testSettingsDisabledDev() throws {
        try renderSettingsSnapshot(
            updater: DisabledUpdater(reason: .development),
            name: "15-settings-disabled-dev"
        )
    }

    func testSettingsFileAccessRecoveryRow() throws {
        try renderSettingsSnapshot(
            updater: DisabledUpdater(),
            name: "16-settings-file-access-bottom-dark",
            colorScheme: .dark,
            scrollToBottom: true
        )
    }

    // MARK: - Polish review matrix

    func testPolishReviewMatrix() throws {
        let schemes: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
        for theme in AppTheme.allCases {
            ThemeManager.shared.setTheme(theme)
            for (colorScheme, schemeName) in schemes {
                try renderSnapshot(
                    sessions: SessionData.qaShowcase,
                    name: "20-active-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderRecentSnapshot(
                    name: "21-recent-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderSettingsSnapshot(
                    updater: DisabledUpdater(),
                    name: "22-settings-top-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderSettingsSnapshot(
                    updater: DisabledUpdater(),
                    name: "23-settings-bottom-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme,
                    scrollToBottom: true
                )
            }
        }
        ThemeManager.shared.setTheme(.codex)
    }

    func testRefinedPanelContextSnapshots() throws {
        ThemeManager.shared.setTheme(.tokyoNight)
        let schemes: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
        for (colorScheme, schemeName) in schemes {
            try renderRefinedPanelContextSnapshot(
                PopupView(
                    userSessions: userSessions(fromDataFixtures: SessionData.qaShowcase),
                    updater: DisabledUpdater(),
                    pluginManager: inertPluginManager()
                ),
                name: "24-refined-active-tokyoNight-\(schemeName)",
                colorScheme: colorScheme
            )
            try renderRefinedPanelContextSnapshot(
                PopupView(
                    userSessions: userSessions(fromDataFixtures: SessionData.qaShowcase),
                    recentProjects: RecentProject.mockRecents,
                    updater: DisabledUpdater(),
                    pluginManager: inertPluginManager(),
                    initialTab: .recent
                ),
                name: "25-refined-recent-tokyoNight-\(schemeName)",
                colorScheme: colorScheme
            )
            try renderRefinedPanelContextSnapshot(
                SettingsSection(updater: DisabledUpdater(), pluginManager: inertPluginManager()),
                name: "26-refined-settings-tokyoNight-\(schemeName)",
                colorScheme: colorScheme
            )
        }
        ThemeManager.shared.setTheme(.codex)
    }

    // MARK: - Live update simulation

    /// Simulates adding a 5th session to an existing 4-session view.
    /// Captures before (4 sessions) and after (5 sessions) in the same hosting view
    /// to test that SwiftUI re-renders correctly when the data changes.
    func testAddFifthSession() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)

        let hostingView = NSHostingView(rootView: AnyView(popupView(for: SessionData.mockSessions)))
        window.contentView = hostingView

        // Render "before" with 4 sessions
        var fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/11-add-fifth-before.png")

        // Update to 5 sessions in the same hosting view
        hostingView.rootView = AnyView(popupView(for: SessionData.qaFiveSessions))
        fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/11-add-fifth-after.png")
    }

    private func popupView(for sessions: [SessionData]) -> some View {
        PopupView(
            userSessions: userSessions(fromDataFixtures: sessions),
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager()
        )
            .frame(width: 320)
            .panelSnapshotChrome()
            .environment(\.colorScheme, .light)
    }

    // MARK: - Rendering

    private func renderSnapshot(
        sessions: [SessionData],
        updater: UpdaterBase? = nil,
        name: String,
        colorScheme: ColorScheme = .light
    ) throws {
        let view = PopupView(
            userSessions: userSessions(fromDataFixtures: sessions),
            updater: updater ?? DisabledUpdater(),
            pluginManager: inertPluginManager()
        )
            .frame(width: 320)
            .panelSnapshotChrome()
            .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func renderRecentSnapshot(
        name: String,
        colorScheme: ColorScheme = .light
    ) throws {
        let view = PopupView(
            userSessions: userSessions(fromDataFixtures: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .recent
        )
        .frame(width: 320)
        .panelSnapshotChrome()
        .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func renderSettingsSnapshot(
        updater: UpdaterBase,
        name: String,
        colorScheme: ColorScheme = .light,
        scrollToBottom: Bool = false
    ) throws {
        let view = SettingsSection(updater: updater, pluginManager: inertPluginManager())
            .frame(width: 320)
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        if scrollToBottom {
            scrollFirstScrollViewToBottom(in: hostingView)
            hostingView.layoutSubtreeIfNeeded()
        }

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func renderRefinedPanelContextSnapshot<Content: View>(
        _ content: Content,
        name: String,
        colorScheme: ColorScheme
    ) throws {
        let view = ZStack {
            RefinedPanelContextScene(colorScheme: colorScheme)
            content
                .frame(width: 320)
                .panelSnapshotChrome()
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 22, x: 0, y: 16)
        }
        .frame(width: 640, height: 720)
        .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func scrollFirstScrollViewToBottom(in view: NSView) {
        guard
            let scrollView = firstSubview(ofType: NSScrollView.self, in: view),
            let documentView = scrollView.documentView
        else { return }

        let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func firstSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(ofType: type, in: subview) { return match }
        }
        return nil
    }

    private func captureToFile(hostingView: NSHostingView<some View>, path: String) throws {
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Failed to create bitmap for \(path)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to generate PNG for \(path)")
            return
        }

        try pngData.write(to: URL(fileURLWithPath: path))
        print("QA snapshot saved: \(path)")
    }
}

private extension View {
    func panelSnapshotChrome() -> some View {
        background {
            PanelSurfaceBackground()
        }
        .overlay {
            PanelAccentHairline(cornerRadius: AppChrome.panelCornerRadius)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.panelCornerRadius, style: .continuous))
    }
}

private struct RefinedPanelContextScene: View {
    let colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundGradient
            editorWindow
                .frame(width: 520, height: 470)
                .offset(x: 34, y: 42)
            floatingInspector
                .frame(width: 220, height: 180)
                .offset(x: 378, y: 440)
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.13, green: 0.12, blue: 0.18)]
                : [Color(red: 0.84, green: 0.86, blue: 0.91), Color(red: 0.94, green: 0.92, blue: 0.86)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var editorWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.93, green: 0.28, blue: 0.33)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 0.96, green: 0.68, blue: 0.25)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 0.42, green: 0.78, blue: 0.36)).frame(width: 9, height: 9)
                Text("~/projects/cctop")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(backdropText.opacity(0.72))
                    .padding(.leading, 12)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(backdropSurface.opacity(0.76))

            VStack(alignment: .leading, spacing: 9) {
                ForEach(codeLines.indices, id: \.self) { index in
                    codeLine(codeLines[index], accent: lineAccent(index))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(backdropSurface.opacity(0.54))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(backdropText.opacity(0.12), lineWidth: 1)
        }
    }

    private var floatingInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Signals")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(backdropText.opacity(0.78))
            ForEach(["Permission", "Working", "Idle"], id: \.self) { label in
                HStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(inspectorAccent(label))
                        .frame(width: 36, height: 7)
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(backdropText.opacity(0.60))
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(16)
        .background(backdropSurface.opacity(colorScheme == .dark ? 0.46 : 0.58))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(backdropText.opacity(0.10), lineWidth: 1)
        }
    }

    private func codeLine(_ line: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent.opacity(0.68))
                .frame(width: 24, height: 7)
            Text(line)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(backdropText.opacity(0.64))
                .lineLimit(1)
            Spacer()
        }
    }

    private var backdropText: Color {
        colorScheme == .dark ? Color(red: 0.78, green: 0.82, blue: 0.96) : Color(red: 0.20, green: 0.23, blue: 0.31)
    }

    private var backdropSurface: Color {
        colorScheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.21) : Color.white
    }

    private var codeLines: [String] {
        [
            "struct PanelSurfaceBackground: View {",
            "  Color.panelBackground",
            "  PanelAccentHairline(cornerRadius: 16)",
            "}",
            "cardSelectionStyle(isSelected: true)",
            "HeaderView(counts: statusCounts)",
            "renderPanelScreenshot(...)",
        ]
    }

    private func lineAccent(_ index: Int) -> Color {
        [Color(red: 0.97, green: 0.46, blue: 0.56), Color(red: 0.60, green: 0.80, blue: 0.42),
         Color(red: 0.48, green: 0.64, blue: 0.97), Color(red: 1.00, green: 0.62, blue: 0.39)][index % 4]
    }

    private func inspectorAccent(_ label: String) -> Color {
        switch label {
        case "Permission": return Color(red: 0.97, green: 0.46, blue: 0.56)
        case "Working": return Color(red: 0.60, green: 0.80, blue: 0.42)
        default: return Color(red: 0.42, green: 0.45, blue: 0.56)
        }
    }
}

// MARK: - Mock Updater for QA

@MainActor
private class MockQAUpdater: UpdaterBase {
    override var canCheckForUpdates: Bool { true }
}
