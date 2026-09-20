import Foundation
import WhileCore

@main enum WorkHook {
    static func main() {
        // Always exit successfully and emit nothing, so monitoring never blocks the AI.
        guard CommandLine.arguments.count == 2,
              let provider = HookProvider(rawValue: CommandLine.arguments[1]) else { return }
        var data = Data()
        while data.count <= 1_048_576 {
            do {
                guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            } catch { return }
        }
        try? HookBridge.record(data, provider: provider)
    }
}
