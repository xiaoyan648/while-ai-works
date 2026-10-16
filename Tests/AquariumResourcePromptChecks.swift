import AppKit
import SwiftUI

@main enum AquariumResourcePromptChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let manifest = try JSONDecoder().decode(AquariumPackManifest.self, from: Data(contentsOf:
            URL(fileURLWithPath: "Sources/WhileAIWorks/Resources/AquariumPack.json")))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = AquariumResourceDownload(manifest: manifest, cacheRoot: cache, bundledReady: false)
        let output = URL(fileURLWithPath: ".build/ui-review/aquarium-download")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: AquariumResourcePrompt(resources: resources).padding(24)
                .frame(width: 680, height: 380, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentLayoutRect
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
        }
        precondition(resources.status == .missing && !FileManager.default.fileExists(atPath: cache.path), "rendering the prompt does not download or install resources")
        print("AquariumResourcePromptChecks: light/dark prompts rendered; no download or cache created")
    }
}
