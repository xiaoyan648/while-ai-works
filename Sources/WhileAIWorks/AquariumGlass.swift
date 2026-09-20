import AppKit
import SceneKit
import simd

enum AquariumLayout {
    static let minimum = SIMD3<Float>(-3.84, 0.30, -2.65)
    static let maximum = SIMD3<Float>(3.84, 4.95, 2.65)
    static let sceneryScale = SIMD3<Float>(0.93, 0.90, 0.82)
    static let sceneryPosition = SIMD3<Float>(0, 0.08, -0.97)
    static func sceneryPoint(_ p: SIMD3<Float>) -> SIMD3<Float> { p * sceneryScale + sceneryPosition }
}

/// An open riverbed seen through water. The habitat has no glass shell or pedestal.
enum AquariumGlass {
    static func install(in scene: SCNScene) {
        scene.background.contents = backdrop()
        scene.fogColor = NSColor(srgbRed:0.10,green:0.27,blue:0.27,alpha:1)
        scene.fogStartDistance = 15; scene.fogEndDistance = 38
        let floor = SCNPlane(width:60,height:60)
        let sand = SCNMaterial(); sand.lightingModel = .physicallyBased
        sand.diffuse.contents = NSColor(srgbRed:0.38,green:0.43,blue:0.32,alpha:1)
        sand.roughness.contents = 1
        sand.shaderModifiers = [.surface:"""
        #pragma arguments
        float flowTime;
        #pragma body
        float3 p=(scn_frame.inverseViewTransform*float4(_surface.position,1.0)).xyz;
        float grain=fract(sin(dot(floor(p*210.0),float3(12.9898,78.233,41.17)))*43758.5453);
        float a=sin(p.x*3.4+p.z*2.8+flowTime*0.36);
        float b=sin(p.x*2.2-p.z*4.1-flowTime*0.24);
        float ripple=pow(max(0.0,1.0-abs(a+b)*2.0),5.0);
        _surface.diffuse.rgb *= 0.92+grain*0.07+ripple*0.19;
        """]
        sand.writesToDepthBuffer=false
        sand.shaderModifiers?[.fragment]="""
        #pragma transparent
        #pragma body
        float3 bedWorld=(scn_frame.inverseViewTransform*float4(_surface.position,1.0)).xyz;
        float opacity=smoothstep(-5.0,-1.0,bedWorld.z)*(1.0-smoothstep(1.5,6.0,bedWorld.z))*0.32;
        _output.color.a *= opacity;
        _output.color.rgb *= opacity;
        """
        floor.materials=[sand];floor.setValue(Float(0),forKey:"flowTime")
        let bed=SCNNode(geometry:floor);bed.name="riverbed";bed.eulerAngles.x = -.pi/2;bed.position.y=0.21
        scene.rootNode.addChildNode(bed)
        let water=SCNPlane(width:60,height:60)
        let surface=SCNMaterial();surface.lightingModel = .constant;surface.isDoubleSided=true
        surface.writesToDepthBuffer=false
        surface.shaderModifiers=[.fragment:"""
        #pragma arguments
        float flowTime;
        #pragma transparent
        #pragma body
        float2 uv=_surface.diffuseTexcoord*35.0;
        float wave=sin(uv.x*2.1+uv.y*1.3+flowTime*0.28)*cos(uv.y*3.0-flowTime*0.19);
        float glow=smoothstep(0.7,1.0,wave);
        float edgeFade=smoothstep(0.0,0.12,_surface.diffuseTexcoord.x)*smoothstep(0.0,0.12,_surface.diffuseTexcoord.y)*smoothstep(0.0,0.12,1.0-_surface.diffuseTexcoord.x)*smoothstep(0.0,0.12,1.0-_surface.diffuseTexcoord.y);
        float alpha=glow*0.04*edgeFade;
        _output.color=float4(float3(0.46,0.73,0.64)*alpha,alpha);
        """]
        water.materials=[surface];water.setValue(Float(0),forKey:"flowTime")
        let top=SCNNode(geometry:water);top.name="water-surface";top.eulerAngles.x = -.pi/2;top.position.y=7.8
        top.renderingOrder=20;top.castsShadow=false;scene.rootNode.addChildNode(top)
        installLayers(in:scene)
    }

    // Camera-aligned image layers keep the illustrated composition intact at every window size.
    // Their different, bounded offsets suggest depth without moving collision geometry or fish.
    private static func installLayers(in scene:SCNScene) {
        guard let camera=scene.rootNode.childNode(withName:"aquarium-camera",recursively:false) else{return}
        func layer(_ name:String,image:Any,order:Int)->SCNNode {
            let material=SCNMaterial();material.lightingModel = .constant
            material.diffuse.contents=image;material.writesToDepthBuffer=false;material.readsFromDepthBuffer=false
            material.isDoubleSided=true;material.transparencyMode = .aOne
            let plane=SCNPlane(width:1,height:1);plane.materials=[material]
            let node=SCNNode(geometry:plane);node.name=name;node.renderingOrder=order
            node.castsShadow=false;camera.addChildNode(node);return node
        }
        _ = layer("habitat-distance",image:backdrop(),order:-100)
        if let image=texture("underwater-foreground-v2.png") {
            let foreground=layer("habitat-foreground",image:image,order:40)
            foreground.opacity=0.70
            (foreground.geometry as? SCNPlane)?.widthSegmentCount=32
            (foreground.geometry as? SCNPlane)?.heightSegmentCount=12
            foreground.geometry?.shaderModifiers=[.geometry:"""
            #pragma arguments
            float flowTime;
            #pragma body
            float tip=clamp(_geometry.position.y+0.5,0.0,1.0);
            _geometry.position.x += sin(flowTime*0.48+_geometry.position.x*5.0)*tip*tip*0.0035;
            """]
            foreground.geometry?.setValue(Float(0),forKey:"flowTime")
        }
        let glow=layer("habitat-light",image:NSColor.white,order:30)
        glow.geometry?.firstMaterial?.shaderModifiers=[.fragment:"""
        #pragma arguments
        float flowTime;
        #pragma transparent
        #pragma body
        float2 uv=_surface.diffuseTexcoord;
        float column=uv.x+uv.y*0.20;
        float shafts=pow(max(0.0,sin(column*27.0+sin(flowTime*0.17)*0.24)),12.0);
        float top=pow(1.0-uv.y,1.5);
        float fade=(1.0-smoothstep(0.0,0.76,uv.x))*top;
        float light=shafts*fade*0.045;
        float bed=smoothstep(0.65,0.94,uv.y);
        float ripple=sin(uv.x*41.0+uv.y*29.0+flowTime*0.22)+sin(uv.x*23.0-uv.y*36.0-flowTime*0.16);
        float caustic=pow(max(0.0,1.0-abs(ripple)*1.8),5.0)*bed*0.018;
        float alpha=light+caustic;
        _output.color=float4(float3(0.80,0.89,0.67)*alpha,alpha);
        """]
        glow.geometry?.firstMaterial?.setValue(Float(0),forKey:"flowTime")
        let particles=SCNNode();particles.name="habitat-particles";camera.addChildNode(particles)
        let mote=SCNPlane(width:1,height:1),material=SCNMaterial()
        material.lightingModel = .constant;material.diffuse.contents=NSColor.white
        material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
        material.shaderModifiers=[.fragment:"""
        #pragma transparent
        #pragma body
        float2 p=(_surface.diffuseTexcoord-0.5)*2.0;
        float alpha=pow(max(0.0,1.0-dot(p,p)),3.0)*0.15;
        _output.color=float4(float3(0.75,0.85,0.69)*alpha,alpha);
        """]
        mote.materials=[material]
        for i in 0..<18 {
            let node=SCNNode(geometry:mote);node.name="mote-\(i)";node.renderingOrder=32;node.castsShadow=false
            particles.addChildNode(node)
        }
        layoutLayers(in:scene,aspect:1.5,yaw:0,pitch:0.08,target:SIMD3(0,2.55,0))
        updateLayers(in:scene,time:0)
    }

    static func layoutLayers(in scene:SCNScene,aspect:Float,yaw:Float,pitch:Float,target:SIMD3<Float>) {
        guard let camera=scene.rootNode.childNode(withName:"aquarium-camera",recursively:false),aspect>0 else{return}
        let tangent=tan(Float(camera.camera?.fieldOfView ?? 34)*Float.pi/360)
        let depthShift=yaw*0.055+target.x*0.007
        let vertical=(pitch-0.08)*0.05+(target.y-2.55)*0.006
        func size(_ name:String,distance:Float,cover:Bool=false)->SCNNode? {
            guard let node=camera.childNode(withName:name,recursively:false) else{return nil}
            let h=camera.camera?.usesOrthographicProjection == true ? Float(camera.camera?.orthographicScale ?? 4.5)*2:2*tangent*distance
            let w=h*aspect
            let height=cover ? max(h,w/1.5)*1.12:h
            node.scale=SCNVector3(cover ? height*1.5:w,height,1)
            node.position=SCNVector3(0,0,-distance);return node
        }
        if let far=size("habitat-distance",distance:1.5,cover:true) {
            far.simdPosition.x = -depthShift*far.simdScale.x
            far.simdPosition.y = -vertical*far.simdScale.y
        }
        if let near=size("habitat-foreground",distance:1) {
            // Corner plants occupy the lower half. The middle stays completely transparent.
            let fullHeight=near.simdScale.y
            near.simdScale.x *= 1.13;near.simdScale.y *= 0.58
            near.simdPosition.x = -depthShift*near.simdScale.x*1.8
            near.simdPosition.y = -fullHeight*0.24-vertical*fullHeight*1.8
        }
        _ = size("habitat-light",distance:1.1)
        if let particles=size("habitat-particles",distance:0.9) {
            for (i,node) in particles.childNodes.enumerated() {
                let diameter:Float=0.0025+Float(i%3)*0.0007
                node.scale=SCNVector3(diameter/aspect,diameter,1)
            }
        }
    }

    static func updateLayers(in scene:SCNScene,time:Double) {
        guard let camera=scene.rootNode.childNode(withName:"aquarium-camera",recursively:false) else{return}
        camera.childNode(withName:"habitat-foreground",recursively:false)?.geometry?.setValue(Float(time),forKey:"flowTime")
        camera.childNode(withName:"habitat-light",recursively:false)?.geometry?.firstMaterial?.setValue(Float(time),forKey:"flowTime")
        if let particles=camera.childNode(withName:"habitat-particles",recursively:false) {
            for (i,node) in particles.childNodes.enumerated() {
                let seed=Double(i)*0.61803398875
                let phase=(seed+time*(0.003+Double(i%3)*0.0006)).truncatingRemainder(dividingBy:1)
                node.position=SCNVector3(Float((seed*1.71).truncatingRemainder(dividingBy:1)-0.5+sin(time*0.12+seed*9)*0.012),Float(phase-0.5),0)
                node.opacity=CGFloat(min(1,min(phase,1-phase)*12))
            }
        }
    }

    private static let textures:[String:NSImage] = {
        #if SWIFT_PACKAGE
        let root=Bundle.module.resourceURL
        #else
        let root=Bundle.main.resourceURL
        #endif
        guard let root else{return [:]}
        return Dictionary(uniqueKeysWithValues:["underwater-backdrop-v2.png","underwater-foreground-v2.png","underwater-backdrop.png"].compactMap {name in
            NSImage(contentsOf:root.appendingPathComponent("AquariumAssets/"+name)).map {(name,$0)}
        })
    }()
    private static func texture(_ name:String)->NSImage? {textures[name]}

    /// Cached scene texture, built once; no full-frame image is used by the fishing field.
    private static func backdrop() -> NSImage {
        if let image=texture("underwater-backdrop-v2.png") ?? texture("underwater-backdrop.png") {return image}

        let size=NSSize(width:1600,height:1000), image=NSImage(size:NSSize(width:1600,height:1000))
        image.lockFocus();defer{image.unlockFocus()}
        NSGradient(colors:[NSColor(srgbRed:0.055,green:0.15,blue:0.16,alpha:1),NSColor(srgbRed:0.16,green:0.36,blue:0.35,alpha:1),NSColor(srgbRed:0.36,green:0.57,blue:0.50,alpha:1)])!.draw(in:NSRect(origin:.zero,size:size),angle:90)
        // Broad, low-contrast light shafts keep the centre quiet and the upper water luminous.
        for i in 0..<5 {
            let x=CGFloat(200+i*240)
            let ray=NSBezierPath();ray.move(to:CGPoint(x:x,y:1000));ray.line(to:CGPoint(x:x+72,y:1000))
            ray.line(to:CGPoint(x:x-190,y:100));ray.line(to:CGPoint(x:x-350,y:100));ray.close()
            NSGraphicsContext.saveGraphicsState();ray.addClip()
            NSGradient(starting:NSColor(srgbRed:0.77,green:0.90,blue:0.73,alpha:0),ending:NSColor(srgbRed:0.77,green:0.90,blue:0.73,alpha:0.10))!.draw(in:NSRect(origin:.zero,size:size),angle:90)
            NSGraphicsContext.restoreGraphicsState()
        }
        for layer in 0..<2 {
            for i in 0..<18 {
                let x=CGFloat((i*157+layer*59)%1700)-50, h=CGFloat(70+(i*71)%190)
                let stem=NSBezierPath();stem.move(to:CGPoint(x:x,y:0))
                stem.curve(to:CGPoint(x:x+18,y:h),controlPoint1:CGPoint(x:x-30,y:h*0.4),controlPoint2:CGPoint(x:x+36,y:h*0.78))
                NSColor(srgbRed:0.08,green:0.23,blue:0.23,alpha:0.12).setStroke();stem.lineWidth=CGFloat(10+layer*7);stem.stroke()
            }
        }
        return image
    }
    static func studioLight() -> NSImage {
        let image=NSImage(size:NSSize(width:512,height:256));image.lockFocus()
        NSGradient(colors:[NSColor(srgbRed:0.10,green:0.22,blue:0.23,alpha:1),NSColor(srgbRed:0.66,green:0.77,blue:0.64,alpha:1)])!.draw(in:NSRect(x:0,y:0,width:512,height:256),angle:90)
        image.unlockFocus();return image
    }
}
