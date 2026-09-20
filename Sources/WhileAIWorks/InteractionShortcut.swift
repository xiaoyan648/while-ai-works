import AppKit
import Carbon
import Combine

/// A registered system hotkey works even when the overlay cannot become key.
final class InteractionShortcut {
    private let state: AppState
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var subscription: AnyCancellable?
    private var localMonitor: Any?
    private var escapeHotKey: EventHotKeyRef?
    private var chargeSubscription: AnyCancellable?

    init(state: AppState) {
        self.state = state
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<InteractionShortcut>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x57414957 else { return OSStatus(eventNotHandledErr) }
            if id.id == 2 { owner.state.cancelFishingCast() }
            else if id.id == 1 { owner.state.desktopEnabled.toggle() }
            else { return OSStatus(eventNotHandledErr) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Self.handleEscape(event, state: self.state) { return nil }
            let expected: NSEvent.ModifierFlags = self.state.shortcutModifiers == 0 ? [.command, .shift] : self.state.shortcutModifiers == 1 ? [.control, .option] : [.control, .shift]
            let actual = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard Int(event.keyCode) == self.state.shortcutKey, actual == expected else { return event }
            if !event.isARepeat { self.state.desktopEnabled.toggle() }
            return nil
        }
        subscription = state.$shortcutKey.combineLatest(state.$shortcutModifiers).sink { [weak self] key, modifiers in
            self?.register(key: key, modifiers: modifiers)
        }
        // The desktop panel never takes keyboard focus. Reserve plain Escape only
        // for the duration of a charge, then immediately return it to other apps.
        chargeSubscription = state.$castStartedAt.map { $0 != nil }.removeDuplicates().sink { [weak self] charging in
            guard let self else { return }
            if let key = self.escapeHotKey { UnregisterEventHotKey(key); self.escapeHotKey = nil }
            if charging {
                RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x57414957, id: 2),
                                    GetApplicationEventTarget(), 0, &self.escapeHotKey)
            }
        }
    }
    static func handleEscape(_ event: NSEvent, state: AppState) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape),
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty else { return false }
        return state.cancelFishingCast()
    }
    private func register(key: Int, modifiers: Int) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let flags = modifiers == 0 ? UInt32(cmdKey | shiftKey) : modifiers == 1 ? UInt32(controlKey | optionKey) : UInt32(controlKey | shiftKey)
        let result = RegisterEventHotKey(UInt32(key), flags, EventHotKeyID(signature: 0x57414957, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        DispatchQueue.main.async { [weak self] in
            self?.state.shortcutError = result == noErr ? nil : "快捷键被占用，请换一个组合；仍可使用开关。"
        }
    }
    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
    }
}
