import AgentHUDSupport

// App-owned accessors: upstream intentionally keeps its convenience extensions internal.
extension JSONValue {
    var catObject: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var catString: String? { if case .string(let value) = self { return value }; return nil }
    var catArray: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var catBool: Bool? { if case .bool(let value) = self { return value }; return nil }
    subscript(cat key: String) -> JSONValue { catObject?[key] ?? .null }
}
