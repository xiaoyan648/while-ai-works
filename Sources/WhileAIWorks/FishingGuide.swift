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

struct FishingGuide: View {
    @ObservedObject var state: AppState
    enum Section: String, CaseIterable { case book = "鱼图鉴", rods = "钓具", achievements = "成就", tank = "水下观赏" }
    @State var section: Section = .book
    @StateObject private var presentation = AquariumPresentation.shared
    private let ink = Color(nsColor: .playInk)
    private let mint = Color(nsColor: .playMint)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("河畔收藏").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(mint)
            HStack(alignment: .firstTextBaseline) {
                Text(section == .book ? "我的鱼图鉴" : section.rawValue).font(.system(size: 23, weight: .semibold))
                Spacer()
                Text(collectionProgress).font(.system(size: 12, design: .monospaced)).foregroundStyle(mint)
            }.padding(.top, 10)
            Picker("收藏视图", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.top, 14)
            if section == .tank { AquariumView(state: state, presentation: presentation) }
            else if section == .rods { rods }
            else if section == .achievements { achievements }
            else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(state.fishingBook.total)").font(.system(size: 31, weight: .medium, design: .rounded)).monospacedDigit()
                Text("总鱼获").font(.system(size: 11)).foregroundStyle(ink.opacity(0.6))
                Spacer()
                Text("鱼 \(state.fishingBook.fishCount) · 杂物 \(state.fishingBook.itemCount)").font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            }.padding(.top, 16)
            Text("指向水面，按住蓄力，松开抛竿。\n浅水偏小鱼，荷叶旁藏杂物，深水偏大鱼。")
                .font(.system(size: 11)).lineSpacing(4).foregroundStyle(ink.opacity(0.6)).padding(.top, 10).padding(.bottom, 16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionTitle("鱼类", detail: "\(CatchSpecies.catalog.filter(\.isFish).count) 种")
                    ForEach(CatchSpecies.catalog.filter(\.isFish)) { row($0) }
                    sectionTitle("水底的奇怪东西", detail: "7 种")
                    ForEach(CatchSpecies.catalog.filter { !$0.isFish }) { row($0) }
                }
            }.accessibilityIdentifier("fishing-guide-list")
            Divider()
            Text("剪影尚未钓获；未知巨物钓获后揭晓。概率为基础占比，水域与昼夜会改变鱼池。")
                .font(.system(size: 10)).lineSpacing(3).foregroundStyle(ink.opacity(0.5)).padding(.top, 12)
            }
        }
        .padding(.horizontal, 22).padding(.top, 45).padding(.bottom, 22)
        .frame(width: 360, height: 688)
        .foregroundStyle(ink).background(Color(red: 0.947, green: 0.945, blue: 0.916))
        .accessibilityIdentifier("fishing-guide")
    }
    private var collectionProgress: String {
        switch section {
        case .rods: return "\(FishingRod.allCases.filter { $0.isUnlocked(in: state.fishingBook) }.count) / \(FishingRod.allCases.count)"
        case .achievements: return "\(FishingAchievement.allCases.filter { state.fishingProgression.earned.contains($0.id) }.count) / \(FishingAchievement.allCases.count)"
        case .book, .tank: return "\(state.fishingBook.discoveredFish) / \(CatchSpecies.catalog.filter(\.isFish).count)"
        }
    }
    private var rods: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("当前装备 · \(state.fishingProgression.selectedRod.title)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(mint)
                Text("累计钓获包含杂物。解锁后永久拥有。\n钓鱼途中暂不能更换钓竿。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                ForEach(FishingRod.allCases) { rod in
                    rodCard(rod)
                }
                Text("增益直接增加判定块占轨道的比例，各阶不叠加。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            }.padding(.vertical, 12)
        }.accessibilityIdentifier("fishing-rods")
    }
    private func rodCard(_ rod: FishingRod) -> some View {
        let unlocked = rod.isUnlocked(in: state.fishingBook)
        let equipped = state.fishingProgression.selectedRod == rod
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RodIllustration(rod: rod).frame(width: 66, height: 50).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(rod.title).font(.system(size: 16, weight: .semibold))
                    Text(rod.appearance).font(.system(size: 10)).foregroundStyle(ink.opacity(0.65))
                    Text(rod.bonus == 0 ? "基础判定块" : "判定块 +\(Int((rod.bonus * 100).rounded())) 个百分点")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(mint)
                }
            }
            HStack {
                Text(rod.requirement(in: state.fishingBook)).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(equipped ? "已装备" : unlocked ? "装备" : "未解锁") { state.equipRod(rod) }
                    .disabled(equipped || !unlocked || !state.canEquipRod)
                    .accessibilityIdentifier("equip-rod-" + rod.id)
            }
        }.padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(mint.opacity(equipped ? 0.10 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mint.opacity(equipped ? 0.55 : 0.15), lineWidth: 1))
    }
    private var achievements: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("已达成 \(FishingAchievement.allCases.filter { state.fishingProgression.earned.contains($0.id) }.count) / \(FishingAchievement.allCases.count) · 金牌鱼种 \(state.fishingBook.goldSpeciesCount)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(mint).padding(.vertical, 16)
                ForEach(FishingAchievement.allCases) { achievement in
                    achievementRow(achievement)
                }
            }
        }.accessibilityIdentifier("fishing-achievements")
    }
    private func achievementRow(_ achievement: FishingAchievement) -> some View {
        let earned = state.fishingProgression.earned.contains(achievement.id)
        let progress = achievement.progress(in: state.fishingBook)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: earned ? "medal.fill" : "medal")
                .font(.system(size: 23)).foregroundStyle(earned ? Color(red: 0.63, green: 0.43, blue: 0.13) : ink.opacity(0.3))
                .frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(achievement.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(earned ? "已达成" : "\(progress.current)/\(progress.target)")
                        .font(.system(size: 10)).foregroundStyle(mint)
                }
                Text(achievement == .secret && earned ? "已发现未知巨物，资料已收入图鉴" : achievement.detail)
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(progress.current), total: Double(progress.target)).tint(mint)
            }
        }.padding(.vertical, 12).accessibilityElement(children: .combine)
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(detail).font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)) }
            .padding(.top, 18).padding(.bottom, 7)
    }
    private func ratingBadge(_ medal: FishingMedal, species: CatchSpecies, largestCM: Double) -> some View {
        let rating = medal == .normal ? "无" : medal.title
        let thresholds = String(format: "银牌 ≥ %.1f cm；金牌 ≥ %.1f cm", species.medalThreshold(.silver), species.medalThreshold(.gold))
        let remaining = medal == .gold ? "" : String(format: "\n距金牌还差 %.1f cm", species.medalThreshold(.gold) - largestCM)
        return HStack(spacing: 3) {
            Text("评级").foregroundStyle(ink.opacity(0.55))
            if medal == .normal {
                Text("无").foregroundStyle(ink.opacity(0.55))
            } else if medal == .silver {
                Image(systemName: "medal.fill")
                    .foregroundStyle(LinearGradient(colors: [
                        Color(white: 0.48), Color(white: 0.78), Color(white: 0.48)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Image(systemName: "medal.fill")
                    .foregroundStyle(Color(red: 0.63, green: 0.43, blue: 0.13))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .fixedSize()
        .help("历史最高评级：" + rating + "\n" + thresholds + remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("历史最高评级：" + rating)
        .accessibilityValue(thresholds + remaining)
    }
    func row(_ species: CatchSpecies) -> some View {
        let record = state.fishingBook.records[species.id]
        let hidden = species.isHidden(in:state.fishingBook)
        return HStack(spacing: 12) {
            CatchIllustration(species: species, discovered: record != nil).frame(width: 84, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(species.guideName(in:state.fishingBook)).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 2)
                    if let record, let medal = species.medal(for: record.largestCM) {
                        ratingBadge(medal, species: species, largestCM: record.largestCM)
                            .padding(.trailing, 5)
                    }
                    Text(record.map { "\($0.count) 次" } ?? "未钓获").font(.system(size: 10)).foregroundStyle(mint)
                }
                if hidden {
                    Text("资料未解锁").font(.system(size:10)).foregroundStyle(ink.opacity(0.7))
                    Text("钓获后揭晓").font(.system(size:10)).foregroundStyle(mint)
                } else {
                Text(species.timeHint).font(.system(size:10, weight: .medium)).foregroundStyle(mint)
                Text(String(format: "%g–%g cm · %@", species.minCM, species.maxCM, species.difficultyLabel))
                    .font(.system(size: 9)).foregroundStyle(ink.opacity(0.5))
                Text(String(format: "基础概率 %.1f%%", species.probability * 100))
                    .font(.system(size: 9)).foregroundStyle(ink.opacity(0.6))
                Text(record.map { String(format: "最大纪录  %.1f cm", $0.largestCM) } ?? "最大纪录  —")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(ink.opacity(record == nil ? 0.3 : 0.8))
                if let note=species.discoveryNote {Text(note).font(.system(size:10)).foregroundStyle(ink.opacity(0.7)).fixedSize(horizontal:false,vertical:true)}
                }
            }
        }.padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
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
