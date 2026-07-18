import Foundation
import MdictKit
import SQLite3

private let SQLITE_TRANSIENT_IDX = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// On-disk headword index for one dictionary, so the app doesn't hold every
/// headword string in RAM (the memory hog for large MDX files). Built once
/// per dictionary next to its files; reused on later launches. After it's
/// built, MdictFile.releaseKeyStrings() frees the in-memory strings and the
/// dictionary keeps only its compact record-offset array.
final class DictIndex {
    private var db: OpaquePointer?
    private var lookupStatement: OpaquePointer?
    private var suggestStatement: OpaquePointer?
    private let queryLock = NSLock()
    private let path: URL

    /// Bumped when the schema or build logic changes so stale indexes rebuild.
    private static let schemaVersion = 1

    /// Opens an existing, valid index without building. Returns nil if the
    /// index is missing or stale (caller must then do a full parse + build).
    init?(openExistingIn dictFolder: URL, expectedCount: Int) {
        self.path = dictFolder.appendingPathComponent("goi-index.sqlite3")
        guard openAndValidate(expectedCount: expectedCount), prepareQueries() else { return nil }
    }

    /// Builds (or rebuilds) the index from a fully-parsed dictionary.
    init?(buildIn dictFolder: URL, mdx: MdictFile) {
        self.path = dictFolder.appendingPathComponent("goi-index.sqlite3")
        guard build(from: mdx), prepareQueries() else { return nil }
    }

    deinit {
        sqlite3_finalize(lookupStatement)
        sqlite3_finalize(suggestStatement)
        sqlite3_close(db)
    }

    private func openAndValidate(expectedCount: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return false
        }
        // metadata sanity: right schema version and same entry count
        let version = scalar("PRAGMA user_version")
        let count = scalar("SELECT COUNT(*) FROM entry")
        if version == Self.schemaVersion && count == expectedCount { return true }
        sqlite3_close(db); db = nil
        try? FileManager.default.removeItem(at: path)
        return false
    }

    private func build(from mdx: MdictFile) -> Bool {
        try? FileManager.default.removeItem(at: path)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { return false }
        exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        exec("CREATE TABLE entry(norm TEXT NOT NULL, hw TEXT NOT NULL, ki INTEGER NOT NULL);")
        exec("BEGIN")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO entry(norm, hw, ki) VALUES(?,?,?)", -1, &stmt, nil)
        mdx.forEachKey { headword, index in
            let norm = mdx.normalize(headword)
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, norm, -1, SQLITE_TRANSIENT_IDX)
            sqlite3_bind_text(stmt, 2, headword, -1, SQLITE_TRANSIENT_IDX)
            sqlite3_bind_int64(stmt, 3, Int64(index))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
        exec("CREATE INDEX idx_norm ON entry(norm)")
        exec("PRAGMA user_version=\(Self.schemaVersion)")
        return true
    }

    // MARK: - Queries

    /// Key indices whose normalized headword equals the query.
    func lookup(norm: String) -> [Int] {
        queryLock.lock()
        defer {
            sqlite3_reset(lookupStatement)
            sqlite3_clear_bindings(lookupStatement)
            queryLock.unlock()
        }
        guard let statement = lookupStatement else { return [] }
        sqlite3_bind_text(statement, 1, norm, -1, SQLITE_TRANSIENT_IDX)
        var out: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return out
    }

    /// Distinct headwords whose normalized form starts with `norm`.
    func suggest(normPrefix norm: String, limit: Int) -> [String] {
        guard !norm.isEmpty else { return [] }
        // range scan on the norm index: [prefix, prefix+lastChar+1)
        var upper = norm
        upper.unicodeScalars.removeLast()
        if let last = norm.unicodeScalars.last, let bumped = Unicode.Scalar(last.value + 1) {
            upper.unicodeScalars.append(bumped)
        } else {
            upper = norm + "\u{FFFF}"
        }
        queryLock.lock()
        defer {
            sqlite3_reset(suggestStatement)
            sqlite3_clear_bindings(suggestStatement)
            queryLock.unlock()
        }
        guard let statement = suggestStatement else { return [] }
        sqlite3_bind_text(statement, 1, norm, -1, SQLITE_TRANSIENT_IDX)
        sqlite3_bind_text(statement, 2, upper, -1, SQLITE_TRANSIENT_IDX)
        sqlite3_bind_int64(statement, 3, Int64(limit))
        var out: [String] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0) {
                let hw = String(cString: c)
                if seen.insert(hw).inserted { out.append(hw) }
            }
        }
        return out
    }

    // MARK: - SQLite helpers

    private func prepareQueries() -> Bool {
        let lookupOK = sqlite3_prepare_v2(
            db, "SELECT ki FROM entry WHERE norm=?", -1, &lookupStatement, nil
        ) == SQLITE_OK
        let suggestOK = sqlite3_prepare_v2(
            db,
            "SELECT hw FROM entry WHERE norm >= ? AND norm < ? ORDER BY norm LIMIT ?",
            -1,
            &suggestStatement,
            nil
        ) == SQLITE_OK
        return lookupOK && suggestOK
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func scalar(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }
}
