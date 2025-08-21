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
            print("SQL was: \(sql)")
            return []
        }
        
        // Bind parameters
        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
                if let stringParam = param as? String {
                sqlite3_bind_text(statement, bindIndex, stringParam, Int32(stringParam.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let intParam = param as? Int {
                sqlite3_bind_int64(statement, bindIndex, Int64(intParam))
            } else if let doubleParam = param as? Double {
                sqlite3_bind_double(statement, bindIndex, doubleParam)
            } else if let dataParam = param as? Data {
                _ = dataParam.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, bindIndex, bytes.baseAddress, Int32(dataParam.count), nil)
                }
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
                case SQLITE_BLOB:
                    let blobBytes = sqlite3_column_bytes(statement, i)
                    if let blobPtr = sqlite3_column_blob(statement, i), blobBytes > 0 {
                        row[columnName] = Data(bytes: blobPtr, count: Int(blobBytes))
                    }
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
    
    public func getDocumentCount() throws -> Int {
        let sql = "SELECT COUNT(*) as count FROM documents"
        let results = query(sql)
        return results.first?["count"] as? Int ?? 0
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
                // Use SQLITE_TRANSIENT to force SQLite to make its own copy of the string
                sqlite3_bind_text(statement, bindIndex, stringVal, Int32(stringVal.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let intVal = value as? Int {
                sqlite3_bind_int64(statement, bindIndex, Int64(intVal))
            } else if let doubleVal = value as? Double {
                sqlite3_bind_double(statement, bindIndex, doubleVal)
            } else if let dataVal = value as? Data {
                _ = dataVal.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, bindIndex, bytes.baseAddress, Int32(dataVal.count), nil)
                }
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
            
                    print("Attempting to create basic schema...")
                    print("Database path: \(dbPath)")
                    
                    if execute(basicSchema) {
                        updateSchemaVersion(1)
                        print("Basic schema created successfully")
                    } else {
                        print("CRITICAL: Basic schema creation failed")
                        print("Database error: \(String(cString: sqlite3_errmsg(db)))")
                        print("Database path: \(dbPath)")
                        
                        // Try to provide recovery instead of fatal error
                        print("Attempting recovery by creating minimal schema...")
                        let minimalSchema = """
                        CREATE TABLE IF NOT EXISTS documents (
                            id TEXT PRIMARY KEY,
                            type TEXT NOT NULL,
                            title TEXT,
                            content TEXT,
                            app_source TEXT,
                            source_id TEXT,
                            created_at INTEGER,
                            updated_at INTEGER,
                            last_seen_at INTEGER,
                            deleted BOOLEAN DEFAULT FALSE
                        );
                        """
                        
                        if execute(minimalSchema) {
                            print("Minimal schema created successfully")
                            updateSchemaVersion(1)
                        } else {
                            fatalError("Failed to create even minimal schema - database may be corrupted or inaccessible")
                        }
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
        // Check for ENV variable first
        if let envPath = ProcessInfo.processInfo.environment["KENNY_PROJECT_ROOT"] {
            if FileManager.default.fileExists(atPath: envPath + "/migrations") {
                return envPath
            }
        }
        
        let currentPath = FileManager.default.currentDirectoryPath
        print("Current directory: \(currentPath)")
        
        // Search upward for migrations directory
        var searchPath = currentPath
        for _ in 0..<5 { // Limit search depth
            let candidatePaths = [
                searchPath + "/migrations",
                searchPath + "/mac_tools/migrations"
            ]
            
            for candidatePath in candidatePaths {
                if FileManager.default.fileExists(atPath: candidatePath) {
                    return candidatePath.hasSuffix("/mac_tools/migrations") ? 
                           searchPath + "/mac_tools" : searchPath
                }
            }
            
            // Move up one directory
            let parentPath = (searchPath as NSString).deletingLastPathComponent
            if parentPath == searchPath { break } // Reached root
            searchPath = parentPath
        }
        
        print("Could not find migrations directory, using current: \(currentPath)")
        return currentPath
    }
}

// MARK: - Search Extensions
extension Database {
    public func testSimpleSearch(_ searchQuery: String) -> [[String: Any]] {
        let sql = "SELECT d.id, d.title FROM documents_fts JOIN documents d ON documents_fts.rowid = d.rowid WHERE documents_fts MATCH ?"
        return query(sql, parameters: [searchQuery])
    }
    
    public func searchMultiDomain(_ searchQuery: String, types: [String] = [], limit: Int = 20) -> [SearchResult] {
        var whereClause = "documents_fts MATCH ?"
        var parameters: [Any] = [searchQuery]
        
        if !types.isEmpty {
            let typeList = types.map { "'\($0)'" }.joined(separator: ",")
            whereClause += " AND d.type IN (\(typeList))"
        }
        
        let sql = """
            SELECT d.id, d.type, d.title, d.content, d.app_source, d.source_path,
                   snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as search_snippet,
                   bm25(documents_fts) as rank,
                   COALESCE(ev.location, '') as context_info
            FROM documents_fts 
            JOIN documents d ON documents_fts.rowid = d.rowid
            LEFT JOIN events ev ON d.id = ev.document_id  
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
    
    // MARK: - Embedding Search Support
    
    /// Search for similar documents using cosine similarity with embeddings
    public func searchEmbeddings(queryVector: [Float], limit: Int = 20) -> [(String, Float, String)] {
        let sql = """
            SELECT d.id, d.title, d.content, e.vector, c.text as chunk_text
            FROM documents d
            JOIN chunks c ON d.id = c.document_id
            JOIN embeddings e ON c.id = e.chunk_id
            WHERE e.vector IS NOT NULL
            ORDER BY d.created_at DESC
            LIMIT 1000
        """
        
        var stmt: OpaquePointer?
        var results: [(String, Float, String)] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0),
                      let titlePtr = sqlite3_column_text(stmt, 1),
                      let contentPtr = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                
                let id = String(cString: idPtr)
                let _ = String(cString: titlePtr)  
                let content = String(cString: contentPtr)
                
                // Get chunk text for snippet
                let chunkText = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? content
                
                // Extract embedding vector from BLOB
                let blobBytes = sqlite3_column_bytes(stmt, 3)
                if let blobPtr = sqlite3_column_blob(stmt, 3), blobBytes > 0 {
                    let data = Data(bytes: blobPtr, count: Int(blobBytes))
                    if let vector = deserializeFloatArray(from: data) {
                        let similarity = cosineSimilarity(queryVector, vector)
                        if similarity > 0.1 { // Threshold for relevance
                            let snippet = String(chunkText.prefix(200))
                            results.append((id, similarity, snippet))
                        }
                    }
                }
            }
        }
        
        sqlite3_finalize(stmt)
        
        // Sort by similarity (descending) and limit
        return Array(results.sorted { $0.1 > $1.1 }.prefix(limit))
    }
    
    /// Serialize float array to Data for BLOB storage
    public func serializeFloatArray(_ array: [Float]) -> Data {
        return array.withUnsafeBytes { Data($0) }
    }
    
    /// Deserialize Data back to float array
    public func deserializeFloatArray(from data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self).prefix(count))
        }
    }
    
    /// Calculate cosine similarity between two vectors
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0.0 }
        
        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let magnitudeA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let magnitudeB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        
        guard magnitudeA > 0 && magnitudeB > 0 else { return 0.0 }
        
        return dotProduct / (magnitudeA * magnitudeB)
    }
    
    // MARK: - Chunk and Embedding Management
    
    /// Store chunks for a document
    public func storeChunks(_ chunks: [EmbeddingChunk]) -> Bool {
        for chunk in chunks {
            let now = Int(Date().timeIntervalSince1970)
            let metadataJson: String
            if let jsonData = try? JSONSerialization.data(withJSONObject: chunk.metadata),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                metadataJson = jsonString
            } else {
                metadataJson = "{}"
            }
            
            let chunkData: [String: Any] = [
                "id": chunk.id,
                "document_id": chunk.documentId,
                "text": chunk.text,
                "chunk_index": chunk.chunkIndex,
                "start_offset": chunk.startOffset,
                "end_offset": chunk.endOffset,
                "metadata_json": metadataJson,
                "created_at": now,
                "updated_at": now
            ]
            
            if !insert("chunks", data: chunkData) {
                print("Failed to store chunk: \(chunk.id)")
                return false
            }
        }
        return true
    }
    
    /// Store embedding vector for a chunk
    public func storeEmbedding(chunkId: String, vector: [Float], model: String) -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        let vectorData = serializeFloatArray(vector)
        
        let embeddingData: [String: Any] = [
            "id": UUID().uuidString,
            "chunk_id": chunkId,
            "model": model,
            "vector": vectorData,
            "dimensions": vector.count,
            "created_at": now
        ]
        
        return insert("embeddings", data: embeddingData)
    }
    
    /// Get chunks for a document that don't have embeddings yet
    public func getUnembeddedChunks(for documentId: String? = nil) -> [[String: Any]] {
        var sql = """
            SELECT c.id, c.document_id, c.text, c.chunk_index
            FROM chunks c
            LEFT JOIN embeddings e ON c.id = e.chunk_id
            WHERE e.id IS NULL
        """
        
        var parameters: [Any] = []
        
        if let documentId = documentId {
            sql += " AND c.document_id = ?"
            parameters.append(documentId)
        }
        
        sql += " ORDER BY c.document_id, c.chunk_index LIMIT 100"
        
        return query(sql, parameters: parameters)
    }
    
    /// Check if document has embeddings
    public func hasEmbeddings(for documentId: String) -> Bool {
        let sql = """
            SELECT COUNT(*) as count
            FROM chunks c
            JOIN embeddings e ON c.id = e.chunk_id
            WHERE c.document_id = ?
        """
        
        let result = query(sql, parameters: [documentId])
        return (result.first?["count"] as? Int64 ?? 0) > 0
    }
    
    /// Get embedding statistics
    public func getEmbeddingStats() -> [String: Any] {
        let totalChunks = query("SELECT COUNT(*) as count FROM chunks").first?["count"] as? Int64 ?? 0
        let embeddedChunks = query("SELECT COUNT(*) as count FROM embeddings").first?["count"] as? Int64 ?? 0
        let unembeddedChunks = totalChunks - embeddedChunks
        
        let modelStats = query("""
            SELECT model, COUNT(*) as count, AVG(dimensions) as avg_dimensions
            FROM embeddings
            GROUP BY model
        """)
        
        return [
            "total_chunks": totalChunks,
            "embedded_chunks": embeddedChunks,
            "unembedded_chunks": unembeddedChunks,
            "embedding_coverage": totalChunks > 0 ? Double(embeddedChunks) / Double(totalChunks) : 0.0,
            "models": modelStats
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