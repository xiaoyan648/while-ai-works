import AgentHUDSupport
import Foundation

/// Codex's hook does not name the reviewer. The matching turn's persisted context is the available source;
/// permission_mode describes the approval policy and cannot distinguish automatic review from a user's decision.
enum CodexPermissionReviewer {
    static func isUser(payload: JSONValue) -> Bool {
        guard let path = payload["transcript_path"].stringValue, !path.isEmpty,
              let turn = payload["turn_id"].stringValue, !turn.isEmpty else { return false }
        var reviewer: String?
        do {
            try ProviderFiles.lines(URL(fileURLWithPath: path), markers: [Data("\"turn_context\"".utf8)]) { record, _ in
                guard record["type"].stringValue == "turn_context",
                      record["payload"]["turn_id"].stringValue == turn else { return }
                reviewer = record["payload"]["approvals_reviewer"].stringValue
            }
        } catch { return false }
        return reviewer == "user"
    }
}
