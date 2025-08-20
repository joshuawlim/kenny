import Foundation
import SQLite3

public class Database {
    private var db: OpaquePointer?
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
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            print("ERROR preparing statement: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        if sqlite3_step(statement) != SQLITE_DONE {
            print("ERROR executing statement: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    
    func query(_ sql: String, parameters: [Any] = []) -> [[String: Any]] {
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
        let columns = data.keys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("ERROR preparing insert: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // Bind parameters in order
        for (index, key) in data.keys.sorted().enumerated() {
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
        let currentVersion = getCurrentSchemaVersion()
        let migrationFiles = getMigrationFiles()
        
        for file in migrationFiles.sorted() {
            let version = extractVersionFromFilename(file)
            if version > currentVersion {
                print("Running migration: \(file)")
                if let migrationSQL = loadMigrationSQL(file) {
                    if execute(migrationSQL) {
                        updateSchemaVersion(version)
                        print("Migration \(version) completed")
                    } else {
                        fatalError("Migration \(version) failed")
                    }
                }
            }
        }
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
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsPath) else {
            return []
        }
        return files.filter { $0.hasSuffix(".sql") }
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
    
    private func loadMigrationSQL(_ filename: String) -> String? {
        let migrationsPath = getProjectRoot() + "/migrations/" + filename
        return try? String(contentsOfFile: migrationsPath)
    }
    
    private func getProjectRoot() -> String {
        // In a real app, this would be the app bundle or a known path
        // For now, assume we're running from the project directory
        return FileManager.default.currentDirectoryPath
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
                       WHEN 'email' THEN e.from_name || ' <' || e.from_address || '>'
                       WHEN 'event' THEN ev.location
                       WHEN 'file' THEN f.file_path
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