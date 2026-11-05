import AppKit

/// Renders the menubar item as the same hairline status bar used throughout cctop.
/// With no sessions it becomes a monochrome template bar.
@MainActor
enum MenubarIconRenderer {
    private static let size = NSSize(width: 36, height: 18)
    private static let barRect = NSRect(x: 0, y: 6, width: 36, height: 6)

    static func render(counts: StatusCounts) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let label = counts.questionLabel.map { NSAttributedString(string: $0, attributes: [.font: font]) }
        let width = size.width + (label.map { ceil($0.size().width) + 4 } ?? 0)
        let image = NSImage(size: NSSize(width: width, height: size.height), flipped: false) { _ in
            if counts.total == 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(
                    roundedRect: barRect,
                    xRadius: barRect.height / 2,
                    yRadius: barRect.height / 2
                ).fill()
            } else {
                // AppKit makes the status item's effective appearance current here,
                // so one live image follows menu-bar light/dark changes immediately.
                drawSegmentedBar(
                    in: barRect,
                    counts: counts,
                    appearance: NSAppearance.current
                )
            }
            if let text = counts.questionLabel {
                (text as NSString).draw(at: NSPoint(x: barRect.maxX + 4, y: 2), withAttributes: [
                    .font: font, .foregroundColor: StatusColors.color(for: .attention, appearance: NSAppearance.current)
                ])
            }
            return true
        }

        image.isTemplate = counts.total == 0
        return image
    }

    private static func drawSegmentedBar(
        in barRect: NSRect, counts: StatusCounts, appearance: NSAppearance
    ) {
        let path = NSBezierPath(
            roundedRect: barRect,
            xRadius: barRect.height / 2,
            yRadius: barRect.height / 2
        )
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()

        let segments = counts.barSegments(forWidth: Double(barRect.width))
        var xPos = barRect.minX
        for (index, seg) in segments.enumerated() {
            // Last segment fills to the right edge to avoid float rounding gaps
            let segWidth = index == segments.count - 1
                ? max(0, barRect.maxX - xPos)
                : barRect.width * seg.proportion
            StatusColors.color(for: seg.kind, appearance: appearance).setFill()
            NSRect(
                x: xPos, y: barRect.minY,
                width: segWidth, height: barRect.height
            ).fill()
            xPos += segWidth
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
