import AppKit
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot load icon artwork at \(sourceURL.path)")
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
// Remove only the concept sheet's outer margin. Apply the native tile silhouette
// to keep the desktop outside the icon genuinely transparent.
let margin = CGFloat(artwork.width) * 0.04
let crop = CGRect(x: margin, y: margin, width: CGFloat(artwork.width) - margin * 2,
                  height: CGFloat(artwork.height) - margin * 2)
let tile = artwork.cropping(to: crop)!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
        let shape = CGPath(roundedRect: rect, cornerWidth: 205, cornerHeight: 205, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                          color: CGColor(gray: 0, alpha: 0.16))
        context.addPath(shape); context.setFillColor(CGColor(gray: 0.97, alpha: 1)); context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(shape); context.clip()
        context.interpolationQuality = .high
        context.draw(tile, in: rect)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let output = directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(name)") }
    }
}
