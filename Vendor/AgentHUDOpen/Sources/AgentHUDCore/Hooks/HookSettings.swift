import AgentHUDSupport
import Foundation

/// A client's settings file, rewritten to add or take out Agent HUD's handlers.
public enum HookSettings {
    /// Writes `object` to the file `url` names, as sorted, pretty-printed JSON. A settings file kept as a symbolic link,
    /// as a dotfiles checkout keeps it, is written where the link leads and stays a link; the file keeps the permissions
    /// it had, since a client's settings can hold credentials.
    public static func write(_ object: [String: JSONValue], to url: URL) throws {
        let file = target(of: url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(object)).write(to: file, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    /// The file behind `url`: where its symbolic links lead, a relative one from the directory that holds it.
    static func target(of url: URL) -> URL {
        var file = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) else { break }
            file = URL(fileURLWithPath: destination, relativeTo: file.deletingLastPathComponent()).absoluteURL.standardizedFileURL
        }
        return file
    }
}
