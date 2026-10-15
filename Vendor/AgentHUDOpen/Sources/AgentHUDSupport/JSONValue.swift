import Foundation

/// A Sendable JSON value that preserves integer precision.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    /// Reads JSON text directly into values, many times faster than through `Decodable`, which tries each type in turn
    /// and throws on each miss. It gives what `JSONDecoder` gives: a number written whole, or with a fraction of zeros
    /// or an exponent, is an integer when it fits Int64, and a repeated key keeps its first value. Text it does not
    /// take, such as one with a byte order mark, a trailing comma or bytes that are not UTF-8, goes to `JSONDecoder`.
    public static func parse(_ data: Data) throws -> Self {
        let parsed: Self? = data.withUnsafeBytes { buffer in
            var parser = JSONParser(bytes: buffer.bindMemory(to: UInt8.self))
            guard let value = try? parser.value(depth: 0) else { return nil }
            parser.skipSpace()
            return parser.index == parser.bytes.count ? value : nil
        }
        return try parsed ?? JSONDecoder().decode(Self.self, from: data)
    }

    public static func from<T: Encodable>(_ value: T) throws -> Self {
        try parse(RecordCoding.encoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: RecordCoding.encoder().encode(self))
    }
}

/// JSON's grammar over UTF-8 bytes, into `JSONValue`s.
private struct JSONParser {
    /// Text the parser does not take, which `JSONDecoder` then reads or rejects itself.
    struct Malformed: Error {}

    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
    }

    mutating func value(depth: Int) throws -> JSONValue {
        skipSpace()
        guard index < bytes.count, depth < 512 else { throw Malformed() }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var object: [String: JSONValue] = [:]
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed() }
                index += 1
                let member = try value(depth: depth + 1)
                if object.index(forKey: key) == nil { object[key] = member }
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "}") else { throw Malformed() }
                index += 1
                return .object(object)
            }
        case UInt8(ascii: "["):
            index += 1
            var array: [JSONValue] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            while true {
                array.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "]") else { throw Malformed() }
                index += 1
                return .array(array)
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    mutating func literal(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        guard bytes.count - index >= count, memcmp(bytes.baseAddress! + index, word.utf8Start, count) == 0 else { throw Malformed() }
        index += count
    }

    /// The string starting at the opening quote.
    mutating func string() throws -> String {
        index += 1
        let start = index
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let raw = UnsafeBufferPointer(rebasing: bytes[start..<index])
                let text = String(decoding: raw, as: UTF8.self)
                // Text that is not UTF-8 is not repaired here.
                guard ascii || text.utf8.elementsEqual(raw) else { throw Malformed() }
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { break }
            guard byte >= 0x20 else { throw Malformed() }
            if byte >= 0x80 { ascii = false }
            index += 1
        }
        // Escaped: rebuilt byte by byte from where the plain run stopped.
        var utf8 = Array(bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                let text = String(decoding: utf8, as: UTF8.self)
                guard text.utf8.elementsEqual(utf8) else { throw Malformed() }
                return text
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw Malformed() }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex()
                    if (0xD800..<0xDC00).contains(scalar) {
                        guard bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw Malformed() }
                        index += 2
                        let low = try hex()
                        guard (0xDC00..<0xE000).contains(low) else { throw Malformed() }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00..<0xE000).contains(scalar) { throw Malformed() }
                    guard let unicode = Unicode.Scalar(scalar) else { throw Malformed() }
                    utf8.append(contentsOf: unicode.utf8)
                default: throw Malformed()
                }
            default:
                guard byte >= 0x20 else { throw Malformed() }
                utf8.append(byte)
            }
        }
        throw Malformed()
    }

    mutating func hex() throws -> UInt32 {
        guard bytes.count - index >= 4 else { throw Malformed() }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw Malformed()
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    /// JSON's number grammar. A whole number within Int64 is an integer however it is written, as `JSONDecoder` reads
    /// it; any other is a Double.
    mutating func number() throws -> JSONValue {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else { throw Malformed() }
        if bytes[index] == UInt8(ascii: "0") { index += 1 } else { while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 } }
        let integerEnd = index
        var zeroFraction = true, exponent = false
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                if bytes[index] != UInt8(ascii: "0") { zeroFraction = false }
                index += 1
            }
            guard index > digits else { throw Malformed() }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            exponent = true
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digits else { throw Malformed() }
        }
        // Written whole, or with a fraction of zeros: an integer when its digits fit, exactly as written.
        if !exponent, zeroFraction,
           let integer = Int64(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<integerEnd]), as: UTF8.self)) {
            return .integer(integer)
        }
        guard let double = Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)),
              double.isFinite else { throw Malformed() }
        if exponent, let integer = Int64(exactly: double) { return .integer(integer) }
        return .number(double)
    }
}
