import AppKit
import SwiftUI
import RiveRuntime

/// Drives one Rive cat (`Resources/Rive/mascot.riv`, authored in `design/mascot`).
/// Each controller owns its own runtime instance, so the menu bar panel and the
/// settings preview animate independently.
final class MascotController: ObservableObject {
    let riveViewModel: RiveViewModel?
    /// Shown instead of the live cat when the Rive file cannot load (and in offscreen renders).
    let placeholder: NSImage?
    private var instance: RiveDataBindingViewModel.Instance?
    private var mood: MascotMood = .idle
    private var coat: MascotCoat = .ink
    private var look = CGPoint.zero
    var attention: CGPoint?
    private var active = true

    static var resources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    /// Pass a nil bundle to show only the placeholder still.
    init(bundle: Bundle? = MascotController.resources, placeholder: NSImage? = nil) {
        self.placeholder = placeholder
        guard let bundle, let url = bundle.url(forResource: "mascot", withExtension: "riv", subdirectory: "Rive"),
              let data = try? Data(contentsOf: url),
              let file = try? RiveFile(data: data, loadCdn: false) else {
            riveViewModel = nil
            return
        }
        let model = RiveModel(riveFile: file)
        riveViewModel = RiveViewModel(model, stateMachineName: nil, fit: .contain, alignment: .center,
                                      autoPlay: true, artboardName: "Cat")
        model.enableAutoBind { [weak self] instance in
            self?.instance = instance
            self?.applyAll()
        }
    }

    var isAvailable: Bool { riveViewModel != nil }

    func set(mood: MascotMood, coat: MascotCoat) {
        if mood != self.mood {
            self.mood = mood
            instance?.enumProperty(fromPath: "mood")?.value = mood.rawValue
        }
        if coat != self.coat {
            self.coat = coat
            instance?.enumProperty(fromPath: "coat")?.value = coat.rawValue
        }
    }

    /// Where the cat should look, each axis from -1 to 1 (y grows downward).
    func look(x: Double, y: Double) {
        let next = attention ?? CGPoint(x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100)
        guard next != look else { return }
        look = next
        instance?.numberProperty(fromPath: "lookX")?.value = Float(next.x)
        instance?.numberProperty(fromPath: "lookY")?.value = Float(next.y)
    }

    func celebrate() {
        guard active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        instance?.triggerProperty(fromPath: "celebrate")?.trigger()
    }

    func pet() { instance?.triggerProperty(fromPath: "pet")?.trigger() }

    /// Stop rendering while nothing on screen shows the cat.
    func setActive(_ active: Bool) {
        guard active != self.active, let riveViewModel else { return }
        self.active = active
        if active { riveViewModel.play() } else { riveViewModel.pause() }
    }

    private func applyAll() {
        instance?.enumProperty(fromPath: "mood")?.value = mood.rawValue
        instance?.enumProperty(fromPath: "coat")?.value = coat.rawValue
        instance?.numberProperty(fromPath: "lookX")?.value = Float(look.x)
        instance?.numberProperty(fromPath: "lookY")?.value = Float(look.y)
    }
}

/// Hosts the Rive view, follows the pointer while visible and pauses when hidden.
final class MascotHostView: NSView {
    let controller: MascotController
    private var timer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    init(controller: MascotController) {
        self.controller = controller
        super.init(frame: .zero)
        // Transparent hosts can otherwise expose a dirty rect extending into sibling
        // views on macOS 14+. Keep the Metal viewport local to the cat's bounds.
        clipsToBounds = true
        if let riveView = controller.riveViewModel?.createRiveView() {
            riveView.clipsToBounds = true
            riveView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(riveView)
            NSLayoutConstraint.activate([
                riveView.leadingAnchor.constraint(equalTo: leadingAnchor),
                riveView.trailingAnchor.constraint(equalTo: trailingAnchor),
                riveView.topAnchor.constraint(equalTo: topAnchor),
                riveView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("小猫")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            controller.setActive(false)
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            self?.refreshActivity()
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.followPointer() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshActivity()
    }

    private var visible: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private func refreshActivity() { controller.setActive(visible) }

    private func followPointer() {
        guard visible, let window, bounds.width > 0 else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        // The artboard's eyes sit near the horizontal centre, a little above the middle.
        let eyes = CGPoint(x: bounds.midX, y: isFlipped ? bounds.height * 0.47 : bounds.height * 0.53)
        let dx = Double((point.x - eyes.x) / max(120, bounds.width * 1.2))
        let dy = Double((point.y - eyes.y) / max(110, bounds.height * 1.1))
        controller.look(x: Foundation.tanh(dx * 1.6), y: Foundation.tanh((isFlipped ? dy : -dy) * 1.6))
    }
}

struct MascotView: NSViewRepresentable {
    let controller: MascotController

    func makeNSView(context: Context) -> NSView {
        guard controller.isAvailable else {
            if let placeholder = controller.placeholder {
                let still = NSImageView(image: placeholder)
                still.imageScaling = .scaleProportionallyUpOrDown
                still.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                still.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                return still
            }
            let fallback = NSImageView(image: NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "小猫") ?? NSImage())
            fallback.symbolConfiguration = .init(pointSize: 44, weight: .regular)
            fallback.contentTintColor = .secondaryLabelColor
            fallback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fallback.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return fallback
        }
        return MascotHostView(controller: controller)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
