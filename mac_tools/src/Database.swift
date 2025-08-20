import Foundation
import SQLite3

public class Database {
    internal var db: OpaquePointer?
    private let dbPath: String
    
    public init(path: String? = nil) {
        if let customPath = path {
            dbPath = customPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, 
                                                     in: .userDomainMask).first!
            let assistantDir = appSupport.appendingPathComponent("Assistant")
            try? FileManager.default.createDirectory(at: assistantDir, 
                                                   withIntermediateDirectories: true)
            dbPath = assistantDir.appendingPathComponent("assistant.db").path
        }
        
        openDatabase()
        setupWAL()
        runMigrations()
    }
    
    deinit {
        closeDatabase()
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            fatalError("Unable to open database at \(dbPath)")
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func setupWAL() {
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA foreign_keys=ON")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA temp_store=MEMORY")
        execute("PRAGMA mmap_size=268435456") // 256MB
    }
    
    @discardableResult
    func execute(_ sql: String) -> Bool {
        // Handle multi-statement SQL by splitting and executing each statement
        let statements = sql.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        for statement in statements {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_prepare_v2(db, statement, -1, &stmt, nil) != SQLITE_OK {
                print("ERROR preparing statement: \(String(cString: sqlite3_errmsg(db)))")
                print("Statement: \(statement)")
                return false
            }
            
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE && result != SQLITE_ROW {
                print("ERROR executing statement: \(String(cString: sqlite3_errmsg(db)))")
                print("Statement: \(statement)")
                return false
            }
        }
        
        return true
    }
    
    public func query(_ sql: String, parameters: [Any] = []) -> [[String: Any]] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("ERROR preparing query: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        
        // Bind parameters
        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            if let stringParam = param as? String {
                sqlite3_bind_text(statement, bindIndex, stringParam, -1, nil)
            } else if let intParam = param as? Int {
                sqlite3_bind_int64(statement, bindIndex, Int64(intParam))
            } else if let doubleParam = param as? Double {
                sqlite3_bind_double(statement, bindIndex, doubleParam)
            } else if param is NSNull {
                sqlite3_bind_null(statement, bindIndex)
            }
        }
        
        var results: [[String: Any]] = []
        let columnCount = sqlite3_column_count(statement)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(statement, i))
                let columnType = sqlite3_column_type(statement, i)
                
                switch columnType {
                case SQLITE_TEXT:
                    row[columnName] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_INTEGER:
                    row[columnName] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    row[columnName] = sqlite3_column_double(statement, i)
                case SQLITE_NULL:
                    row[columnName] = NSNull()
                default:
                    break
                }
            }
            results.append(row)
        }
        
        return results
    }
    
    public func insert(_ table: String, data: [String: Any]) -> Bool {
        let sortedKeys = data.keys.sorted()
        let columns = sortedKeys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("ERROR preparing insert: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // Bind parameters in same order as columns
        for (index, key) in sortedKeys.enumerated() {
            let value = data[key]
            let bindIndex = Int32(index + 1)
            
            if let stringVal = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringVal, -1, nil)
            } else if let intVal = value as? Int {
                sqlite3_bind_int64(statement, bindIndex, Int64(intVal))
            } else if let doubleVal = value as? Double {
                sqlite3_bind_double(statement, bindIndex, doubleVal)
            } else if value is NSNull {
                sqlite3_bind_null(statement, bindIndex)
            }
        }
        
        if sqlite3_step(statement) != SQLITE_DONE {
            print("ERROR executing insert: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    
    func search(_ query: String, table: String = "documents_fts", limit: Int = 20) -> [[String: Any]] {
        let sql = """
            SELECT d.*, 
                   snippet(\(table), 1, '<mark>', '</mark>', '...', 32) as snippet,
                   rank
            FROM \(table) 
            JOIN documents d ON \(table).rowid = d.rowid
            WHERE \(table) MATCH ?
            ORDER BY rank
            LIMIT ?
        """
        return self.query(sql, parameters: [query, limit])
    }
    
    // Migration system
    private func runMigrations() {
        createSchemaMigrationsTable()
        
        let currentVersion = getCurrentSchemaVersion()
        print("Current schema version: \(currentVersion)")
        
        // Run migrations up to version 3 (includes embeddings)
        let targetVersion = 3
        
        if currentVersion < targetVersion {
            for version in (currentVersion + 1)...targetVersion {
                let migrationFile = String(format: "%03d_", version)
                if let migration = loadMigration(startingWith: migrationFile) {
                    print("Applying migration version \(version)...")
                    execute(migration)
                    updateSchemaVersion(version)
                } else if currentVersion == 0 && version == 1 {
                    // Fallback: Create basic schema for version 1
                    print("Using fallback schema for version 1...")
                    let basicSchema = """
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT,
                app_source TEXT NOT NULL,
                source_id TEXT,
                source_path TEXT,
                hash TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL,
                deleted BOOLEAN DEFAULT FALSE,
                metadata_json TEXT,
                UNIQUE(app_source, source_id)
            );
            
            CREATE TABLE IF NOT EXISTS emails (
                document_id TEXT PRIMARY KEY REFERENCES documents(id),
                thread_id TEXT,
                message_id TEXT UNIQUE,
                from_address TEXT,
                from_name TEXT,
                to_addresses TEXT,
                cc_addresses TEXT,
                bcc_addresses TEXT,
                date_sent INTEGER,
                date_received INTEGER,
                is_read BOOLEAN DEFAULT FALSE,
                is_flagged BOOLEAN DEFAULT FALSE,
                mailbox TEXT,
                snippet TEXT
            );
            
            CREATE TABLE IF NOT EXISTS messages (
                document_id TEXT PRIMARY KEY REFERENCES documents(id),
                thread_id TEXT,
                from_contact TEXT,
                date_sent INTEGER,
                is_from_me BOOLEAN DEFAULT FALSE,
                is_read BOOLEAN DEFAULT FALSE,
                service TEXT,
                chat_name TEXT,
                has_attachments BOOLEAN DEFAULT FALSE
            );
            
            CREATE TABLE IF NOT EXISTS events (
                document_id TEXT PRIMARY KEY REFERENCES documents(id),
                start_time INTEGER NOT NULL,
                end_time INTEGER,
                location TEXT
            );
            
            CREATE TABLE IF NOT EXISTS contacts (
                document_id TEXT PRIMARY KEY REFERENCES documents(id),
                first_name TEXT,
                last_name TEXT,
                full_name TEXT
            );
            
            CREATE TABLE IF NOT EXISTS files (
                document_id TEXT PRIMARY KEY REFERENCES documents(id),
                file_size INTEGER,
                mime_type TEXT,
                parent_directory TEXT
            );
            
            CREATE TABLE IF NOT EXISTS orchestrator_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                event TEXT NOT NULL,
                type TEXT NOT NULL,
                user_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                success BOOLEAN,
                duration_ms INTEGER,
                error TEXT,
                UNIQUE(request_id, event)
            );
            
            CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
                title, content, content='documents', content_rowid='rowid'
            );
            
            -- FTS triggers
            DROP TRIGGER IF EXISTS documents_fts_insert;
            CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, title, content) VALUES (new.rowid, new.title, new.content);
            END;
            
            DROP TRIGGER IF EXISTS documents_fts_delete;  
            CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, content) VALUES ('delete', old.rowid, old.title, old.content);
            END;
            
            DROP TRIGGER IF EXISTS documents_fts_update;
            CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, content) VALUES ('delete', old.rowid, old.title, old.content);
                INSERT INTO documents_fts(rowid, title, content) VALUES (new.rowid, new.title, new.content);
            END;
            """
            
                    if execute(basicSchema) {
                        updateSchemaVersion(1)
                        print("Basic schema created successfully")
                    } else {
                        fatalError("Failed to create basic schema")
                    }
                } else {
                    print("Warning: Could not find migration for version \(version)")
                }
            }
        }
        
        print("Schema migration complete. Current version: \(getCurrentSchemaVersion())")
    }
    
    private func createSchemaMigrationsTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        )
        """
        execute(sql)
    }
    
    private func getCurrentSchemaVersion() -> Int {
        let result = query("SELECT MAX(version) as version FROM schema_migrations")
        if let row = result.first, let version = row["version"] as? Int64 {
            return Int(version)
        }
        return 0
    }
    
    private func updateSchemaVersion(_ version: Int) {
        let now = Int(Date().timeIntervalSince1970)
        execute("INSERT INTO schema_migrations (version, applied_at) VALUES (\(version), \(now))")
    }
    
    private func getMigrationFiles() -> [String] {
        let migrationsPath = getProjectRoot() + "/migrations"
        print("Looking for migrations in: \(migrationsPath)")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsPath) else {
            print("Failed to read migration directory: \(migrationsPath)")
            return []
        }
        let sqlFiles = files.filter { $0.hasSuffix(".sql") }
        print("Found migration files: \(sqlFiles)")
        return sqlFiles
    }
    
    private func extractVersionFromFilename(_ filename: String) -> Int {
        let pattern = #"^(\d+)_.*\.sql$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(filename.startIndex..., in: filename)
        
        if let match = regex.firstMatch(in: filename, range: range) {
            let versionRange = Range(match.range(at: 1), in: filename)!
            return Int(filename[versionRange]) ?? 0
        }
        return 0
    }
    
    private func loadMigration(startingWith prefix: String) -> String? {
        let migrationsPath = getProjectRoot() + "/migrations"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsPath) else {
            print("Could not read migrations directory: \(migrationsPath)")
            return nil
        }
        
        // Find file starting with the prefix (e.g., "003_")
        if let filename = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".sql") }) {
            return try? String(contentsOfFile: migrationsPath + "/" + filename)
        }
        
        return nil
    }
    
    private func loadMigrationSQL(_ filename: String) -> String? {
        let migrationsPath = getProjectRoot() + "/migrations/" + filename
        return try? String(contentsOfFile: migrationsPath)
    }
    
    private func getProjectRoot() -> String {
        // In a real app, this would be the app bundle or a known path
        // For now, try to find the project directory containing migrations
        let currentPath = FileManager.default.currentDirectoryPath
        print("Current directory: \(currentPath)")
        
        // Try current directory first
        let migrationsPath1 = currentPath + "/migrations"
        if FileManager.default.fileExists(atPath: migrationsPath1) {
            return currentPath
        }
        
        // Try mac_tools subdirectory
        let migrationsPath2 = currentPath + "/mac_tools/migrations"  
        if FileManager.default.fileExists(atPath: migrationsPath2) {
            return currentPath + "/mac_tools"
        }
        
        // Fallback to hardcoded path
        let fallbackPath = "/Users/joshwlim/Documents/Kenny/mac_tools"
        if FileManager.default.fileExists(atPath: fallbackPath + "/migrations") {
            return fallbackPath
        }
        
        print("Could not find migrations directory, using current: \(currentPath)")
        return currentPath
    }
}

// MARK: - Search Extensions
extension Database {
    public func searchMultiDomain(_ searchQuery: String, types: [String] = [], limit: Int = 20) -> [SearchResult] {
        var whereClause = "documents_fts MATCH ?"
        var parameters: [Any] = [searchQuery]
        
        if !types.isEmpty {
            let typeList = types.map { "'\($0)'" }.joined(separator: ",")
            whereClause += " AND d.type IN (\(typeList))"
        }
        
        let sql = """
            SELECT d.*, 
                   snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as search_snippet,
                   bm25(documents_fts) as rank,
                   CASE d.type
                       WHEN 'email' THEN COALESCE(e.from_name, '') || ' <' || COALESCE(e.from_address, '') || '>'
                       WHEN 'event' THEN COALESCE(ev.location, '')
                       WHEN 'file' THEN COALESCE(f.parent_directory, '') || '/' || d.title
                       ELSE d.app_source
                   END as context_info
            FROM documents_fts 
            JOIN documents d ON documents_fts.rowid = d.rowid
            LEFT JOIN emails e ON d.id = e.document_id
            LEFT JOIN events ev ON d.id = ev.document_id  
            LEFT JOIN files f ON d.id = f.document_id
            WHERE \(whereClause)
            ORDER BY rank
            LIMIT ?
        """
        
        parameters.append(limit)
        let results = query(sql, parameters: parameters)
        
        return results.map { row in
            SearchResult(
                id: row["id"] as? String ?? "",
                type: row["type"] as? String ?? "",
                title: row["title"] as? String ?? "",
                snippet: row["search_snippet"] as? String ?? "",
                contextInfo: row["context_info"] as? String ?? "",
                rank: row["rank"] as? Double ?? 0.0,
                sourcePath: row["source_path"] as? String
            )
        }
    }
    
    func findRelated(_ documentId: String, limit: Int = 10) -> [SearchResult] {
        let sql = """
            SELECT DISTINCT d2.*, 
                   r.relationship_type,
                   r.strength
            FROM relationships r
            JOIN documents d2 ON (r.to_document_id = d2.id OR r.from_document_id = d2.id)
            WHERE (r.from_document_id = ? OR r.to_document_id = ?) 
              AND d2.id != ?
              AND d2.deleted = FALSE
            ORDER BY r.strength DESC, d2.updated_at DESC
            LIMIT ?
        """
        
        let results = query(sql, parameters: [documentId, documentId, documentId, limit])
        return results.map { row in
            SearchResult(
                id: row["id"] as? String ?? "",
                type: row["type"] as? String ?? "",
                title: row["title"] as? String ?? "",
                snippet: String((row["content"] as? String ?? "").prefix(200)),
                contextInfo: row["relationship_type"] as? String ?? "",
                rank: row["strength"] as? Double ?? 0.0,
                sourcePath: row["source_path"] as? String
            )
        }
    }
    
    /// Get database statistics
    public func getStats() -> [String: Any] {
        let documentCount = query("SELECT COUNT(*) as count FROM documents").first?["count"] as? Int64 ?? 0
        let emailCount = query("SELECT COUNT(*) as count FROM emails").first?["count"] as? Int64 ?? 0
        let eventCount = query("SELECT COUNT(*) as count FROM events").first?["count"] as? Int64 ?? 0
        let contactCount = query("SELECT COUNT(*) as count FROM contacts").first?["count"] as? Int64 ?? 0
        let messageCount = query("SELECT COUNT(*) as count FROM messages").first?["count"] as? Int64 ?? 0
        let fileCount = query("SELECT COUNT(*) as count FROM files").first?["count"] as? Int64 ?? 0
        
        return [
            "total_documents": documentCount,
            "emails": emailCount,
            "events": eventCount,
            "contacts": contactCount,
            "messages": messageCount,
            "files": fileCount,
            "database_path": dbPath
        ]
    }
}

public struct SearchResult: Codable {
    public let id: String
    public let type: String
    public let title: String
    public let snippet: String
    public let contextInfo: String
    public let rank: Double
    public let sourcePath: String?
}