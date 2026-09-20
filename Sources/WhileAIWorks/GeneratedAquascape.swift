import AppKit
import SceneKit

/// Independent textured driftwood and rock assets, plus individually bending leaf blades.
final class GeneratedAquascape {
    private struct Asset: Decodable {
        let version: Int
        let positions, normals, uvs: [Float]
        let indices: [UInt32]
        let colorTexture, surfaceTexture: String
        let normalTexture: String?
        let tangents: [Float]?
        let collisionPositions:[Float];let collisionIndices:[UInt32]
        init(from decoder:Decoder) throws {
            let f=try MeshFields(decoder)
            collisionPositions=try f.optional([Float].self,"collisionPositions") ?? [];collisionIndices=try f.optional([UInt32].self,"collisionIndices") ?? []
            normalTexture=try f.optional(String.self,"normalTexture")
            tangents=try f.optionalFloats("tangents")
            version=try f.value(Int.self,"version")
            positions=try f.floats("positions")
            normals=try f.floats("normals")
            uvs=try f.floats("uvs")
            indices=try f.integers("indices")
            colorTexture=try f.value(String.self,"colorTexture")
            surfaceTexture=try f.value(String.self,"surfaceTexture")
        }
    }
    private struct Props:Decodable {
        struct Part:Decodable {let id,mesh,lowMesh:String}
        let version:Int
        let parts:[Part]
    }
    private static var geometryCache:[(String,SCNGeometry)] = []
    private static var plantGeometry:SCNGeometry?
    private static var collisionCache:AquariumCollisionField?
    private static var points:[SIMD3<Float>] = []
    private static var triangles:[UInt32] = []
    static func collisionField() throws -> AquariumCollisionField {
        if let collisionCache {return collisionCache}
        _ = try makeNode()
        let field=AquariumCollisionField(positions:points,indices:triangles)
        collisionCache=field;return field
    }
    private static func validate(_ a:Asset) throws {
        let count=a.positions.count/3
        guard a.version==1,count>0,a.positions.count%3==0,a.positions.allSatisfy(\.isFinite),
            a.normals.count==count*3,a.normals.allSatisfy(\.isFinite),
            a.uvs.count==count*2,a.uvs.allSatisfy(\.isFinite),
            a.indices.count%3==0,a.indices.allSatisfy({Int($0)<count}) else {throw CocoaError(.fileReadCorruptFile)}
    }
    private static func geometry(_ a:Asset,folder:URL) throws -> SCNGeometry {
        try validate(a)
        guard let color=NSImage(contentsOf:folder.appendingPathComponent(a.colorTexture)),
            let surface=NSImage(contentsOf:folder.appendingPathComponent(a.surfaceTexture)) else {throw CocoaError(.fileReadCorruptFile)}
        let count=a.positions.count/3
        var sources=[
            SCNGeometrySource(vertices:stride(from:0,to:a.positions.count,by:3).map{SCNVector3(a.positions[$0],a.positions[$0+1],a.positions[$0+2])}),
            SCNGeometrySource(normals:stride(from:0,to:a.normals.count,by:3).map{SCNVector3(a.normals[$0],a.normals[$0+1],a.normals[$0+2])}),
            SCNGeometrySource(textureCoordinates:stride(from:0,to:a.uvs.count,by:2).map{CGPoint(x:CGFloat(a.uvs[$0]),y:1-CGFloat(a.uvs[$0+1]))})]
        if let tangents=a.tangents {
            guard tangents.count==count*4,tangents.allSatisfy(\.isFinite) else {throw CocoaError(.fileReadCorruptFile)}
            sources.append(tangents.withUnsafeBytes{SCNGeometrySource(data:Data($0),semantic:.tangent,vectorCount:count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)})
        }
        let geometry=SCNGeometry(sources:sources,elements:[SCNGeometryElement(indices:a.indices,primitiveType:.triangles)])
        let material=SCNMaterial();material.lightingModel = .physicallyBased
        material.diffuse.contents=color
        material.roughness.contents=surface;material.roughness.textureComponents = .green
        material.metalness.contents=0
        material.diffuse.intensity=0.82
        material.roughness.contents=0.88
        if let name=a.normalTexture {
            guard let normal=NSImage(contentsOf:folder.appendingPathComponent(name)) else {throw CocoaError(.fileReadCorruptFile)}
            material.normal.contents=normal;material.normal.intensity=0.28
        }
        material.isDoubleSided=false
        for property in [material.diffuse,material.roughness,material.normal] {
            property.minificationFilter = .linear;property.magnificationFilter = .linear;property.mipFilter = .linear;property.maxAnisotropy=4
        }
        geometry.materials=[material];return geometry
    }
    static func makeNode() throws -> SCNNode {
        if !geometryCache.isEmpty {return decorate()}
        #if SWIFT_PACKAGE
        let root=Bundle.module.resourceURL
        #else
        let root=Bundle.main.resourceURL
        #endif
        guard let folder=root?.appendingPathComponent("AquariumAssets/Aquascape") else {throw CocoaError(.fileNoSuchFile)}
        let props=try JSONDecoder().decode(Props.self,from:Data(contentsOf:folder.appendingPathComponent("props.json")))
        guard props.version==1,Set(props.parts.map(\.id))==Set(["driftwood","rocks"]) else {throw CocoaError(.fileReadCorruptFile)}
        var prepared:[(String,SCNGeometry)]=[]
        var collisionPoints:[SIMD3<Float>]=[];var collisionTriangles:[UInt32]=[]
        func collision(_ positions:[Float],_ indices:[UInt32]) {
            let offset=UInt32(collisionPoints.count)
            collisionPoints += stride(from:0,to:positions.count,by:3).map{SIMD3(positions[$0],positions[$0+1],positions[$0+2])}
            collisionTriangles += indices.map{$0+offset}
        }
        for part in props.parts {
            let path=folder.appendingPathComponent(part.mesh)
            let high=try PackedMesh.decode(Asset.self,from:path)
            let low=try PackedMesh.decode(Asset.self,from:folder.appendingPathComponent(part.lowMesh))
            let mesh=try geometry(high,folder:path.deletingLastPathComponent())
            let preview=try geometry(low,folder:path.deletingLastPathComponent())
            // Share each prop's textures and material between display detail levels.
            preview.materials=mesh.materials
            mesh.levelsOfDetail=[SCNLevelOfDetail(geometry:preview,screenSpaceRadius:150)]
            prepared.append((part.id,mesh))
            // Include both displayed silhouettes. No invisible legacy terrain remains.
            collision(high.positions,high.indices);collision(low.positions,low.indices)
        }
        let plant=try PackedMesh.decode(Asset.self,from:folder.appendingPathComponent("plants.json"))
        try validate(plant)
        guard plant.collisionPositions.count%3==0,plant.collisionPositions.allSatisfy(\.isFinite),plant.collisionIndices.count%3==0,
            plant.collisionIndices.allSatisfy({Int($0)<plant.collisionPositions.count/3}) else {throw CocoaError(.fileReadCorruptFile)}
        collision(plant.collisionPositions,plant.collisionIndices)
        let leaves=SCNGeometry(sources:[
            SCNGeometrySource(vertices:stride(from:0,to:plant.positions.count,by:3).map{SCNVector3(plant.positions[$0],plant.positions[$0+1],plant.positions[$0+2])}),
            SCNGeometrySource(normals:stride(from:0,to:plant.normals.count,by:3).map{SCNVector3(plant.normals[$0],plant.normals[$0+1],plant.normals[$0+2])}),
            SCNGeometrySource(textureCoordinates:stride(from:0,to:plant.uvs.count,by:2).map{CGPoint(x:CGFloat(plant.uvs[$0]),y:CGFloat(plant.uvs[$0+1]))})
        ],elements:[SCNGeometryElement(indices:plant.indices,primitiveType:.triangles)])
        let leaf=SCNMaterial();leaf.lightingModel = .physicallyBased;leaf.diffuse.contents=NSColor(srgbRed:0.17,green:0.37,blue:0.13,alpha:1);leaf.roughness.contents=0.68;leaf.isDoubleSided=true
        leaf.shaderModifiers=[.surface:"""
        #pragma body
        float2 uv=_surface.diffuseTexcoord;
        float vein=exp(-abs(uv.x-0.5)*75.0);
        float ribs=pow(max(0.0,cos(uv.y*90.0+abs(uv.x-0.5)*25.0)),14.0)*0.045;
        _surface.diffuse.rgb=mix(float3(0.08,0.22,0.065),float3(0.26,0.43,0.15),uv.y*0.4+vein*0.45+ribs);
        """]
        leaves.materials=[leaf];leaves.shaderModifiers=[.geometry:"""
        #pragma arguments
        float flowTime;
        #pragma body
        float tip=_geometry.texcoords[0].y;
        _geometry.position.x += sin(flowTime*0.85+_geometry.position.x*3.0)*tip*tip*0.035;
        _geometry.position.z += cos(flowTime*0.6+_geometry.position.z*2.0)*tip*tip*0.022;
        """]
        leaves.setValue(Float(0),forKey:"flowTime");plantGeometry=leaves
        points=collisionPoints;triangles=collisionTriangles;geometryCache=prepared
        return decorate()
    }
    private static func decorate()->SCNNode {
        let node=SCNNode()
        for (id,geometry) in geometryCache {let part=SCNNode(geometry:geometry);part.name=id;node.addChildNode(part)}
        if let plantGeometry {let leaves=SCNNode(geometry:plantGeometry);leaves.name="aquatic-leaves";node.addChildNode(leaves)}
        return node
    }
}
