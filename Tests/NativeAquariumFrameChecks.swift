import AppKit
import SceneKit
import WhileCore

/// A real, visible SCNView. Records render callbacks, not offline snapshot throughput.
private final class FrameProbe:NSObject,SCNSceneRendererDelegate {
    let view:AquariumSCNView
    private let lock=NSLock()
    private var last:Double?
    private var first:Double?
    private var ages:[Double]=[]
    private var intervals:[Double]=[]
    private var stale=0
    init(_ view:AquariumSCNView) {self.view=view}
    func renderer(_ renderer:SCNSceneRenderer,updateAtTime time:TimeInterval) {
        let active=view.isPlaying
        let before=view.aquarium.node(for:"crucian")!.simdPosition
        view.renderer(renderer,updateAtTime:time)
        let after=view.aquarium.node(for:"crucian")!.simdPosition
        lock.lock();defer{lock.unlock()}
        guard active && view.isPlaying else {last=nil;return}
        if first == nil {first=time}
        if let last,time-last>0 {
            intervals.append(time-last);ages.append(time-first!)
            if simd_distance(before,after)<0.000001 {stale += 1}
        }
        last=time
    }
    func report()->[String:Any]? {
        lock.lock();defer{lock.unlock()}
        let sorted=intervals.sorted()
        print("Live probe callbacks",sorted.count,"unchanged",stale)
        guard sorted.count>60 else {return nil}
        precondition(stale==0,"Each render callback must apply its pose before returning")
        let warm=zip(intervals,ages).filter{$0.1>2}.map{$0.0}.sorted()
        guard !warm.isEmpty else {return nil}
        let worstIndex=intervals.indices.max{intervals[$0]<intervals[$1]}!
        return ["worstIntervalAtSecond":ages[worstIndex],"warmCallbacks":warm.count,"warmMeanCallbackFPS":Double(warm.count)/warm.reduce(0,+),"warmP95IntervalMS":warm[Int(Double(warm.count-1)*0.95)]*1000,"warmMaxIntervalMS":warm.last!*1000,"callbacks":sorted.count,"unchangedPoses":stale,"meanCallbackFPS":Double(sorted.count)/sorted.reduce(0,+),"p95IntervalMS":sorted[Int(Double(sorted.count-1)*0.95)]*1000,"maximumIntervalMS":sorted.last!*1000]
    }
}
@main enum NativeAquariumFrameChecks {
    static func main() throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared;NSApp.setActivationPolicy(.regular)
        let view=AquariumSCNView(frame:NSRect(x:0,y:0,width:1000,height:680))
        var book=FishingBook()
        let ids=["crucian","sardine","perch","trout","salmon"]
        for id in ids {book.record(.init(species:CatchSpecies.catalog.first{$0.id==id}!,sizeCM:30))}
        view.aquarium.sync(ids:ids,book:book);view.resetCamera()
        let probe=FrameProbe(view);view.delegate=probe
        let window=NSWindow(contentRect:view.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.level = .floating
        window.isReleasedWhenClosed=false;window.title="游动帧间隔检查 · 自动关闭"
        window.contentView=view;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        // AquariumPresentation also refreshes playback after ordering its window.
        view.updatePlayback()
        RunLoop.main.run(until:Date().addingTimeInterval(8))
        print("Window visible",window.isVisible,"occlusion",window.occlusionState.rawValue,"playing",view.isPlaying)
        view.renderingRequested=false
        guard let report=probe.report() else {
            window.orderOut(nil);window.close()
            print("UNAVAILABLE: the macOS window stayed occluded; no live frame-rate claim can be made from this run.")
            exit(2)
        }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/corner-live-frames.json"))
        window.orderOut(nil);window.close()
        print("NativeAquariumFrameChecks:",report)
    }
}
