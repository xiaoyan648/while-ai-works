import AppKit
import WhileCore

/// Decoded once, shared by the guide and catch reveal; originals stay untouched.
enum FishingSprites {
    struct Sprite {
        let image: NSImage
        let silhouette: NSImage
    }
    static let catalog: [String: Sprite] = {
        var result: [String: Sprite] = [:]
        for species in CatchSpecies.catalog {
            #if SWIFT_PACKAGE
            let root = Bundle.module.resourceURL
            #else
            let root = Bundle.main.resourceURL
            #endif
            guard let url = root?.appendingPathComponent("FishAssets/\(species.id).png"),
                  let source = NSImage(contentsOf: url),
                  let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let bitmap = CGContext(data: nil, width: cg.width, height: cg.height,
                                         bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = bitmap.data else { continue }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
            for y in 0..<cg.height {
                for x in 0..<cg.width where bytes[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { continue }
            let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            guard let image = bitmap.makeImage()?.cropping(to: crop) else { continue }
            // Source-in retains only the real fish alpha, with no visible markings.
            bitmap.setBlendMode(.sourceIn)
            bitmap.setFillColor(CGColor(gray: 0.48, alpha: 0.3))
            bitmap.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let mask = bitmap.makeImage()?.cropping(to: crop) else { continue }
            result[species.id] = Sprite(image: NSImage(cgImage: image, size: crop.size),
                                       silhouette: NSImage(cgImage: mask, size: crop.size))
        }
        return result
    }()

    static func draw(_ species: CatchSpecies, in rect: CGRect, discovered: Bool) -> Bool {
        guard let sprite = catalog[species.id], rect.width > 0, rect.height > 0 else { return false }
        let image = discovered ? sprite.image : sprite.silhouette
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}
