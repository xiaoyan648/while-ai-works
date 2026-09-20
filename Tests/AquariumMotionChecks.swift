import AppKit
import SceneKit
import WhileCore
import simd
@main enum MotionChecks {
 static func main() throws {
  _ = NSApplication.shared
  let view=AquariumSCNView(frame:NSRect(x:0,y:0,width:960,height:600));view.resetCamera()
  var book=FishingBook();let ids=["crucian","sardine","perch","trout","salmon"]
  for id in ids {book.record(.init(species:CatchSpecies.catalog.first{$0.id==id}!,sizeCM:30))}
  view.aquarium.sync(ids:ids,book:book)
  let nav=view.aquarium.navigation!
  var lastDelta:[String:SIMD3<Float>]=[:], reversals=0,maxSpeed:Float=0,maxAngle:Float=0,stops=0
  let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=view.aquarium.scene;renderer.pointOfView=view.aquarium.camera
  try FileManager.default.createDirectory(atPath:".build/underwater-motion",withIntermediateDirectories:true)
  view.aquarium.advance(0)
  for frame in 1...1800 {
   let before=nav.agents;view.aquarium.advance(Double(frame)/30)
   for (id,a) in nav.agents {
    let delta=a.position-before[id]!.position,speed=simd_length(delta)*30
    maxSpeed=max(maxSpeed,speed)
    let angular=2*acos(min(1,abs(simd_dot(a.orientation.vector,before[id]!.orientation.vector))))
    maxAngle=max(maxAngle,angular)
    if let last=lastDelta[id],simd_length(last)>0.0005,simd_length(delta)>0.0005,simd_dot(simd_normalize(last),simd_normalize(delta))<0 {reversals += 1}
    if speed<0.001 {stops += 1}
    lastDelta[id]=delta
   }
   if !CommandLine.arguments.contains("--no-frames") && frame<=240 && frame%2==0 {
    let shot=renderer.snapshot(atTime:Double(frame)/30,with:CGSize(width:960,height:600),antialiasingMode:.multisampling4X)
    let bitmap=NSBitmapImageRep(data:shot.tiffRepresentation!)!
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:String(format:".build/underwater-motion/%04d.png",frame/2)))
   }
  }
  precondition(stops==0,"Every fish must move on every animation tick")
  precondition(reversals==0,"Swimming must not alternate displacement direction between visible frames")
  precondition(maxAngle<0.025,"Body heading must not jump")
  precondition(nav.agents.values.allSatisfy{$0.distanceTravelled>1},"Fish must actually explore")
  let report:[String:Any]=["seconds":60,"fish":5,"directionReversals":reversals,"maxFrameTurnDegrees":maxAngle*180/Float.pi,"maxSpeed":maxSpeed,"stationarySamples":stops,"samples":9000,"distance":nav.agents.mapValues(\.distanceTravelled)]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build/underwater-motion.json"))
  print(report)
 }
}
