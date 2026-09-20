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
    @State private var showingTank = false
    @StateObject private var presentation = AquariumPresentation.shared
    private let ink = Color(nsColor: .playInk)
    private let mint = Color(nsColor: .playMint)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("河畔收藏").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(mint)
            HStack(alignment: .firstTextBaseline) {
                Text(showingTank ? "水下观赏" : "我的鱼图鉴").font(.system(size: 23, weight: .semibold))
                Spacer()
                Text("\(state.fishingBook.discoveredFish) / \(CatchSpecies.catalog.filter(\.isFish).count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(mint)
            }.padding(.top, 10)
            Picker("收藏视图", selection: $showingTank) {
                Text("鱼图鉴").tag(false); Text("水下观赏").tag(true)
            }.pickerStyle(.segmented).padding(.top, 14)
            if showingTank { AquariumView(state: state, presentation: presentation) } else {
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
    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(detail).font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)) }
            .padding(.top, 18).padding(.bottom, 7)
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
