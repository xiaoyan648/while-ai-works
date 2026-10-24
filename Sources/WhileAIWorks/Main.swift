import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static var isLocalPreview: Bool {
        ProcessInfo.processInfo.environment["WHILE_AI_WORKS_CAT_PREVIEW"] == "1"
            || Bundle.main.object(forInfoDictionaryKey: "WAWLocalPreview") as? Bool == true
    }
    let state: AppState = {
        guard AppDelegate.isLocalPreview else { return AppState() }
        // A runnable review build reads real local work state, but never changes
        // the installed app's preferences or starts its games/audio.
        let localAgents = Bundle.main.object(forInfoDictionaryKey: "WAWLocalPreview") as? Bool == true
        let defaults = UserDefaults(suiteName: localAgents ? "WhileAIWorks.HermesDSHPreview" : "WhileAIWorks.CatDockPreview")!
        let state = AppState(defaults: defaults)
        state.desktopEnabled = false; state.soundEnabled = false
        state.desktopPetEnabled = true
        state.agentReplyPreviews = true
        if localAgents && defaults.object(forKey: "work.sources") == nil { state.selectedSources = [.codex, .claude, .hermes, .dsh] }
        return state
    }()
    private var statusItem: NSStatusItem!
    private var overlay: DesktopOverlay!
    private var monitor: CodexMonitor!
    private var interactionShortcut: InteractionShortcut!
    private var windows: AppWindows!
    private var panel: MenuBarPanelController!
    private var desktopPet: DesktopPetController!
    private var agentHub: AgentHubDataController!
    private var updater: AppUpdater!
    private let mascot = MascotController()
    private let quickMenu = NSMenu()
    private var subscriptions: Set<AnyCancellable> = []
    private var statusIconScheduled = false
    private var statusIconKey: (filled: Bool, working: Bool, tip: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundle=Bundle.main.bundleIdentifier,
           let other=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).filter({$0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated}).sorted(by:{($0.launchDate ?? .distantPast)<($1.launchDate ?? .distantPast)}).first {
            other.activate(options:[.activateAllWindows])
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("whileaiworks.showSettings"),object:bundle)
            NSApp.terminate(nil);return
        }
        NSApp.setActivationPolicy(.accessory)
        AgentCommandEnvironment.configure()
        updater = AppUpdater(state: state)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(showPanel),name:Notification.Name("whileaiworks.showSettings"),object:Bundle.main.bundleIdentifier)
        interactionShortcut = InteractionShortcut(state: state)
        overlay = DesktopOverlay(state: state)
        monitor = CodexMonitor(state: state)
        agentHub = AgentHubDataController(state: state)
        windows = AppWindows(state: state)
        panel = MenuBarPanelController(content: MenuBarView(
            state: state, mascot: mascot,
            openCollection: { [weak self] in self?.panel.close(); self?.windows.showCollection() },
            openSettings: { [weak self] in self?.panel.close(); self?.windows.showSettings() },
            quit: { NSApp.terminate(nil) }))
        buildMenus()
        desktopPet = DesktopPetController(state: state,
            showPanel: { [weak self] in self?.showPanel() },
            showSettings: { [weak self] in self?.showSettings() })
        state.objectWillChange.sink { [weak self] _ in
            guard let self, !self.statusIconScheduled else { return }
            self.statusIconScheduled = true
            DispatchQueue.main.async { [weak self] in self?.statusIconScheduled = false; self?.updateStatusIcon() }
        }.store(in: &subscriptions)
        if DebugSnapshots.directory != nil { runSnapshots(); return }
        if AppDelegate.isLocalPreview { return }
        updater.start()
        // Greet with the panel so a first launch never looks like nothing happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
    }

    private func runSnapshots() {
        typealias D = DebugSnapshots
        D.run([
            .init(delay: 0.5) { D.appearance(false); self.showPanel() },
            .init(delay: 1.8) { D.capture(self.panel.panel, as: "panel-light") },
            .init(delay: 0.1) { self.mascot.celebrate() },
            .init(delay: 0.42) { D.capture(self.panel.panel, as: "panel-light-celebrate") },
            .init(delay: 1.4) { D.appearance(true) },
            .init(delay: 1.0) { D.capture(self.panel.panel, as: "panel-dark") },
            .init(delay: 0.1) { self.mascot.pet() },
            .init(delay: 0.8) { D.capture(self.panel.panel, as: "panel-dark-pet") },
            .init(delay: 0.3) { self.panel.close(); D.appearance(false); self.windows.showSettings() },
            .init(delay: 1.6) { D.capture(self.windows.settingsWindow, as: "settings-light") },
            .init(delay: 0.1) { D.appearance(true) },
            .init(delay: 1.2) { D.capture(self.windows.settingsWindow, as: "settings-dark") },
            .init(delay: 0.1) { self.windows.settingsWindow?.close(); D.appearance(false); self.windows.showCollection() },
            .init(delay: 2.0) { D.capture(self.windows.collectionWindow, as: "collection-light") },
            .init(delay: 0.1) { D.appearance(true) },
            .init(delay: 1.4) { D.capture(self.windows.collectionWindow, as: "collection-dark") },
            .init(delay: 0.3) { NSApp.terminate(nil) }
        ])
    }

    private func buildMenus() {
        let main = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AI 干活时我们干什么", action: #selector(about), keyEquivalent: "")
        add(appMenu, "检查更新…", #selector(checkForUpdates))
        add(appMenu, "设置…", #selector(showSettings), key: ",")
        add(appMenu, "渔获", #selector(showCollection), key: "y")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.submenu = appMenu
        main.addItem(item)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = TextEditingMenu.menu
        main.addItem(editItem)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("AI 干活时我们干什么")
        quickMenu.delegate = self
        updateStatusIcon()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel.close()
            // Attach the menu only for this click so the status item keeps its own placement.
            statusItem.menu = quickMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle(from: button)
        }
    }

    /// Right-click menu: every switch without opening the panel.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: state.status, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let desktop = add(menu, state.desktopEnabled ? "回去工作 · " + state.shortcutLabel : "开始玩 · " + state.shortcutLabel, #selector(toggleDesktop))
        desktop.state = state.desktopEnabled ? .on : .off
        menu.addItem(.separator())
        for mode in PlayMode.allCases {
            let item = add(menu, mode.title + " · " + state.shortCount(for: mode), #selector(selectMode(_:)))
            item.representedObject = mode.rawValue
            item.state = state.mode == mode ? .on : .off
        }
        add(menu, "切换到下一个", #selector(nextMode))
        add(menu, state.mode == .fishing ? "收竿重来" : "重新铺满", #selector(reset)).isEnabled = state.mode != .woodfish && state.desktopEnabled
        menu.addItem(.separator())
        add(menu, "跟随 AI 工作", #selector(toggleFollowAI)).state = state.followAI ? .on : .off
        add(menu, "声音", #selector(toggleSound)).state = state.soundEnabled ? .on : .off
        add(menu, "桌面小猫", #selector(toggleDesktopPet)).state = state.desktopPetEnabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "渔获…", #selector(showCollection))
        add(menu, "设置…", #selector(showSettings))
        add(menu, "检查更新…", #selector(checkForUpdates))
        add(menu, "退出", #selector(quit), key: "q")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return state.canCheckForUpdates }
        return true
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func updateStatusIcon() {
        let filled = state.desktopEnabled && state.interactionEnabled
        let working = state.desktopEnabled && state.followAI && state.detectedWorking
        let tip = state.desktopEnabled
            ? (state.interactionEnabled ? "正在玩 · " : "桌面效果已开启 · ") + state.shortcutLabel + " 收起"
            : "AI 干活时我们干什么 · " + state.shortcutLabel + " 开始玩"
        // Drawn again only when it changes, not for every state change.
        if let key = statusIconKey, key == (filled, working, tip), statusItem?.button?.image != nil { return }
        statusIconKey = (filled, working, tip)
        statusItem?.button?.image = StatusIcon.image(filled: filled, working: working)
        statusItem?.button?.toolTip = tip
    }

    @objc func showPanel() {
        guard let button = statusItem?.button else { return }
        panel.show(from: button)
    }
    @objc private func showSettings() { panel.close(); windows.showSettings() }
    @objc private func checkForUpdates() { panel.close(); state.checkForUpdates() }
    @objc private func showCollection() { panel.close(); windows.showCollection() }
    @objc private func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func toggleDesktop() { state.desktopEnabled.toggle() }
    @objc private func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PlayMode(rawValue: raw) { state.mode = mode }
    }
    @objc private func reset() { state.reset() }
    @objc private func toggleFollowAI() { state.followAI.toggle() }
    @objc private func nextMode() { state.nextMode() }
    @objc private func toggleSound() { state.soundEnabled.toggle() }
    @objc private func toggleDesktopPet() { state.desktopPetEnabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AI 干活时我们干什么",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.15.0",
            .credits: NSAttributedString(string: "擦污渍、捏气泡、敲木鱼、钓鱼。\n菜单栏里还住着一只猫。")
        ])
    }
    func applicationWillTerminate(_ notification: Notification) { agentHub?.stop(); PlayAudio.shared.stopAll() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPanel() }
        return true
    }
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
