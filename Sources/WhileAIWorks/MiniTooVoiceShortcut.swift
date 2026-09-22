import AppKit
import SwiftUI
import Carbon
import Combine

@MainActor final class MiniTooVoiceShortcut: ObservableObject {
    static let shared = MiniTooVoiceShortcut()
    static let labels = ["⌃ ⌥ 空格", "⌘ ⌥ 空格", "⌃ ⇧ 空格"]
    @Published var selection: Int { didSet { UserDefaults.standard.set(selection, forKey: "minitoo.voice.shortcut"); register() } }
    @Published private(set) var error: String?
    private var enabled = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var held = false
    private var panel: NSPanel?
    private var hide: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    var label: String { Self.labels[min(2, max(0, selection))] }
    init() { selection = min(2, max(0, UserDefaults.standard.integer(forKey: "minitoo.voice.shortcut"))) }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }; enabled = value; register()
        if !value { hide?.cancel(); panel?.orderOut(nil) }
    }
    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil; held = false; error = nil
        guard enabled else { return }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.enabled, event.keyCode == UInt16(kVK_Space) else { return false }
                    if event.type == .keyUp { self.held = false; return false }
                    let choices: [NSEvent.ModifierFlags] = [[.control, .option], [.command, .option], [.control, .shift]]
                    guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == choices[min(2, max(0, self.selection))] else { return false }
                    if !event.isARepeat { self.keyEvent(pressed: true) }
                    return true
                }
                return consumed ? nil : event
            }
        }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == 0x4D545643 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<MiniTooVoiceShortcut>.fromOpaque(context).takeUnretainedValue()
                let pressed = GetEventKind(event) == kEventHotKeyPressed
                MainActor.assumeIsolated { owner.keyEvent(pressed: pressed) }
                return noErr
            }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let flags = [UInt32(controlKey | optionKey), UInt32(cmdKey | optionKey), UInt32(controlKey | shiftKey)][min(2, max(0, selection))]
        if RegisterEventHotKey(UInt32(kVK_Space), flags, EventHotKeyID(signature: 0x4D545643, id: 1), GetApplicationEventTarget(), 0, &hotKey) != noErr {
            error = "快捷键已被占用，请换一个组合。"
        }
    }
    func keyEvent(pressed: Bool) {
        if !pressed { held = false; return }
        guard enabled, !held else { return }; held = true
        showHUD()
        let voice = MiniTooVoice.shared
        if voice.phase == .recording { voice.finishRecording() }
        else if voice.busy || MiniTooAgent.shared.running { voice.cancel() }
        else { voice.startRecording() }
        scheduleHide()
    }
    private func showHUD() {
        hide?.cancel()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 112), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.level = .floating
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: MiniTooVoiceHUD())
            self.panel = panel
            MiniTooVoice.shared.$phase.combineLatest(MiniTooAgent.shared.$running).sink { [weak self] _, _ in
                Task { @MainActor in self?.scheduleHide() }
            }.store(in: &observers)
        }
        if let frame = NSScreen.main?.visibleFrame { panel?.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 374, y: frame.maxY - 24)) }
        panel?.orderFrontRegardless()
    }
    private func scheduleHide() {
        hide?.cancel()
        guard !MiniTooVoice.shared.busy, !MiniTooAgent.shared.running else { return }
        hide = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            self?.panel?.orderOut(nil)
        }
    }
}

@MainActor private struct MiniTooVoiceHUD: View {
    @ObservedObject private var voice = MiniTooVoice.shared
    @ObservedObject private var agent = MiniTooAgent.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("MiniToo · 工作语音").font(.headline); Spacer()
                if voice.phase == .recording { Button("发送") { voice.finishRecording() } }
                if voice.busy || agent.running { Button("停止") { voice.cancel() } }
            }
            Text(agent.running ? agent.status : voice.status).font(.system(size: 11)).lineLimit(2)
            if voice.phase == .recording { ProgressView(value: Double(voice.level)) }
        }.padding(16).frame(width: 350, height: 112).preferredColorScheme(.light)
    }
}
