import Foundation

public enum SessionTitle {
    /// Session title: first real user prompt, first line, trimmed to 60 characters. Skips slash-command/meta lines.
    public static func from(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        let collapsed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return clipped(collapsed)
    }

    /// A title the client keeps for the session, whether the user gave it or the client generated it: its first
    /// non-empty line, trimmed to 60 characters like a prompt title; nil when it is empty.
    public static func named(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return clipped(line)
    }

    private static func clipped(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}
