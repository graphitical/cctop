import AppKit
import SwiftUI
import XCTest
@testable import CctopMenubar

final class FloatingPanelMouseEventTests: XCTestCase {
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
        delegate.windowWillStartLiveResize(notification)
        delegate.windowDidEndLiveResize(notification)
        XCTAssertEqual(delegate.panelHeightModel.height, preferredHeight)
    }

    @MainActor
    func testOnlySingleEdgeDragsCountAsManualResizing() throws {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [], backing: .buffered, defer: false
        )
        for (point, count, expected) in [
            (NSPoint(x: 160, y: 2), 1, true),
            (NSPoint(x: 160, y: 250), 1, false),
            (NSPoint(x: 160, y: 498), 2, false),
        ] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1
            ))
            XCTAssertEqual(panel.isUserResizeEvent(event), expected)
        }
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
