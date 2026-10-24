import Foundation

@main enum NodeLocatorChecks {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("WAW-node-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        func executable(_ name: String, runnable: Bool = true) throws -> URL {
            let file = home.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: runnable ? 0o755 : 0o644], ofItemAtPath: file.path)
            return file
        }
        func found(path: String = "", environment: [String: String] = [:]) -> URL? {
            let candidates = DeepSeekLocator.nodeCandidates(path: path, home: home, environment: environment)
            // Isolate fixtures from system-wide Node installations on the test machine.
            return Executables.first(candidates.filter { $0.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/") })
        }
        precondition(found() == nil)
        _ = try executable(".local/share/fnm/node-versions/v99.0.0/installation/bin/node", runnable: false)
        let old = try executable(".local/share/fnm/node-versions/v9.0.0/installation/bin/node")
        let recent = try executable(".local/share/fnm/node-versions/v24.14.1/installation/bin/node")
        precondition(found()?.resolvingSymlinksInPath() == recent.resolvingSymlinksInPath(), "Finder PATH fallback uses numeric version order and skips non-executables")
        let alias = home.appendingPathComponent(".local/share/fnm/aliases/default")
        try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: old.deletingLastPathComponent().deletingLastPathComponent())
        precondition(found()?.resolvingSymlinksInPath() == old.resolvingSymlinksInPath(), "fnm default takes precedence over other installed versions")
        let shell = try executable("shell/bin/node")
        precondition(found(path: shell.deletingLastPathComponent().path) == shell, "explicit shell PATH is preserved")
        try fm.removeItem(at: home.appendingPathComponent(".local/share/fnm"))
        let native = try executable("Library/Application Support/fnm/node-versions/v24.0.0/installation/bin/node")
        precondition(found()?.resolvingSymlinksInPath() == native.resolvingSymlinksInPath(), "macOS fnm directory with spaces")
        try fm.removeItem(at: home.appendingPathComponent("Library/Application Support/fnm"))
        let custom = try executable("custom-fnm/node-versions/v24.0.0/installation/bin/node")
        precondition(found(environment: ["FNM_DIR": home.appendingPathComponent("custom-fnm").path])?.resolvingSymlinksInPath() == custom.resolvingSymlinksInPath())
        let nvm = try executable(".nvm/versions/node/v24.0.0/bin/node")
        precondition(found()?.resolvingSymlinksInPath() == nvm.resolvingSymlinksInPath())
        try fm.removeItem(at: home.appendingPathComponent(".nvm"))
        let volta = try executable(".volta/bin/node")
        precondition(found() == volta)
        print("NodeLocatorChecks: minimal PATH, fnm default/version order/custom/macOS paths, nvm, Volta and non-executable fallback passed")
    }
}
