import AppKit
import SwiftUI
import SceneKit
import WhileCore

/// Renders the real SwiftUI settings into a local bitmap, without system input.
@main enum NativeFishingGuideChecks {
    static func main() throws {
        _ = NSApplication.shared
        let fish = CatchSpecies.catalog.filter(\.isFish)
        precondition(fish.allSatisfy { FishingSprites.catalog[$0.id] != nil }, "All fish PNGs must load from bundled resources")
        precondition(FishingSprites.catalog["computer"] != nil, "CRT collectible uses the prepared PNG artwork")
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 960,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        for (index, species) in fish.enumerated() {
            let sprite = FishingSprites.catalog[species.id]!
            precondition(sprite.image.size == sprite.silhouette.size)
            let mask = NSBitmapImageRep(cgImage: sprite.silhouette.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            var visiblePixels = 0
            for y in stride(from: 0, to: mask.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: mask.pixelsWide, by: 8) {
                    let color = mask.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.01 {
                        visiblePixels += 1
                        precondition(abs(color.redComponent - color.greenComponent) < 0.025 && abs(color.greenComponent - color.blueComponent) < 0.025, "Locked fish must hide colored markings")
                        precondition(color.alphaComponent < 0.32)
                    }
                }
            }
            precondition(visiblePixels > 0)
            let x = CGFloat(index % 4) * 250, y = CGFloat(3 - index / 4) * 240
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSRect(x: x, y: y + 120, width: 250, height: 120).fill()
            NSColor(srgbRed: 0.06, green: 0.17, blue: 0.21, alpha: 1).setFill()
            NSRect(x: x, y: y, width: 250, height: 120).fill()
            for offset: CGFloat in [0, 120] {
                FishingArtwork.specimen(species, in: NSRect(x: x + 10, y: y + offset + 10, width: 152, height: 92))
                FishingArtwork.specimen(species, in: NSRect(x: x + 178, y: y + offset + 50, width: 63, height: 53), discovered: false)
                FishingArtwork.text(species.name, x: x + 175, y: y + offset + 20, size: 11,
                                    color: offset == 0 ? .white : .black)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/fishing-sprites.png"))
        print("NativeFishingGuideChecks: 15 bundled sprites loaded; silhouettes hide color and retain alpha; light/dark render sheet saved.")
        let suite = "WhileAIWorks.GuideChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = FishingBook()
        for (index, species) in CatchSpecies.catalog.enumerated() where index < 6 || !species.isFish {
            book.record(.init(species: species, sizeCM: species.minCM + (species.maxCM - species.minCM) * 0.6))
        }
        let tank = Aquarium3DScene()
        precondition(tank.assetError == nil, "Blender scenery must load")
        let ids = fish.prefix(6).map(\.id)
        tank.sync(ids: ids, book: book)
        precondition(tank.assetError == nil && tank.displayedLengths.count == 6)
        let start = tank.node(for: ids[0])!.position
        tank.advance(0)
        for frame in 1...450 { tank.advance(Double(frame) / 30) }
        precondition(!SCNVector3EqualToVector3(tank.node(for: ids[0])!.position, start), "3D fish must swim")
        for id in ids {
            let agent = tank.navigation!.agents[id]!
            precondition(tank.navigation!.balls(for: agent).allSatisfy { tank.navigation!.field.isFree($0.center, radius: $0.radius) }, "Animated fish envelope stays inside the glass and outside scenery")
            precondition(tank.fishID(for: tank.node(for: id)!.childNodes.first!) == id, "mesh hits resolve to collection IDs")
        }
        tank.reduceMotion = true
        let still = tank.node(for: ids[0])!.position
        tank.advance(16)
        precondition(SCNVector3EqualToVector3(tank.node(for: ids[0])!.position, still), "reduced motion stops swimming")
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = tank.scene; renderer.pointOfView = tank.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 900), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let bitmap3D = NSBitmapImageRep(data: tiff), let png = bitmap3D.representation(using: .png, properties: [:]) else { fatalError("3D snapshot failed") }
        try png.write(to: URL(fileURLWithPath: ".build/aquarium-3d-preview.png"))
        if CommandLine.arguments.contains("--aquarium-movie") {
            let directory = URL(fileURLWithPath: ".build/aquarium-frames")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            tank.reduceMotion = false
            let renderStart = CACurrentMediaTime()
            for frame in 0..<144 {
                tank.advance(17 + Double(frame) / 24)
                let image = renderer.snapshot(atTime: Double(frame) / 24, with: CGSize(width: 720, height: 540), antialiasingMode: .multisampling4X)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "%04d.png", frame)))
            }
            print("3D offline capture: 144 frames at 720 × 540 in \(String(format: "%.2f", CACurrentMediaTime() - renderStart)) s (includes PNG encoding, not a live FPS benchmark).")
        }
        tank.sync(ids: Array(ids.dropFirst()), book: book)
        precondition(tank.node(for: ids[0]) == nil, "removed residents leave the 3D scene")
        // Exercise all authored fish, including rare species, using test-only records.
        var complete = FishingBook()
        for species in fish { complete.record(.init(species: species, sizeCM: species.maxCM)) }
        for species in fish {
            tank.sync(ids: [species.id], book: complete)
            precondition(tank.assetError == nil && tank.node(for: species.id) != nil)
        }
        print("NativeFishingGuideChecks: 15 native fish loaded, motion/bounds/selection/reduced motion checked; actual 3D render saved.")
        book.save(defaults: defaults)
        let state = AppState(defaults: defaults)
        state.mode = .fishing
        state.followAI = true; state.selectedSources = [.codex]
        state.detectedWorking = true
        state.workIntensity = 0.72
        state.soundEnabled = false
        let view = NSHostingView(rootView: ContentView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 798, height: 688), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 798, height: 688)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("settings bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("settings PNG unavailable") }
        try data.write(to: URL(fileURLWithPath: ".build/fishing-guide.png"))
        precondition(view.bounds.width == 798 && view.bounds.height == 688)
        precondition(state.fishingBook.total == 13 && state.fishingBook.discoveredFish == 6)
        print("NativeFishingGuideChecks: settings and populated catalogue rendered at 798 × 688 using an isolated test store.")
        for section in [FishingGuide.Section.rods, .achievements] {
            let pane = NSHostingView(rootView: FishingGuide(state: state, section: section))
            let paneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 688), styleMask: [.borderless], backing: .buffered, defer: false)
            paneWindow.contentView = pane
            pane.frame = NSRect(x: 0, y: 0, width: 360, height: 688)
            pane.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let capture = pane.bitmapImageRepForCachingDisplay(in: pane.bounds)!
            pane.cacheDisplay(in: pane.bounds, to: capture)
            let name = section == .rods ? "fishing-rods" : "fishing-achievements"
            try capture.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name + ".png"))
        }
        print("NativeFishingGuideChecks: equipment and achievements panes rendered using isolated fixture data.")
        state.mode = .woodfish
        state.followAI = true; state.selectedSources = [.workbuddy]
        state.hookSetupMessage = "已安装，请重启 WorkBuddy；如有 Hooks 审核提示，请在客户端启用。"
        let hookView = NSHostingView(rootView: ContentView(state: state))
        hookView.frame = NSRect(x: 0, y: 0, width: 438, height: 688)
        hookView.layoutSubtreeIfNeeded()
        let hookBitmap = hookView.bitmapImageRepForCachingDisplay(in: hookView.bounds)!
        hookView.cacheDisplay(in: hookView.bounds, to: hookBitmap)
        try hookBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/hook-settings.png"))
        print("NativeFishingGuideChecks: WorkBuddy settings with hook setup result rendered at 438 × 688.")
    }
}
