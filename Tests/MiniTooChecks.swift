import AppKit
import ImageIO
import UniformTypeIdentifiers
import WhileCore

@main enum MiniTooChecks {
    static func main() throws {
        _ = NSApplication.shared
        // Hand-calculated length/checksum vector (the public notes' announce checksum has a typo).
        let announce = Data([1, 8, 0, 0x8b, 0, 0xa1, 0x2e, 0, 0, 0x62, 1, 2])
        precondition(MiniTooProtocol.upload(Data(repeating: 0, count: 11937))[0] == announce)
        let request = Data([1, 7, 0, 4, 0x8b, 0x55, 0, 1, 0xec, 0, 2])
        let ack = Data([1, 9, 0, 4, 0xbd, 0x55, 0x13, 1, 5, 0, 0x38, 1, 2])
        precondition(MiniTooProtocol.packet(4, Data([0x8b, 0x55, 0, 1])) == request)
        var decoder = MiniTooProtocol.Decoder()
        var decoded: [Data] = []
        // Bluetooth may split a frame at any byte, including header/checksum.
        for byte in Data([0, 255, 2]) + request + ack { decoded += decoder.append(Data([byte])) }
        precondition(decoded == [Data([4, 0x8b, 0x55, 0, 1]), Data([4, 0xbd, 0x55, 0x13, 1, 5, 0])])
        var corrupt = request; corrupt[8] = 0
        precondition(decoder.append(corrupt + request) == [Data([4, 0x8b, 0x55, 0, 1])])
        let fish = MiniTooArtwork.loadFish(["carp", "koi", "moonfish"], root: URL(fileURLWithPath: "Sources/WhileAIWorks/Resources/FishAssets"))
        precondition(fish.map(\.id) == ["carp", "koi", "moonfish"], "shared fish assets must retain species identity")
        let payload = try MiniTooArtwork.payload(fish: fish)
        precondition(payload.prefix(6) == Data([0x23, 48, 0, 200, 8, 10]))
        var offset = 6
        var frames: [CGImage] = []
        for _ in 0..<48 {
            precondition(payload[offset] == 1)
            let length = payload[(offset+1)..<(offset+5)].reduce(0) { ($0 << 8) | Int($1) }
            let jpeg = payload.subdata(in: (offset+5)..<(offset+5+length))
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(image.width == 160 && image.height == 128)
            frames.append(image); offset += 5 + length
        }
        precondition(offset == payload.count)
        let packets = MiniTooProtocol.upload(payload)
        var wire = MiniTooProtocol.Decoder()
        var reconstructed = Data()
        for (index, packet) in packets.dropFirst().enumerated() {
            let frame = wire.append(packet)[0]
            precondition(frame[0] == 0x8b && frame[1] == 1)
            precondition(Int(frame[6]) + (Int(frame[7]) << 8) == index)
            let chunk = frame.dropFirst(8)
            precondition(chunk.count == 256 || index == packets.count - 2)
            reconstructed.append(contentsOf: chunk)
        }
        precondition(reconstructed == payload)
        let directory = URL(fileURLWithPath: "docs/minitoo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("aquarium.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in frames {
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        let png = CGImageDestinationCreateWithURL(directory.appendingPathComponent("aquarium.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png, frames[0], nil); precondition(CGImageDestinationFinalize(png))
        var tracker = CodexDisplayTracker()
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        for i in 1...4 {
            let line = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": format.string(from: now.addingTimeInterval(-70)), "payload": ["type": i == 3 ? "task_complete" : "task_started", "turn_id": "turn"]])
            tracker.consume(line: line, sessionID: "test-\(i)")
        }
        let quota = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": format.string(from: now), "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 90, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 3600]]]])
        tracker.consume(line: quota, sessionID: "test-1")
        let snapshot = tracker.snapshot(now: now)
        let firstPage = MiniTooArtwork.dashboardPage(snapshot, page: 0, now: now)
        precondition(firstPage.lines.contains("周额度剩余 10%"))
        precondition(MiniTooArtwork.dashboardPage(snapshot, page: 1, now: now).lines.contains { $0.contains("本轮完成") })
        let stalePage = MiniTooArtwork.dashboardPage(snapshot, page: 0, now: now.addingTimeInterval(3601))
        precondition(stalePage.lines.contains("周额度 待更新"))
        let statusImage = MiniTooArtwork.dashboard(firstPage)
        let statusPNG = CGImageDestinationCreateWithURL(directory.appendingPathComponent("codex-example.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(statusPNG, statusImage, nil); precondition(CGImageDestinationFinalize(statusPNG))
        let statusPayload = MiniTooProtocol.animation(jpegs: [try MiniTooArtwork.jpeg(statusImage)], milliseconds: 1000)
        precondition(statusPayload[1] == 1 && statusPayload.count < payload.count / 4)
        for state in MiniTooCompanionArtwork.State.allCases {
            let animation = try MiniTooCompanionArtwork.payload(state)
            precondition(animation.prefix(6) == Data([0x23, 16, 0, 120, 8, 10]))
            var cursor = 6
            var distinct = Set<Data>()
            for _ in 0..<16 {
                precondition(animation[cursor] == 1)
                let length = animation[(cursor+1)..<(cursor+5)].reduce(0) { ($0 << 8) | Int($1) }
                let jpeg = animation.subdata(in: (cursor+5)..<(cursor+5+length))
                let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                precondition(image.width == 160 && image.height == 128)
                distinct.insert(jpeg); cursor += 5 + length
            }
            precondition(cursor == animation.count && distinct.count > 8, "character must contain real motion")
            precondition(animation.count < 65_536, "keep state animations small enough for Bluetooth")
            let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("work-\(state.rawValue).gif") as CFURL, UTType.gif.identifier as CFString, 16, nil)!
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for image in MiniTooCompanionArtwork.frames[state]! {
                CGImageDestinationAddImage(output, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(output))
            print("Work character \(state.rawValue): \(animation.count) bytes / 16 frames")
        }
        let suite = "WhileAIWorks.MiniTooChecks.\(UUID().uuidString)"
        let chatPayload = try MiniTooCompanionArtwork.chatPayload()
        precondition(chatPayload[1] == 1 && chatPayload.count < 5_000,
                     "chat uploads only one small frame instead of a state animation")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MiniTooAquarium(defaults: defaults)
        precondition(controller.responds(to: NSSelectorFromString("rfcommChannelWriteComplete:refcon:status:")))
        precondition(controller.responds(to: NSSelectorFromString("rfcommChannelWriteComplete:refcon:status:bytesWritten:")))
        precondition(!controller.enabled && controller.phase == .idle && !controller.busy)
        controller.setMode(.codex); controller.updateCodex(snapshot)
        controller.changePage(1); precondition(controller.page == 1 && controller.pageCount == 2)
        controller.changePage(50); precondition(controller.page == 1)
        precondition(MiniTooAquarium(defaults: defaults).mode == .codex, "manual selection persists")
        controller.setMode(.work); controller.setCompanionPreview(.speaking)
        controller.updateCodex(snapshot)
        precondition(controller.mode == .work && controller.companionPreviewState == .speaking)
        precondition(controller.contentDetail.contains("预览") && controller.contentDetail.contains("不会收音"))
        controller.setAgentActivity(.thinking, detail: "测试任务处理中")
        precondition(controller.contentDetail.contains("测试任务处理中") && controller.companionPreviewState == .thinking)
        controller.setCompanionPreview(.thinking)
        precondition(controller.agentActivityDetail == nil, "switching back to preview clears real agent activity")
        precondition(MiniTooAquarium(defaults: defaults).mode == .work)
        precondition(!controller.enabled && controller.phase == .idle, "preview must not enable Bluetooth")
        controller.setMode(.chat)
        let fixedPreview = controller.preview
        for state in MiniTooCompanionArtwork.State.allCases {
            controller.setAgentActivity(state, detail: "fixture status")
            controller.setCompanionPreview(state)
            precondition(controller.preview === fixedPreview, "chat state changes must retain the fixed frame")
            precondition(controller.contentDetail.contains("固定画面"))
        }
        controller.setRealtimeActive(true)
        controller.setEnabled(true)
        controller.retry()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(!controller.canRetry && controller.phase == .idle,
                     "realtime audio blocks even explicit display retries")
        controller.setEnabled(false)
        controller.setRealtimeActive(false)
        controller.setMode(.aquarium); precondition(controller.page == 0)
        // Enabling then immediately cancelling must not connect after rendering finishes.
        controller.setEnabled(true); controller.setEnabled(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(!controller.enabled && controller.phase == .idle)
        precondition(!defaults.bool(forKey: "minitoo.aquarium.enabled"))
        print("MiniTooChecks passed: captured protocol fixtures, fragmented/corrupt RX, 48 JPEG frames, exact chunk reassembly, cancellation; \(payload.count) bytes / \(packets.count) packets.")
        if CommandLine.arguments.contains("--device") {
            controller.setEnabled(true)
            let limit = Date().addingTimeInterval(90)
            var previous = ""
            while Date() < limit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if previous != controller.status { print(controller.status); fflush(stdout); previous = controller.status }
                if controller.phase == .displaying || controller.phase == .failed { break }
            }
            let success = controller.phase == .displaying
            if CommandLine.arguments.contains("--off"), success {
                controller.setEnabled(false)
                let stopLimit = Date().addingTimeInterval(6)
                while controller.busy && Date() < stopLimit { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                print("Off: \(controller.status)")
            }
            controller.shutdown()
            guard success else { exit(1) }
        }
    }
}
