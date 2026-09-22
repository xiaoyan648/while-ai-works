import AppKit
import SwiftUI

@main enum MiniTooVoiceViewChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        func render<V: View>(_ root: V, size: CGSize, name: String) throws {
            let view = NSHostingView(rootView: root.background(Color.white).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name + ".png"))
        }
        try render(MiniTooVoiceSettingsView(), size: .init(width: 560, height: 610), name: "minitoo-voice-settings")
        try render(MiniTooAgentView(), size: .init(width: 560, height: 690), name: "minitoo-voice-workbench")
        try render(MiniTooRealtimeView().padding(20).frame(width: 410, height: 420), size: .init(width: 410, height: 420), name: "minitoo-realtime")
        precondition(!MiniTooRealtime.shared.active)
        precondition(!MiniTooVoice.shared.busy && !MiniTooAgent.shared.running)
        print("MiniTooVoiceViewChecks passed: actual SwiftUI settings/workbench rendered offscreen; no recording or network requests")
    }
}
