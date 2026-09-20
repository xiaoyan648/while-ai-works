import AppKit
import SceneKit
import simd

/// Generated fish share GPU resources; each aquarium instance owns its skeleton.
/// Original generated Puffer remains on its approved, unchanged asset path.
final class GeneratedFish {
    private struct Asset: Decodable {
        let version: Int
        let positions, normals, uvs, weights: [Float]
        let indices: [UInt32]
        let boneNames: [String]
        let inverseBinds: [[Float]]
        let frames: [[[Float]]]
        let fps: Double
        let length: Double
        let colorTexture: String
        let surfaceTexture: String?
        let normalTexture: String?
        let tangents: [Float]?
        let influenceCount: Int?
        let influenceIndices: [UInt16]?
        init(from decoder:Decoder) throws {
            let f=try MeshFields(decoder)
            version=try f.value(Int.self,"version")
            positions=try f.floats("positions")
            normals=try f.floats("normals")
            uvs=try f.floats("uvs")
            indices=try f.integers("indices")
            colorTexture=try f.value(String.self,"colorTexture")
            surfaceTexture=try f.optional(String.self,"surfaceTexture")
            weights=try f.floats("weights")
            boneNames=try f.value([String].self,"boneNames")
            inverseBinds=try f.value([[Float]].self,"inverseBinds")
            frames=try f.value([[[Float]]].self,"frames")
            fps=try f.value(Double.self,"fps")
            length=try f.value(Double.self,"length")
            normalTexture=try f.optional(String.self,"normalTexture")
            tangents=try f.optionalFloats("tangents")
            influenceCount=try f.optional(Int.self,"influenceCount")
            influenceIndices=try f.optionalIndices("influenceIndices")
        }
    }
    private struct Animation {
        let boneNames:[String];let inverseBinds:[[Float]];let frames:[[[Float]]];let fps:Double;let length:Double;let top:Double
        init(_ a:Asset) { boneNames=a.boneNames;inverseBinds=a.inverseBinds;frames=a.frames;fps=a.fps;length=a.length;top=Double(stride(from:1,to:a.positions.count,by:3).map{a.positions[$0]}.max() ?? 0) }
    }
    private struct Resources {
        let asset: Animation
        let geometry: SCNGeometry
        let weights, indices: SCNGeometrySource
    }
    static let supportedIDs: Set<String> = ["crucian", "carp", "sardine", "perch", "trout", "catfish", "salmon", "eel", "koi", "tuna", "oarfish", "moonfish", "dragon", "arapaima"]
    private static let cacheLock = NSLock()
    private static var cache: [String: Resources] = [:]
    private static var cacheOrder: [String] = []
    let node = SCNNode()
    let meshNode = SCNNode()
    private(set) var boneNodes: [SCNNode] = []
    let length: Double
    let top: Double
    let duration: Double
    private let resources: Resources

    init(id: String) throws {
        guard Self.supportedIDs.contains(id) else { throw CocoaError(.fileNoSuchFile) }
        let resources = try Self.resources(id: id)
        self.resources = resources
        let asset = resources.asset
        length = asset.length
        top = asset.top
        duration = Double(asset.frames.count - 1) / asset.fps
        node.name = id; meshNode.name = "generated-\(id)-skin"
        let skeleton = SCNNode(); skeleton.name = "\(id)-skeleton"
        node.addChildNode(skeleton)
        for name in asset.boneNames {
            let bone = SCNNode(); bone.name = name; skeleton.addChildNode(bone); boneNodes.append(bone)
        }
        meshNode.geometry = resources.geometry
        meshNode.skinner = SCNSkinner(baseGeometry: resources.geometry, bones: boneNodes,
            boneInverseBindTransforms: asset.inverseBinds.map { NSValue(scnMatrix4: SCNMatrix4(Self.matrix($0))) },
            boneWeights: resources.weights, boneIndices: resources.indices)
        meshNode.skinner?.skeleton = skeleton
        node.addChildNode(meshNode)
        update(time: 0)
    }

    func update(time: Double, turn:Float=0) {
        let position = max(0, time).truncatingRemainder(dividingBy: duration) * resources.asset.fps
        let index = min(resources.asset.frames.count - 2, Int(position))
        let fraction = Float(position - Double(index))
        for (boneIndex, node) in boneNodes.enumerated() {
            let a = Self.matrix(resources.asset.frames[index][boneIndex])
            let b = Self.matrix(resources.asset.frames[index + 1][boneIndex])
            let influence=Float(boneIndex)/Float(max(1,boneNodes.count-1))
            let bend=turn*0.035*influence
            node.simdOrientation = simd_quatf(angle:bend,axis:SIMD3<Float>(0,1,0))*simd_slerp(simd_quatf(a), simd_quatf(b), fraction)
            let p = a.columns.3 + (b.columns.3 - a.columns.3) * fraction
            node.simdPosition = SIMD3(p.x, p.y, p.z + sin(bend)*Float(length)*0.16*influence)
        }
    }

    private static func matrix(_ v: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                               SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
    }

    static func prepare(id: String) throws { _ = try resources(id: id) }
    static func isPrepared(id: String) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[id] != nil
    }

    private static func resources(id: String) throws -> Resources {
        cacheLock.lock()
        if let cached = cache[id] {
            cacheOrder.removeAll { $0 == id }; cacheOrder.append(id)
            cacheLock.unlock(); return cached
        }
        cacheLock.unlock()
        #if SWIFT_PACKAGE
        let root = Bundle.module.resourceURL
        #else
        let root = Bundle.main.resourceURL
        #endif
        guard let folder = root?.appendingPathComponent("AquariumAssets/Generated/\(id)") else { throw CocoaError(.fileNoSuchFile) }
        let a = try PackedMesh.decode(Asset.self, from: folder.appendingPathComponent("fish.json"))
        let count = a.positions.count / 3
        let influences = a.influenceCount ?? 3
        let bones = a.boneNames.count
        guard a.version == 1, count > 0, a.positions.count % 3 == 0,
              a.normals.count == count * 3, a.uvs.count == count * 2, a.weights.count == count * influences, (1...4).contains(influences),
              a.indices.count % 3 == 0, a.indices.allSatisfy({ $0 < count }),
              bones >= 3, bones <= 32, a.inverseBinds.count == bones, a.inverseBinds.allSatisfy({ $0.count == 16 }),
              a.frames.count >= 2, a.frames.allSatisfy({ $0.count == bones && $0.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isFinite) }) }),
              a.fps.isFinite, a.fps > 0, a.length.isFinite, a.length > 0,
              a.positions.allSatisfy(\.isFinite), a.normals.allSatisfy(\.isFinite), a.weights.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let color = NSImage(contentsOf: folder.appendingPathComponent(a.colorTexture)) else { throw CocoaError(.fileReadCorruptFile) }
        let positions = stride(from: 0, to: a.positions.count, by: 3).map { SCNVector3(a.positions[$0], a.positions[$0 + 1], a.positions[$0 + 2]) }
        let normals = stride(from: 0, to: a.normals.count, by: 3).map { SCNVector3(a.normals[$0], a.normals[$0 + 1], a.normals[$0 + 2]) }
        // Blender UVs start at the bottom; SceneKit's NSImage textures start at the top.
        let uv = stride(from: 0, to: a.uvs.count, by: 2).map { CGPoint(x: CGFloat(a.uvs[$0]), y: 1 - CGFloat(a.uvs[$0 + 1])) }
        var sources = [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uv)]
        if let tangents = a.tangents {
            guard tangents.count == count * 4, tangents.allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
            sources.append(tangents.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .tangent, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16) })
        }
        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: a.indices, primitiveType: .triangles)])
        let material = SCNMaterial(); material.name = "Generated \(id) PBR"; material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        if let name = a.normalTexture {
            guard let normal = NSImage(contentsOf: folder.appendingPathComponent(name)) else { throw CocoaError(.fileReadCorruptFile) }
            material.normal.contents = normal
        }
        if let name=a.surfaceTexture {
            guard let surface=NSImage(contentsOf:folder.appendingPathComponent(name)) else {throw CocoaError(.fileReadCorruptFile)}
            material.roughness.contents = surface; material.roughness.textureComponents = .green
            material.metalness.contents = surface; material.metalness.textureComponents = .blue
        } else {material.roughness.contents=0.72;material.metalness.contents=0.06}
        if id == "arapaima" {material.isDoubleSided=true;material.transparencyMode = .aOne}
        for property in [material.diffuse, material.roughness, material.metalness, material.normal] {
            property.minificationFilter = .linear; property.magnificationFilter = .linear; property.mipFilter = .linear
            property.maxAnisotropy = 4
        }
        geometry.materials = [material]
        let boneWeights = a.weights.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .boneWeights, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: influences, bytesPerComponent: 4, dataOffset: 0, dataStride: influences * 4) }
        let indices = a.influenceIndices ?? (0..<count).flatMap { _ in [UInt16(0), UInt16(1), UInt16(2)] }
        guard indices.count == count * influences, indices.allSatisfy({ Int($0) < bones }) else { throw CocoaError(.fileReadCorruptFile) }
        let boneIndices = indices.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .boneIndices, vectorCount: count,
            usesFloatComponents: false, componentsPerVector: influences, bytesPerComponent: 2, dataOffset: 0, dataStride: influences * 2) }
        let result = Resources(asset: Animation(a), geometry: geometry, weights: boneWeights, indices: boneIndices)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let existing = cache[id] { return existing }
        // Current fish retain their own resources even if an older cache entry is evicted.
        // Keep switching through the collection from retaining every 2K texture forever.
        while cacheOrder.count >= 8 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cache[id] = result; cacheOrder.append(id); return result
    }
}
