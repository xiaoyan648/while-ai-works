import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = AppState()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var overlay: DesktopOverlay!
    private var monitor: CodexMonitor!
    private var interactionShortcut: InteractionShortcut!
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundle=Bundle.main.bundleIdentifier,
           let other=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).filter({$0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated}).sorted(by:{($0.launchDate ?? .distantPast)<($1.launchDate ?? .distantPast)}).first {
            other.activate(options:[.activateAllWindows])
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("whileaiworks.showSettings"),object:bundle)
            NSApp.terminate(nil);return
        }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(showWindow),name:Notification.Name("whileaiworks.showSettings"),object:Bundle.main.bundleIdentifier)
        buildMenu()
        interactionShortcut = InteractionShortcut(state: state)
        overlay = DesktopOverlay(state: state)
        monitor = CodexMonitor(state: state)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 438, height: 688),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "AI 干活时我们干什么"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.976, green: 0.969, blue: 0.949, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 438, height: 688)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(state: state))
        window.center()
        state.$mode.removeDuplicates().sink { [weak self] mode in
            DispatchQueue.main.async {
                guard let self, let window = self.window else { return }
                window.setContentSize(NSSize(width: mode == .fishing ? 798 : 438, height: 688))
                if let screen = window.screen, window.frame.maxX > screen.visibleFrame.maxX {
                    var frame = window.frame; frame.origin.x = screen.visibleFrame.maxX - frame.width
                    window.setFrame(frame, display: true)
                }
            }
        }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }.store(in: &subscriptions)
        showWindow()
    }

    private func buildMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AI 干活时我们干什么", action: #selector(about), keyEquivalent: "")
        add(appMenu, "打开设置", #selector(showWindow), key: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.submenu = appMenu
        main.addItem(item)
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "AI 干活时我们干什么"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: state.status, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        add(menu, "打开设置", #selector(showWindow))
        let desktop = add(menu, state.desktopEnabled ? "回去工作 · " + state.shortcutLabel : "开始玩 · " + state.shortcutLabel, #selector(toggleDesktop))
        desktop.state = state.desktopEnabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "擦污渍", #selector(selectWipe)).state = state.mode == .wipe ? .on : .off
        add(menu, "捏气泡", #selector(selectBubbles)).state = state.mode == .bubbles ? .on : .off
        add(menu, "敲木鱼 · 总计 \(state.totalStrikes)", #selector(selectWoodfish)).state = state.mode == .woodfish ? .on : .off
        add(menu, "钓鱼 · 总鱼获 \(state.fishingBook.total)", #selector(selectFishing)).state = state.mode == .fishing ? .on : .off
        add(menu, "自动切换", #selector(toggleAuto)).state = state.autoSwitch ? .on : .off
        add(menu, "切换到下一个", #selector(nextMode))
        add(menu, "整个屏幕", #selector(toggleArea)).state = state.area == .fullScreen ? .on : .off
        add(menu, "重新铺满", #selector(reset)).isEnabled = state.mode != .woodfish && state.desktopEnabled
        menu.addItem(.separator())
        add(menu, "跟随 AI 工作", #selector(toggleFollowAI)).state = state.followAI ? .on : .off
        for (index, source) in WorkSource.allCases.enumerated() {
            let item = add(menu, source.clientName, #selector(selectSource(_:)))
            item.tag = index
            item.state = state.selectedSources.contains(source) ? .on : .off
            item.isEnabled = state.followAI
        }
        add(menu, "声音", #selector(toggleSound)).state = state.soundEnabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "退出", #selector(quit), key: "q")
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    private func updateStatusIcon() {
        let name = state.interactionEnabled ? "hand.point.up.left.fill" : state.desktopEnabled ? "sparkles" : "circle.dotted"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AI 干活时我们干什么")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = state.interactionEnabled ? "操作已开启 · " + state.shortcutLabel + " 关闭" : "操作已关闭 · " + state.shortcutLabel + " 开启"
    }
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func closeWindow() { (NSApp.keyWindow ?? window)?.close() }
    @objc private func toggleInteraction() { state.interactionEnabled.toggle() }
    @objc private func toggleDesktop() { state.desktopEnabled.toggle() }
    @objc private func selectWipe() { state.mode = .wipe }
    @objc private func selectBubbles() { state.mode = .bubbles }
    @objc private func reset() { state.reset() }
    @objc private func toggleFollowAI() { state.followAI.toggle() }
    @objc private func selectSource(_ sender: NSMenuItem) {
        let source = WorkSource.allCases[sender.tag]
        state.setSource(source, selected: !state.selectedSources.contains(source))
    }
    @objc private func selectFishing() { state.mode = .fishing }
    @objc private func selectWoodfish() { state.mode = .woodfish }
    @objc private func toggleAuto() { state.autoSwitch.toggle() }
    @objc private func nextMode() { state.nextMode() }
    @objc private func toggleArea() { state.area = state.area == .edges ? .fullScreen : .edges }
    @objc private func toggleSound() { state.soundEnabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AI 干活时我们干什么",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.13.0",
            .credits: NSAttributedString(string: "擦污渍、捏气泡、敲木鱼、钓鱼。\n原生 macOS 小玩具。")
        ])
    }
    func applicationWillTerminate(_ notification: Notification) { PlayAudio.shared.stopAll() }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum WhileAIWorks {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
