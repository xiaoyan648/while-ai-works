import AppKit
import WhileCore

@main enum NativeScreenChecks {
    static func main() {
        _ = NSApplication.shared
        precondition(DesktopScreenChoice.selectedID(preferred:"second",available:["first","second"],primary:"first")=="second")
        precondition(DesktopScreenChoice.selectedID(preferred:"missing",available:["first"],primary:"first")=="first")
        precondition(DesktopScreenChoice.selectedID(preferred:"",available:["first","second"],primary:"second")=="second")
        precondition(DesktopScreenChoice.selectedID(preferred:"",available:[],primary:nil)==nil)
        let suite="WhileAIWorks.ScreenChecks."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set(false,forKey:"desktopEnabled")
        let state=AppState(defaults:defaults),overlay=DesktopOverlay(state:state)
        state.soundEnabled=false;state.followAI = false;state.mode = .fishing
        func settle() {RunLoop.main.run(until:Date().addingTimeInterval(0.08))}
        func visiblePanels()->[DesktopPanel] {NSApp.windows.compactMap{$0 as? DesktopPanel}.filter(\.isVisible)}
        state.desktopEnabled=true;settle()
        for screen in NSScreen.screens {
            state.targetScreenID=DesktopScreenChoice.id(for:screen);settle()
            precondition(visiblePanels().count==1,"Only the chosen display gets an overlay")
            precondition(visiblePanels()[0].frame==screen.visibleFrame,"The overlay uses the chosen monitor's origin and visible frame")
            precondition(defaults.string(forKey:"desktop.targetScreen")==state.targetScreenID)
        }
        state.targetScreenID="disconnected-test-screen";settle()
        precondition(state.selectedScreenUnavailable && state.targetScreenID=="disconnected-test-screen")
        precondition(visiblePanels().count==(NSScreen.screens.isEmpty ? 0:1))
        if let screen=state.targetScreen {precondition(visiblePanels()[0].frame==screen.visibleFrame)}
        state.desktopEnabled=false;settle();precondition(visiblePanels().isEmpty)
        precondition(state.fishingBook.total==0,"Changing monitors must never create fish records")
        withExtendedLifetime(overlay) {}
        print("NativeScreenChecks: persisted selection, primary fallback, disconnected choice retained, one overlay per selected monitor; actual monitors:",NSScreen.screens.map(\.localizedName))
    }
}
