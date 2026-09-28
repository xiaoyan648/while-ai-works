import AppKit
import SwiftUI
import SceneKit
import WhileCore

@main enum NativeMysteryChecks {
    static func main() throws {
        setbuf(stdout,nil);_ = NSApplication.shared
        let suite="WhileAIWorks.MysteryChecks."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let state=AppState(defaults:defaults)
        state.desktopEnabled=false;state.mode = .fishing;state.followAI = false;state.soundEnabled=false
        let secret=CatchSpecies.catalog.first(where: \.isSecret)!
        let directory=URL(fileURLWithPath:"docs/beach-mystery-0.13.0")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func entry(_ name:String) throws {
            let host=NSHostingView(rootView:SpeciesCard(state:state,species:secret).frame(width:190).padding(16).background(Color(nsColor:.windowBackgroundColor)))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:222,height:190),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host
            host.frame=NSRect(x:0,y:0,width:222,height:190);host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.03))
            let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds)!
            host.cacheDisplay(in:host.bounds,to:rep)
            try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("secret-\(name).png"))
            var visited=Set<ObjectIdentifier>()
            func strings(_ node:NSObject)->[String] {
                guard visited.insert(ObjectIdentifier(node)).inserted else{return []}
                var result:[String]=[]
                for key in ["accessibilityLabel","accessibilityValue"] {
                    let selector=NSSelectorFromString(key)
                    if node.responds(to:selector),let value=node.perform(selector)?.takeUnretainedValue() as? String {result.append(value)}
                }
                let selector=NSSelectorFromString("accessibilityChildren")
                if node.responds(to:selector),let children=node.perform(selector)?.takeUnretainedValue() as? [NSObject] {for child in children {result += strings(child)}}
                return result
            }
            let text=strings(host).joined(separator:" ")
            try text.write(to:directory.appendingPathComponent("secret-\(name)-accessibility.txt"),atomically:true,encoding:.utf8)
            if text.isEmpty {
                print("Accessibility tree unavailable offscreen: \(name). Row bitmap saved for visual inspection.")
            } else if name=="locked" {
                precondition(text.contains("未知巨物"))
                precondition(!text.contains(secret.name) && !text.contains(secret.timeHint) && !text.contains("cm") && !text.contains("%"),"Locked guide must not leak identity, time, size, or probability")
            } else {precondition(text.contains(secret.name) && text.contains(secret.timeHint),"A recorded catch reveals the full entry")}
            window.close()
        }
        precondition(secret.guideName(in:state.fishingBook)=="未知巨物")
        try entry("locked")
        let play=PlayView(state:state);play.frame=NSRect(x:0,y:0,width:860,height:310)
        state.desktopEnabled=true;state.interactionHeld=true;state.area = .edges
        func picture(_ name:String) throws {
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1720,pixelsHigh:620,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            let c=NSGraphicsContext.current!.cgContext;c.scaleBy(x:2,y:2)
            play.drawFishing(at:state.fishingReward.map {$0.caughtAt+0.5} ?? ProcessInfo.processInfo.systemUptime,context:c)
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("giant-\(name).png"))
        }
        func bite() {
            state.reset();state.castStartedAt=ProcessInfo.processInfo.systemUptime-3
            state.finishCast(at:ProcessInfo.processInfo.systemUptime-2,landing:CGPoint(x:0.63,y:0.76),water:.deep,origin:CGPoint(x:0.8,y:0.6))
            let period=state.fishingEnvironment.period
            func weight(_ s:CatchSpecies)->Double {s.weight*FishingWater.deep.multiplier(for:s)*s.timeMultiplier(in:period)}
            let total=CatchSpecies.catalog.reduce(0){$0+weight($1)},before=CatchSpecies.catalog.prefix{$0.id != secret.id}.reduce(0){$0+weight($1)}
            var rolls=[0.0,(before+weight(secret)/2)/total,0.9]
            for _ in 0..<22 {state.advanceFishing(delta:0.1,random:{rolls.isEmpty ? 0.99:rolls.removeFirst()})}
            precondition(state.fishing.phase == .bite && state.fishing.catchResult?.species.id == secret.id)
        }
        bite();precondition(secret.isHidden(in:state.fishingBook));try picture("bite")
        for _ in 0..<82 {state.advanceFishing(delta:0.1,random:{0.5})}
        precondition(state.fishing.phase == .escaped && secret.isHidden(in:state.fishingBook),"Seeing or losing a giant must not reveal its name")
        bite();state.fishingPress();state.fishingRelease();try picture("fight")
        var previous=state.fishing.bar
        for _ in 0..<1950 {
            let velocity=(state.fishing.bar-previous)*30;previous=state.fishing.bar
            if state.fishing.bar+velocity*0.24<state.fishing.fish {if !state.fishing.pressed {state.fishingPress()}} else {state.fishingRelease()}
            state.advanceFishing(delta:1/30,random:{0.5})
            if state.fishing.phase == .landed || state.fishing.phase == .escaped {break}
        }
        precondition(state.fishing.phase == .landed && state.fishingBook.records[secret.id]?.count==1)
        precondition(state.aquarium.residents.contains(secret.id) && state.fishingReward?.title == "未知巨物揭晓！")
        precondition(FishingBook.load(defaults:defaults).records[secret.id]?.count==1,"Unlock persists without rewriting existing save schema")
        try picture("landed");try entry("revealed")
        let tank=AquariumSCNView(frame:NSRect(x:0,y:0,width:960,height:600))
        tank.aquarium.sync(ids:[secret.id],book:state.fishingBook);tank.resetCamera();tank.focusFish(secret.id)
        precondition(tank.aquarium.assetError==nil && tank.aquarium.node(for:secret.id) != nil)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=tank.scene;renderer.pointOfView=tank.aquarium.camera
        let image=renderer.snapshot(atTime:0,with:CGSize(width:960,height:600),antialiasingMode:.multisampling4X)
        try NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("giant-underwater.png"))
        state.desktopEnabled=false
        print("NativeMysteryChecks: locked/revealed guide rendered; failed encounter stays hidden; full giant catch, reveal, persistence and 3D observation passed. Accessibility coverage is reported separately above.")
    }
}
