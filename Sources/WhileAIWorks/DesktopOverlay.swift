import AppKit
import Combine

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopOverlay {
    private let state: AppState
    private var panels: [DesktopPanel] = []
    private var subscription: AnyCancellable?
    private var screensObserver: NSObjectProtocol?
    private var inputTimer: Timer?
    private var wasHeld = false

    init(state: AppState) {
        self.state = state
        subscription = state.$desktopEnabled.combineLatest(state.$targetScreenID).removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.sink { [weak self] enabled,_ in
            DispatchQueue.main.async { self?.setEnabled(enabled) }
        }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, self.state.desktopEnabled else { return }
            self.setEnabled(true)
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updateInput() }
        RunLoop.main.add(timer, forMode: .common)
        inputTimer = timer
    }
    deinit {
        inputTimer?.invalidate()
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
    }
    private func updateInput() {
        guard !panels.isEmpty else { return }
        let held = state.interactionEnabled
        let changed = held != wasHeld
        wasHeld = held
        if changed { state.interactionHeld = held }
        if changed && !held { PlayAudio.shared.endWipe() }
        for panel in panels {
            guard let view = panel.contentView as? PlayView else { continue }
            let local = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let accepts = held && (state.mode != .fishing || view.fishingContains(local) || state.fishing.pressed || state.castStartedAt != nil)
            if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
            if changed { view.setInteractionEnabled(held) }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        PlayAudio.shared.stopAll()
        for panel in panels {
            (panel.contentView as? PlayView)?.cancelInteraction()
            panel.orderOut(nil); panel.close()
        }
        panels.removeAll()
        state.interactionHeld = false
        wasHeld = false
        guard enabled else { return }
        for screen in [state.targetScreen].compactMap({$0}) {
            let panel = DesktopPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.contentView = PlayView(state: state)
            panel.setFrame(screen.visibleFrame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        updateInput()
    }
}
