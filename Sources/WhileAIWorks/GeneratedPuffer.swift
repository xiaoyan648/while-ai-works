import AppKit
import SceneKit
import simd

/// Uses the approved Blender mesh, UVs, PBR images and sampled three-bone animation.
final class GeneratedPuffer {
    private struct Asset: Decodable {
        let version: Int
        let positions, normals, uvs, weights: [Float]
        let indices: [UInt32]
        let boneNames: [String]
        let inverseBinds: [[Float]]
        let frames: [[[Float]]]
        let fps: Double
        let length: Double
        let colorTexture, surfaceTexture: String
        init(from decoder:Decoder) throws {
            let f=try MeshFields(decoder)
            version=try f.value(Int.self,"version")
            positions=try f.floats("positions")
            normals=try f.floats("normals")
            uvs=try f.floats("uvs")
            indices=try f.integers("indices")
            colorTexture=try f.value(String.self,"colorTexture")
            surfaceTexture=try f.value(String.self,"surfaceTexture")
            weights=try f.floats("weights")
            boneNames=try f.value([String].self,"boneNames")
            inverseBinds=try f.value([[Float]].self,"inverseBinds")
            frames=try f.value([[[Float]]].self,"frames")
            fps=try f.value(Double.self,"fps")
            length=try f.value(Double.self,"length")
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
    private static let cacheLock = NSLock()
    private static var cached: Resources?
    let node = SCNNode()
    let meshNode = SCNNode()
    private(set) var boneNodes: [SCNNode] = []
    let length: Double
    let duration: Double
    private let resources: Resources

    init() throws {
        let resources = try Self.resources()
        self.resources = resources
        let asset = resources.asset
        length = asset.length; duration = Double(asset.frames.count - 1) / asset.fps
        node.name = "puffer"; meshNode.name = "generated-puffer-skin"
        let skeleton = SCNNode(); skeleton.name = "puffer-skeleton"
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

    static func prepare() throws { _ = try resources() }
    static func isPrepared() -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cached != nil
    }

    private static func resources() throws -> Resources {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        #if SWIFT_PACKAGE
        let root = Bundle.module.resourceURL
        #else
        let root = Bundle.main.resourceURL
        #endif
        guard let folder = root?.appendingPathComponent("AquariumAssets/Puffer") else { throw CocoaError(.fileNoSuchFile) }
        let a = try PackedMesh.decode(Asset.self, from: folder.appendingPathComponent("puffer.json"))
        let count = a.positions.count / 3
        guard a.version == 1, count > 0, a.positions.count % 3 == 0,
              a.normals.count == count * 3, a.uvs.count == count * 2, a.weights.count == count * 3,
              a.indices.count % 3 == 0, a.indices.allSatisfy({ $0 < count }),
              a.boneNames.count == 3, a.inverseBinds.count == 3, a.inverseBinds.allSatisfy({ $0.count == 16 }),
              a.frames.count >= 2, a.frames.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isFinite) }) }),
              a.fps > 0, a.length > 0,
              let color = NSImage(contentsOf: folder.appendingPathComponent(a.colorTexture)),
              let surface = NSImage(contentsOf: folder.appendingPathComponent(a.surfaceTexture)) else { throw CocoaError(.fileReadCorruptFile) }
        let positions = stride(from: 0, to: a.positions.count, by: 3).map { SCNVector3(a.positions[$0], a.positions[$0 + 1], a.positions[$0 + 2]) }
        let normals = stride(from: 0, to: a.normals.count, by: 3).map { SCNVector3(a.normals[$0], a.normals[$0 + 1], a.normals[$0 + 2]) }
        // Blender UVs start at the bottom; SceneKit's NSImage textures start at the top.
        let uv = stride(from: 0, to: a.uvs.count, by: 2).map { CGPoint(x: CGFloat(a.uvs[$0]), y: 1 - CGFloat(a.uvs[$0 + 1])) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uv)], elements: [SCNGeometryElement(indices: a.indices, primitiveType: .triangles)])
        let material = SCNMaterial(); material.name = "TRELLIS Puffer PBR"; material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = surface; material.roughness.textureComponents = .green
        material.metalness.contents = surface; material.metalness.textureComponents = .blue
        for property in [material.diffuse, material.roughness, material.metalness] {
            property.minificationFilter = .linear; property.magnificationFilter = .linear; property.mipFilter = .linear
            property.maxAnisotropy = 4
        }
        geometry.materials = [material]
        let boneWeights = a.weights.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .boneWeights, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12) }
        let indices = (0..<count).flatMap { _ in [UInt16(0), UInt16(1), UInt16(2)] }
        let boneIndices = indices.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .boneIndices, vectorCount: count,
            usesFloatComponents: false, componentsPerVector: 3, bytesPerComponent: 2, dataOffset: 0, dataStride: 6) }
        let result = Resources(asset: Animation(a), geometry: geometry, weights: boneWeights, indices: boneIndices)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return cached }
        cached = result; return result
    }
}
