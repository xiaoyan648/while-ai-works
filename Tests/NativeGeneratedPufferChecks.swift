import AppKit
import SceneKit
import WhileCore

@main enum NativeGeneratedPufferChecks {
    static func main() throws {
        _ = NSApplication.shared
        let puffer = try GeneratedPuffer()
        precondition(puffer.meshNode.geometry!.elements[0].primitiveCount == 95575, "approved geometry retained")
        precondition(puffer.meshNode.skinner!.bones.count == 3)
        let material = puffer.meshNode.geometry!.firstMaterial!
        precondition((material.diffuse.contents as? NSImage)?.size == CGSize(width: 2048, height: 2048))
        precondition(material.roughness.textureComponents == .green && material.metalness.textureComponents == .blue)
        precondition(abs(puffer.duration - 2) < 0.001)
        let head = puffer.boneNodes[0].transform, tail = puffer.boneNodes[2].transform
        puffer.update(time: 0.5)
        precondition(SCNMatrix4EqualToMatrix4(head, puffer.boneNodes[0].transform), "head remains stable")
        precondition(!SCNMatrix4EqualToMatrix4(tail, puffer.boneNodes[2].transform), "Blender tail animation plays")
        puffer.update(time: 2)
        precondition(SCNMatrix4EqualToMatrix4(tail, puffer.boneNodes[2].transform), "loop closes")
        let independent = try GeneratedPuffer()
        independent.update(time: 0.5)
        precondition(SCNMatrix4EqualToMatrix4(tail, puffer.boneNodes[2].transform), "view instances have independent skeletons")

        let preview = Aquarium3DScene(previewOnly: true)
        precondition(preview.assetError == nil)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = preview.scene; renderer.pointOfView = preview.camera
        func save(_ name: String) throws {
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 800), antialiasingMode: .multisampling4X)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name))
        }
        try save("puffer-native-preview.png")
        let tank = Aquarium3DScene()
        precondition(tank.scene.rootNode.childNode(withName:"generated-aquascape",recursively:true)==nil,"Observation uses image scenery without rigid wood or rocks")
        precondition(tank.navigation!.field.isOpenWater,"Removed props must not leave invisible collision obstacles")
        var book = FishingBook()
        let species = CatchSpecies.catalog.first { $0.id == "puffer" }!
        book.record(.init(species: species, sizeCM: 32))
        tank.sync(ids: ["puffer"], book: book)
        let fish = tank.node(for: "puffer")!
        precondition(fish.childNode(withName: "generated-puffer-skin", recursively: true)?.skinner != nil)
        precondition(tank.displayedLengths["puffer"] == 32)
        let originalScale = fish.scale.x
        book.record(.init(species: species, sizeCM: 41))
        tank.sync(ids: ["puffer"], book: book)
        precondition(fish.scale.x > originalScale, "new record resizes the generated model")
        tank.advance(0); tank.advance(0.04)
        let tailNode = fish.childNode(withName: "tail_fin", recursively: true)!
        let animated = tailNode.transform
        tank.reduceMotion = true; tank.advance(0.08)
        precondition(SCNMatrix4EqualToMatrix4(animated, tailNode.transform), "reduced motion freezes bones")
        precondition(tank.fishID(for: fish.childNode(withName: "generated-puffer-skin", recursively: true)!) == "puffer")
        renderer.scene = tank.scene; renderer.pointOfView = tank.camera
        try save("puffer-in-aquarium.png")
        tank.sync(ids: [], book: book)
        precondition(tank.node(for: "puffer") == nil && book.total == 2, "removal does not change collection")
        for id in GeneratedFish.supportedIDs.sorted() {
            let generated = try GeneratedFish(id: id)
            precondition((3...8).contains(generated.meshNode.skinner!.bones.count))
            precondition(generated.meshNode.geometry!.elements[0].primitiveCount <= 60000)
            let material = generated.meshNode.geometry!.firstMaterial!
            precondition(material.diffuse.contents is NSImage && (id == "arapaima" ? material.roughness.contents is NSNumber : material.roughness.contents is NSImage))
            let first = generated.boneNodes[2].transform
            generated.update(time: 0.5)
            precondition(!SCNMatrix4EqualToMatrix4(first, generated.boneNodes[2].transform))
            generated.update(time: 2)
            precondition(SCNMatrix4EqualToMatrix4(first, generated.boneNodes[2].transform))
            let separate = try GeneratedFish(id: id); separate.update(time: 0.5)
            precondition(SCNMatrix4EqualToMatrix4(first, generated.boneNodes[2].transform))
            let species = CatchSpecies.catalog.first { $0.id == id }!
            book = FishingBook()
            book.record(.init(species: species, sizeCM: species.minCM))
            tank.sync(ids: [id], book: book)
            let node = tank.node(for: id)!
            let skin = node.childNode(withName: "generated-\(id)-skin", recursively: true)!
            precondition(skin.skinner != nil && skin.geometry?.shaderModifiers?[.geometry] == nil,
                         "generated fish uses authored skinning, not the old procedural deformation")
            precondition(tank.fishID(for: skin) == id)
            let oldScale = node.scale.x
            book.record(.init(species: species, sizeCM: species.maxCM))
            tank.sync(ids: [id], book: book)
            precondition(node.scale.x >= oldScale && tank.displayedLengths[id] == species.maxCM)
            tank.reduceMotion = false; tank.advance(0.2); tank.advance(0.24)
            let bone = node.childNode(withName: "tail_fin", recursively: true)!
            let transform = bone.transform
            tank.reduceMotion = true; tank.advance(0.28)
            precondition(SCNMatrix4EqualToMatrix4(transform, bone.transform))
            let count = book.total
            try save("\(id)-native-aquarium.png")
            tank.sync(ids: [], book: book)
            precondition(tank.node(for: id) == nil && book.total == count)
        }
        let residentIDs = Array((["crucian", "carp", "sardine", "perch", "trout", "puffer"]).prefix(Aquarium.capacity))
        for id in residentIDs {
            let species = CatchSpecies.catalog.first { $0.id == id }!
            book.record(.init(species: species, sizeCM: 30))
        }
        tank.sync(ids: residentIDs, book: book)
        precondition(residentIDs.allSatisfy { tank.node(for: $0) != nil && !tank.node(for: $0)!.isHidden })
        tank.reduceMotion = false
        try save("generated-fish-six-native.png")
        if CommandLine.arguments.contains("--audit-tank") {
            precondition(tank.assetError == nil)
            precondition(tank.scene.background.contents is NSImage)
            for frame in 0..<900 { tank.advance(100+Double(frame)/30) }
            for (name,position) in [("three-quarter",SCNVector3(7.2,6.2,12.5)),("front",SCNVector3(0,4.1,15)),("rear",SCNVector3(-7.2,6.2,-12.5)),("side",SCNVector3(15,5.5,1))] {
                tank.camera.position=position;tank.camera.look(at:SCNVector3(0,2.05,0))
                try save("aquarium-"+name+".png")
            }
            tank.camera.position=SCNVector3(7.2,6.2,12.5);tank.camera.look(at:SCNVector3(0,2.05,0))
            let image=renderer.snapshot(atTime:30,with:CGSize(width:330,height:280),antialiasingMode:.multisampling4X)
            let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/aquarium-widget.png"))
        }
        if CommandLine.arguments.contains("--render-motion") {
            let directory = URL(fileURLWithPath: ".build/generated-fish-motion")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for frame in 0..<96 {
                tank.advance(100 + Double(frame) / 24)
                let image = renderer.snapshot(atTime: Double(frame) / 24, with: CGSize(width: 900, height: 720), antialiasingMode: .multisampling4X)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "%04d.png", frame)))
            }
        }
        print("NativeGeneratedPufferChecks: approved mesh/textures, skeleton loop, view isolation, collection sizing, reduced motion and native rendering passed.")
    }
}
