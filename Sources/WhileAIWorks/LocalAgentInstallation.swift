import AppKit
import AgentHUDSupport

@MainActor enum LocalAgentInstallation {
    static func show(source: WorkSource, state: AppState) {
        guard source.isLocalAgent, let resources = Bundle.main.resourceURL?.appendingPathComponent("LocalAgents"),
              FileManager.default.fileExists(atPath: resources.path) else {
            state.agentInteractionSetupMessage = "请从完整应用包安装增强监听"; return
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/While AI Works/Integrations")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(source.rawValue)
            // Only our own exported package is replaced; client settings are never overwritten.
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: resources.appendingPathComponent(source.rawValue), to: destination)
            let guide = resources.appendingPathComponent("README.md")
            NSWorkspace.shared.open(guide)
            NSWorkspace.shared.selectFile(destination.path, inFileViewerRootedAtPath: root.path)
            let command = source == .dsh ? "dsh plugin --profile " + LocalAgentReader.quote(dshProfile()) + " add " + LocalAgentReader.quote(destination.path)
                : "mkdir -p \"${HERMES_HOME:-$HOME/.hermes}/plugins/while-ai-works\" && cp -R " + LocalAgentReader.quote(destination.path) + "/. \"${HERMES_HOME:-$HOME/.hermes}/plugins/while-ai-works/\" && hermes plugins enable while-ai-works"
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            state.agentInteractionSetupMessage = "已导出 \(source.clientName) 增强监听并复制安装命令。按说明选择原客户端 profile，安装后重启会话。"
        } catch { state.agentInteractionSetupMessage = "增强监听未能导出，请检查目录权限" }
    }
    static func dshProfile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let root = ProcessInfo.processInfo.environment["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
        // dst has its own profile; the similarly named tui profile is a different installation.
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/dsh-tui/package.json").path) ? "dsh-tui" : "web"
    }
}
