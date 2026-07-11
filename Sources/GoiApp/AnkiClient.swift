import Foundation

/// AnkiConnect (localhost:8765) client. The open interop surface: words are
/// pushed as notes of a documented custom note type "Goi Word", so any tool
/// that talks to Anki (or syncs via AnkiWeb) can read and edit them.
enum AnkiClient {
    static let deckName = "Goi"
    static let modelName = "Goi Word"
    static let fields = [
        "Lemma", "Surfaces", "Definition", "Familiarity",
        "LookupCount", "FirstSeen", "Source", "GoiId",
    ]

    struct AnkiError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func invoke(_ action: String, _ params: [String: Any] = [:]) throws -> Any? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action, "version": 6, "params": params,
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Any?, Error> = .failure(AnkiError(message: "无响应"))
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if error != nil {
                result = .failure(AnkiError(message: "无法连接 Anki——请确认 Anki 正在运行且已安装 AnkiConnect 插件（代码 2055492159）"))
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(AnkiError(message: "AnkiConnect 响应无法解析"))
                return
            }
            if let err = obj["error"] as? String {
                result = .failure(AnkiError(message: "AnkiConnect：\(err)"))
            } else {
                result = .success(obj["result"] ?? nil)
            }
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    private static func ensureInfrastructure() throws {
        let models = try invoke("modelNames") as? [String] ?? []
        if !models.contains(modelName) {
            _ = try invoke("createModel", [
                "modelName": modelName,
                "inOrderFields": fields,
                "css": """
                .card { font-family: -apple-system, sans-serif; font-size: 17px; padding: 12px; }
                .lemma { font-size: 26px; font-weight: 600; }
                .meta { color: #888; font-size: 12px; margin-top: 12px; }
                """,
                "cardTemplates": [[
                    "Name": "Recognition",
                    "Front": "<div class=\"lemma\">{{Lemma}}</div>",
                    "Back": """
                    <div class="lemma">{{Lemma}}</div><hr>
                    {{Definition}}
                    <div class="meta">查过 {{LookupCount}} 次 · 熟悉度 {{Familiarity}} · via Goi</div>
                    """,
                ]],
            ])
        }
        let decks = try invoke("deckNames") as? [String] ?? []
        if !decks.contains(deckName) {
            _ = try invoke("createDeck", ["deck": deckName])
        }
    }

    struct PushResult {
        var added = 0
        var updated = 0
        var failed: [String] = []
    }

    /// Pushes wordbook entries; returns per-word note ids via the callback
    /// so the caller can persist the mapping.
    static func push(
        words: [(row: VocabStore.WordRow, definition: String)],
        noteIDSaved: (String, Int64) -> Void
    ) throws -> PushResult {
        try ensureInfrastructure()
        var result = PushResult()

        for (row, definition) in words {
            let familiarity = String(format: "%.0f", VocabStore.effectiveFamiliarity(of: row))
            let fieldValues: [String: String] = [
                "Lemma": row.lemma,
                "Surfaces": row.surfaces.replacingOccurrences(of: "\n", with: " / "),
                "Definition": definition,
                "Familiarity": familiarity,
                "LookupCount": "\(row.lookupCount)",
                "FirstSeen": ISO8601DateFormatter().string(from: row.firstSeen),
                "Source": row.manual ? "manual" : "auto",
                "GoiId": row.lemma,
            ]
            do {
                if let noteID = row.ankiNoteID {
                    _ = try invoke("updateNoteFields", [
                        "note": ["id": noteID, "fields": fieldValues],
                    ])
                    result.updated += 1
                } else {
                    let id = try invoke("addNote", [
                        "note": [
                            "deckName": deckName,
                            "modelName": modelName,
                            "fields": fieldValues,
                            "tags": ["goi"],
                            "options": ["allowDuplicate": false],
                        ],
                    ])
                    if let id = id as? Int64 {
                        noteIDSaved(row.lemma, id)
                    } else if let id = id as? Int {
                        noteIDSaved(row.lemma, Int64(id))
                    }
                    result.added += 1
                }
            } catch {
                result.failed.append("\(row.lemma)：\(error.localizedDescription)")
            }
        }
        return result
    }
}
