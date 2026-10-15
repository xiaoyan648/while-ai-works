import Foundation

enum DeepSeekLogReader {
    /// A whole log's text.
    static func read(_ url: URL) async throws -> Data {
        try await read(url, from: DecodedPosition())?.data ?? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// A compressed log's text from `start`, a frame's start, with the start of every complete frame after it; nil for a
    /// plain log, which is read from its offset. Harness appends a frame per write batch, so a log that grew is decoded
    /// from the last frame read before rather than from its first.
    static func read(_ url: URL, from start: DecodedPosition) async throws -> DecodedLog? {
        guard url.pathExtension == "zstd" else { return nil }
        // Node's decoder stops at one frame, and decodes a frame that is still being written as far as it goes; the
        // frame's own layout says where it ends. Each frame goes out as its size in the file, a size of 0 for the frame
        // still being written, then the length and bytes of its text.
        let output = try await DeepSeekNode.run(script: """
        const {openSync, fstatSync, readSync} = require('node:fs');
        const {zstdDecompressSync, constants} = require('node:zlib');
        const fd = openSync(process.argv[1], 'r'), start = Number(process.argv[2]);
        const input = Buffer.alloc(Math.max(0, fstatSync(fd).size - start));
        readSync(fd, input, 0, input.length, start);
        function frameSize(at) {
          if (input.length - at < 8) return 0;
          const magic = input.readUInt32LE(at);
          if (magic >= 0x184D2A50 && magic <= 0x184D2A5F) {
            const size = 8 + input.readUInt32LE(at + 4);
            return at + size <= input.length ? size : 0;
          }
          if (magic !== 0xFD2FB528) throw new Error('Invalid Zstandard frame');
          const descriptor = input[at + 4], single = (descriptor >> 5) & 1;
          let p = at + 5 + (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + [single, 2, 4, 8][descriptor >> 6];
          for (;;) {
            if (input.length - p < 3) return 0;
            const header = input[p] | (input[p + 1] << 8) | (input[p + 2] << 16), type = (header >> 1) & 3;
            if (type === 3) throw new Error('Invalid Zstandard block');
            p += 3 + (type === 1 ? 1 : header >>> 3);
            if (header & 1) break;
          }
          p += (descriptor >> 2) & 1 ? 4 : 0;
          return p <= input.length ? p - at : 0;
        }
        function emit(stored, text) {
          const header = Buffer.alloc(8);
          header.writeUInt32LE(stored, 0);
          header.writeUInt32LE(text.length, 4);
          process.stdout.write(header);
          process.stdout.write(text);
        }
        for (let offset = 0; input.length - offset >= 4;) {
          const size = frameSize(offset);
          if (!size) {
            try { emit(0, zstdDecompressSync(input.subarray(offset), {finishFlush: constants.ZSTD_e_flush})); }
            catch { /* Too little of the frame is written to decode any of it. */ }
            break;
          }
          emit(size, zstdDecompressSync(input.subarray(offset, offset + size)));
          offset += size;
        }
        """, arguments: [url.path, String(start.stored)], timeout: 10)
        var data = Data(), restarts: [DecodedPosition] = [], position = start, index = output.startIndex
        func number(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(output[at + $1]) << (8 * $1) } }
        while output.endIndex - index >= 8 {
            let stored = number(index), count = number(index + 4)
            index += 8
            guard output.endIndex - index >= count else { throw ProviderFailure.format }
            data.append(output[index..<(index + count)])
            index += count
            guard stored > 0 else { break }
            position = DecodedPosition(stored: position.stored + stored, decoded: position.decoded + count)
            restarts.append(position)
        }
        return DecodedLog(start: start, data: data, restarts: restarts)
    }
}

public enum DeepSeekNode {
    public static func run(script: String, arguments: [String], environment: [String: String] = [:],
                           timeout: TimeInterval = 30) async throws -> Data {
        guard let node = DeepSeekLocator.nodeExecutable() else {
            throw UsageProviderError(L10n.text("读取 Harness 数据需要 Node.js", "Node.js is required to read Harness data"))
        }
        // A truncated log would parse as a different one, so output beyond the cap fails the read.
        let output = try await ChildProcess.run(node, ["-e", script] + arguments, environment: environment,
                                                timeout: timeout, stdoutLimit: 256 * 1024 * 1024)
        guard output.status == 0, !output.truncated else {
            throw UsageProviderError(L10n.text("Harness 数据读取失败，请检查本机安装和 Node.js 版本", "Cannot read Harness data; check the local install and Node.js version"))
        }
        return output.stdout
    }
}
