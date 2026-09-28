import SwiftUI
import WhileCore

/// What the menu bar panel shows: the cat, the play switch, the four games and today's numbers.
struct MenuBarView: View {
    @ObservedObject var state: AppState
    let mascot: MascotController
    var openCollection: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    @Namespace private var tiles
    @State private var taps: [PlayMode: Int] = [:]

    static let width: CGFloat = 344

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            playSwitch
            modePicker
            stats
            Divider().opacity(0.6).padding(.horizontal, 2)
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .onAppear(perform: syncMascot)
        .onChange(of: state.mascotMood) { _, _ in syncMascot() }
        .onChange(of: state.mascotCoat) { _, _ in syncMascot() }
        .onChange(of: state.celebrationSerial) { _, _ in mascot.celebrate() }
    }

    private func syncMascot() { mascot.set(mood: state.mascotMood, coat: state.mascotCoat) }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 0) {
            MascotView(controller: mascot)
                .frame(width: 150, height: 150)
                .padding(.leading, -10).padding(.trailing, -4)
            VStack(alignment: .leading, spacing: 5) {
                Text("AI 干活时我们干什么")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                statusChip.padding(.top, 3)
            }
            .animation(Theme.spring, value: headline)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 12)
        .padding(.top, 22)
        .background { ForestBackdrop(cornerRadius: 14, focus: 0.2) }
        .overlay(alignment: .topTrailing) {
            Toggle(isOn: $state.desktopPetEnabled) {
                Label("桌面猫", systemImage: "cat")
                    .font(.system(size: 10, weight: .medium))
            }
            .toggleStyle(.button).buttonStyle(.borderless).tint(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.desktopPetEnabled ? Theme.accent.opacity(0.13) : Theme.well, in: Capsule())
            .foregroundStyle(state.desktopPetEnabled ? Theme.accent : .secondary)
            .help(state.desktopPetEnabled ? "收起桌面小猫" : "在桌面显示小猫")
            .accessibilityIdentifier("desktop-pet-toggle")
            .padding(8)
        }
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        switch state.mascotMood {
        case .idle: return "想摸会儿鱼吗？"
        case .sleep: return "AI 还没开工"
        case .watch: return "盯着浮漂"
        case .play, .proud, .curious, .effort, .focus: return state.mode.title + "中"
        }
    }

    private var detail: String {
        switch state.mascotMood {
        case .idle: return "打开开关，桌面就开始长活儿。"
        case .sleep: return "水面很安静，先眯一会儿。"
        case .watch: return state.fishingActivityLabel
        case .play, .proud, .curious, .effort, .focus:
            if state.followAI, state.detectedWorking { return workingClients + " 在干活，你在摸鱼。" }
            return "\(state.shortcutLabel) 随时收起。"
        }
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            ActivityDot(active: state.desktopEnabled && state.followAI && state.detectedWorking)
            Text(chipText).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.well, in: Capsule())
    }

    private var chipText: String {
        guard state.followAI else { return "随时开启" }
        if state.desktopEnabled && state.detectedWorking { return workingClients + " 工作中" }
        return "跟随 " + state.selectedClientsLabel
    }

    private var workingClients: String { state.activeClientsLabel.isEmpty ? "AI" : state.activeClientsLabel }

    // MARK: Play switch

    private var playSwitch: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.desktopEnabled ? "正在玩" : "开始玩")
                    .font(.system(size: 14, weight: .semibold))
                Text(state.desktopEnabled ? "按 \(state.shortcutLabel) 回去工作" : "开启后在桌面玩，\(state.shortcutLabel) 随时收起")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("开始玩", isOn: $state.desktopEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .accessibilityIdentifier("desktop-toggle")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Modes

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(PlayMode.allCases) { mode in
                let selected = state.mode == mode
                Button {
                    taps[mode, default: 0] += 1
                    withAnimation(Theme.spring) { state.mode = mode }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .symbolEffect(.bounce, value: taps[mode, default: 0])
                            .frame(height: 22)
                        Text(mode.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        Text(state.shortCount(for: mode))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(selected ? Theme.accent : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Theme.accent.opacity(0.13))
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                                .matchedGeometryEffect(id: "selection", in: tiles)
                        } else {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.well)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle(hoverFill: false))
                .accessibilityLabel(mode.title + "，" + state.countLabel(for: mode))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("mode-\(mode.rawValue)")
            }
        }
    }

    // MARK: Stats

    private var stats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.primaryStatTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(state.primaryStatValue.formatted())
                            .font(Theme.number(28))
                            .contentTransition(.numericText(value: Double(state.primaryStatValue)))
                            .animation(Theme.spring, value: state.primaryStatValue)
                        Text(state.primaryStatUnit).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("本次 \(state.session(for: state.mode).formatted()) \(state.mode.unit)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    if state.mode != .woodfish {
                        InlineAction(title: state.mode == .fishing ? "收竿重来" : "重新铺满",
                                     symbol: "arrow.counterclockwise", tint: Theme.accent) { state.reset() }
                            .disabled(!state.desktopEnabled)
                            .padding(.trailing, -8)
                            .accessibilityIdentifier("reset-surface")
                    }
                }
            }
            if state.mode == .fishing {
                InlineAction(title: "查看鱼获", symbol: "fish", tint: Theme.accent) { openCollection() }
                    .padding(.leading, -8)
                    .accessibilityIdentifier("open-collection")
            }
            if let hint = state.modeHint {
                Label(hint, systemImage: state.mode == .woodfish ? "hourglass" : "water.waves")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            InlineAction(title: "设置", symbol: "gearshape") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityIdentifier("open-settings")
            Spacer()
            Button { state.soundEnabled.toggle() } label: {
                Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle())
            .help(state.soundEnabled ? "静音" : "打开声音")
            .accessibilityLabel(state.soundEnabled ? "静音" : "打开声音")
            .accessibilityIdentifier("sound-toggle")
            InlineAction(title: "退出", symbol: "power") { quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .foregroundStyle(.primary)
    }
}
