import Foundation

/// MiniToo 2.4.0 Bluetooth Classic framing. See docs/minitoo/README.md.
enum MiniTooProtocol {
    static func little(_ n: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }
    static func big(_ n: Int, bytes: Int) -> Data { Data(little(n, bytes: bytes).reversed()) }
    static func packet(_ command: UInt8, _ body: Data) -> Data {
        precondition(body.count <= 4093)
        var data = Data([1]) + little(body.count + 3, bytes: 2) + Data([command]) + body
        data += little(data.dropFirst().reduce(0) { $0 + Int($1) } & 0xffff, bytes: 2)
        data.append(2)
        return data
    }
    static func animation(jpegs: [Data], milliseconds: Int) -> Data {
        precondition((1...255).contains(jpegs.count) && (1...65535).contains(milliseconds))
        // Dimensions are 16-pixel cells: 10 columns × 8 rows = 160 × 128.
        var result = Data([0x23, UInt8(jpegs.count)]) + big(milliseconds, bytes: 2) + Data([8, 10])
        for jpeg in jpegs { result += Data([1]) + big(jpeg.count, bytes: 4) + jpeg }
        return result
    }
    static func upload(_ payload: Data) -> [Data] {
        precondition(!payload.isEmpty && payload.count <= 256 * 65535)
        let size = little(payload.count, bytes: 4)
        var packets = [packet(0x8b, Data([0]) + size)]
        for offset in stride(from: 0, to: payload.count, by: 256) {
            packets.append(packet(0x8b, Data([1]) + size + little(offset / 256, bytes: 2)
                + payload.subdata(in: offset..<min(offset + 256, payload.count))))
        }
        return packets
    }
    static func screen(_ on: Bool) -> Data { packet(0xbd, Data([0x2f, on ? 1 : 0])) }

    struct Decoder {
        private var buffer = Data()
        mutating func append(_ bytes: Data) -> [Data] {
            buffer.append(bytes)
            var frames: [Data] = []
            while !buffer.isEmpty {
                guard buffer.first == 1 else { buffer = Data(buffer.dropFirst()); continue }
                guard buffer.count >= 3 else { break }
                let size = Int(buffer[1]) + (Int(buffer[2]) << 8) + 4
                guard (7...4100).contains(size) else { buffer = Data(buffer.dropFirst()); continue }
                guard buffer.count >= size else { break }
                let frame = Data(buffer.prefix(size))
                let sum = frame[1..<(size - 3)].reduce(0) { $0 + Int($1) } & 0xffff
                guard frame.last == 2, sum == Int(frame[size - 3]) + (Int(frame[size - 2]) << 8) else {
                    buffer = Data(buffer.dropFirst()); continue
                }
                frames.append(Data(frame[3..<(size - 3)]))
                buffer = Data(buffer.dropFirst(size))
            }
            return frames
        }
    }
}
