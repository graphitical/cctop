import AppKit
import SwiftUI
import XCTest
@testable import CctopMenubar

private final class ResizeTraceDelegate: AppDelegate {
    var frameRequestMarkers: [Bool] = []

    override func windowWillStartLiveResize(_ notification: Notification) {
        frameRequestMarkers.append(isSettingPanelFrame)
        super.windowWillStartLiveResize(notification)
    }
}

private struct ResizeContentProbe: View {
    @ObservedObject var heightModel: PanelHeightModel
    let sessions: [UserSession]
    let pluginManager: PluginManager

    var body: some View {
        PopupView(userSessions: sessions, updater: DisabledUpdater(), pluginManager: pluginManager,
                  panelHeight: heightModel.height)
            .frame(width: 320)
            .background { PanelSurfaceBackground() }
            .environment(\.colorScheme, .dark)
    }
}

private final class LiveResizePanel: FloatingPanel {
    override var inLiveResize: Bool { true }
}

final class FloatingPanelMouseEventTests: XCTestCase {
    @MainActor
    func testLiveResizeKeepsContentHeightAlignedWithoutAMouseCurrentEvent() throws {
        let delegate = AppDelegate()
        let panel = LiveResizePanel(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 500),
            styleMask: [], backing: .buffered, defer: false
        )
        delegate.panel = panel
        delegate.panelHeightModel.updateLiveHeight(500)
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = panel.host(ResizeContentProbe(
            heightModel: delegate.panelHeightModel,
            sessions: userSessions(fromDataFixtures: Array(SessionData.qaFiveSessions.prefix(2))),
            pluginManager: inertPluginManager()
        ))
        host.layoutSubtreeIfNeeded()
        let notification = Notification(name: NSWindow.didResizeNotification, object: panel)
        delegate.windowWillStartLiveResize(notification)
        XCTAssertTrue(delegate.isUserResizingPanel)

        for height: CGFloat in [280, 540, 320] {
            panel.setContentSize(NSSize(width: 320, height: height))
            delegate.windowDidResize(notification)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 0.5,
                           "The rendered header and footer must fit inside the resized panel")
            XCTAssertEqual(delegate.panelHeightModel.height, height,
                           "The fixed SwiftUI height must follow the live window height so chrome is not clipped")
        }
    }

    @MainActor
    func testAnimatedFrameRequestMarksItsResizeStart() {
        let delegate = ResizeTraceDelegate()
        let panel = FloatingPanel(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 500),
            styleMask: [], backing: .buffered, defer: false
        )
        delegate.panel = panel
        panel.delegate = delegate
        panel.host(Color.clear.frame(width: 320, height: 500))
        let preferredHeight = delegate.panelHeightModel.height
        delegate.setPanelFrame(NSRect(x: 100, y: 200, width: 320, height: 400), animate: true)
        XCTAssertEqual(delegate.frameRequestMarkers, [true])
        XCTAssertFalse(delegate.isSettingPanelFrame, "A later native drag must not inherit the request marker")
        XCTAssertFalse(delegate.isUserResizingPanel)
        let notification = Notification(name: NSWindow.didEndLiveResizeNotification, object: panel)
        delegate.windowDidEndLiveResize(notification)
        XCTAssertEqual(delegate.panelHeightModel.height, preferredHeight)

        delegate.windowWillStartLiveResize(notification)
        XCTAssertTrue(delegate.isUserResizingPanel, "A native start after the request must be recognized")
        panel.orderOut(nil)
    }

    @MainActor
    func testFirstLiveResizeEstablishesAndPersistsTheContentHeight() throws {
        let defaults = UserDefaults.standard
        let savedHeight = defaults.object(forKey: "panelHeight")
        defaults.removeObject(forKey: "panelHeight")
        defer { defaults.set(savedHeight, forKey: "panelHeight") }
        let delegate = AppDelegate()
        let panel = LiveResizePanel(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 500),
            styleMask: [], backing: .buffered, defer: false
        )
        delegate.panel = panel
        XCTAssertNil(delegate.panelHeightModel.height)
        let host = panel.host(ResizeContentProbe(
            heightModel: delegate.panelHeightModel,
            sessions: userSessions(fromDataFixtures: SessionData.qaFiveSessions),
            pluginManager: inertPluginManager()
        ))
        let notification = Notification(name: NSWindow.didResizeNotification, object: panel)
        delegate.windowWillStartLiveResize(notification)
        panel.setContentSize(NSSize(width: 320, height: 280))
        delegate.windowDidResize(notification)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 280, accuracy: 0.5)
        delegate.windowDidEndLiveResize(notification)
        XCTAssertFalse(delegate.isUserResizingPanel)
        XCTAssertEqual(PanelHeightModel().height, 280)
    }

    @MainActor
    func testPanelEnablesNativeResizeWithFixedWidth() {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.minSize.width, 320)
        XCTAssertEqual(panel.maxSize.width, 320)
        XCTAssertGreaterThan(panel.maxSize.height, panel.minSize.height)
    }

    @MainActor
    func testSwiftUIHeightDoesNotLockNativeResizeLimits() {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let host = panel.host(Color.clear.frame(width: 320, height: 500))
        host.layoutSubtreeIfNeeded()
        host.rootView = Color.clear.frame(width: 320, height: 800)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(panel.maxSize.height, 800)
        let delegate = AppDelegate()
        delegate.panel = panel
        XCTAssertEqual(delegate.windowWillResize(panel, to: NSSize(width: 640, height: 500)).width, 320)
    }

    @MainActor
    func testProgrammaticResizeDoesNotReplacePreferredHeight() {
        let delegate = AppDelegate()
        delegate.panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [], backing: .buffered, defer: false
        )
        let preferredHeight = delegate.panelHeightModel.height
        let notification = Notification(name: NSWindow.didEndLiveResizeNotification, object: delegate.panel)
        delegate.isSettingPanelFrame = true
        delegate.windowWillStartLiveResize(notification)
        delegate.isSettingPanelFrame = false
        delegate.windowDidEndLiveResize(notification)
        XCTAssertEqual(delegate.panelHeightModel.height, preferredHeight)
    }

    func testPrimesKeyWindowForInactiveBodyMouseDown() {
        XCTAssertTrue(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: false,
                isHeaderClick: false
            )
        )
    }

    func testDoesNotPrimeKeyWindowForAlreadyKeyPanel() {
        XCTAssertFalse(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: true,
                isHeaderClick: false
            )
        )
    }

    func testDoesNotPrimeKeyWindowForHeaderMouseDown() {
        XCTAssertFalse(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: false,
                isHeaderClick: true
            )
        )
    }
}
