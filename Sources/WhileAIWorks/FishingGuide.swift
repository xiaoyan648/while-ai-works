import SwiftUI
import WhileCore

struct CatchIllustration: NSViewRepresentable {
    let species: CatchSpecies
    let discovered: Bool
    func makeNSView(context: Context) -> SpecimenView { SpecimenView() }
    func updateNSView(_ nsView: SpecimenView, context: Context) {
        nsView.species = species; nsView.discovered = discovered; nsView.needsDisplay = true
    }
}
final class SpecimenView: NSView {
    var species = CatchSpecies.catalog[0]
    var discovered = false
    override func draw(_ dirtyRect: NSRect) { FishingArtwork.specimen(species, in: bounds.insetBy(dx: 3, dy: 4), discovered: discovered) }
}

/// The collection window: fish book, rods, achievements and the underwater view.
struct FishingGuide: View {
    @ObservedObject var state: AppState
    enum Section: String, CaseIterable, Identifiable {
        case book = "鱼图鉴", rods = "钓具", achievements = "成就", tank = "水下观赏"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .book: return "book.pages"; case .rods: return "figure.fishing"; case .achievements: return "medal"; case .tank: return "water.waves" }
        }
    }
    @State var section: Section? = .book
    @StateObject private var presentation = AquariumPresentation.shared

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .safeAreaInset(edge: .bottom) { summary }
            .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 220)
        } detail: {
            detail(for: section ?? .book)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .accessibilityIdentifier("fishing-guide")
    }

    @ViewBuilder func detail(for section: Section) -> some View {
        switch section {
        case .book: book
        case .rods: rods
        case .achievements: achievements
        case .tank: tank
        }
    }

    // MARK: Sidebar summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow("鱼种", state.fishingBook.discoveredFish, CatchSpecies.catalog.filter(\.isFish).count)
            summaryRow("钓竿", FishingRod.allCases.filter { $0.isUnlocked(in: state.fishingBook) }.count, FishingRod.allCases.count)
            summaryRow("成就", earnedCount, FishingAchievement.allCases.count)
        }
        .padding(12)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
    }

    private func summaryRow(_ title: String, _ current: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(current) / \(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(current), total: Double(max(total, 1)))
                .progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
        }
    }

    private var earnedCount: Int { FishingAchievement.allCases.filter { state.fishingProgression.earned.contains($0.id) }.count }

    // MARK: Pages

    private func page<Trailing: View, Content: View>(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing,
                                                     @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 26, weight: .bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    trailing()
                }
                content()
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
        }
    }

    private var book: some View {
        let fish = CatchSpecies.catalog.filter(\.isFish)
        let items = CatchSpecies.catalog.filter { !$0.isFish }
        return page("鱼图鉴", subtitle: "指向水面，按住蓄力，松开抛竿。浅水偏小鱼，荷叶旁藏杂物，深水偏大鱼。") {
            ProgressRing(value: state.fishingBook.discoveredFish, total: fish.count, caption: "鱼种")
        } content: {
            HStack(spacing: 10) {
                StatTile(title: "总鱼获", value: state.fishingBook.total, unit: "件")
                StatTile(title: "鱼", value: state.fishingBook.fishCount, unit: "条")
                StatTile(title: "杂物", value: state.fishingBook.itemCount, unit: "件")
                StatTile(title: "金牌鱼种", value: state.fishingBook.goldSpeciesCount, unit: "种")
            }
            speciesGrid("鱼类", detail: "\(fish.count) 种", species: fish)
            speciesGrid("水底的奇怪东西", detail: "\(items.count) 种", species: items)
            Text("剪影尚未钓获；未知巨物钓获后揭晓。概率为基础占比，水域与昼夜会改变鱼池。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("fishing-guide-list")
    }

    private func speciesGrid(_ title: String, detail: String, species: [CatchSpecies]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(species) { SpeciesCard(state: state, species: $0) }
            }
        }
    }

    private var rods: some View {
        page("钓具", subtitle: "累计钓获包含杂物。解锁后永久拥有；钓鱼途中暂不能更换钓竿。") {
            ProgressRing(value: FishingRod.allCases.filter { $0.isUnlocked(in: state.fishingBook) }.count,
                         total: FishingRod.allCases.count, caption: "已解锁")
        } content: {
            VStack(spacing: 12) {
                ForEach(FishingRod.allCases) { rodCard($0) }
            }
            Text("增益直接增加判定块占轨道的比例，各阶不叠加。").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("fishing-rods")
    }

    private func rodCard(_ rod: FishingRod) -> some View {
        let unlocked = rod.isUnlocked(in: state.fishingBook)
        let equipped = state.fishingProgression.selectedRod == rod
        return HStack(spacing: 18) {
            RodIllustration(rod: rod)
                .frame(width: 96, height: 64)
                .saturation(unlocked ? 1 : 0)
                .opacity(unlocked ? 1 : 0.55)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(rod.title).font(.system(size: 16, weight: .semibold))
                    if equipped {
                        Text("使用中").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(rod.appearance).font(.callout).foregroundStyle(.secondary)
                Text(rod.bonus == 0 ? "基础判定块" : "判定块 +\(Int((rod.bonus * 100).rounded())) 个百分点")
                    .font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button(equipped ? "已装备" : unlocked ? "装备" : "未解锁") { state.equipRod(rod) }
                    .disabled(equipped || !unlocked || !state.canEquipRod)
                    .accessibilityIdentifier("equip-rod-" + rod.id)
                Text(rod.requirement(in: state.fishingBook)).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(equipped ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
    }

    private var achievements: some View {
        page("成就", subtitle: "已达成 \(earnedCount) / \(FishingAchievement.allCases.count) · 金牌鱼种 \(state.fishingBook.goldSpeciesCount)") {
            ProgressRing(value: earnedCount, total: FishingAchievement.allCases.count, caption: "已达成")
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(FishingAchievement.allCases) { achievementCard($0) }
            }
        }
        .accessibilityIdentifier("fishing-achievements")
    }

    private func achievementCard(_ achievement: FishingAchievement) -> some View {
        let earned = state.fishingProgression.earned.contains(achievement.id)
        let progress = achievement.progress(in: state.fishingBook)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: earned ? "medal.fill" : "medal")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(earned ? Theme.gold : Color.secondary.opacity(0.6))
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(achievement.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(earned ? "已达成" : "\(progress.current)/\(progress.target)")
                        .font(.caption.monospacedDigit()).foregroundStyle(earned ? Theme.accent : .secondary)
                }
                Text(achievement == .secret && earned ? "已发现未知巨物，资料已收入图鉴" : achievement.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(progress.current), total: Double(max(progress.target, 1)))
                    .tint(earned ? Theme.gold : Theme.accent).controlSize(.small)
            }
        }
        .padding(14)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var tank: some View {
        page("水下观赏", subtitle: "只留每种最大的那一条；移出不丢纪录，更大鱼获会自动更新。") {
            Button { presentation.open() } label: { Label("独立窗口观赏", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("打开水下观赏").accessibilityLabel("打开水下观赏")
        } content: {
            AquariumView(state: state, presentation: presentation)
        }
    }
}

/// One entry in the fish book. Hidden species reveal nothing but that they exist.
struct SpeciesCard: View {
    @ObservedObject var state: AppState
    let species: CatchSpecies
    @State private var showDetail = false
    @State private var hovering = false

    var body: some View {
        let record = state.fishingBook.records[species.id]
        let hidden = species.isHidden(in: state.fishingBook)
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    CatchIllustration(species: species, discovered: record != nil)
                        .frame(maxWidth: .infinity).frame(height: 74)
                        .accessibilityHidden(true)
                    if let record, let medal = species.medal(for: record.largestCM), medal != .normal {
                        MedalBadge(medal: medal).font(.system(size: 15))
                    }
                }
                .padding(.bottom, 4)
                Text(species.guideName(in: state.fishingBook)).font(.system(size: 13, weight: .semibold))
                Text(hidden ? "资料未解锁" : species.timeHint).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                HStack {
                    Text(hidden ? "钓获后揭晓" : record.map { String(format: "最大 %.1f cm", $0.largestCM) } ?? "未钓获")
                    Spacer(minLength: 4)
                    if let record { Text("\(record.count) 次") }
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(hovering ? 0.45 : 0), lineWidth: 1))
            .opacity(record == nil ? 0.82 : 1)
        }
        .buttonStyle(PressableButtonStyle(hoverFill: false))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .popover(isPresented: $showDetail, arrowEdge: .trailing) { SpeciesDetail(state: state, species: species) }
        .accessibilityElement(children: .combine)
    }
}

struct SpeciesDetail: View {
    @ObservedObject var state: AppState
    let species: CatchSpecies
    var body: some View {
        let record = state.fishingBook.records[species.id]
        let hidden = species.isHidden(in: state.fishingBook)
        VStack(alignment: .leading, spacing: 12) {
            CatchIllustration(species: species, discovered: record != nil).frame(height: 118)
            HStack(spacing: 8) {
                Text(species.guideName(in: state.fishingBook)).font(.title3.weight(.semibold))
                if let record, let medal = species.medal(for: record.largestCM), medal != .normal {
                    MedalBadge(medal: medal)
                    Text(medal.title).font(.callout).foregroundStyle(.secondary)
                }
            }
            if hidden {
                Text("资料未解锁，钓获后揭晓。").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    row("出没", species.timeHint)
                    row("体型", String(format: "%g–%g cm", species.minCM, species.maxCM))
                    row("难度", species.difficultyLabel)
                    row("基础概率", String(format: "%.1f%%", species.probability * 100))
                    row("最大纪录", record.map { String(format: "%.1f cm", $0.largestCM) } ?? "—")
                    row("钓获", record.map { "\($0.count) 次" } ?? "未钓获")
                    if species.isFish {
                        row("评级", String(format: "银牌 ≥ %.1f cm · 金牌 ≥ %.1f cm", species.medalThreshold(.silver), species.medalThreshold(.gold)))
                        if let record, species.medal(for: record.largestCM) != .gold {
                            row("距金牌", String(format: "还差 %.1f cm", species.medalThreshold(.gold) - record.largestCM))
                        }
                    }
                }
                .font(.callout)
                if let note = species.discoveryNote {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.formatted()).font(Theme.number(22))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ProgressRing: View {
    let value: Int
    let total: Int
    let caption: String
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.wellStrong, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(value) / CGFloat(total))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value) / \(total)").font(Theme.number(15))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RodIllustration: NSViewRepresentable {
    let rod: FishingRod
    func makeNSView(context: Context) -> RodSpecimenView { RodSpecimenView() }
    func updateNSView(_ view: RodSpecimenView, context: Context) { view.rod = rod; view.needsDisplay = true }
}
final class RodSpecimenView: NSView {
    var rod: FishingRod = .bamboo
    override func draw(_ dirtyRect: NSRect) {
        FishingRodArtwork.draw(rod, start: CGPoint(x: 9, y: 9), tip: CGPoint(x: bounds.width - 9, y: bounds.height - 9), bend: 0)
    }
}
