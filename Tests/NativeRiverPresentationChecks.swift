import AppKit
import WhileCore

/// Uses production drawing and gameplay with isolated records; never posts system input.
@main enum NativeRiverPresentationChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.RiverPresentation." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let state=AppState(defaults:defaults)
        state.mode = .fishing; state.area = .fullScreen; state.followAI = false
        state.soundEnabled=false; state.desktopEnabled=true; state.interactionHeld=true
        let view=PlayView(state:state)
        view.frame=NSRect(x:0,y:0,width:860,height:310)
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        for width:CGFloat in [330,860,1440] {
            for x in stride(from:CGFloat(20),to:width-20,by:17) {
                precondition(!RiverScenery.contains(CGPoint(x:x,y:RiverScenery.near(x,width)-1),width:width))
                precondition(!RiverScenery.contains(CGPoint(x:x,y:RiverScenery.far(x,width)+1),width:width))
                precondition(RiverScenery.contains(RiverScenery.clamp(CGPoint(x:x,y:20),width:width),width:width))
                precondition(!RiverScenery.contains(CGPoint(x:x,y:RiverScenery.far(x,width)-2),width:width),"The nearly transparent edge cannot intercept desktop clicks")
            }
            precondition(!RiverScenery.contains(CGPoint(x:width-30,y:20),width:width),"The small beach is not a water landing target")
            let x=width*0.6,y=RiverScenery.far(x,width)
            precondition(RiverScenery.edgeOpacity(CGPoint(x:x,y:y+2),width:width)==0)
            precondition(RiverScenery.edgeOpacity(CGPoint(x:x,y:y-4),width:width)<0.2)
            precondition(RiverScenery.edgeOpacity(CGPoint(x:x,y:y-60),width:width)>0.99)
        }
        func render(_ name:String) throws {
            state.refreshFishingEnvironment(date:Date(timeIntervalSince1970:(name.hasPrefix("night") ? 22:name == "dusk" ? 18:12)*3600),calendar:calendar)
            let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1720,pixelsHigh:620,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:image)
            let context=NSGraphicsContext.current!.cgContext
            context.scaleBy(x:2,y:2)
            NSColor(srgbRed:0.945,green:0.95,blue:0.94,alpha:1).setFill();view.bounds.fill()
            let now=ProcessInfo.processInfo.systemUptime
            view.drawFishing(at:now,context:context)
            NSGraphicsContext.restoreGraphicsState()
            let directory=URL(fileURLWithPath:"docs/beach-mystery-0.13.0")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try image.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("river-\(name).png"))
        }
        for mode in [FishingTimeMode.day,.night] {
            state.reset()
            try render(mode.rawValue)
            state.fishingPress()
            state.castReleasedAt=ProcessInfo.processInfo.systemUptime-2
            for _ in 0..<22 {state.advanceFishing(delta:0.1,random:{0})}
            precondition(state.fishing.phase == .bite)
            try render(mode.rawValue+"-bite")
            state.fishingPress();state.fishingRelease()
            precondition(state.fishing.phase == .fighting)
            try render(mode.rawValue+"-fight")
            state.fishingAccessiblePress();precondition(state.fishing.pressed,"Accessibility press must sustain upward input")
            state.advanceFishing(delta:0.1,random:{0.5});precondition(state.fishing.pressed)
            state.fishingAccessiblePress();precondition(!state.fishing.pressed,"Next accessibility activation must release")
        }
        state.reset()
        state.refreshFishingEnvironment(date:Date(timeIntervalSince1970:18*3600),calendar:calendar)
        try render("dusk")
        precondition(state.fishingBook.total == 0 && state.totalStrikes == 0,"Presentation checks cannot create records")
        state.desktopEnabled=false
        print("NativeRiverPresentationChecks: day/night/dusk plus bite/fight presentation rendered using production code and isolated preferences.")
    }
}
