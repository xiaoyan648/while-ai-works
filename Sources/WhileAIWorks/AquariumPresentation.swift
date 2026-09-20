import AppKit
import SwiftUI

/// Move one live renderer between the preview and its own resizable window.
final class AquariumPresentation: NSObject, ObservableObject, NSWindowDelegate {
    // Survives switching away from fishing while the independent window is open.
    static let shared = AquariumPresentation()
    @Published private(set) var expanded=false
    @Published var selectionLabel="点击鱼查看纪录 · 双击聚焦"
    var previewVisible=false { didSet { storedView?.renderingRequested = expanded || previewVisible } }
    private(set) var observationWindow:NSWindow?
    private var storedView:AquariumSCNView?
    weak var previewHost:NSView?
    var view:AquariumSCNView {
        if let storedView { return storedView }
        let result=AquariumSCNView(frame:.zero);storedView=result;return result
    }
    func attach(to host:NSView) {
        previewHost=host
        if !expanded { install(view,in:host) }
    }
    private func install(_ view:NSView,in parent:NSView) {
        if view.superview === parent {return}
        view.removeFromSuperview();view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor),view.topAnchor.constraint(equalTo:parent.topAnchor),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor)])
    }
    func open(show:Bool=true) {
        if let observationWindow { observationWindow.makeKeyAndOrderFront(nil);return }
        let visible=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:min(1040,visible.width-60),height:min(780,visible.height-60)),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="河湾 · 水下观赏";window.identifier=NSUserInterfaceItemIdentifier("aquarium-observation")
        window.minSize=NSSize(width:640,height:480);window.collectionBehavior=[.fullScreenPrimary]
        window.backgroundColor=NSColor(srgbRed:0.10,green:0.23,blue:0.23,alpha:1)
        window.isReleasedWhenClosed=false;window.delegate=self;window.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+2)
        let content=NSView();window.contentView=content
        let toolbar=NSHostingView(rootView:AquariumToolbar(presentation:self));toolbar.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(toolbar)
        let viewport=NSView();viewport.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(viewport)
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo:content.topAnchor),toolbar.leadingAnchor.constraint(equalTo:content.leadingAnchor),toolbar.trailingAnchor.constraint(equalTo:content.trailingAnchor),toolbar.heightAnchor.constraint(equalToConstant:76),viewport.topAnchor.constraint(equalTo:toolbar.bottomAnchor),viewport.leadingAnchor.constraint(equalTo:content.leadingAnchor),viewport.trailingAnchor.constraint(equalTo:content.trailingAnchor),viewport.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        observationWindow=window;expanded=true;view.renderingRequested=true;view.interactive=true;install(view,in:viewport);view.resetCamera()
        window.center();if show {window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)};view.updatePlayback()
    }
    func close() { observationWindow?.close() }
    func zoom(_ factor:Float) { view.zoomCamera(factor) }
    func reset() { view.resetCamera() }
    func rotate(_ radians:Float) { view.orbitCamera(yaw:radians,pitch:0) }
    func fullScreen() { observationWindow?.toggleFullScreen(nil) }
    func windowWillClose(_ notification:Notification) {
        view.removeFromSuperview();observationWindow?.contentView=nil;observationWindow=nil
        expanded=false;view.renderingRequested=previewVisible;view.interactive=false;view.resetCamera()
        if let previewHost { install(view,in:previewHost) };view.updatePlayback()
    }
    deinit { storedView?.tearDown() }
}
private struct AquariumToolbar:View {
    @ObservedObject var presentation:AquariumPresentation
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
        HStack(spacing:9) {
            Text(presentation.selectionLabel).font(.system(size:12)).lineLimit(1)
            Spacer(minLength:4)
            Button {presentation.rotate(-.pi/8)} label:{Image(systemName:"rotate.left")}.help("向左旋转").accessibilityLabel("向左旋转")
            Button {presentation.rotate(.pi/8)} label:{Image(systemName:"rotate.right")}.help("向右旋转").accessibilityLabel("向右旋转")
            Button {presentation.zoom(0.8)} label:{Image(systemName:"minus.magnifyingglass")}.help("缩小").accessibilityLabel("缩小画面")
            Button {presentation.zoom(1.25)} label:{Image(systemName:"plus.magnifyingglass")}.help("放大").accessibilityLabel("放大水下画面")
            Button("复位视角") {presentation.reset()}
            Button {presentation.fullScreen()} label:{Image(systemName:"arrow.up.left.and.arrow.down.right")}.help("全屏").accessibilityLabel("全屏观赏")
        }.buttonStyle(.bordered).controlSize(.small)
        Text("拖动调整视角 · 滚轮 / 捏合缩放 · Shift 拖动平移 · Esc 复位").font(.system(size:11)).foregroundStyle(.secondary)
        }.padding(.horizontal,16).foregroundStyle(Color(red:0.87,green:0.93,blue:0.88)).preferredColorScheme(.dark)
    }
}
