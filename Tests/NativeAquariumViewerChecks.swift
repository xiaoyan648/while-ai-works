import AppKit
import SceneKit
import WhileCore
@main enum NativeAquariumViewerChecks {
 static func main() throws {
  _ = NSApplication.shared
  let p=AquariumPresentation(),host=NSView(frame:NSRect(x:0,y:0,width:330,height:280))
  p.attach(to:host);host.layoutSubtreeIfNeeded();let view=p.view
  precondition(view.aquarium.scene.rootNode.childNode(withName:"generated-aquascape",recursively:true)==nil)
  precondition(view.aquarium.navigation!.field.isOpenWater)
  precondition(view.aquarium.camera.camera?.wantsExposureAdaptation == false,"Transparent surroundings must not alter exposure over time")
  precondition(view.aquarium.scene.rootNode.childNode(withName:"rimless-glass-tank",recursively:true)==nil)
  precondition(view.aquarium.scene.rootNode.childNode(withName:"riverbed",recursively:true) != nil)
  precondition(view.aquarium.scene.background.contents is NSImage)
  var book=FishingBook()
  for id in ["crucian","sardine","perch","trout","salmon"] {book.record(.init(species:CatchSpecies.catalog.first{$0.id==id}!,sizeCM:30))}
  let coldStart=ProcessInfo.processInfo.systemUptime
  view.aquarium.sync(ids:["crucian","sardine","perch","trout","salmon"],book:book,asynchronous:true)
  let submissionMS=(ProcessInfo.processInfo.systemUptime-coldStart)*1000
  precondition(view.aquarium.isPreparing && view.aquarium.node(for:"crucian")==nil,"Cold resource loading must yield before constructing fish")
  var heartbeat=0
  let deadline=Date().addingTimeInterval(8)
  while view.aquarium.isPreparing && Date()<deadline {heartbeat += 1; RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
  precondition(!view.aquarium.isPreparing && view.aquarium.assetError == nil)
  precondition(heartbeat>0)
  print("Cold async submission: \(submissionMS) ms; main run loop serviced \(heartbeat) times")
  // Cancel a cold resource request with an empty aquarium, then replace it while warm-up is in flight.
  var replacementBook=book
  for id in ["eel","puffer"] {replacementBook.record(.init(species:CatchSpecies.catalog.first{$0.id==id}!,sizeCM:30))}
  let alternate=Aquarium3DScene()
  alternate.sync(ids:["eel","puffer"],book:replacementBook,asynchronous:true)
  precondition(alternate.isPreparing)
  alternate.sync(ids:[],book:replacementBook,asynchronous:true)
  alternate.sync(ids:["puffer"],book:replacementBook,asynchronous:true)
  let replacementDeadline=Date().addingTimeInterval(10)
  while alternate.isPreparing && Date()<replacementDeadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
  precondition(!alternate.isPreparing && alternate.assetError==nil)
  precondition(alternate.node(for:"eel")==nil && alternate.node(for:"puffer") != nil,"Stale resource completions must not restore removed fish")
  precondition(Set(alternate.navigation!.agents.keys)==Set(["puffer"]))
  alternate.sync(ids:[],book:replacementBook,asynchronous:true)
  while alternate.isPreparing && Date()<replacementDeadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
  precondition(!alternate.isPreparing && alternate.navigation!.agents.isEmpty,"Removing all residents must also clear the simulation")
  let identity=ObjectIdentifier(view),nav=view.aquarium.navigation!
  for _ in 0..<20 {
   p.open(show:false);p.observationWindow!.contentView!.layoutSubtreeIfNeeded();view.layoutSubtreeIfNeeded()
   precondition(ObjectIdentifier(p.view)==identity && p.view.aquarium.navigation === nav,"Expansion must reuse renderer and simulation")
   precondition(p.observationWindow!.styleMask.contains(.resizable) && view.interactive)
   let position=view.aquarium.camera.simdPosition;p.zoom(1.25)
   precondition(simd_distance(position,view.aquarium.camera.simdPosition)>0.1)
   p.rotate(0.4);precondition(abs(view.cameraYaw-0.38)<0.001)
   view.panCamera(x:0.2,y:0.1);view.focusFish("crucian");precondition(view.cameraZoom>2)
   p.reset();precondition(abs(view.cameraZoom-1)<0.001 && abs(view.cameraYaw)<0.001)
   p.close();precondition(!p.expanded && view.superview===host && !view.interactive)
  }
  p.open(show:false)
  let replacementHost=NSView(frame:NSRect(x:0,y:0,width:330,height:280))
  p.attach(to:replacementHost)
  precondition(p.view.superview !== replacementHost,"A new preview cannot steal the renderer from observation")
  p.close();precondition(p.view.superview === replacementHost,"Closing restores the newest preview host")
  view.frame=NSRect(x:0,y:0,width:1000,height:800);view.resetCamera();view.layoutSubtreeIfNeeded()
  let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=view.aquarium.scene;renderer.pointOfView=view.aquarium.camera
  let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:800),antialiasingMode:.multisampling4X)
  let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
  var magenta=0
  for y in stride(from:0,to:bitmap.pixelsHigh,by:2) {for x in stride(from:0,to:bitmap.pixelsWide,by:2) {
   let pixel=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
   if pixel.alphaComponent>0.9 && pixel.redComponent>0.9 && pixel.blueComponent>0.9 && pixel.greenComponent<0.15 {magenta += 1}
  }}
  precondition(magenta < 8, "Metal shader failure renders magenta water or leaves")
  try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/aquarium-viewer-0.13.png"))
  try FileManager.default.createDirectory(atPath:"docs/optimization-0.13.0",withIntermediateDirectories:true)
  for (name,yaw) in [("front",Float(0)),("left",Float(-0.38)),("right",Float(0.38)),("three-quarter",Float(0.20))] {
   view.resetCamera();view.orbitCamera(yaw:yaw-view.cameraYaw,pitch:0)
   precondition(abs(view.aquarium.camera.simdWorldTransform.columns.0.y)<0.0001,"Orbit and reset must preserve a level horizon")
   let shot=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:800),antialiasingMode:.multisampling4X)
   let checked=NSBitmapImageRep(data:shot.tiffRepresentation!)!
   var failedPixels=0
   for py in stride(from:0,to:checked.pixelsHigh,by:4) {for px in stride(from:0,to:checked.pixelsWide,by:4) {
    let color=checked.colorAt(x:px,y:py)!.usingColorSpace(.deviceRGB)!
    if color.redComponent>0.9 && color.blueComponent>0.9 && color.greenComponent<0.15 {failedPixels += 1}
   }}
   precondition(failedPixels<8,"Every camera angle must render without shader fallback")
   for (theme,color) in [("light",NSColor(srgbRed:0.95,green:0.955,blue:0.945,alpha:1)),("dark",NSColor(srgbRed:0.09,green:0.12,blue:0.13,alpha:1))] {
    let composite=NSImage(size:NSSize(width:1000,height:800));composite.lockFocus()
    color.setFill();NSRect(x:0,y:0,width:1000,height:800).fill()
    shot.draw(in:NSRect(x:0,y:0,width:1000,height:800))
    composite.unlockFocus()
    let rep=NSBitmapImageRep(data:composite.tiffRepresentation!)!
    try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"docs/optimization-0.13.0/aquarium-\(name)-\(theme).png"))
   }
  }
  view.renderingRequested=false;precondition(!view.isPlaying,"Inactive preview must stop rendering")
  print("NativeAquariumViewerChecks: async preparation, 20 reopen cycles reuse one renderer and simulation, zoom/orbit/pan/focus/reset, resize and preview restoration passed")
 }
}
