import SwiftUI
import SceneKit
import WhileCore

private struct AquariumCanvas: NSViewRepresentable {
    let state:AppState
    let presentation:AquariumPresentation
    let select:(String)->Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeNSView(context:Context)->NSView { let host=NSView();presentation.attach(to:host);return host }
    func updateNSView(_ host:NSView,context:Context) {
        presentation.attach(to:host)
        let view=presentation.view
        view.selectFish={ id in
            select(id)
            if let fish=CatchSpecies.catalog.first(where:{$0.id==id}),let record=state.fishingBook.records[id] {
                presentation.selectionLabel=fish.name+String(format:" · %.1f cm · 钓获 %d 次",record.largestCM,record.count)
            }
        };view.aquarium.reduceMotion=reduced
        view.aquarium.sync(ids:state.aquarium.residents,book:state.fishingBook,asynchronous:true)
        view.updatePlayback()
    }
}

struct AquariumView: View {
    @ObservedObject var state: AppState
    @State private var selected: String?
    @State private var replacement: String?
    @ObservedObject var presentation: AquariumPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AquariumCanvas(state: state, presentation: presentation) { selected = $0 }
                .frame(minHeight: 320).frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label("\(state.aquarium.residents.count) / \(Aquarium.capacity)", systemImage: "fish")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
                .overlay { if presentation.expanded { Button("前往观赏窗口") { presentation.open() }.buttonStyle(.bordered) } }
                .overlay { if state.aquarium.residents.isEmpty { Text(state.fishingBook.discoveredFish == 0 ? "钓到的第一条鱼，会住在这里" : "从下方收藏选择鱼入住").font(.callout).foregroundStyle(.secondary) } }
                .accessibilityLabel("水下观赏，\(state.aquarium.residents.count) 条鱼；可通过下方列表选择")
            if let id = selected, let fish = CatchSpecies.catalog.first(where: { $0.id == id }), let record = state.fishingBook.records[id] {
                HStack {
                    Text(fish.name + String(format: " · %.1f cm", record.largestCM)).font(.headline)
                    Spacer()
                    Text("钓获 \(record.count) 次").font(.callout).foregroundStyle(.secondary)
                }
            } else { Text("点击鱼查看纪录，或从下方选择入住").font(.callout).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(CatchSpecies.catalog.filter { $0.isFish && state.fishingBook.records[$0.id] != nil }) { fish in
                    let resident = state.aquarium.residents.contains(fish.id)
                    HStack(spacing: 10) {
                        Button { selected = fish.id } label: {
                            HStack(spacing: 8) {
                                CatchIllustration(species: fish, discovered: true).frame(width: 56, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fish.name).font(.system(size: 13, weight: .medium))
                                    Text(String(format: "%.1f cm", state.fishingBook.records[fish.id]!.largestCM))
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                        Spacer(minLength: 4)
                        if resident {
                            Button("移出") { state.removeFromAquarium(fish.id) }
                        } else {
                            Button("放入") {
                                if state.aquarium.residents.count == Aquarium.capacity { replacement = fish.id }
                                else { state.putInAquarium(fish.id) }
                            }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(10)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(resident ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
                }
            }
        }
        .onAppear { presentation.previewVisible=true }
        .onDisappear { presentation.previewVisible=false }
        .sheet(isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("观赏名额已满，替换哪一条？").font(.headline)
                ForEach(state.aquarium.residents, id: \.self) { id in
                    Button(CatchSpecies.catalog.first { $0.id == id }?.name ?? id) {
                        if let new = replacement { state.putInAquarium(new, replacing: id); selected = new }
                        replacement = nil
                    }
                }
                Button("取消") { replacement = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 270)
        }
    }
}
