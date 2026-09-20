import AppKit
import SceneKit
import WhileCore

@main enum NativeHabitatChecks {
    static func main() throws {
        _ = NSApplication.shared
        let view=AquariumSCNView(frame:NSRect(x:0,y:0,width:1000,height:680))
        var book=FishingBook()
        let ids=["crucian","sardine","perch","trout","salmon"]
        for id in ids {book.record(.init(species:CatchSpecies.catalog.first{$0.id==id}!,sizeCM:30))}
        view.aquarium.sync(ids:ids,book:book);view.resetCamera()
        let camera=view.aquarium.camera
        let far=camera.childNode(withName:"habitat-distance",recursively:false)!
        let near=camera.childNode(withName:"habitat-foreground",recursively:false)!
        let light=camera.childNode(withName:"habitat-light",recursively:false)!
        let particles=camera.childNode(withName:"habitat-particles",recursively:false)!
        precondition(particles.childNodes.count==18)
        for node in [far,near,light]+particles.childNodes {
            precondition(node.geometry?.firstMaterial?.writesToDepthBuffer==false)
            precondition(view.aquarium.fishID(for:node)==nil,"Scenery cannot be mistaken for a selectable fish")
        }
        let texture=near.geometry!.firstMaterial!.diffuse.contents as! NSImage
        let rep=NSBitmapImageRep(data:texture.tiffRepresentation!)!
        for y in stride(from:0,to:rep.pixelsHigh,by:13) {
            for x in stride(from:rep.pixelsWide*4/10,to:rep.pixelsWide*6/10,by:13) {
                precondition(rep.colorAt(x:x,y:y)!.alphaComponent<0.025,"The swimming centre must remain clear")
            }
        }
        let original=view.aquarium.node(for:"crucian")!.simdPosition
        view.orbitCamera(yaw:0.38,pitch:0.14);view.panCamera(x:3,y:1.45)
        precondition(abs(near.simdPosition.x/near.simdScale.x)>abs(far.simdPosition.x/far.simdScale.x),"Foreground must respond more than distance")
        precondition(view.aquarium.node(for:"crucian")!.simdPosition==original,"Camera parallax cannot reposition fish")
        let directory=URL(fileURLWithPath:"docs/underwater-layered-0.13.0")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
        func snapshot(_ name:String) throws {
            let shot=renderer.snapshot(atTime:0,with:view.bounds.size,antialiasingMode:.multisampling4X)
            let bitmap=NSBitmapImageRep(data:shot.tiffRepresentation!)!
            var magenta=0
            for y in stride(from:0,to:bitmap.pixelsHigh,by:4) {for x in stride(from:0,to:bitmap.pixelsWide,by:4) {
                let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if c.redComponent>0.9 && c.blueComponent>0.9 && c.greenComponent<0.15 {magenta += 1}
            }}
            precondition(magenta<8,"New water/plant shaders must render without Metal fallback")
            try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
        }
        for (name,width,height) in [("preview",330,280),("portrait",640,900),("wide",1440,650),("front",1000,680)] {
            view.frame=NSRect(x:0,y:0,width:width,height:height);view.resetCamera()
            try snapshot(name)
            for direction:Float in [-1,1] {
                view.resetCamera();view.orbitCamera(yaw:direction*0.38,pitch:direction*0.3);view.panCamera(x:direction*3,y:direction*3);view.zoomCamera(2.6)
                let h=2*tan(Float(camera.camera!.fieldOfView)*Float.pi/360)*1.5
                let w=h*Float(width)/Float(height)
                precondition(far.simdScale.x/2-abs(far.simdPosition.x)>=w/2 && far.simdScale.y/2-abs(far.simdPosition.y)>=h/2,"Extreme camera poses must not reveal a background seam")
            }
        }
        view.resetCamera();view.aquarium.advance(0)
        for i in 1...180 {view.aquarium.advance(Double(i)/60)}
        try snapshot("flow")
        view.orbitCamera(yaw:-0.38,pitch:0.08);try snapshot("left")
        view.resetCamera();view.orbitCamera(yaw:0.38,pitch:-0.10);try snapshot("right")
        let time=near.geometry!.value(forKey:"flowTime") as! Float
        let point=particles.childNodes[5].simdPosition
        view.aquarium.reduceMotion=true
        for i in 181...240 {view.aquarium.advance(Double(i)/60)}
        precondition(near.geometry!.value(forKey:"flowTime") as! Float==time && particles.childNodes[5].simdPosition==point,"Reduce Motion freezes plants, lighting and particles")
        view.renderingRequested=false;precondition(!view.isPlaying)
        view.tearDown()
        print("NativeHabitatChecks: transparent centre, parallax, camera limits at four sizes, native shader renders, Reduce Motion and stopped playback passed.")
    }
}
