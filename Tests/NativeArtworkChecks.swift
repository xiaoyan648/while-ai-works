import AppKit
import ImageIO

@main enum NativeArtworkChecks {
    static func main() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        func render(finger: Bool, pressure: CGFloat, flipped: Bool = false) -> Data {
            let context = CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 1280,
                                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let anchor = CGPoint(x: 160, y: 160)
            if finger { InteractionArtwork.finger(at: anchor, pressure: pressure, rebound: 0, flipped: flipped, mirrored: false, context: context) }
            else { InteractionArtwork.cloth(at: anchor, pressure: pressure, angle: 0, context: context) }
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            precondition(bytes[(320 - 1 - 160) * 1280 + 160 * 4 + 3] > 230, "tool must cover its actual contact hotspot")
            return Data(bytes: bytes, count: 320 * 1280)
        }
        let clothUp = render(finger: false, pressure: 0)
        let clothDown = render(finger: false, pressure: 1)
        let fingerUp = render(finger: true, pressure: 0)
        let fingerDown = render(finger: true, pressure: 1)
        precondition(clothUp != clothDown && fingerUp != fingerDown, "pressing must change the tool's rendered shape")
        precondition(render(finger: true, pressure: 1, flipped: true) != fingerDown, "edge orientation must keep a visible, differently oriented hand")

        let context = CGContext(data: nil, width: 1200, height: 760, bitsPerComponent: 8, bytesPerRow: 4800,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(NSColor(srgbRed: 0.956, green: 0.95, blue: 0.93, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 380))
        InteractionArtwork.cloth(at: CGPoint(x: 150, y: 278), pressure: 0, angle: -0.12, context: context)
        InteractionArtwork.cloth(at: CGPoint(x: 450, y: 278), pressure: 1, angle: 0.14, context: context)
        InteractionArtwork.finger(at: CGPoint(x: 135, y: 139), pressure: 0, rebound: 0, flipped: false, mirrored: false, context: context)
        InteractionArtwork.finger(at: CGPoint(x: 435, y: 139), pressure: 1, rebound: 0, flipped: false, mirrored: false, context: context)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.darkGray]
        for (text, x, y): (String, CGFloat, CGFloat) in [("帕子 · 悬停", 115, 335), ("帕子 · 擦动", 415, 335), ("手指 · 悬停", 115, 185), ("手指 · 按压", 415, 185)] {
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let destinationURL = URL(fileURLWithPath: ".build/interaction-tools.png")
        let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "artwork preview must export")
        print("NativeArtworkChecks: contact hotspots, pressure rendering, edge orientation and preview export passed.")
    }
}
