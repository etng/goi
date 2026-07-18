import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lookup history + vocabulary book, backed by SQLite.
///
/// Data model (REQUIREMENTS §5): `lookup_log` is the raw append-only stream;
/// `word` is the aggregate view. Familiarity v0: 0 = unknown, 100 = mastered.
/// Every lookup costs 15 points; unlooked-up words drift back toward 100
/// (20% of the gap per 30 days); manual wordbook additions cost 40 and
/// freeze the drift.
final class VocabStore {
    struct WordRow: Identifiable {
        var id: String { lemma }
        let lemma: String
        let surfaces: String
        let lookupCount: Int
        let firstSeen: Date
        let lastSeen: Date
        let manual: Bool
        let familiarity: Double
        let inWordbook: Bool
        let ankiNoteID: Int64?
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "goi.vocab")

    init(url: URL) {
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 2_000)
        exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;
        CREATE TABLE IF NOT EXISTS lookup_log(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            surface TEXT NOT NULL,
            lemma TEXT NOT NULL,
            source TEXT NOT NULL,
            ts REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS word(
            lemma TEXT PRIMARY KEY,
            surfaces TEXT NOT NULL DEFAULT '',
            lookup_count INTEGER NOT NULL DEFAULT 0,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            manual INTEGER NOT NULL DEFAULT 0,
            familiarity REAL NOT NULL DEFAULT 100,
            in_wordbook INTEGER NOT NULL DEFAULT 0,
            anki_note_id INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_log_lemma ON lookup_log(lemma);
        CREATE INDEX IF NOT EXISTS idx_log_ts_id ON lookup_log(ts, id);
        CREATE INDEX IF NOT EXISTS idx_log_lemma_id ON lookup_log(lemma, id DESC);
        CREATE INDEX IF NOT EXISTS idx_word_wordbook_seen
            ON word(in_wordbook, last_seen DESC, lemma);
        CREATE TABLE IF NOT EXISTS recent_lookup(
            lemma TEXT PRIMARY KEY,
            last_log_id INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_recent_lookup_id
            ON recent_lookup(last_log_id DESC);
        CREATE TABLE IF NOT EXISTS lookup_day(
            day TEXT PRIMARY KEY,
            count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS note(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lemma TEXT NOT NULL,
            content TEXT NOT NULL,
            ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_note_lemma ON note(lemma);
        CREATE TABLE IF NOT EXISTS dict_hit(
            dict_id TEXT NOT NULL,
            day TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(dict_id, day)
        );
        CREATE TABLE IF NOT EXISTS dict_use(
            dict_id TEXT NOT NULL,
            day TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(dict_id, day)
        );
        """)
        // migrations (harmless no-ops when the column already exists)
        exec("ALTER TABLE word ADD COLUMN familiarity_source TEXT NOT NULL DEFAULT 'auto'")
        exec("ALTER TABLE lookup_log ADD COLUMN context TEXT")
        backfillRecentLookupIfNeeded()
        backfillLookupDaysIfNeeded()
    }

    /// Direct familiarity write (e.g. Anki review data flowing back).
    func setFamiliarity(lemma: String, value: Double, source: String) {
        queue.sync {
            _ = run("UPDATE word SET familiarity=?, familiarity_source=? WHERE lemma=?",
                    [.real(max(0, min(100, value))), .text(source), .text(lemma)])
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Recording

    /// Auto-wordbook threshold: looked up at least twice.
    private static let autoThreshold = 2

    func recordLookup(surface: String, lemma: String, source: String, context: String? = nil) {
        queue.sync {
            let now = Date().timeIntervalSince1970
            exec("BEGIN IMMEDIATE")
            run("INSERT INTO lookup_log(surface, lemma, source, ts, context) VALUES(?,?,?,?,?)",
                [.text(surface), .text(lemma), .text(source), .real(now),
                 context.map { Value.text($0) } ?? .null])
            run("""
                INSERT INTO lookup_day(day, count)
                VALUES(strftime('%Y-%m-%d', ?, 'unixepoch', 'localtime'), 1)
                ON CONFLICT(day) DO UPDATE SET count=count+1
                """, [.real(now)])
            run("""
                INSERT INTO recent_lookup(lemma, last_log_id) VALUES(?, last_insert_rowid())
                ON CONFLICT(lemma) DO UPDATE SET last_log_id=excluded.last_log_id
                """, [.text(lemma)])

            if let word = fetchWord(lemma) {
                var familiarity = word.manual
                    ? word.familiarity
                    : Self.recovered(word.familiarity, since: word.lastSeen)
                familiarity = max(0, familiarity - 15)
                var surfaces = Set(word.surfaces.split(separator: "\n").map(String.init))
                surfaces.insert(surface)
                let count = word.lookupCount + 1
                let inBook = word.inWordbook || word.manual || count >= Self.autoThreshold
                run("""
                    UPDATE word SET surfaces=?, lookup_count=?, last_seen=?,
                        familiarity=?, in_wordbook=? WHERE lemma=?
                    """,
                    [.text(surfaces.sorted().joined(separator: "\n")), .int(Int64(count)),
                     .real(now), .real(familiarity), .int(inBook ? 1 : 0), .text(lemma)])
            } else {
                run("""
                    INSERT INTO word(lemma, surfaces, lookup_count, first_seen, last_seen,
                        manual, familiarity, in_wordbook)
                    VALUES(?,?,?,?,?,0,85,0)
                    """,
                    [.text(lemma), .text(surface), .int(1), .real(now), .real(now)])
            }
            exec("COMMIT")
        }
    }

    func addManually(lemma: String, surface: String) {
        queue.sync {
            let now = Date().timeIntervalSince1970
            if let word = fetchWord(lemma) {
                let familiarity = max(0, word.familiarity - 40)
                run("UPDATE word SET manual=1, in_wordbook=1, familiarity=? WHERE lemma=?",
                    [.real(familiarity), .text(lemma)])
            } else {
                run("""
                    INSERT INTO word(lemma, surfaces, lookup_count, first_seen, last_seen,
                        manual, familiarity, in_wordbook)
                    VALUES(?,?,0,?,?,1,60,1)
                    """,
                    [.text(lemma), .text(surface), .real(now), .real(now)])
            }
        }
    }

    func removeFromWordbook(lemma: String) {
        queue.sync {
            _ = run("UPDATE word SET in_wordbook=0, manual=0 WHERE lemma=?", [.text(lemma)])
        }
    }

    func deleteWord(lemma: String) {
        queue.sync {
            _ = run("DELETE FROM word WHERE lemma=?", [.text(lemma)])
        }
    }

    func isInWordbook(lemma: String) -> Bool {
        queue.sync { fetchWord(lemma)?.inWordbook ?? false }
    }

    func setAnkiNoteID(_ noteID: Int64, lemma: String) {
        queue.sync {
            _ = run("UPDATE word SET anki_note_id=? WHERE lemma=?", [.int(noteID), .text(lemma)])
        }
    }

    /// Time drift: familiarity climbs back toward 100 by 20% of the gap
    /// per 30 days without a lookup (a word you stopped looking up is
    /// probably either mastered or irrelevant).
    private static func recovered(_ familiarity: Double, since lastSeen: Date) -> Double {
        let days = Date().timeIntervalSince(lastSeen) / 86400
        guard days > 0 else { return familiarity }
        let factor = pow(0.8, days / 30)
        return 100 - (100 - familiarity) * factor
    }

    // MARK: - Queries

    func wordbook() -> [WordRow] {
        queue.sync {
            rows("SELECT * FROM word WHERE in_wordbook=1 ORDER BY last_seen DESC", [])
        }
    }

    func wordbook(offset: Int, limit: Int) -> [WordRow] {
        guard offset >= 0, limit > 0 else { return [] }
        return queue.sync {
            rows("SELECT * FROM word WHERE in_wordbook=1 ORDER BY last_seen DESC, lemma LIMIT ? OFFSET ?",
                 [.int(Int64(limit)), .int(Int64(offset))])
        }
    }

    func wordbookCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM word WHERE in_wordbook=1", []) }
    }

    func allWords() -> [WordRow] {
        queue.sync {
            rows("SELECT * FROM word ORDER BY last_seen DESC", [])
        }
    }

    /// Display familiarity with drift applied (stored value is updated lazily).
    static func effectiveFamiliarity(of row: WordRow) -> Double {
        row.manual ? row.familiarity : recovered(row.familiarity, since: row.lastSeen)
    }

    /// Word stats for display (no side effects, no weight change).
    func info(lemma: String) -> WordRow? {
        queue.sync { fetchWord(lemma) }
    }

    // MARK: - History

    struct LogRow: Identifiable {
        let id: Int64
        let surface: String
        let lemma: String
        let source: String
        let ts: Date
    }

    /// Removes one history entry and repairs the per-lemma recent lookup row.
    func deleteHistory(id: Int64) {
        queue.sync {
            var lemma = ""
            var day = ""
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT lemma, strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') FROM lookup_log WHERE id=?",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK {
                bind(stmt, [.int(id)])
                if sqlite3_step(stmt) == SQLITE_ROW {
                    lemma = text(stmt, 0)
                    day = text(stmt, 1)
                }
            }
            sqlite3_finalize(stmt)
            exec("BEGIN IMMEDIATE")
            run("DELETE FROM lookup_log WHERE id=?", [.int(id)])
            if !day.isEmpty {
                run("UPDATE lookup_day SET count=count-1 WHERE day=?", [.text(day)])
                run("DELETE FROM lookup_day WHERE day=? AND count<=0", [.text(day)])
            }
            if !lemma.isEmpty {
                run("DELETE FROM recent_lookup WHERE lemma=?", [.text(lemma)])
                run("""
                    INSERT INTO recent_lookup(lemma, last_log_id)
                    SELECT lemma, MAX(id) FROM lookup_log WHERE lemma=? HAVING COUNT(*) > 0
                    """, [.text(lemma)])
            }
            exec("COMMIT")
        }
    }

    func clearHistory() {
        queue.sync {
            exec("BEGIN IMMEDIATE")
            run("DELETE FROM lookup_log", [])
            run("DELETE FROM recent_lookup", [])
            run("DELETE FROM lookup_day", [])
            exec("COMMIT")
        }
    }

    func historyCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lookup_log", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func history(offset: Int, limit: Int) -> [LogRow] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT id, surface, lemma, source, ts FROM lookup_log ORDER BY id DESC LIMIT ? OFFSET ?",
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [.int(Int64(limit)), .int(Int64(offset))])
            var out: [LogRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(LogRow(
                    id: sqlite3_column_int64(stmt, 0),
                    surface: text(stmt, 1),
                    lemma: text(stmt, 2),
                    source: text(stmt, 3),
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                ))
            }
            return out
        }
    }

    /// Most recently looked-up lemmas. The projection table is maintained at
    /// write time, so this remains O(limit) instead of grouping the full log.
    func recentHistory(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT lemma FROM recent_lookup ORDER BY last_log_id DESC LIMIT ?",
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [.int(Int64(limit))])
            var result: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { result.append(text(stmt, 0)) }
            return result
        }
    }

    // MARK: - Statistics

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func today() -> String { dayFormatter.string(from: Date()) }

    /// Called once per *logged* lookup with every dictionary that had a hit.
    /// (Live previews and browse mode don't count.)
    func recordHits(dictIDs: [String]) {
        guard !dictIDs.isEmpty else { return }
        let day = Self.today()
        queue.sync {
            exec("BEGIN IMMEDIATE")
            for id in dictIDs {
                run("""
                    INSERT INTO dict_hit(dict_id, day, count) VALUES(?,?,1)
                    ON CONFLICT(dict_id, day) DO UPDATE SET count = count + 1
                    """, [.text(id), .text(day)])
            }
            exec("COMMIT")
        }
    }

    /// A dictionary only counts as *used* when the user explicitly clicks
    /// its tab — searches hit every dictionary automatically.
    func recordTabUse(dictID: String) {
        guard !dictID.isEmpty else { return }
        let day = Self.today()
        queue.sync {
            _ = run("""
                INSERT INTO dict_use(dict_id, day, count) VALUES(?,?,1)
                ON CONFLICT(dict_id, day) DO UPDATE SET count = count + 1
                """, [.text(dictID), .text(day)])
        }
    }

    /// Lookup counts per local calendar day for the heatmap.
    func dailyLookupCounts(days: Int) -> [String: Int] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT day, count FROM lookup_day
                WHERE day >= date(?, 'unixepoch', 'localtime')
                ORDER BY day
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [.real(cutoff)])
            var out: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[text(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
            }
            return out
        }
    }

    struct DictStat {
        let dictID: String
        let hits: Int
        let uses: Int
    }

    func dictStats() -> [DictStat] {
        queue.sync {
            var hits: [String: Int] = [:]
            var uses: [String: Int] = [:]
            for (table, target) in [("dict_hit", 0), ("dict_use", 1)] {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT dict_id, SUM(count) FROM \(table) GROUP BY dict_id", -1, &stmt, nil) == SQLITE_OK else { continue }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = text(stmt, 0)
                    let value = Int(sqlite3_column_int64(stmt, 1))
                    if target == 0 { hits[id] = value } else { uses[id] = value }
                }
                sqlite3_finalize(stmt)
            }
            let ids = Set(hits.keys).union(uses.keys)
            return ids.map { DictStat(dictID: $0, hits: hits[$0] ?? 0, uses: uses[$0] ?? 0) }
        }
    }

    // MARK: - Notes (per-word comments; community layer comes later)

    struct CommentRow: Identifiable {
        let id: Int64
        let content: String
        let ts: Date
    }

    func addComment(lemma: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            _ = run("INSERT INTO note(lemma, content, ts) VALUES(?,?,?)",
                    [.text(lemma), .text(trimmed), .real(Date().timeIntervalSince1970)])
        }
    }

    /// Own comments, newest first.
    func comments(lemma: String) -> [CommentRow] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT id, content, ts FROM note WHERE lemma=? ORDER BY id DESC", -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [.text(lemma)])
            var out: [CommentRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(CommentRow(
                    id: sqlite3_column_int64(stmt, 0),
                    content: text(stmt, 1),
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                ))
            }
            return out
        }
    }

    func commentCount(lemma: String) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM note WHERE lemma=?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [.text(lemma)])
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // MARK: - Export / import

    /// Streams the full export through a sibling temporary file. The old
    /// array-based path held every history row plus the encoded JSON in memory,
    /// which multiplied memory use for long-lived profiles.
    func exportJSON(to destination: URL) throws {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        _ = fm.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try queue.sync {
                let iso = ISO8601DateFormatter()
                func write(_ value: String) throws {
                    try handle.write(contentsOf: Data(value.utf8))
                }
                func writeObject(_ value: [String: Any]) throws {
                    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                }
                func stream(_ sql: String, object: (OpaquePointer?) -> [String: Any]) throws {
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                        throw NSError(domain: "goi", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取导出数据"])
                    }
                    defer { sqlite3_finalize(stmt) }
                    var first = true
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if !first { try write(",") }
                        try writeObject(object(stmt))
                        first = false
                    }
                }

                try write("{\"version\":1,\"words\":[")
                try stream("SELECT * FROM word ORDER BY last_seen DESC") { stmt in
                    let row = WordRow(
                        lemma: text(stmt, 0), surfaces: text(stmt, 1),
                        lookupCount: Int(sqlite3_column_int64(stmt, 2)),
                        firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                        lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                        manual: sqlite3_column_int64(stmt, 5) == 1,
                        familiarity: sqlite3_column_double(stmt, 6),
                        inWordbook: sqlite3_column_int64(stmt, 7) == 1,
                        ankiNoteID: nil
                    )
                    return [
                        "lemma": row.lemma,
                        "surfaces": row.surfaces.split(separator: "\n").map(String.init),
                        "lookup_count": row.lookupCount,
                        "first_seen": iso.string(from: row.firstSeen),
                        "last_seen": iso.string(from: row.lastSeen),
                        "manual": row.manual,
                        "familiarity": (Self.effectiveFamiliarity(of: row) * 10).rounded() / 10,
                        "in_wordbook": row.inWordbook,
                    ]
                }
                try write("],\"lookup_log\":[")
                try stream("SELECT surface, lemma, source, ts FROM lookup_log ORDER BY id") { stmt in
                    [
                        "surface": text(stmt, 0), "lemma": text(stmt, 1),
                        "source": text(stmt, 2),
                        "ts": iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))),
                    ]
                }
                try write("],\"notes\":[")
                try stream("SELECT lemma, content, ts FROM note ORDER BY id") { stmt in
                    [
                        "lemma": text(stmt, 0), "content": text(stmt, 1),
                        "ts": iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))),
                    ]
                }
                try write("]}")
            }
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// CSV laid out for direct Anki import: lemma, surfaces, definition placeholder,
    /// lookup count, familiarity, tag.
    func exportWordbookCSV() -> Data {
        var csv = "lemma,surfaces,lookup_count,familiarity,manual,first_seen,last_seen\n"
        let iso = ISO8601DateFormatter()
        for row in wordbook() {
            let familiarity = String(format: "%.0f", Self.effectiveFamiliarity(of: row))
            let fields = [
                row.lemma, row.surfaces.replacingOccurrences(of: "\n", with: " / "),
                "\(row.lookupCount)", familiarity, row.manual ? "1" : "0",
                iso.string(from: row.firstSeen), iso.string(from: row.lastSeen),
            ]
            csv += fields.map { f in
                f.contains(",") || f.contains("\"") ? "\"\(f.replacingOccurrences(of: "\"", with: "\"\""))\"" : f
            }.joined(separator: ",") + "\n"
        }
        return Data(csv.utf8)
    }

    /// Merge-import from an exportJSON payload: keeps the more-unknown
    /// familiarity and unions surfaces/counts in one transaction.
    func importJSON(_ data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = root["words"] as? [[String: Any]] else {
            throw NSError(domain: "goi", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 Goi 导出文件"])
        }
        let iso = ISO8601DateFormatter()
        return queue.sync {
            exec("BEGIN IMMEDIATE")
            var imported = 0
            for entry in words {
                guard let lemma = entry["lemma"] as? String else { continue }
                let surfaces = (entry["surfaces"] as? [String] ?? []).joined(separator: "\n")
                let count = entry["lookup_count"] as? Int ?? 0
                let manual = entry["manual"] as? Bool ?? false
                let familiarity = entry["familiarity"] as? Double ?? 100
                let inBook = entry["in_wordbook"] as? Bool ?? false
                let first = (entry["first_seen"] as? String).flatMap(iso.date(from:)) ?? Date()
                let last = (entry["last_seen"] as? String).flatMap(iso.date(from:)) ?? Date()
                if let existing = fetchWord(lemma) {
                    let mergedSurfaces = Set(existing.surfaces.split(separator: "\n").map(String.init))
                        .union(surfaces.split(separator: "\n").map(String.init))
                    run("""
                        UPDATE word SET surfaces=?, lookup_count=?, familiarity=?,
                            manual=?, in_wordbook=?, first_seen=?, last_seen=? WHERE lemma=?
                        """, [
                        .text(mergedSurfaces.sorted().joined(separator: "\n")),
                        .int(Int64(existing.lookupCount + count)),
                        .real(min(existing.familiarity, familiarity)),
                        .int((existing.manual || manual) ? 1 : 0),
                        .int((existing.inWordbook || inBook) ? 1 : 0),
                        .real(min(existing.firstSeen.timeIntervalSince1970, first.timeIntervalSince1970)),
                        .real(max(existing.lastSeen.timeIntervalSince1970, last.timeIntervalSince1970)),
                        .text(lemma),
                    ])
                } else {
                    run("""
                        INSERT INTO word(lemma, surfaces, lookup_count, first_seen, last_seen,
                            manual, familiarity, in_wordbook)
                        VALUES(?,?,?,?,?,?,?,?)
                        """, [
                        .text(lemma), .text(surfaces), .int(Int64(count)),
                        .real(first.timeIntervalSince1970), .real(last.timeIntervalSince1970),
                        .int(manual ? 1 : 0), .real(familiarity), .int(inBook ? 1 : 0),
                    ])
                }
                imported += 1
            }
            if let notes = root["notes"] as? [[String: Any]] {
                for note in notes {
                    guard let lemma = note["lemma"] as? String,
                          let content = note["content"] as? String,
                          let ts = (note["ts"] as? String).flatMap(iso.date(from:)) else { continue }
                    // skip if the identical note already exists
                    var stmt: OpaquePointer?
                    var exists = false
                    if sqlite3_prepare_v2(db, "SELECT 1 FROM note WHERE lemma=? AND content=? AND ts=?", -1, &stmt, nil) == SQLITE_OK {
                        bind(stmt, [.text(lemma), .text(content), .real(ts.timeIntervalSince1970)])
                        exists = sqlite3_step(stmt) == SQLITE_ROW
                        sqlite3_finalize(stmt)
                    }
                    if !exists {
                        run("INSERT INTO note(lemma, content, ts) VALUES(?,?,?)",
                            [.text(lemma), .text(content), .real(ts.timeIntervalSince1970)])
                    }
                }
            }
            exec("COMMIT")
            return imported
        }
    }

    // MARK: - SQLite plumbing

    private enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func backfillRecentLookupIfNeeded() {
        guard scalarInt("SELECT COUNT(*) FROM recent_lookup", []) == 0,
              scalarInt("SELECT COUNT(*) FROM lookup_log", []) > 0 else { return }
        exec("""
            INSERT INTO recent_lookup(lemma, last_log_id)
            SELECT lemma, MAX(id) FROM lookup_log
            WHERE TRIM(lemma) != ''
            GROUP BY lemma
        """)
    }

    private func backfillLookupDaysIfNeeded() {
        guard scalarInt("SELECT COUNT(*) FROM lookup_day", []) == 0,
              scalarInt("SELECT COUNT(*) FROM lookup_log", []) > 0 else { return }
        exec("""
            INSERT INTO lookup_day(day, count)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime'), COUNT(*)
            FROM lookup_log
            GROUP BY 1
        """)
    }

    private func scalarInt(_ sql: String, _ values: [Value]) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, index, n)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    /// Must be called on `queue`.
    private func fetchWord(_ lemma: String) -> WordRow? {
        rows("SELECT * FROM word WHERE lemma=?", [.text(lemma)]).first
    }

    /// Must be called on `queue`.
    private func rows(_ sql: String, _ values: [Value]) -> [WordRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        var out: [WordRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(WordRow(
                lemma: text(stmt, 0),
                surfaces: text(stmt, 1),
                lookupCount: Int(sqlite3_column_int64(stmt, 2)),
                firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                manual: sqlite3_column_int64(stmt, 5) == 1,
                familiarity: sqlite3_column_double(stmt, 6),
                inWordbook: sqlite3_column_int64(stmt, 7) == 1,
                ankiNoteID: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
            ))
        }
        return out
    }
}
