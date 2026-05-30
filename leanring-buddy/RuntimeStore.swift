//
//  RuntimeStore.swift
//  leanring-buddy
//
//  SQLite-backed persistence layer for the Clicky runtime.
//  Schema mirrors the commercial app's runtime.sqlite layout:
//  sessions, events (append-only), tool_calls, artifacts, memory (+ FTS).
//
//  All writes happen on a dedicated serial background queue so the main actor
//  is never blocked. Reads used by the UI are async and cross to the queue too.
//
//  Note: Requires sqlite3 to be linked. If you see linker errors, add
//  libsqlite3.tbd to the target's "Frameworks, Libraries, and Embedded Content".
//

import Foundation
import SQLite3

actor RuntimeStore {

    // MARK: - Internal state

    private var db: OpaquePointer?
    private let dbURL: URL

    // MARK: - Init

    init(databaseFileName: String = "runtime.sqlite") throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clickyDir = appSupport.appendingPathComponent("ClickyClone", isDirectory: true)
        try FileManager.default.createDirectory(at: clickyDir, withIntermediateDirectories: true)
        self.dbURL = clickyDir.appendingPathComponent(databaseFileName)

        var dbPointer: OpaquePointer?
        let openResult = sqlite3_open(dbURL.path, &dbPointer)
        guard openResult == SQLITE_OK, let db = dbPointer else {
            throw RuntimeStoreError.openFailed("sqlite3_open failed: \(String(cString: sqlite3_errmsg(dbPointer)))")
        }
        self.db = db

        try createSchemaIfNeeded()
        print("📦 RuntimeStore: opened at \(dbURL.path)")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func createSchemaIfNeeded() throws {
        // Enable WAL mode for better concurrent read performance
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")

        try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                harness_type TEXT NOT NULL,
                capabilities_json TEXT NOT NULL DEFAULT '{}',
                tool_policy_json TEXT NOT NULL DEFAULT '{}'
            );
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS child_sessions (
                id TEXT PRIMARY KEY,
                parent_session_id TEXT NOT NULL REFERENCES sessions(id),
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                harness_type TEXT NOT NULL,
                task_description TEXT NOT NULL DEFAULT ''
            );
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                occurred_at REAL NOT NULL,
                sequence_number INTEGER NOT NULL,
                event_type TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}'
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, sequence_number);")

        try exec("""
            CREATE TABLE IF NOT EXISTS tool_calls (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                created_at REAL NOT NULL,
                tool_name TEXT NOT NULL,
                input_json TEXT NOT NULL DEFAULT '{}',
                output_json TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                duration_seconds REAL
            );
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                created_at REAL NOT NULL,
                artifact_type TEXT NOT NULL,
                content_json TEXT NOT NULL DEFAULT '{}'
            );
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS memory (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                key TEXT NOT NULL UNIQUE,
                value TEXT NOT NULL,
                tags_json TEXT NOT NULL DEFAULT '[]',
                session_id TEXT
            );
        """)

        // FTS table for full-text search over memory key + value
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(key, value, content=memory, content_rowid=rowid);
        """)

        // Keep FTS in sync via triggers
        try exec("""
            CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory BEGIN
                INSERT INTO memory_fts(rowid, key, value) VALUES (new.rowid, new.key, new.value);
            END;
        """)
        try exec("""
            CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, key, value) VALUES ('delete', old.rowid, old.key, old.value);
            END;
        """)
        try exec("""
            CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, key, value) VALUES ('delete', old.rowid, old.key, old.value);
                INSERT INTO memory_fts(rowid, key, value) VALUES (new.rowid, new.key, new.value);
            END;
        """)
    }

    // MARK: - Sessions

    func insertSession(_ session: RuntimeSession) throws {
        let sql = """
            INSERT INTO sessions (id, created_at, updated_at, status, harness_type, capabilities_json, tool_policy_json)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, session.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, session.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, session.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, session.harnessType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, session.capabilitiesJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, session.toolPolicyJSON, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RuntimeStoreError.writeFailed(lastErrorMessage())
            }
        }
    }

    func updateSessionStatus(_ sessionId: String, status: RuntimeSession.SessionStatus) throws {
        let sql = "UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?;"
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, sessionId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RuntimeStoreError.writeFailed(lastErrorMessage())
            }
        }
    }

    func fetchSession(id: String) throws -> RuntimeSession? {
        let sql = "SELECT id, created_at, updated_at, status, harness_type, capabilities_json, tool_policy_json FROM sessions WHERE id = ?;"
        var result: RuntimeSession?
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = sessionFromStatement(stmt)
            }
        }
        return result
    }

    func fetchRecentSessions(limit: Int = 50) throws -> [RuntimeSession] {
        let sql = "SELECT id, created_at, updated_at, status, harness_type, capabilities_json, tool_policy_json FROM sessions ORDER BY created_at DESC LIMIT ?;"
        var results: [RuntimeSession] = []
        try prepare(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let session = sessionFromStatement(stmt) {
                    results.append(session)
                }
            }
        }
        return results
    }

    // MARK: - Events

    func appendEvent(_ envelope: RuntimeEventEnvelope) throws {
        let sql = """
            INSERT INTO events (id, session_id, occurred_at, sequence_number, event_type, payload_json)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, envelope.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, envelope.sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, envelope.occurredAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 4, Int32(envelope.sequenceNumber))
            sqlite3_bind_text(stmt, 5, envelope.eventType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, envelope.payloadJSON, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RuntimeStoreError.writeFailed(lastErrorMessage())
            }
        }
    }

    func fetchEvents(sessionId: String, afterSequence: Int = 0) throws -> [RuntimeEventEnvelope] {
        let sql = """
            SELECT id, session_id, occurred_at, sequence_number, event_type, payload_json
            FROM events WHERE session_id = ? AND sequence_number > ?
            ORDER BY sequence_number ASC;
        """
        var results: [RuntimeEventEnvelope] = []
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(afterSequence))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let envelope = eventEnvelopeFromStatement(stmt) {
                    results.append(envelope)
                }
            }
        }
        return results
    }

    func fetchNextSequenceNumber(sessionId: String) throws -> Int {
        let sql = "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM events WHERE session_id = ?;"
        var nextSeq = 1
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                nextSeq = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return nextSeq
    }

    // MARK: - Memory

    func upsertMemory(_ entry: RuntimeMemoryEntry) throws {
        let tagsJSON = (try? JSONEncoder().encode(entry.tags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = """
            INSERT INTO memory (id, created_at, updated_at, key, value, tags_json, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                tags_json = excluded.tags_json,
                updated_at = excluded.updated_at,
                session_id = excluded.session_id;
        """
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, entry.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, entry.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, entry.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, entry.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, entry.value, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, tagsJSON, -1, SQLITE_TRANSIENT)
            if let sessionId = entry.sessionId {
                sqlite3_bind_text(stmt, 7, sessionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RuntimeStoreError.writeFailed(lastErrorMessage())
            }
        }
    }

    func fetchMemory(key: String) throws -> RuntimeMemoryEntry? {
        let sql = "SELECT id, created_at, updated_at, key, value, tags_json, session_id FROM memory WHERE key = ?;"
        var result: RuntimeMemoryEntry?
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = memoryEntryFromStatement(stmt)
            }
        }
        return result
    }

    func listMemory(tag: String? = nil) throws -> [RuntimeMemoryEntry] {
        let sql: String
        if let tag {
            // JSON contains search for tag
            sql = "SELECT id, created_at, updated_at, key, value, tags_json, session_id FROM memory WHERE tags_json LIKE ? ORDER BY updated_at DESC;"
        } else {
            sql = "SELECT id, created_at, updated_at, key, value, tags_json, session_id FROM memory ORDER BY updated_at DESC;"
        }
        var results: [RuntimeMemoryEntry] = []
        try prepare(sql) { stmt in
            if let tag {
                sqlite3_bind_text(stmt, 1, "%\"\(tag)\"%", -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = memoryEntryFromStatement(stmt) {
                    results.append(entry)
                }
            }
        }
        return results
    }

    func searchMemory(query: String, limit: Int = 10) throws -> [RuntimeMemoryEntry] {
        // Use FTS for full-text search over key + value
        let sql = """
            SELECT m.id, m.created_at, m.updated_at, m.key, m.value, m.tags_json, m.session_id
            FROM memory m
            JOIN memory_fts f ON m.rowid = f.rowid
            WHERE memory_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
        """
        var results: [RuntimeMemoryEntry] = []
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = memoryEntryFromStatement(stmt) {
                    results.append(entry)
                }
            }
        }
        return results
    }

    func removeMemory(key: String) throws {
        let sql = "DELETE FROM memory WHERE key = ?;"
        try prepare(sql) { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RuntimeStoreError.writeFailed(lastErrorMessage())
            }
        }
    }

    // MARK: - Private helpers

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw RuntimeStoreError.execFailed(message)
        }
    }

    private func prepare(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw RuntimeStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }

    // Column-reading helpers

    private func string(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private func sessionFromStatement(_ stmt: OpaquePointer) -> RuntimeSession? {
        let id = string(stmt, 0)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let statusRaw = string(stmt, 3)
        let harnessRaw = string(stmt, 4)
        let capJSON = string(stmt, 5)
        let policyJSON = string(stmt, 6)

        guard let status = RuntimeSession.SessionStatus(rawValue: statusRaw),
              let harness = HarnessType(rawValue: harnessRaw) else { return nil }

        return RuntimeSession(id: id, createdAt: createdAt, updatedAt: updatedAt,
                              status: status, harnessType: harness,
                              capabilitiesJSON: capJSON, toolPolicyJSON: policyJSON)
    }

    private func eventEnvelopeFromStatement(_ stmt: OpaquePointer) -> RuntimeEventEnvelope? {
        let id = string(stmt, 0)
        let sessionId = string(stmt, 1)
        let occurredAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let seq = Int(sqlite3_column_int(stmt, 3))
        let typeRaw = string(stmt, 4)
        let payloadJSON = string(stmt, 5)
        guard let eventType = RuntimeEventType(rawValue: typeRaw) else { return nil }
        return RuntimeEventEnvelope(id: id, sessionId: sessionId, occurredAt: occurredAt,
                                    sequenceNumber: seq, eventType: eventType, payloadJSON: payloadJSON)
    }

    private func memoryEntryFromStatement(_ stmt: OpaquePointer) -> RuntimeMemoryEntry? {
        let id = string(stmt, 0)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let key = string(stmt, 3)
        let value = string(stmt, 4)
        let tagsJSON = string(stmt, 5)
        let sessionId: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : string(stmt, 6)

        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []

        var entry = RuntimeMemoryEntry(key: key, value: value, tags: tags, sessionId: sessionId)
        // Override generated id/timestamps with what's in the DB
        return RuntimeMemoryEntry(id: id, createdAt: createdAt, updatedAt: updatedAt,
                                  key: key, value: value, tags: tags, sessionId: sessionId)
    }
}

// MARK: - RuntimeMemoryEntry memberwise init helper

extension RuntimeMemoryEntry {
    init(id: String, createdAt: Date, updatedAt: Date, key: String, value: String, tags: [String], sessionId: String?) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.key = key
        self.value = value
        self.tags = tags
        self.sessionId = sessionId
    }
}

// MARK: - Errors

enum RuntimeStoreError: Error, LocalizedError {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "RuntimeStore: open failed — \(msg)"
        case .execFailed(let msg): return "RuntimeStore: exec failed — \(msg)"
        case .prepareFailed(let msg): return "RuntimeStore: prepare failed — \(msg)"
        case .writeFailed(let msg): return "RuntimeStore: write failed — \(msg)"
        case .readFailed(let msg): return "RuntimeStore: read failed — \(msg)"
        }
    }
}
