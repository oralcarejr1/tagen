import Foundation

public struct ConversationRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var mode: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct MessageRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var role: ChatRole
    public var text: String
    public var hadImage: Bool
    public var createdAt: Date
}

public struct AgentSessionRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var provider: String
    public var externalSessionID: String?
    public var title: String
    public var workingDirectory: String
    public var status: String
    public var lastError: String?
    public var resultSummary: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID, provider: String, externalSessionID: String?, title: String, workingDirectory: String, status: String,
                lastError: String?, resultSummary: String?, createdAt: Date, updatedAt: Date) {
        self.id = id; self.provider = provider; self.externalSessionID = externalSessionID; self.title = title
        self.workingDirectory = workingDirectory; self.status = status; self.lastError = lastError
        self.resultSummary = resultSummary; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Application persistence. Stores conversation text, agent sessions, settings and the
/// audit log. Never stores screenshots, audio or credentials; text is redacted.
public final class AppStore: AuditSink, @unchecked Sendable {
    public let db: SQLiteDatabase
    let redactor = Redactor()
    public static let schemaVersion = 1

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    public static func inMemory() throws -> AppStore { try AppStore(path: ":memory:") }

    func migrate() throws {
        let v = db.userVersion
        if v < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS conversations(
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, mode TEXT NOT NULL,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(
                  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                  role TEXT NOT NULL, text TEXT NOT NULL, had_image INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at);
                CREATE TABLE IF NOT EXISTS agent_sessions(
                  id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_session_id TEXT, title TEXT NOT NULL,
                  working_directory TEXT NOT NULL, status TEXT NOT NULL, last_error TEXT, result_summary TEXT,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS agent_events(
                  session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
                  kind TEXT NOT NULL, summary TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(session_id, seq));
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS audit_log(
                  id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, category TEXT NOT NULL, action TEXT NOT NULL,
                  decision TEXT NOT NULL, detail TEXT NOT NULL);
                """)
                try db.setUserVersion(1)
            }
        }
    }

    // MARK: conversations

    public func createConversation(title: String, mode: String, now: Date = Date()) throws -> ConversationRecord {
        let r = ConversationRecord(id: UUID(), title: redactor.redact(String(title.prefix(200))), mode: mode, createdAt: now, updatedAt: now)
        try db.run("INSERT INTO conversations(id,title,mode,created_at,updated_at) VALUES(?,?,?,?,?)",
                   [.text(r.id.uuidString), .text(r.title), .text(mode), .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970)])
        return r
    }

    public func appendMessage(conversationID: UUID, role: ChatRole, text: String, hadImage: Bool, now: Date = Date()) throws -> MessageRecord {
        let m = MessageRecord(id: UUID(), conversationID: conversationID, role: role, text: redactor.redact(text), hadImage: hadImage, createdAt: now)
        try db.transaction {
            try db.run("INSERT INTO messages(id,conversation_id,role,text,had_image,created_at) VALUES(?,?,?,?,?,?)",
                       [.text(m.id.uuidString), .text(conversationID.uuidString), .text(role.rawValue), .text(m.text),
                        .int(hadImage ? 1 : 0), .double(now.timeIntervalSince1970)])
            try db.run("UPDATE conversations SET updated_at=? WHERE id=?", [.double(now.timeIntervalSince1970), .text(conversationID.uuidString)])
        }
        return m
    }

    public func conversations(limit: Int = 100) throws -> [ConversationRecord] {
        try db.query("SELECT * FROM conversations ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard let id = row["id"]?.text.flatMap(UUID.init(uuidString:)) else { return nil }
            return ConversationRecord(id: id, title: row["title"]?.text ?? "", mode: row["mode"]?.text ?? "ask",
                                      createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                                      updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    public func messages(conversationID: UUID) throws -> [MessageRecord] {
        try db.query("SELECT * FROM messages WHERE conversation_id=? ORDER BY created_at, rowid", [.text(conversationID.uuidString)]).compactMap { row in
            guard let id = row["id"]?.text.flatMap(UUID.init(uuidString:)) else { return nil }
            return MessageRecord(id: id, conversationID: conversationID, role: ChatRole(rawValue: row["role"]?.text ?? "user") ?? .user,
                                 text: row["text"]?.text ?? "", hadImage: row["had_image"]?.int == 1,
                                 createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0))
        }
    }

    public func deleteConversation(_ id: UUID) throws {
        try db.run("DELETE FROM conversations WHERE id=?", [.text(id.uuidString)])
    }

    public func deleteAllHistory() throws {
        try db.transaction {
            try db.run("DELETE FROM messages"); try db.run("DELETE FROM conversations")
            try db.run("DELETE FROM agent_events"); try db.run("DELETE FROM agent_sessions")
        }
    }

    // MARK: agent sessions

    public func upsertAgentSession(_ s: AgentSessionRecord) throws {
        try db.run("""
        INSERT INTO agent_sessions(id,provider,external_session_id,title,working_directory,status,last_error,result_summary,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET external_session_id=excluded.external_session_id, title=excluded.title,
          status=excluded.status, last_error=excluded.last_error, result_summary=excluded.result_summary, updated_at=excluded.updated_at
        """, [.text(s.id.uuidString), .text(s.provider), s.externalSessionID.map(SQLValue.text) ?? .null, .text(redactor.redact(s.title)),
              .text(s.workingDirectory), .text(s.status), s.lastError.map { .text(redactor.redact($0)) } ?? .null,
              s.resultSummary.map { .text(redactor.redact($0)) } ?? .null,
              .double(s.createdAt.timeIntervalSince1970), .double(s.updatedAt.timeIntervalSince1970)])
    }

    public func agentSessions(limit: Int = 100) throws -> [AgentSessionRecord] {
        try db.query("SELECT * FROM agent_sessions ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.sessionRow)
    }

    public func agentSession(id: UUID) throws -> AgentSessionRecord? {
        try db.query("SELECT * FROM agent_sessions WHERE id=?", [.text(id.uuidString)]).compactMap(Self.sessionRow).first
    }

    static func sessionRow(_ row: [String: SQLValue]) -> AgentSessionRecord? {
        guard let id = row["id"]?.text.flatMap(UUID.init(uuidString:)) else { return nil }
        return AgentSessionRecord(id: id, provider: row["provider"]?.text ?? "", externalSessionID: row["external_session_id"]?.text,
                                  title: row["title"]?.text ?? "", workingDirectory: row["working_directory"]?.text ?? "",
                                  status: row["status"]?.text ?? "", lastError: row["last_error"]?.text,
                                  resultSummary: row["result_summary"]?.text,
                                  createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                                  updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
    }

    public func appendAgentEvent(sessionID: UUID, kind: String, summary: String, now: Date = Date()) throws {
        try db.run("""
        INSERT INTO agent_events(session_id,seq,kind,summary,created_at)
        VALUES(?, COALESCE((SELECT MAX(seq)+1 FROM agent_events WHERE session_id=?),0), ?, ?, ?)
        """, [.text(sessionID.uuidString), .text(sessionID.uuidString), .text(kind), .text(redactor.redact(String(summary.prefix(4000)))),
              .double(now.timeIntervalSince1970)])
    }

    public func agentEvents(sessionID: UUID) throws -> [(kind: String, summary: String)] {
        try db.query("SELECT kind, summary FROM agent_events WHERE session_id=? ORDER BY seq", [.text(sessionID.uuidString)])
            .map { ($0["kind"]?.text ?? "", $0["summary"]?.text ?? "") }
    }

    // MARK: settings

    public func setSetting<T: Encodable>(_ key: String, _ value: T) throws {
        let json = try JSONValue.from(value).encoded()
        try db.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(json)])
    }

    public func setting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let s = try db.query("SELECT value FROM settings WHERE key=?", [.text(key)]).first?["value"]?.text else { return nil }
        return try JSONValue.parse(s).decode(T.self)
    }

    // MARK: audit

    public func record(_ entry: AuditEntry) {
        _ = try? db.run("INSERT INTO audit_log(ts,category,action,decision,detail) VALUES(?,?,?,?,?)",
                        [.double(entry.timestamp.timeIntervalSince1970), .text(entry.category), .text(entry.action),
                         .text(entry.decision), .text(entry.detail)])
    }

    public func auditLog(limit: Int = 200) throws -> [AuditEntry] {
        try db.query("SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map {
            AuditEntry(timestamp: Date(timeIntervalSince1970: $0["ts"]?.double ?? 0), category: $0["category"]?.text ?? "",
                       action: $0["action"]?.text ?? "", decision: $0["decision"]?.text ?? "", detail: $0["detail"]?.text ?? "")
        }
    }
}
