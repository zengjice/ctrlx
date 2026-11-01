import CSQLite
import Foundation

/// Confined to RelayAccessService's single-thread NIO pool. SQLite also serializes
/// transactions against the local administrator process using BEGIN IMMEDIATE.
final class RelaySQLite: @unchecked Sendable {
    enum Value: Sendable {
        case text(String)
        case integer(Int64)
        case null
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open Relay database"
            if let handle {
                sqlite3_close(handle)
            }
            self.handle = nil
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try query("PRAGMA journal_mode=WAL")
        try query("PRAGMA synchronous=FULL")
        try query("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw failure() }
        self.handle = nil
    }

    @discardableResult
    func query(_ sql: String, _ values: [Value] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case let .integer(integer): result = sqlite3_bind_int64(statement, index, integer)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [[String: String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                var row: [String: String] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    if let text = sqlite3_column_text(statement, index) {
                        row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
                    }
                }
                rows.append(row)
            default: throw failure()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try query("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try query("COMMIT")
            return result
        } catch {
            do { try query("ROLLBACK") }
            catch { throw Failure(description: "Relay database rollback failed: \(error)") }
            throw error
        }
    }

    private func failure() -> Failure {
        Failure(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Relay database closed")
    }
}
