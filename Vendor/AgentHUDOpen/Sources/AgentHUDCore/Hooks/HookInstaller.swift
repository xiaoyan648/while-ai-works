import AgentHUDSupport
import Foundation

/// Agent HUD's handler for one hook of one client: the settings file it lives in, and the arguments that follow the
/// executable in its command. Reading that file, telling Agent HUD's handlers from the client's own and writing the
/// result back are the same for every hook; only the edit is the hook's own.
public struct HookInstaller: Sendable {
    /// The largest client settings file read or rewritten.
    public static let configurationLimit = 16 * 1024 * 1024

    /// The client's settings file.
    public let configuration: URL
    /// What follows the executable in the handler's command, such as `--completion-hook cursor`.
    public let arguments: String

    public init(configuration: URL, arguments: String) {
        self.configuration = configuration
        self.arguments = arguments
    }

    /// The settings, empty when the file is missing or empty. A file over `configurationLimit`, or one whose content is
    /// not a JSON object, throws.
    public func read() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: configuration.path) else { return [:] }
        let data = try Data(contentsOf: configuration)
        guard data.count <= Self.configurationLimit else { throw ProviderFailure.limit }
        guard !data.isEmpty else { return [:] }
        guard let object = try ProviderJSON.read(data).objectValue else { throw ProviderFailure.format }
        return object
    }

    /// Whether `command` runs this handler, whichever copy of Agent HUD wrote it.
    public func owns(_ command: String?) -> Bool { HookCommand.runs(command, arguments: arguments) }

    /// Points every Agent HUD handler of the hook at `executable`, whichever copy wrote it (`HookCommand`), or with
    /// `enabled` false takes them all out. `updating` gives the settings with the handlers set to a command, or taken out
    /// for nil, leaves every other entry alone and throws for a layout it does not recognize. A file that already says
    /// the same is not rewritten, taking the handlers out never leaves behind a file the client did not have, and a copy
    /// running from a transient place adds nothing (`HookCommand.checkInstall(executable:)`). `willWrite` runs just before
    /// a changed file is written (`HookSettings.write(_:to:)`).
    public func configure(enabled: Bool, executable: URL,
                          updating: ([String: JSONValue], String?) throws -> [String: JSONValue],
                          willWrite: () -> Void = {}) throws {
        guard enabled || FileManager.default.fileExists(atPath: configuration.path) else { return }
        if enabled { try HookCommand.checkInstall(executable: executable) }
        let object = try read()
        let updated = try updating(object, enabled ? HookCommand.make(executable: executable, arguments: arguments) : nil)
        guard updated != object else { return }
        willWrite()
        try HookSettings.write(updated, to: configuration)
    }
}
