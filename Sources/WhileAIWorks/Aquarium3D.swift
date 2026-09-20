import AppKit
import SceneKit
import WhileCore
import simd

/// Blender meshes are exported in metres, Y-up. No Blender installation is needed at runtime.
private struct AquariumMeshFile: Decodable {
    struct Material: Decodable { let color: [CGFloat]; let roughness: CGFloat; let metalness: CGFloat }
    struct Mesh: Decodable { let material: String; let vertices: [Float]; let normals: [Float]; let indices: [UInt32] }
    let version: Int
    let materials: [String: Material]
    let meshes: [Mesh]
}

final class Aquarium3DScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private(set) var displayedLengths: [String: Double] = [:]
    private(set) var assetError: String?
    private var fishNodes: [String: SCNNode] = [:]
    private var generatedPuffer: GeneratedPuffer?
    private var generatedFish: [String: GeneratedFish] = [:]
    private let previewOnly: Bool
    private let stateLock=NSRecursiveLock()
    private(set) var navigation: AquariumNavigation?
    private var envelopes: [String: Float] = [:]
    private var collisionShapes: [String:[AquariumBall]] = [:]
    private var clock = 0.0
    private var lastTime: TimeInterval?
    private var swimClocks:[String:Double]=[:]
    private var reduced=false
    var reduceMotion:Bool {
        get {stateLock.lock();defer{stateLock.unlock()};return reduced}
        set {stateLock.lock();defer{stateLock.unlock()};reduced=newValue}
    }
    private(set) var isPreparing=false
    var preparationChanged:((Bool)->Void)?
    private var layoutSignature: String?
    private var layoutGeneration=0
    private var assetGeneration=0
    private var pendingAssets: String?
    private var latestRequest: ([String], FishingBook)?
    private var failedAssets=Set<String>()
    private static let preparationQueue=DispatchQueue(label:"aquarium.layout",qos:.userInitiated)
    private static var meshCache: [String: AquariumMeshFile] = [:]

    init(previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        scene.background.contents = NSColor.clear
        scene.fogStartDistance = 0; scene.fogEndDistance = 0
        scene.lightingEnvironment.contents = AquariumGlass.studioLight()
        scene.lightingEnvironment.intensity = 0.65
        camera.name = "aquarium-camera"; camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 4.5
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 40
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = 0.35
        camera.camera?.bloomIntensity = 0.025
        camera.position = SCNVector3(7.2, 6.2, 12.5)
        camera.look(at: SCNVector3(0, 2.05, 0))
        scene.rootNode.addChildNode(camera)

        light(.ambient, color: NSColor(srgbRed: 0.85, green: 0.89, blue: 0.94, alpha: 1), intensity: 280, position: SCNVector3Zero)
        let key = light(.directional, color: NSColor(srgbRed: 1, green: 0.97, blue: 0.90, alpha: 1), intensity: 950, position: SCNVector3(-3, 7, 4))
        key.look(at: SCNVector3(0, 0, 0))
        key.light?.castsShadow = true; key.light?.shadowRadius = 4
        key.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.light?.shadowColor = NSColor.black.withAlphaComponent(0.24)
        key.light?.orthographicScale = 9; key.light?.shadowBias = 0.04
        let rim = light(.omni, color: NSColor(srgbRed: 0.82, green: 0.89, blue: 1, alpha: 1), intensity: 300, position: SCNVector3(2, 4, -2))
        rim.light?.attenuationStartDistance = 2; rim.light?.attenuationEndDistance = 10

        if previewOnly {
            key.light?.color = NSColor(srgbRed: 1, green: 0.96, blue: 0.90, alpha: 1)
            key.light?.intensity = 650
            rim.light?.intensity = 90
            camera.camera?.exposureOffset = 0
            camera.camera?.orthographicScale = 1.25
            camera.position = SCNVector3(1.4, 0.5, 3.8); camera.look(at: SCNVector3Zero)
            do {
                let fish = try GeneratedPuffer(); generatedPuffer = fish
                fish.node.scale = SCNVector3(1.8, 1.8, 1.8)
                scene.rootNode.addChildNode(fish.node)
            } catch { assetError = "河豚模型加载失败" }
            return
        }

        key.light?.intensity = 650
        rim.light?.intensity = 150
        camera.camera?.exposureOffset = -0.1
        do {
            navigation = AquariumNavigation(field:AquariumCollisionField(positions:[],indices:[]))
            #if SWIFT_PACKAGE
            let resources = Bundle.module.resourceURL!
            #else
            let resources = Bundle.main.resourceURL!
            #endif
            struct Envelope: Decodable { let radius: Float; let spheres: [AquariumBall] }
            let safety = try JSONDecoder().decode([String: Envelope].self, from: Data(contentsOf: resources.appendingPathComponent("AquariumAssets/fish-envelopes.json")))
            envelopes = safety.mapValues(\.radius); collisionShapes = safety.mapValues(\.spheres)
        } catch { assetError = "水下资源加载失败" }
        addTank()
    }

    @discardableResult private func light(_ type: SCNLight.LightType, color: NSColor, intensity: CGFloat, position: SCNVector3) -> SCNNode {
        let node = SCNNode(); node.light = SCNLight(); node.light?.type = type
        node.light?.color = color; node.light?.intensity = intensity; node.position = position
        scene.rootNode.addChildNode(node); return node
    }

    private func load(_ name: String) throws -> SCNNode {
        let file: AquariumMeshFile
        if let cached = Self.meshCache[name] { file = cached }
        else {
            #if SWIFT_PACKAGE
            let root = Bundle.module.resourceURL
            #else
            let root = Bundle.main.resourceURL
            #endif
            guard let root else { throw CocoaError(.fileNoSuchFile) }
            file = try JSONDecoder().decode(AquariumMeshFile.self, from: Data(contentsOf: root.appendingPathComponent("AquariumAssets/Models/\(name).json")))
            guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            Self.meshCache[name] = file
        }
        let parent = SCNNode(); parent.name = name
        for mesh in file.meshes {
            guard mesh.vertices.count == mesh.normals.count, mesh.vertices.count % 3 == 0,
                  mesh.indices.count % 3 == 0, mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count / 3 }),
                  let description = file.materials[mesh.material], description.color.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
            let vertices = stride(from: 0, to: mesh.vertices.count, by: 3).map { SCNVector3(mesh.vertices[$0], mesh.vertices[$0 + 1], mesh.vertices[$0 + 2]) }
            let normals = stride(from: 0, to: mesh.normals.count, by: 3).map { SCNVector3(mesh.normals[$0], mesh.normals[$0 + 1], mesh.normals[$0 + 2]) }
            let uv = vertices.map { CGPoint(x: CGFloat($0.x) * 13, y: CGFloat($0.y) * 23) }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uv)], elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
            let material = SCNMaterial(); material.name = mesh.material
            material.lightingModel = .physicallyBased
            material.diffuse.contents = NSColor(srgbRed: description.color[0], green: description.color[1], blue: description.color[2], alpha: 1)
            material.roughness.contents = description.roughness
            material.metalness.contents = description.metalness
            material.isDoubleSided = true
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.name = mesh.material
            parent.addChildNode(node)
        }
        return parent
    }

    private func addTank() { AquariumGlass.install(in: scene) }

    func layoutScenery(aspect:Float,yaw:Float,pitch:Float,target:SIMD3<Float>) {
        stateLock.lock();defer{stateLock.unlock()}
        guard !previewOnly else{return}
        AquariumGlass.layoutLayers(in:scene,aspect:aspect,yaw:yaw,pitch:pitch,target:target)
    }

    func sync(ids: [String], book: FishingBook, asynchronous: Bool = false) {
        stateLock.lock();defer{stateLock.unlock()}
        guard !previewOnly else { return }
        let eligible = Array(ids.filter { id in CatchSpecies.catalog.contains { $0.id == id && $0.isFish } && book.records[id] != nil }.prefix(Aquarium.capacity))
        latestRequest=(ids,book)
        let assetSignature=eligible.sorted().joined(separator:"|")
        if let pendingAssets {
            if asynchronous && pendingAssets == assetSignature { return }
            assetGeneration += 1; self.pendingAssets=nil
            isPreparing=false; preparationChanged?(false)
        }
        let missing=eligible.filter { id in
            guard fishNodes[id] == nil, !failedAssets.contains(id) else {return false}
            return id == "puffer" ? !GeneratedPuffer.isPrepared() :
                GeneratedFish.supportedIDs.contains(id) && !GeneratedFish.isPrepared(id:id)
        }
        if asynchronous && !missing.isEmpty {
            assetGeneration += 1; let generation=assetGeneration
            layoutGeneration += 1; layoutSignature=nil
            pendingAssets=assetSignature; isPreparing=true; preparationChanged?(true)
            Self.preparationQueue.async { [weak self] in
                var failures=Set<String>()
                for id in missing {
                    do {
                        if id == "puffer" {try GeneratedPuffer.prepare()}
                        else {try GeneratedFish.prepare(id:id)}
                    } catch {failures.insert(id)}
                }
                let failed=failures
                DispatchQueue.main.async { [weak self] in
                    guard let self else {return}
                    self.stateLock.lock();defer{self.stateLock.unlock()}
                    guard self.assetGeneration==generation else {return}
                    self.pendingAssets=nil; self.isPreparing=false
                    self.failedAssets.formUnion(failed)
                    if !failed.isEmpty {self.assetError="部分三维鱼模型加载失败"}
                    if let request=self.latestRequest {self.sync(ids:request.0,book:request.1,asynchronous:true)}
                    self.preparationChanged?(self.isPreparing)
                }
            }
            return
        }
        for id in Array(fishNodes.keys) where !eligible.contains(id) {
            fishNodes.removeValue(forKey: id)?.removeFromParentNode(); displayedLengths.removeValue(forKey: id)
            if id == "puffer" { generatedPuffer = nil }
            generatedFish.removeValue(forKey: id)
        }
        for id in eligible {
            guard !failedAssets.contains(id), let record = book.records[id] else { continue }
            if fishNodes[id] == nil {
                do {
                    let node: SCNNode
                    if id == "puffer" {
                        let fish = try GeneratedPuffer(); generatedPuffer = fish; node = fish.node
                    } else if GeneratedFish.supportedIDs.contains(id) {
                        let fish = try GeneratedFish(id: id); generatedFish[id] = fish; node = fish.node
                    } else { node = try load("fish-" + id) }
                    node.name = id
                    node.enumerateChildNodes { child,_ in
                        for material in child.geometry?.materials ?? [] {
                            material.metalness.intensity=0.12
                            material.normal.intensity=0.45
                            material.shaderModifiers?[.surface]=Self.underwaterShader
                            if material.shaderModifiers == nil {material.shaderModifiers=[.surface:Self.underwaterShader]}
                        }
                    }
                    for child in node.childNodes where id != "puffer" && generatedFish[id] == nil {
                        child.geometry?.shaderModifiers = [.geometry: Self.fishShader]
                        if let materialName = child.name, ["flank", "back", "belly"].contains(where: { materialName.hasSuffix($0) }), !["eel", "catfish", "puffer"].contains(id) {
                            child.geometry?.shaderModifiers?[.surface] = Self.scaleShader
                        }
                        child.geometry?.setValue(Float(0), forKey: "swimPhase")
                    }
                    fishNodes[id] = node; scene.rootNode.addChildNode(node)
                } catch { assetError = "部分三维鱼模型加载失败"; continue }
            }
            let length = CatchSpecies.catalog.first{$0.id==id}!.displayLength(for:record.largestCM)
            // Eels and ribbon fish have longer authored meshes.
            let sourceLength = id == "puffer" ? (generatedPuffer?.length ?? 1) : (generatedFish[id]?.length ?? (["eel", "oarfish"].contains(id) ? 2.75 : 1.95))
            let scale = Float(length / sourceLength)
            fishNodes[id]?.scale = SCNVector3(scale, scale, scale)
            displayedLengths[id] = record.largestCM
        }
        do {
            let radii = try Dictionary(uniqueKeysWithValues: fishNodes.map { id, node in
                guard let radius = envelopes[id] else { throw CocoaError(.fileReadCorruptFile) }
                return (id, radius * Float(node.scale.x) + 0.14)
            })
            let shapes = Dictionary(uniqueKeysWithValues: fishNodes.map { id, node in
                let scale = Float(node.scale.x)
                return (id,(collisionShapes[id] ?? []).map { AquariumBall(center:$0.center*scale,radius:$0.radius*scale+0.12) })
            })
            let signature=radii.keys.sorted().map { $0+":"+String(radii[$0]!.bitPattern) }.joined(separator:"|")
            if signature == layoutSignature { return }
            layoutSignature=signature;layoutGeneration += 1
            if asynchronous, let field=navigation?.field {
                let generation=layoutGeneration
                isPreparing=true;preparationChanged?(true)
                for node in fishNodes.values { node.isHidden=true }
                Self.preparationQueue.async { [weak self] in
                    let prepared=AquariumNavigation(field:field)
                    let result=Result { try prepared.configure(radii:radii,shapes:shapes) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else{return}
                        self.stateLock.lock();defer{self.stateLock.unlock()}
                        guard self.layoutGeneration==generation else{return}
                        self.isPreparing=false
                        switch result {
                        case .success:
                            self.navigation=prepared
                            for node in self.fishNodes.values { node.isHidden=false }
                            self.pose()
                        case .failure: self.assetError="鱼缸暂时无法完成布置"
                        }
                        self.preparationChanged?(false)
                    }
                }
                return
            }
            try navigation?.configure(radii: radii, shapes: shapes)
            for node in fishNodes.values { node.isHidden = false }
        } catch {
            assetError = "鱼缸安全游动空间不足"
            for node in fishNodes.values { node.isHidden = true }
        }
        pose()
    }

    func advance(_ time: TimeInterval) {
        stateLock.lock();defer{stateLock.unlock()}
        defer { lastTime = time }
        guard let lastTime, !reduceMotion, !isPreparing else { return }
        let dt = min(0.05, max(0, time - lastTime))
        clock += dt
        navigation?.advance(Float(dt))
        for (id,agent) in navigation?.agents ?? [:] {
            let speed=Double(simd_length(agent.velocity))
            swimClocks[id,default:Double(id.utf8.reduce(0){$0+Int($1)}%11)*0.17] += dt*(0.24+min(0.36,speed*1.7))
        }
        pose()
    }

    private func pose() {
        SCNTransaction.begin();SCNTransaction.disableActions=true
        defer {SCNTransaction.commit()}
        generatedPuffer?.update(time: previewOnly ? clock*0.45 : swimClocks["puffer",default:0],turn:navigation?.agents["puffer"]?.turn ?? 0)
        for (id, fish) in generatedFish { fish.update(time:swimClocks[id,default:0],turn:navigation?.agents[id]?.turn ?? 0) }
        if previewOnly { return }
        AquariumGlass.updateLayers(in:scene,time:clock)
        for (id, node) in fishNodes {
            guard let agent = navigation?.agents[id] else { continue }
            node.simdPosition = agent.position
            node.simdOrientation = agent.orientation*simd_quatf(angle:agent.turn*0.045,axis:SIMD3<Float>(1,0,0))
        }
        scene.rootNode.childNode(withName:"riverbed",recursively:true)?.geometry?.setValue(Float(clock),forKey:"flowTime")
        if let water=scene.rootNode.childNode(withName:"water-surface",recursively:true)?.geometry {
            water.setValue(Float(clock),forKey:"flowTime");water.firstMaterial?.setValue(Float(clock),forKey:"flowTime")
        }
    }

    func fishID(for node: SCNNode) -> String? {
        stateLock.lock();defer{stateLock.unlock()}
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, fishNodes[name] != nil { return name }
            current = n.parent
        }
        return nil
    }
    func node(for id: String) -> SCNNode? { stateLock.lock();defer{stateLock.unlock()};return fishNodes[id] }

    private static let underwaterShader="""
    #pragma body
    float3 world = (scn_frame.inverseViewTransform * float4(_surface.position,1.0)).xyz;
    // Transform the renderer-provided view direction for the active camera projection.
    float3 ray = normalize((scn_frame.inverseViewTransform * float4(_surface.view,0.0)).xyz);
    float3 edge = mix(float3(-3.845,0.10,-2.65),float3(3.845,4.95,2.65),step(float3(0.0),ray));
    float3 travel = abs(edge-world)/max(abs(ray),float3(0.0001));
    float depth = max(0.0,min(travel.x,min(travel.y,travel.z)));
    float tint = clamp(1.0-exp(-depth*0.085),0.0,0.32);
    _surface.roughness=max(_surface.roughness,0.56);
    _surface.metalness=min(_surface.metalness,0.16);
    _surface.diffuse.rgb=mix(_surface.diffuse.rgb,float3(0.11,0.30,0.27),tint);
    """
    private static let fishShader = """
    #pragma arguments
    float swimPhase;
    #pragma body
    float x = _geometry.position.x;
    float w = pow(clamp((0.35-x)/1.6, 0.0, 1.0), 1.65);
    _geometry.position.z += sin(swimPhase+x*3.8)*w*0.13;
    """
    private static let causticsShader = """
    #pragma arguments
    float flowTime;
    #pragma body
    float3 world = (scn_frame.inverseViewTransform * float4(_surface.position,1.0)).xyz;
    float c = sin(world.x*6.0+flowTime) + sin(world.z*8.0-flowTime*0.7);
    float glow = pow(max(0.0, c*0.5), 10.0);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb,float3(0.11,0.27,0.22),0.16)*(1.0+glow*0.10);
    """
    private static let scaleShader = """
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float stagger = fmod(floor(uv.y), 2.0)*0.5;
    float2 cell = float2(fract(uv.x+stagger)-0.5, fract(uv.y)*0.85);
    float rim = 1.0-smoothstep(0.015, 0.065, abs(length(cell)-0.53));
    _surface.diffuse.rgb *= 1.0-rim*0.14;
    """
}

final class AquariumSCNView: SCNView, SCNSceneRendererDelegate {
    override var isOpaque: Bool { false }
    let aquarium: Aquarium3DScene
    var selectFish: ((String) -> Void)?
    private let frameLock=NSLock()
    private var animationEnabled=false
    var renderingRequested=true { didSet { updatePlayback() } }
    private var observer: NSObjectProtocol?
    private var mouseDownPoint:NSPoint?
    private var lastDragPoint:NSPoint?
    private var dragged=false
    var interactive=false { didSet { preferredFramesPerSecond=60;updatePlayback() } }
    private(set) var cameraYaw:Float=0
    private(set) var cameraPitch:Float=0.08
    private(set) var cameraZoom:Float=1
    private var cameraTarget=SIMD3<Float>(0,2.55,0)
    private var isPreview=false
    private let spinner=NSProgressIndicator()
    override var acceptsFirstResponder:Bool { true }
    override func layout() { super.layout();if !isPreview { applyCamera() } }
    func resetCamera() { cameraYaw=0;cameraPitch=0.08;cameraZoom=1;cameraTarget=SIMD3(0,2.55,0);applyCamera() }
    func zoomCamera(_ factor:Float) { cameraZoom=min(2.6,max(0.9,cameraZoom*factor));applyCamera() }
    func orbitCamera(yaw:Float,pitch:Float) { cameraYaw=min(0.38,max(-0.38,cameraYaw+yaw));cameraPitch=min(0.22,max(-0.06,cameraPitch+pitch));applyCamera() }
    func panCamera(x:Float,y:Float) {
        cameraTarget += SIMD3(cos(cameraYaw)*x,y,-sin(cameraYaw)*x)
        cameraTarget=simd_min(simd_max(cameraTarget,SIMD3(-3,0.4,-1.6)),SIMD3(3,4,1.6));applyCamera()
    }
    func focusFish(_ id:String) { if let node=aquarium.node(for:id) {cameraTarget=node.simdPosition;cameraZoom=2.3;applyCamera()} }
    private func applyCamera() {
        guard bounds.width>0,bounds.height>0,!isPreview else{return}
        let aspect=Float(bounds.width/bounds.height),tangent=tan(Float.pi*34/360)
        let forward=SIMD3<Float>(sin(cameraYaw)*cos(cameraPitch),sin(cameraPitch),cos(cameraYaw)*cos(cameraPitch))
        let right=SIMD3<Float>(cos(cameraYaw),0,-sin(cameraYaw)),up=simd_cross(forward,right)
        var fit:Float=0,nearest:Float=0
        for x:Float in [-4.06,4.06] {for y:Float in [0.05,5.20] {for z:Float in [-2.85,2.85] {
            let q=SIMD3(x,y,z)-cameraTarget,depth=simd_dot(q,forward)
            nearest=max(nearest,depth)
            fit=max(fit,depth+max(abs(simd_dot(q,up))/tangent,abs(simd_dot(q,right))/(tangent*aspect)))
        }}}
        let distance=max(nearest+0.35,fit*0.87/cameraZoom)
        aquarium.camera.camera?.usesOrthographicProjection=false;aquarium.camera.camera?.fieldOfView=34
        aquarium.camera.simdPosition=cameraTarget+forward*distance;aquarium.camera.look(at:SCNVector3(cameraTarget),up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1));needsDisplay=true
        aquarium.layoutScenery(aspect:aspect,yaw:cameraYaw,pitch:cameraPitch,target:cameraTarget)
    }

    override init(frame: NSRect, options: [String: Any]? = nil) {
        aquarium = Aquarium3DScene()
        super.init(frame: frame, options: options)
        configure()
    }
    init(previewFrame: NSRect) {
        isPreview=true
        aquarium = Aquarium3DScene(previewOnly: true)
        super.init(frame: previewFrame, options: nil)
        configure()
        allowsCameraControl = true
        defaultCameraController.target = SCNVector3Zero
    }
    private func configure() {
        scene = aquarium.scene; pointOfView = aquarium.camera;delegate=self
        showsStatistics=CommandLine.arguments.contains("--aquarium-diagnostics")
        preferredFramesPerSecond = 60; antialiasingMode = .multisampling4X
        allowsCameraControl = false; backgroundColor = .clear
        wantsLayer = true; layer?.isOpaque = false; layer?.backgroundColor = NSColor.clear.cgColor
        spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false
        spinner.translatesAutoresizingMaskIntoConstraints=false;addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo:centerXAnchor),spinner.centerYAnchor.constraint(equalTo:centerYAnchor)])
        aquarium.preparationChanged={ [weak self] loading in
            guard let self else{return}
            if loading {self.spinner.startAnimation(nil)} else {self.spinner.stopAnimation(nil)}
            self.updatePlayback();self.needsDisplay=true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.updatePlayback() }
        }
        updatePlayback()
    }
    func updatePlayback() {
        let animate=renderingRequested && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible)==true && !aquarium.reduceMotion && !aquarium.isPreparing
        frameLock.lock();animationEnabled=animate;frameLock.unlock()
        isPlaying=animate
    }
    func renderer(_ renderer:SCNSceneRenderer,updateAtTime time:TimeInterval) {
        frameLock.lock()
        let enabled=animationEnabled;frameLock.unlock()
        // Apply the pose before this frame is rendered, not in a later main-queue task.
        if enabled {aquarium.advance(time)}
    }
    override func mouseDown(with event:NSEvent) {
        if isPreview {super.mouseDown(with:event);return}
        window?.makeFirstResponder(self);mouseDownPoint=event.locationInWindow;lastDragPoint=event.locationInWindow;dragged=false
    }
    override func mouseDragged(with event:NSEvent) {
        if isPreview {super.mouseDragged(with:event);return}
        guard interactive,let old=lastDragPoint,let down=mouseDownPoint else{return}
        let point=event.locationInWindow
        if hypot(point.x-down.x,point.y-down.y)>3 {dragged=true}
        if dragged {
            let dx=Float(point.x-old.x),dy=Float(point.y-old.y)
            if event.modifierFlags.contains(.shift) {panCamera(x:-dx*0.012/cameraZoom,y:-dy*0.012/cameraZoom)}
            else {orbitCamera(yaw:-dx*0.007,pitch:-dy*0.006)}
        }
        lastDragPoint=point
    }
    override func mouseUp(with event:NSEvent) {
        if isPreview {super.mouseUp(with:event);return}
        if !dragged {select(at:event)}
        mouseDownPoint=nil;lastDragPoint=nil
    }
    override func scrollWheel(with event:NSEvent) {if interactive {zoomCamera(exp(Float(event.scrollingDeltaY)*0.018))}else{super.scrollWheel(with:event)}}
    override func magnify(with event:NSEvent) {if interactive {zoomCamera(Float(1+event.magnification))}else{super.magnify(with:event)}}
    override func keyDown(with event:NSEvent) {
        guard interactive else{super.keyDown(with:event);return}
        switch event.keyCode {
        case 35:showsStatistics.toggle()
        case 53:resetCamera()
        case 123:orbitCamera(yaw:-0.12,pitch:0)
        case 124:orbitCamera(yaw:0.12,pitch:0)
        case 125:orbitCamera(yaw:0,pitch:-0.08)
        case 126:orbitCamera(yaw:0,pitch:0.08)
        default:
            if event.characters=="+" || event.characters=="=" {zoomCamera(1.2)}
            else if event.characters=="-" {zoomCamera(0.8)} else{super.keyDown(with:event)}
        }
    }
    private func select(at event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        for hit in hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            if let id = aquarium.fishID(for: hit.node) { selectFish?(id);if event.clickCount==2 && interactive {focusFish(id)}; return }
        }
    }
    func tearDown() {
        frameLock.lock();animationEnabled=false;frameLock.unlock();isPlaying=false;delegate=nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        scene = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
