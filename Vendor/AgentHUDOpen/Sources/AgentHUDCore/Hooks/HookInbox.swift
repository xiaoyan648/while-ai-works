import Foundation

/// Where short-lived hook processes leave what they saw for the running application: one folder per client under the
/// data directory, of small JSON records only the user can read.
struct HookInbox {
    /// The largest hook payload a record is made from.
    static let payloadLimit = 1024 * 1024
    /// The largest record read back.
    static let recordLimit = 64 * 1024

    let folder: URL

    init(directory: URL, source: String) {
        folder = directory.appendingPathComponent(source)
    }

    init(folder: URL) {
        self.folder = folder
    }

    /// Makes the folder, which only the user can open, so it can be watched before its first record.
    func create() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes `record` as `name`.json, which only the user can read; with `replacing` false a record already there stays.
    func write(_ record: some Encodable, name: String, replacing: Bool) throws {
        try create()
        let file = folder.appendingPathComponent(name + ".json")
        guard replacing || !FileManager.default.fileExists(atPath: file.path) else { return }
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The records in the folder, with the resource values `keys` fetched; throws when the folder cannot be listed.
    func files(keys: [URLResourceKey]? = nil) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys).filter { $0.pathExtension == "json" }
    }

    /// A record's content; one over `recordLimit` throws.
    static func data(of file: URL) throws -> Data {
        let data = try Data(contentsOf: file)
        guard data.count <= recordLimit else { throw ProviderFailure.limit }
        return data
    }
}
