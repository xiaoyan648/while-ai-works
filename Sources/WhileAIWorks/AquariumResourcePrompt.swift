import SwiftUI

struct AquariumResourcePrompt: View {
    @ObservedObject var resources: AquariumResourceDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "water.waves").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accent)
            Text("开启你的水下世界").font(.title2.weight(.semibold))
            Text("首次开启需要下载鱼缸资源，之后可以离线观赏。已钓到的鱼和收藏记录会一直保留。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if resources.manifest != nil {
                Text("下载约 \(resources.downloadSize) · 安装后占用约 \(resources.installedSize)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            switch resources.status {
            case .downloading(let progress):
                ProgressView(value: progress).tint(Theme.accent)
                HStack {
                    Text("正在下载 · \(Int(progress * 100))%").monospacedDigit()
                    Spacer()
                    Button("取消下载") { resources.cancel() }
                }.font(.callout)
            case .installing:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在校验并安装…") }
                Button("取消") { resources.cancel() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新下载") { resources.download() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            case .missing:
                Button("下载并开启鱼缸") { resources.download() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(resources.manifest == nil)
                if resources.manifest == nil {
                    Text("鱼缸资源信息不可用，请更新应用后重试。").font(.callout).foregroundStyle(.secondary)
                }
            case .ready: EmptyView()
            }
            Text("下载期间可以继续使用小猫、钓鱼和鱼图鉴。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("aquarium-resource-download")
    }
}
