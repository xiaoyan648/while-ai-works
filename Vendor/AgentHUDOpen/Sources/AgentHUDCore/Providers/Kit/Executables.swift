import Foundation

/// How a client's executable is found: at the places its installers use first, since an application started from
/// Finder gets a minimal `PATH`, then in the directories of `PATH`.
enum Executables {
    /// `name` in each directory of `path`, in order.
    static func onPath(_ name: String, path: String) -> [URL] {
        path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
    }

    /// The first of `candidates` that can run.
    static func first(_ candidates: [URL], fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
