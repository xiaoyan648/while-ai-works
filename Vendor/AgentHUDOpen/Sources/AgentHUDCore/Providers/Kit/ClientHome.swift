import AgentHUDSupport
import Foundation

/// The client home dimension: one client can run from several data directories with different sign-ins.
public enum ClientHome {
    /// A notice or reading issue of one client's login, before that login can identify an account.
    public static func sourceKey(provider: String, home: String) -> String { provider + "@" + home }

    /// Empty for the client's default directory, otherwise a hash of the resolved path.
    public static func key(_ directory: URL, defaultDirectory: URL) -> String {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == defaultDirectory.standardizedFileURL.resolvingSymlinksInPath().path ? "" : RecordCoding.hash([path])
    }

    /// The directory `variable` moves a client's files to, without the whitespace around it; nil when the variable is
    /// unset, empty or only whitespace, which clients read as unset.
    static func variable(_ variable: String, in environment: [String: String]) -> String? {
        guard let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
