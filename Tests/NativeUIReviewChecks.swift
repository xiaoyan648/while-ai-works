import AppKit
import SwiftUI
import WhileCore

/// Renders the menu bar panel, settings and collection offscreen, in light and dark,
/// into `.build/ui-review` for design review. Uses an isolated defaults store.
/// The live cat needs Metal, so these renders use stills from `design/mascot/stills.sh`
/// when present and the SF Symbol fallback otherwise.
@main enum NativeUIReviewChecks {
    static let output = URL(fileURLWithPath: ".build/ui-review")
    static let stills = URL(fileURLWithPath: "design/mascot/build/stills")

    static func main() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "WhileAIWorks.UIReview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = FishingBook()
        for (index, species) in CatchSpecies.catalog.enumerated() where (index < 8 && !species.isSecret) || (!species.isFish && index % 2 == 0) {
            let share = index % 3 == 0 ? 0.97 : 0.62
            book.record(.init(species: species, sizeCM: species.minCM + (species.maxCM - species.minCM) * share))
            if index % 2 == 0 { book.record(.init(species: species, sizeCM: species.minCM)) }
        }
        book.save(defaults: defaults)
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        state.selectedSources = [.codex, .qoder]

        let panels: [(String, MascotMood, (AppState) -> Void)] = [
            ("idle", .idle, { $0.desktopEnabled = false; $0.followAI = true; $0.mode = .fishing }),
            ("sleep", .sleep, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = false; $0.mode = .fishing }),
            ("watch", .watch, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = true
                $0.activeSessionCounts = [.codex: 2]; $0.workIntensity = 0.8; $0.mode = .fishing }),
            ("play", .play, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = true
                $0.activeSessionCounts = [.codex: 1]; $0.mode = .woodfish })
        ]
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for (name, mood, configure) in panels {
                configure(state)
                precondition(state.mascotMood == mood, "panel fixture \(name) must put the cat in \(mood)")
                state.mascotCoat = .ink
                let mascot = MascotController(bundle: nil, placeholder: still(state.mascotCoat, mood.rawValue))
                try render(MenuBarView(state: state, mascot: mascot), name: "panel-\(name)-\(theme)", dark: dark,
                           background: NSColor(white: dark ? 0.17 : 0.93, alpha: 1))
            }
            state.desktopEnabled = false
            state.desktopPetEnabled = true
            state.desktopPetShowsStatus = true
            state.activeSessionCounts = [.codex: 2, .qoder: 0]
            state.workSourceDetails = [.qoder: "等待 Qoder 监听状态"]
            state.detectedWorking = true
            try render(DesktopPetView(state: state, mascot: MascotController(bundle: nil, placeholder: still(.ink, "watch"))),
                       name: "desktop-pet-\(theme)", dark: dark, background: .clear)
            state.desktopPetShowsStatus = false
            try render(DesktopPetView(state: state, mascot: MascotController(bundle: nil, placeholder: still(.snow, "sleep"))),
                       name: "desktop-pet-compact-\(theme)", dark: dark, background: .clear)
            state.desktopPetShowsStatus = true
            state.mascotCoat = .snow
            try render(SettingsView(state: state, preview: MascotController(bundle: nil, placeholder: still(state.mascotCoat, "idle"))),
                       name: "settings-\(theme)", dark: dark, size: NSSize(width: 520, height: 1040), background: .windowBackgroundColor)
            for section in [FishingGuide.Section.book, .rods, .achievements] {
                try render(FishingGuide(state: state, section: section), name: "collection-\(section)-\(theme)", dark: dark,
                           size: NSSize(width: 940, height: 700), background: .windowBackgroundColor)
            }
            let koi = CatchSpecies.catalog.first { book.records[$0.id] != nil && $0.isFish }!
            try render(SpeciesDetail(state: state, species: koi), name: "species-detail-\(theme)", dark: dark, background: .windowBackgroundColor)
        }
        try renderStatusIcons()
        print("NativeUIReviewChecks: panel moods, settings, collection pages and menu bar icons rendered to \(output.path) in light and dark.")
    }

    /// Off, playing, and playing while the AI works; on light and dark menu bars at 4x.
    static func renderStatusIcons() throws {
        let variants: [(filled: Bool, working: Bool)] = [(false, false), (true, false), (true, true)]
        let cell = NSSize(width: 44, height: 28), scale: CGFloat = 4
        let size = NSSize(width: cell.width * CGFloat(variants.count), height: cell.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, dark) in [false, true].enumerated() {
            NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: CGFloat(row) * cell.height, width: size.width, height: cell.height).fill()
            for (index, variant) in variants.enumerated() {
                let icon = StatusIcon.image(filled: variant.filled, working: variant.working)
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    (dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: CGFloat(index) * cell.width + 13, y: CGFloat(row) * cell.height + 5, width: 18, height: 18))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("status-icons.png"))
    }

    static func still(_ coat: MascotCoat, _ pose: String) -> NSImage? {
        NSImage(contentsOf: stills.appendingPathComponent("\(coat.rawValue)-\(pose).png"))
    }

    static func render<V: View>(_ view: V, name: String, dark: Bool, size: NSSize? = nil, background: NSColor) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view.background(Color(nsColor: background)))
        host.appearance = appearance
        let bounds = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        window.close()
    }
}
