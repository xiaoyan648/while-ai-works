import Foundation

public enum DeepSeekLocator {
    public static var dataDirectory: URL { dataDirectory(environment: ProcessInfo.processInfo.environment) }

    public static func dataDirectory(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let path = ClientHome.variable("DSH_HOME", in: environment) else {
            return home.appendingPathComponent(".dsh", isDirectory: true)
        }
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    public static func isInstalled(directory: URL = dataDirectory) -> Bool {
        ["profiles", "sessions"].contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Finder does not inherit the shell setup used by fnm/nvm. Discover their installations
    /// directly; do not source shell startup files or depend on another application's runtime.
    public static func nodeExecutable(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        Executables.first(nodeCandidates(path: path, home: home, environment: environment))
    }

    static func nodeCandidates(path: String, home: URL, environment: [String: String]) -> [URL] {
        func directory(_ variable: String, _ fallback: String) -> URL {
            guard let value = environment[variable], !value.isEmpty else { return home.appendingPathComponent(fallback) }
            return URL(fileURLWithPath: value)
        }
        func versions(_ root: URL, executable: String) -> [URL] {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .map { $0.appendingPathComponent(executable) }
        }
        var candidates = Executables.onPath("node", path: path)
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(fileURLWithPath: $0) }
        let fnmRoots = [directory("FNM_DIR", ".local/share/fnm"), home.appendingPathComponent("Library/Application Support/fnm"), home.appendingPathComponent(".fnm")]
        for root in fnmRoots {
            candidates.append(root.appendingPathComponent("aliases/default/bin/node"))
            candidates += versions(root.appendingPathComponent("node-versions"), executable: "installation/bin/node")
        }
        candidates += versions(directory("NVM_DIR", ".nvm").appendingPathComponent("versions/node"), executable: "bin/node")
        candidates.append(directory("VOLTA_HOME", ".volta").appendingPathComponent("bin/node"))
        return candidates
    }
}
