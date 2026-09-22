import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreText
import WhileCore

/// Frames are encoded on the Mac, then played locally by MiniToo.
enum MiniTooArtwork {
    static let frameCount = 48
    static let milliseconds = 200

    struct Fish {
        let id: String
        let image: CGImage
    }
    static func loadFish(_ ids: [String], root: URL? = Bundle.main.resourceURL?.appendingPathComponent("FishAssets")) -> [Fish] {
        ids.prefix(6).compactMap { id in
            guard let root, let source = CGImageSourceCreateWithURL(root.appendingPathComponent(id + ".png") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = c.data else { return nil }
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var left = image.width, bottom = image.height, right = -1, top = -1
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[y * c.bytesPerRow + x * 4 + 3] > 16 {
                    left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
                }
            }
            guard right >= left, top >= bottom,
                  let cropped = c.makeImage()?.cropping(to: CGRect(x: left, y: bottom, width: right-left+1, height: top-bottom+1)) else { return nil }
            return Fish(id: id, image: cropped)
        }
    }

    static func frame(_ index: Int, fish residents: [Fish] = []) -> CGImage {
        let c = CGContext(data: nil, width: 160, height: 128, bitsPerComponent: 8,
                          bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setShouldAntialias(false)
        let t = Double(index % frameCount) / Double(frameCount) * 2 * Double.pi
        func color(_ hex: Int) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: Int) {
            c.setFillColor(color(hex)); c.fill(CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h))
        }
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: Int) {
            c.setFillColor(color(hex)); c.fillEllipse(in: CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h))
        }
        // Deep teal water, quiet light bands, sandy floor.
        rect(0, 0, 160, 128, 0x103b49)
        rect(0, 72, 160, 56, 0x154b59)
        rect(0, 109, 160, 19, 0x1b5a65)
        for i in 0..<7 {
            rect(Double(i * 27 - 14) + sin(t + Double(i)) * 3, 117, 17, 1, 0x327783)
        }
        rect(0, 0, 160, 12, 0xbaa37b)
        rect(0, 10, 160, 3, 0xd4bf94)
        for i in 0..<30 { rect(Double((i * 37) % 160), Double((i * 7) % 10), 2, 1, 0x8e8766) }
        // Branching plants leave the center clear.
        for (base, height) in [(9, 47), (21, 33), (143, 42), (153, 57)] {
            for y in stride(from: 12, through: height, by: 3) {
                let x = Double(base) + sin(t + Double(y) / 15) * Double(y - 10) / 16
                rect(x, Double(y), 2, 4, 0x458879)
                if y % 2 == 0 { oval(x - 5, Double(y), 6, 3, 0x63a48a) }
                else { oval(x + 1, Double(y), 6, 3, 0x367967) }
            }
        }
        oval(28, 11, 16, 7, 0x788b85); oval(32, 15, 8, 3, 0x9fa99a)
        oval(118, 10, 21, 9, 0x688582); oval(121, 16, 10, 3, 0x94a699)
        // The exact species selected in the desktop aquarium, using the shared art.
        for (i, fish) in residents.enumerated() {
            let phase = Double(i) * 2.1
            let x = 80 + sin(t + phase) * (i % 2 == 0 ? 24 : 19)
            let y = residents.count <= 3 ? 37 + Double(i) * 29 : 29 + Double(i) * 15
            let maximumWidth = residents.count <= 3 ? 43.0 : 33.0
            let scale = min(maximumWidth / Double(fish.image.width), 23 / Double(fish.image.height))
            let width = Double(fish.image.width) * scale
            let height = Double(fish.image.height) * scale
            c.saveGState()
            c.translateBy(x: x.rounded(), y: (y + cos(t + phase) * 3).rounded())
            let turn = 0.45 + 0.55 * min(1, abs(cos(t + phase)) * 3)
            c.scaleBy(x: (cos(t + phase) >= 0 ? -1 : 1) * turn, y: 1)
            c.interpolationQuality = .high
            c.draw(fish.image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            c.restoreGState()
        }
        if residents.isEmpty { text("等待小鱼入住", x: 40, y: 66, size: 12, color: 0xb9d9cf, in: c) }
        for i in 0..<4 {
            let y = (Double(i * 29) + Double(index % frameCount) / Double(frameCount) * 116).truncatingRemainder(dividingBy: 116) + 12
            let x = 128 + sin(t + Double(i)) * 3
            c.setStrokeColor(color(0x68a4ab)); c.setLineWidth(1)
            c.strokeEllipse(in: CGRect(x: x.rounded(), y: y.rounded(), width: 3, height: 3))
        }
        return c.makeImage()!
    }

    static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    struct DashboardPage {
        var lines: [String]
        var colors: [Int]
        var key: String { lines.joined(separator: "|") + colors.map(String.init).joined(separator: ",") }
    }
    static func dashboardPage(_ snapshot: CodexDisplay, page: Int, now: Date = Date()) -> DashboardPage {
        let working = snapshot.sessions.filter { $0.status == .working }.count
        var lines = ["CODEX", "\(working) 个运行中"]
        var colors = [0x8ce4d2, 0xc7d1dd]
        let rows = Array(snapshot.sessions.dropFirst(max(0, page) * 3).prefix(3))
        for i in 0..<3 {
            guard i < rows.count else {
                lines.append(i == 0 ? (snapshot.detail == "等待 Codex 本地会话" ? "暂无近期会话" : snapshot.detail) : "")
                colors.append(0x8899aa); continue
            }
            let row = rows[i]
            var duration = ""
            if let start = row.startedAt, row.status == .working {
                let elapsed = max(0, Int(now.timeIntervalSince(start)) / 10 * 10)
                duration = elapsed >= 3600 ? " \(elapsed / 3600)h\(elapsed % 3600 / 60)m" : String(format: " %02d:%02d", elapsed / 60, elapsed % 60)
            }
            lines.append(String(format: "%02d", row.number) + " " + row.status.rawValue + duration)
            colors.append(row.status == .working ? 0x8ce4d2 : row.status == .completed ? 0xe4edf5 : 0xe8bc7d)
        }
        for i in 0..<2 {
            if i < snapshot.quotas.count {
                let q = snapshot.quotas[i]
                let expired = q.resetsAt.map { $0 <= now } ?? false
                lines.append(expired ? "\(q.label) 待更新" : "\(q.label)剩余 \(q.remaining)%")
                colors.append(expired || q.remaining <= 10 ? 0xe8bc7d : 0xc7d1dd)
            } else { lines.append(i == 0 ? "额度暂不可用" : ""); colors.append(0x8899aa) }
        }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let stamp = snapshot.quotaUpdatedAt.map { formatter.string(from: $0) } ?? "--:--"
        let stale = snapshot.quotaUpdatedAt.map { now.timeIntervalSince($0) >= 300 } ?? true
        lines.append("额度更新 \(stamp)" + (stale ? " · 较早" : "")); colors.append(0x8899aa)
        return DashboardPage(lines: lines, colors: colors)
    }
    static func dashboard(_ page: DashboardPage) -> CGImage {
        let c = CGContext(data: nil, width: 160, height: 128, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0.045, green: 0.075, blue: 0.12, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 160, height: 128))
        let positions: [(CGFloat, CGFloat, CGFloat)] = [(7, 109, 14), (73, 111, 10), (7, 88, 12), (7, 69, 12), (7, 50, 12), (7, 29, 11), (7, 15, 11), (7, 3, 8)]
        for (i, position) in positions.enumerated() {
            text(page.lines[i], x: position.0, y: position.1, size: position.2, color: page.colors[i], in: c)
        }
        return c.makeImage()!
    }
    private static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: Int, in c: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, size, nil)
        let color = CGColor(red: CGFloat((color >> 16) & 255) / 255, green: CGFloat((color >> 8) & 255) / 255,
                            blue: CGFloat(color & 255) / 255, alpha: 1)
        let string = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        c.saveGState(); c.translateBy(x: x, y: y)
        if width > 153 - x { c.scaleBy(x: (153 - x) / width, y: 1) }
        c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
    }
    static func payload(fish: [Fish] = []) throws -> Data {
        MiniTooProtocol.animation(jpegs: try (0..<frameCount).map { try jpeg(frame($0, fish: fish)) }, milliseconds: milliseconds)
    }
}
