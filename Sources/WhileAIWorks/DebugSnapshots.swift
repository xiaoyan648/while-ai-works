import AppKit
import CoreGraphics

/// `WhileAIWorks --snapshot <directory>` captures the menu bar panel and both windows
/// in light and dark appearance, then quits. For design review; the app only
/// captures its own windows and does not change any saved state.
enum DebugSnapshots {
    static var directory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    struct Step {
        let delay: TimeInterval
        let action: () -> Void
    }

    static func run(_ steps: [Step]) {
        guard let first = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + first.delay) {
            first.action()
            run(Array(steps.dropFirst()))
        }
    }

    static func capture(_ window: NSWindow?, as name: String) {
        guard let window, let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let image = (OwnWindowImage() as WindowImaging).image(of: CGWindowID(window.windowNumber)) else {
            print("snapshot: could not capture \(name)")
            return
        }
        let url = directory.appendingPathComponent(name + ".png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }

    static func appearance(_ dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// Capturing the app's own windows needs no screen recording permission, which
/// ScreenCaptureKit would. Called through a protocol to keep the build warning-free.
private protocol WindowImaging { func image(of window: CGWindowID) -> CGImage? }
private struct OwnWindowImage: WindowImaging {
    @available(macOS, deprecated: 14.0)
    func image(of window: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .bestResolution])
    }
}
