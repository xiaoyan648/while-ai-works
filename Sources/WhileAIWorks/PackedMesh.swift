import Foundation

/// Binary vertex streams avoid decoding millions of JSON number tokens on window opening.
enum PackedMesh {
    static let bytesKey = CodingUserInfoKey(rawValue: "aquarium.meshBytes")!
    static func decode<T: Decodable>(_ type: T.Type, from source: URL) throws -> T {
        let stem=source.deletingPathExtension(), metadata=stem.appendingPathExtension("meta.json")
        let decoder=JSONDecoder()
        if FileManager.default.fileExists(atPath: metadata.path) {
            decoder.userInfo[bytesKey]=try Data(contentsOf:stem.appendingPathExtension("meshbin"),options:.mappedIfSafe)
            return try decoder.decode(type,from:Data(contentsOf:metadata))
        }
        return try decoder.decode(type,from:Data(contentsOf:source))
    }
}
struct MeshFields {
    struct Key: CodingKey { let stringValue:String; var intValue:Int? { nil }; init(_ s:String){stringValue=s}; init?(stringValue:String){self.init(stringValue)}; init?(intValue:Int){return nil} }
    struct Range:Decodable { let offset:Int; let count:Int; let type:String }
    let container:KeyedDecodingContainer<Key>
    let bytes:Data?
    let ranges:[String:Range]
    init(_ decoder:Decoder) throws {
        container=try decoder.container(keyedBy:Key.self);bytes=decoder.userInfo[PackedMesh.bytesKey] as? Data
        ranges=try container.decodeIfPresent([String:Range].self,forKey:Key("_buffers")) ?? [:]
    }
    func value<T:Decodable>(_ type:T.Type,_ name:String)throws->T { try container.decode(type,forKey:Key(name)) }
    func optional<T:Decodable>(_ type:T.Type,_ name:String)throws->T? { try container.decodeIfPresent(type,forKey:Key(name)) }
    private func array<T>(_ name:String,type:String,of:T.Type)throws->[T]? {
        guard let r=ranges[name] else{return nil}
        guard let bytes, r.type==type,r.offset>=0,r.count>=0,r.count<=bytes.count/MemoryLayout<T>.stride,r.offset<=bytes.count-r.count*MemoryLayout<T>.stride else {throw CocoaError(.fileReadCorruptFile)}
        return bytes.withUnsafeBytes { raw in
            (0..<r.count).map { raw.loadUnaligned(fromByteOffset:r.offset+$0*MemoryLayout<T>.stride,as:T.self) }
        }
    }
    func floats(_ name:String)throws->[Float] { if let a:[Float]=try array(name,type:"f32",of:Float.self){return a};return try value([Float].self,name) }
    func integers(_ name:String)throws->[UInt32] { if let a:[UInt32]=try array(name,type:"u32",of:UInt32.self){return a};return try value([UInt32].self,name) }
    func optionalFloats(_ name:String)throws->[Float]? { if let a:[Float]=try array(name,type:"f32",of:Float.self){return a};return try optional([Float].self,name) }
    func optionalIndices(_ name:String)throws->[UInt16]? { if let a:[UInt16]=try array(name,type:"u16",of:UInt16.self){return a};return try optional([UInt16].self,name) }
}
