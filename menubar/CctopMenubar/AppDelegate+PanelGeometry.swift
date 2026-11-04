import AppKit

// MARK: - Panel geometry and per-screen position
extension AppDelegate {
    /// The screen key for the screen the panel is currently on.
    @MainActor func panelScreenKey() -> String? {
        PanelPositioning.screenKey(forPanelFrame: panel.frame, in: screenLayouts)
    }

    /// The screen key for the screen containing a point.
    func screenKey(at point: NSPoint) -> String? {
        PanelPositioning.screenKey(containing: point, in: screenLayouts)
    }

    private var screenLayouts: [ScreenLayout] {
        NSScreen.screens.map { ScreenLayout($0) }
    }

    @MainActor func positionPanel(animate: Bool = false) {
        let clickKey = focusLocation.flatMap { screenKey(at: $0) }
            ?? panelScreenKey()
        guard let size = panelFittingSize(maximumHeight: maximumPanelHeight(screenKey: clickKey)) else { return }
        if let frame = panelGeometry.showFrame(
            clickScreenKey: clickKey,
            clickLocation: focusLocation,
            anchorRect: anchorRect(),
            panelSize: size,
            screens: screenLayouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    /// The screen-space rect of the anchor (notch pill or menubar icon).
    @MainActor private func anchorRect() -> NSRect? {
        notchController.pillFrame ?? menubarIconRect()
    }

    /// The screen-space rect of the menubar icon, even when the notch pill
    /// is the anchor (the pill only exists on the built-in screen).
    @MainActor private func menubarIconRect() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Reset panel position on double-click. If the panel is on the same screen
    /// as the anchor (menubar icon / notch pill), snap to anchor. Otherwise, snap
    /// under the menubar icon's mirrored position on the panel's current screen
    /// so it doesn't jump across screens.
    @MainActor private func resetPanelToCurrentScreen(animate: Bool = false) {
        guard let size = panelFittingSize(maximumHeight: maximumPanelHeight(screenKey: panelScreenKey())) else { return }
        let layouts = screenLayouts
        let panelIdx = PanelPositioning.screenIndex(forPanelFrame: panel.frame, in: layouts)
        if let frame = PanelPositioning.resolveResetPosition(
            anchorRect: anchorRect(),
            menubarIconRect: menubarIconRect(),
            panelScreenIndex: panelIdx,
            panelSize: size,
            screens: layouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    @MainActor func handleScreenChange() {
        screenChangeWork?.cancel()
        suppressResize = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.suppressResize = false
            self.hasNotch = NSScreen.builtin?.hasPhysicalNotch == true
            self.refreshStatusDisplay(counts: StatusCounts(userSessions: self.sessionManager.userSessions))
            guard self.panel.isVisible else { return }
            // A click location captured before the debounce must not drive
            // screen-change repositioning; clearing it keeps the key below
            // and positionPanel's internal key identical.
            self.focusLocation = nil
            self.positionPanel(animate: false)
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @MainActor func resizePanel(animate: Bool = false) {
        guard !suppressResize, !panel.inLiveResize else { return }
        let maximumHeight = maximumPanelHeight(screenKey: panelScreenKey(), below: panel.frame.maxY)
        guard let size = panelFittingSize(maximumHeight: maximumHeight) else { return }
        let newFrame = panelGeometry.resizedFrame(
            from: panel.frame, to: size, panelScreenKey: panelScreenKey()
        )
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize(maximumHeight: CGFloat) -> NSSize? {
        if let height = panelHeightModel.resolveHeight(maximumHeight: maximumHeight) {
            return NSSize(width: 320, height: height)
        }
        panel.contentView?.layout()
        guard let size = panel.contentView?.fittingSize else { return nil }
        return NSSize(width: 320, height: min(size.height, 600, maximumHeight))
    }

    private func maximumPanelHeight(screenKey: String?, below topY: CGFloat? = nil) -> CGFloat {
        let screen = screenLayouts.first { $0.key == screenKey } ?? screenLayouts.first
        guard let visibleFrame = screen?.visibleFrame else { return 600 }
        let top = min(topY ?? visibleFrame.maxY - PanelPositioning.margin, visibleFrame.maxY)
        return max(1, top - visibleFrame.minY - PanelPositioning.margin)
    }

    private func setPanelFrame(_ frame: NSRect, animate: Bool) {
        guard !panel.frame.isNearlyEqual(to: frame) else { return }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private extension NSRect {
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5 &&
            abs(origin.y - other.origin.y) < 0.5 &&
            abs(size.width - other.size.width) < 0.5 &&
            abs(size.height - other.size.height) < 0.5
    }
}

// MARK: - FloatingPanelDelegate
extension AppDelegate: FloatingPanelDelegate {
    @MainActor func panelDidDrag(originX: CGFloat, topY: CGFloat) {
        panelGeometry.saveUserDraggedPosition(
            originX: originX,
            topY: topY,
            panelSize: panel.frame.size,
            screens: screenLayouts
        )
    }

    @MainActor func panelDidRequestReset() {
        panelGeometry.clearUserPosition(forPanelFrame: panel.frame, screens: screenLayouts)
        resetPanelToCurrentScreen(animate: true)
    }
}

// MARK: - Native vertical resizing
extension AppDelegate: NSWindowDelegate {
    func windowWillStartLiveResize(_ notification: Notification) {
        // AppKit also sends these callbacks for animated, programmatic frame changes.
        isUserResizingPanel = panel.isUserResizeEvent(NSApp.currentEvent)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let maximumHeight = maximumPanelHeight(screenKey: panelScreenKey(), below: sender.frame.maxY)
        return NSSize(
            width: 320,
            height: PanelHeightModel.clampedHeight(frameSize.height, maximumHeight: maximumHeight)
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard isUserResizingPanel, panel.inLiveResize else { return }
        panelHeightModel.updateLiveHeight(panel.frame.height)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        defer { isUserResizingPanel = false }
        guard isUserResizingPanel else { return }
        panelHeightModel.rememberHeight(panel.frame.height)
    }
}
