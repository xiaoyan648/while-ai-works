import AppKit
import SwiftUI
import AgentHUDCore

struct AgentInteractionQueueView: View {
    @ObservedObject var state: AppState
    let source: WorkSource?
    private var requests: [AgentInteraction] { state.agentInteractions.filter { source == nil || $0.source == source } }
    private var selected: AgentInteraction? { requests.first { $0.id == state.agentInteractionSelectionID } ?? requests.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("需要你处理", systemImage: "hand.raised").foregroundStyle(Theme.attention)
                Spacer()
                Text("\(requests.count)").foregroundStyle(.secondary)
            }.font(.system(size: 10, weight: .medium))
            ForEach(requests) { item in
                if item.id == selected?.id {
                    AgentInteractionCardView(state: state, interaction: item, showActions: false)
                } else {
                    Button { state.agentInteractionSelectionID = item.id; state.agentInteractionInputID = nil } label: {
                        HStack(spacing: 6) {
                            AgentMark(source: item.source, size: 12)
                            Image(systemName: item.request.isQuestion ? "questionmark.bubble" : "hand.raised")
                                .foregroundStyle(Theme.attention)
                            Text(item.request.project ?? item.source.dockName).lineLimit(1)
                            Text(item.request.summary).lineLimit(1).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                        }.font(.system(size: 10)).padding(9).background(Theme.well, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
        }.accessibilityIdentifier("agent-interaction-queue")
    }
}

struct AgentInteractionCardView: View {
    @ObservedObject var state: AppState
    let interaction: AgentInteraction
    var expanded = false
    var showActions = true
    var showHeader = true
    var embedded = false
    var later: (() -> Void)?
    @FocusState private var typing: Bool
    private var request: PermissionRequest { interaction.request }
    private var draft: AgentInteractionDraft { state.agentInteractionDrafts[request.id] ?? .init() }
    private var fullDetail: Bool { expanded || (request.detail != nil && draft.reviewedDetail == request.detail) }
    private var page: Int { min(max(0, draft.page), max(0, request.questions.count - 1)) }
    private func change(_ body: (inout AgentInteractionDraft) -> Void) {
        guard state.agentInteractions.contains(where: { $0.id == request.id }) else { return }
        if state.agentInteractionSelectionID != request.id { state.agentInteractionSelectionID = request.id }
        var updated = draft; body(&updated); state.agentInteractionDrafts[request.id] = updated
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showHeader {
            HStack(spacing: 6) {
                AgentMark(source: interaction.source, size: 14)
                Text(request.project ?? interaction.source.dockName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(interaction.status).font(.system(size: 9)).foregroundStyle(Theme.attention).lineLimit(2)
                Spacer(minLength: 0)
                if !expanded {
                    Button { state.openAgentInteraction(request.id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("在独立浮窗中处理")
                        .accessibilityLabel("展开待处理请求").accessibilityIdentifier("agent-interaction-expand")
                }
                Button { state.openInteractionSession(request) } label: {
                    Image(systemName: "arrow.up.forward").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("回到原会话")
                    .accessibilityLabel("回到请求的原会话")
            }
            }
            if request.isQuestion { question(request.questions[page]) }
            else {
                Text(request.summary).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let detail = request.detail {
                    Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(fullDetail ? nil : 4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9).background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                    if !fullDetail {
                        Button("查看完整操作") { change { $0.reviewedDetail = detail } }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("agent-interaction-review")
                    }
                }
                if request.isPlan {
                    Text("请在 Claude 原客户端阅读并审批完整计划。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if interaction.phase != .ready || !interaction.fresh {
                Text(interaction.status).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showActions { AgentInteractionActionsView(state: state, interaction: interaction, expanded: expanded, later: later) }
        }
        .padding(embedded ? 0 : 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(embedded ? Color.clear : Theme.well, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("agent-interaction-card")
    }
    private func question(_ question: PermissionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if request.questions.count > 1 {
                HStack {
                    Button { change { $0.page = max(0, page - 1) } } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                    Text("\(page + 1) / \(request.questions.count)")
                    Button { change { $0.page = min(request.questions.count - 1, page + 1) } } label: { Image(systemName: "chevron.right") }
                        .disabled(page == request.questions.count - 1)
                    Spacer(); if question.multiSelect { Text("可多选") }
                }.font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
            }
            Text(question.question).font(.system(size: 12, weight: .medium))
                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true)
            answer(question)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                let picked = draft.picks[question.answerKey]?.contains(index) == true
                Button { change { $0.pick(index, for: question) } } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: question.multiSelect ? (picked ? "checkmark.square.fill" : "square") : (picked ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(picked ? Theme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.system(size: 11)).lineLimit(expanded ? nil : 2)
                            if let description = option.description {
                                Text(description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(picked ? Theme.accent.opacity(0.12) : Theme.well, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(!interaction.canAnswer)
                    .accessibilityAddTraits(picked ? .isSelected : []).accessibilityIdentifier("agent-interaction-option-\(index)")
            }
        }
    }
    @ViewBuilder private func answer(_ question: PermissionQuestion) -> some View {
        if expanded || state.agentInteractionInputID == request.id {
            TextField("写下你的回答…", text: Binding(get: { draft.custom[question.answerKey] ?? "" }, set: { text in change { $0.type(text, for: question) } }), axis: .vertical)
                .font(.system(size: 11)).lineLimit(2...5).textFieldStyle(.plain)
                .padding(8).background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                .focused($typing).disabled(!interaction.canAnswer).accessibilityIdentifier("agent-interaction-answer")
                .onAppear { if !expanded { typing = true } }
        } else if let text = draft.custom[question.answerKey], !text.isEmpty {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("你的回答：" + text)
        }
    }
}

/// Kept outside the detail card's scrolling/fade region so the decision never disappears.
struct AgentInteractionActionsView: View {
    @ObservedObject var state: AppState
    let interaction: AgentInteraction
    var expanded = false
    var later: (() -> Void)?
    private var request: PermissionRequest { interaction.request }
    private var draft: AgentInteractionDraft { state.agentInteractionDrafts[request.id] ?? .init() }
    private func submit(_ decision: PermissionDecision) {
        state.answerAgentInteraction(request.id, decision); state.agentInteractionInputID = nil
    }
    var body: some View {
        HStack(spacing: 10) {
            if request.isQuestion {
                Button("稍后") {
                    state.agentInteractionInputID = nil
                    if let later { later() } else { state.desktopPetShowsStatus = false }
                }.foregroundStyle(.secondary)
                if !expanded {
                    Button {
                        if state.agentInteractionInputID == request.id { state.agentInteractionInputID = nil; return }
                        state.agentInteractionSelectionID = request.id
                        state.agentInteractionInputID = request.id; state.focusAgentComposer()
                    } label: { Label(state.agentInteractionInputID == request.id ? "收起输入" : "输入回答", systemImage: "pencil") }
                        .foregroundStyle(.secondary).disabled(!interaction.canAnswer)
                        .accessibilityIdentifier("agent-interaction-type")
                }
                Spacer()
                Button(interaction.phase == .sending ? "发送中…" : "提交回答") { submit(.answer(draft.answers(for: request.questions))) }
                    .disabled(!interaction.canAnswer || !AgentInteractionValidation.allows(.answer(draft.answers(for: request.questions)), for: request))
                    .foregroundStyle(Theme.accent).accessibilityIdentifier("agent-interaction-submit")
            } else {
                Button("回到原会话") { state.openInteractionSession(request) }.foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !request.isPlan {
                    Button("拒绝") { submit(.deny) }.disabled(!interaction.canAnswer)
                        .accessibilityIdentifier("agent-interaction-deny")
                    if expanded || request.detail == nil || draft.reviewedDetail == request.detail {
                        Button(request.nativeApproval == nil ? "允许一次" : "允许此对话") { submit(.allow) }
                            .disabled(!interaction.canAnswer).foregroundStyle(Theme.accent).accessibilityIdentifier("agent-interaction-allow")
                    } else {
                        Button("审阅操作") {
                            var updated = draft; updated.reviewedDetail = request.detail
                            state.agentInteractionDrafts[request.id] = updated
                        }.foregroundStyle(Theme.accent).accessibilityIdentifier("agent-interaction-review")
                    }
                }
            }
        }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain).padding(.vertical, 3)
            .accessibilityIdentifier("agent-interaction-actions")
    }
}

final class AgentInteractionWindowController: NSObject, NSWindowDelegate {
    let panel: DesktopPetPanel
    private let state: AppState
    private(set) var requestID: String?
    init(state: AppState) {
        self.state = state
        panel = DesktopPetPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(); panel.delegate = self
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.level = .floating
        panel.minSize = CGSize(width: 360, height: 300)
        panel.backgroundColor = .adaptive(light: 0xFAFAFC, dark: 0x060708)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(_ id: String, appearance: NSAppearance?, beside anchor: CGRect) {
        guard state.agentInteractions.contains(where: { $0.id == id }) else { return }
        requestID = id; panel.title = "待处理请求"; panel.setAccessibilityLabel("待处理请求")
        panel.appearance = appearance
        panel.contentView = NSHostingView(rootView: AgentInteractionWindowView(state: state, id: id, dismiss: { [weak self] in self?.dismiss() }))
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(anchor) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            let size = CGSize(width: min(480, visible.width - 32), height: min(560, visible.height - 32))
            let origin = CGPoint(x: min(max(anchor.minX, visible.minX + 16), visible.maxX - size.width - 16),
                                 y: min(max(anchor.midY - size.height / 2, visible.minY + 16), visible.maxY - size.height - 16))
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        panel.allowsKeyboard = true; panel.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard let requestID else { return }
        if !state.agentInteractions.contains(where: { $0.id == requestID }) { dismiss() }
        else { panel.appearance = state.desktopCompanionAppearance.native }
    }
    func dismiss() { panel.orderOut(nil); panel.allowsKeyboard = false; panel.contentView = nil; requestID = nil; panel.title = ""; panel.setAccessibilityLabel("") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

struct AgentInteractionWindowView: View {
    @ObservedObject var state: AppState
    let id: String
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待处理请求").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(.plain)
                    .accessibilityLabel("关闭处理浮窗")
            }
            ScrollView {
                if let interaction = state.agentInteractions.first(where: { $0.id == id }) {
                    AgentInteractionCardView(state: state, interaction: interaction, expanded: true, later: dismiss)
                } else { Text("已在原会话处理") }
            }
        }.padding(20).padding(.top, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .adaptive(light: 0xFAFAFC, dark: 0x060708)))
    }
}
