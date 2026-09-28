import AppKit
import SwiftUI

/// Borderless, vibrant panel that drops down from the status item, like a
/// system menu bar extra. It closes on Escape, on outside clicks and when the
/// app deactivates.
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class MenuBarPanelController: NSObject {
    static let cornerRadius: CGFloat = 14
    let panel: MenuBarPanel
    private let host: NSView
    private var frameObserver: NSObjectProtocol?
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private(set) var isShown = false

    init<Content: View>(content: Content) {
        panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        host = NSHostingView(rootView: content.fixedSize())
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }
        panel.setAccessibilityLabel("AI 干活时我们干什么")

        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        material.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.postsFrameChangedNotifications = true
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor)
        ])
        panel.contentView = material
        // The panel always wraps its SwiftUI content, growing downward from the menu bar.
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host,
                                                               queue: .main) { [weak self] _ in
            // Resize outside the layout pass that reported the change.
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        host.layoutSubtreeIfNeeded()
        fitToContent()
        position()
        guard !isShown else { panel.makeKeyAndOrderFront(nil); return }
        isShown = true
        button.highlight(true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        guard isShown else { return }
        isShown = false
        anchor?.highlight(false)
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    private func fitToContent() {
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        resize(to: size)
    }

    private func resize(to size: CGSize) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        if isShown { position() }
    }

    /// Hang the panel under the status item, kept inside the visible screen.
    private func position() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? itemFrame
        let size = panel.frame.size
        var origin = NSPoint(x: itemFrame.midX - size.width / 2, y: itemFrame.minY - 6 - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
    }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in self?.close() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel && event.window !== self.anchor?.window { self.close() }
            return event
        }) {
            monitors.append(local)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.close() }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
