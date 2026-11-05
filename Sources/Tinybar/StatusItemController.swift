import AppKit
import SwiftUI

/// Owns the NSStatusItem and the popover. The menu bar shows a fixed monochrome mark; the numbers
/// live in the popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private lazy var stats = StatsWindowController(model: model)

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        // Size the popover to the SwiftUI content; the default is a fixed 320×320 box that
        // centers and clips the content.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.image = MenuBarIcon.image()
            button.toolTip = "Usage limits"
            button.setAccessibilityLabel("Usage limits")
        }
        model.openStats = { [weak self] in
            self?.popover.performClose(nil)
            self?.stats.show()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refreshOnOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Two concentric open rings drawn as a template image, so the menu bar tints it like any
/// system icon.
@MainActor
enum MenuBarIcon {
    static let size: CGFloat = 16

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setStroke()
            let outer = rect.insetBy(dx: 1.25, dy: 1.25)
            arc(in: outer, sweep: 290, width: 2)
            let inner = rect.insetBy(dx: 5, dy: 5)
            arc(in: inner, sweep: 200, width: 2)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func arc(in rect: NSRect, sweep: CGFloat, width: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
            startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }
}
