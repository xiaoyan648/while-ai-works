import AppKit
import Combine
import SwiftUI

/// Owns the settings and collection windows. The app lives in the menu bar and
/// only shows a Dock icon while one of these windows is open.
final class AppWindows: NSObject, NSWindowDelegate {
    private let state: AppState
    private var settings: NSWindow?
    private var collection: NSWindow?
    private let preview = MascotController()
    private var subscription: AnyCancellable?

    var settingsWindow: NSWindow? { settings }
    var collectionWindow: NSWindow? { collection }

    init(state: AppState) {
        self.state = state
        super.init()
        // Stay above the desktop overlay while it is showing; behave like normal windows otherwise.
        subscription = state.$desktopEnabled.removeDuplicates().sink { [weak self] enabled in
            DispatchQueue.main.async { self?.updateLevels(desktopEnabled: enabled) }
        }
    }

    func showSettings() {
        let window = settings ?? makeWindow(
            title: "设置", size: NSSize(width: 520, height: 660), minSize: NSSize(width: 480, height: 420),
            root: SettingsView(state: state, preview: preview), identifier: "settings", toolbar: false)
        settings = window
        present(window)
    }

    func showCollection(_ section: FishingGuide.Section = .book) {
        let window = collection ?? makeWindow(
            title: "渔获", size: NSSize(width: 940, height: 660), minSize: NSSize(width: 820, height: 560),
            root: FishingGuide(state: state, section: section), identifier: "collection", toolbar: true)
        collection = window
        present(window)
    }

    private func makeWindow<Root: View>(title: String, size: NSSize, minSize: NSSize, root: Root,
                                        identifier: String, toolbar: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.minSize]
        if toolbar { hosting.sceneBridgingOptions = [.toolbars] }
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if toolbar {
            window.toolbar = NSToolbar(identifier: identifier)
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
        }
        window.setContentSize(size)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = level(desktopEnabled: state.desktopEnabled)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func level(desktopEnabled: Bool) -> NSWindow.Level {
        desktopEnabled ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .normal
    }

    private func updateLevels(desktopEnabled: Bool) {
        for window in [settings, collection].compactMap({ $0 }) { window.level = level(desktopEnabled: desktopEnabled) }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async {
            let others = [self.settings, self.collection, AquariumPresentation.shared.observationWindow]
                .compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
            if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
