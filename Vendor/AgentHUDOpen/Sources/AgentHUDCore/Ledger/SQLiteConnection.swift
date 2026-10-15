import Foundation
import SQLite3

/// A read-write SQLite connection confined to one actor. Prepared statements are reused by SQL text.
final class SQLiteConnection {
    enum Value: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
        case integer(Int64), real(Double), text(String), blob(Data), null

        init(integerLiteral value: Int64) { self = .integer(value) }
        init(stringLiteral value: String) { self = .text(value) }
        init(nilLiteral: ()) { self = .null }
        static func int(_ value: Int) -> Value { .integer(Int64(value)) }
        static func nullable(_ value: String?) -> Value { value.map { .text($0) } ?? .null }
        static func nullable(_ value: Int64?) -> Value { value.map { .integer($0) } ?? .null }
    }

    struct Failure: Error, LocalizedError {
        let code: Int32
        let message: String
        var errorDescription: String? { "SQLite \(code): \(message)" }
    }

    struct Row {
        fileprivate let statement: OpaquePointer
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard !isNull(column), let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        func blob(_ column: Int32) -> Data? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }

    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `nil` opens a private in-memory database.
    init(url: URL?) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url?.path ?? ":memory:", &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close_v2(opened) }
            throw Failure(code: result, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw Failure(code: result, message: message)
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure(result) }
    }

    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw failure(result) }
            try row(Row(statement: statement))
        }
    }

    /// Runs `body` in one immediate transaction; any thrown error rolls every statement back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_clear_bindings(statement)
        } else {
            var created: OpaquePointer?
            let result = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &created, nil)
            guard result == SQLITE_OK, let created else { throw failure(result) }
            statements[sql] = created
            statement = created
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let string): result = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .blob(let data) where data.isEmpty: result = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
        return statement
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
