import AppKit

/// Small original character loops. Rendering is independent of voice providers.
/// A preview state is never treated as an actual microphone or agent event.
enum MiniTooCompanionArtwork {
    static func chatPayload() throws -> Data {
        MiniTooProtocol.animation(jpegs: [try MiniTooArtwork.jpeg(frame(.idle, index: 0))], milliseconds: 1000)
    }
    enum State: String, CaseIterable {
        case idle, listening, thinking, speaking, complete
        var title: String {
            switch self {
            case .idle: return "待机"
            case .listening: return "聆听"
            case .thinking: return "思考"
            case .speaking: return "说话"
            case .complete: return "完成"
            }
        }
    }

    static let frameCount = 16
    static let milliseconds = 120
    // Lazy, immutable cache: Swift initializes once, safely across preview/upload queues.
    static let frames: [State: [CGImage]] = Dictionary(uniqueKeysWithValues:
        State.allCases.map { state in (state, (0..<frameCount).map { render(state, index: $0) }) })

    static func frame(_ state: State, index: Int) -> CGImage {
        frames[state]![(index % frameCount + frameCount) % frameCount]
    }

    static func payload(_ state: State) throws -> Data {
        MiniTooProtocol.animation(jpegs: try frames[state]!.map(MiniTooArtwork.jpeg), milliseconds: milliseconds)
    }

    private static func render(_ state: State, index: Int) -> CGImage {
        let c = CGContext(data: nil, width: 160, height: 128, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setShouldAntialias(true)
        let t = Double(index) / Double(frameCount) * .pi * 2
        let black = CGColor(gray: 0.035, alpha: 1)
        let white = CGColor(gray: 0.985, alpha: 1)
        let mint = CGColor(red: 0.2, green: 0.58, blue: 0.51, alpha: 1)
        c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: 160, height: 128))

        func pill(_ rect: CGRect, color: CGColor) {
            c.setFillColor(color)
            c.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width / 2,
                            cornerHeight: rect.height / 2, transform: nil)); c.fillPath()
        }
        func line(_ points: [CGPoint], color: CGColor, width: CGFloat = 2.5) {
            c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
            c.beginPath(); c.addLines(between: points); c.strokePath()
        }
        let hop = state == .complete ? pow((sin(t - .pi / 2) + 1) / 2, 2) * 15 : 0
        c.setFillColor(CGColor(gray: 0.88, alpha: 1))
        c.fillEllipse(in: CGRect(x: 57 + hop * 0.25, y: 19, width: 46 - hop * 0.5, height: 5))
        c.saveGState()
        let sway = state == .thinking ? sin(t) * 4 : sin(t) * 1.5
        c.translateBy(x: 80 + sway, y: 64 + hop + sin(t) * 2)
        let tilt = state == .listening ? 0.15 + sin(t) * 0.045 : state == .thinking ? sin(t) * 0.13 : sin(t) * 0.025
        c.rotate(by: tilt)
        let bounce = state == .speaking ? sin(t * 2) * 0.045 : sin(t) * 0.025
        c.scaleBy(x: 1 + bounce, y: 1 - bounce)
        c.setFillColor(black); c.fillEllipse(in: CGRect(x: -32, y: -32, width: 64, height: 64))

        if state == .complete {
            for x in [-12.0, 9.0] {
                let p = CGMutablePath(); p.move(to: CGPoint(x: x - 4, y: 4))
                p.addQuadCurve(to: CGPoint(x: x + 4, y: 4), control: CGPoint(x: x, y: 13))
                c.addPath(p); c.setStrokeColor(white); c.setLineWidth(3.5); c.setLineCap(.round); c.strokePath()
            }
        } else {
            let blink = state == .idle && index == 11 ? 0.15 : state == .idle && (index == 10 || index == 12) ? 0.65 : 1.0
            let gazeX = state == .thinking ? sin(t) * 4 : state == .listening ? 3.0 : 0
            let gazeY = state == .thinking ? 5.0 : 0
            for x in [-13.0, 9.0] {
                let height = (state == .listening ? 14.0 : 11.0) * blink
                pill(CGRect(x: x + gazeX, y: 7 + gazeY - height / 2, width: 5.5, height: height), color: white)
            }
        }
        if state == .speaking {
            let mouth = 3 + (sin(t * 3) + 1) * 4
            pill(CGRect(x: -5, y: -11 - mouth / 2, width: 10, height: mouth), color: white)
        }
        c.restoreGState()

        switch state {
        case .idle: break
        case .listening:
            for i in 0..<3 {
                let h = 5 + (sin(t + Double(i) * 1.2) + 1) * 5
                pill(CGRect(x: 124 + Double(i) * 6, y: 62 - h / 2, width: 3, height: h), color: mint)
            }
        case .thinking:
            for i in 0..<3 {
                let r = 1.8 + (sin(t - Double(i) * 1.3) + 1) * 0.9
                c.setFillColor(mint)
                c.fillEllipse(in: CGRect(x: 110 + Double(i) * 10 - r, y: 95 - r, width: r * 2, height: r * 2))
            }
        case .speaking:
            for (x, phase) in [(29.0, 0.0), (127.0, 1.5)] {
                let h = 5 + (sin(t * 2 + phase) + 1) * 6
                pill(CGRect(x: x, y: 60 - h / 2, width: 3, height: h), color: mint)
            }
        case .complete:
            let a = 3 + (sin(t) + 1) * 2
            line([CGPoint(x: 119 - a, y: 95), CGPoint(x: 119 + a, y: 95)], color: mint)
            line([CGPoint(x: 119, y: 95 - a), CGPoint(x: 119, y: 95 + a)], color: mint)
            line([CGPoint(x: 34, y: 91), CGPoint(x: 38, y: 87), CGPoint(x: 45, y: 98)], color: mint)
        }
        return c.makeImage()!
    }
}
