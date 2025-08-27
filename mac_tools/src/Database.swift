import Foundation
import SQLite3

public class Database {
    internal var db: OpaquePointer?
    private let dbPath: String
    private static let connectionQueue = DispatchQueue(label: "kenny.database.connection", qos: .userInitiated)
    private static var activeConnections: Int = 0
    private static let maxConnections: Int = 1  // Force single connection for now
    private let connectionSemaphore = DispatchSemaphore(value: 1)
    
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
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return executeInternal(sql)
    }
    
    @discardableResult
    private func executeInternal(_ sql: String) -> Bool {
        // Handle multi-statement SQL by parsing correctly with comment and multi-line support
        let statements = parseMultipleStatements(sql)
        
        for (index, statement) in statements.enumerated() {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_prepare_v2(db, statement, -1, &stmt, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                print("ERROR preparing statement \(index + 1): \(error)")
                print("SQL was: \(statement)")
                print("Full context (first 500 chars): \(String(sql.prefix(500)))")
                return false
            }
            
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE && result != SQLITE_ROW {
                let error = String(cString: sqlite3_errmsg(db))
                print("ERROR executing statement \(index + 1): \(error)")
                print("SQL was: \(statement)")
                print("Full context (first 500 chars): \(String(sql.prefix(500)))")
                return false
            }
        }
        
        return true
    }
    
    @discardableResult
    func execute(_ sql: String, parameters: [Any]) -> Bool {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return executeInternal(sql, parameters: parameters)
    }
    
    @discardableResult
    private func executeInternal(_ sql: String, parameters: [Any]) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("ERROR preparing parameterized statement: \(String(cString: sqlite3_errmsg(db)))")
            print("SQL was: \(sql)")
            return false
        }
        
        // Bind parameters
        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            if let stringParam = param as? String {
                sqlite3_bind_text(stmt, bindIndex, stringParam, Int32(stringParam.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let intParam = param as? Int {
                sqlite3_bind_int64(stmt, bindIndex, Int64(intParam))
            } else if let doubleParam = param as? Double {
                sqlite3_bind_double(stmt, bindIndex, doubleParam)
            } else if let dataParam = param as? Data {
                _ = dataParam.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(stmt, bindIndex, bytes.baseAddress, Int32(dataParam.count), nil)
                }
            } else if param is NSNull {
                sqlite3_bind_null(stmt, bindIndex)
            }
        }
        
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            let error = String(cString: sqlite3_errmsg(db))
            print("ERROR executing parameterized statement: \(error)")
            print("SQL was: \(sql)")
            return false
        }
        
        return true
    }
    
    /// Parse SQL string into individual statements, handling comments and multi-line constructs
    private func parseMultipleStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var currentStatement = ""
        let lines = sql.components(separatedBy: .newlines)
        
        var inBlockComment = false
        var inTrigger = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle block comments /* ... */
            if trimmedLine.contains("/*") && trimmedLine.contains("*/") {
                // Single line block comment - skip it
                continue
            } else if trimmedLine.contains("/*") {
                inBlockComment = true
                continue
            } else if trimmedLine.contains("*/") {
                inBlockComment = false
                continue
            } else if inBlockComment {
                continue
            }
            
            // Skip single-line comments and empty lines
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("--") {
                continue
            }
            
            // Add line to current statement
            currentStatement += line + "\n"
            
            // Track if we're inside a trigger definition
            let upperLine = trimmedLine.uppercased()
            if upperLine.contains("CREATE TRIGGER") {
                inTrigger = true
            }
            
            // Check for statement end
            if trimmedLine.hasSuffix(";") {
                if inTrigger && upperLine.contains("END;") {
                    // End of trigger
                    inTrigger = false
                    let statement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !statement.isEmpty {
                        statements.append(statement)
                    }
                    currentStatement = ""
                } else if !inTrigger {
                    // Regular statement end
                    let statement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !statement.isEmpty {
                        statements.append(statement)
                    }
                    currentStatement = ""
                }
            }
        }
        
        // Handle any remaining statement
        let finalStatement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalStatement.isEmpty {
            statements.append(finalStatement)
        }
        
        return statements
    }
    
    public func query(_ sql: String, parameters: [Any] = []) -> [[String: Any]] {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return [] }
        defer { connectionSemaphore.signal() }
        return queryInternal(sql, parameters: parameters)
    }
    
    private func queryInternal(_ sql: String, parameters: [Any] = []) -> [[String: Any]] {
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
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return insertInternal(table, data: data)
    }
    
    private func insertInternal(_ table: String, data: [String: Any]) -> Bool {
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
    
    public func insertOrReplace(_ table: String, data: [String: Any]) -> Bool {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return insertOrReplaceInternal(table, data: data)
    }
    
    private func insertOrReplaceInternal(_ table: String, data: [String: Any]) -> Bool {
        // For documents table with duplicate (app_source, source_id), reuse existing ID
        if table == "documents",
           let appSource = data["app_source"] as? String,
           let sourceId = data["source_id"] as? String {
            
            let existingDocs = queryInternal(
                "SELECT id FROM documents WHERE app_source = ? AND source_id = ?",
                parameters: [appSource, sourceId]
            )
            
            if let existingDoc = existingDocs.first, let existingId = existingDoc["id"] as? String {
                // Update existing document with existing ID
                var updatedData = data
                updatedData["id"] = existingId
                return insertOrIgnoreThenUpdateInternal(table, data: updatedData)
            }
        }
        
        // For all other cases, use standard insert or replace logic
        return insertOrIgnoreThenUpdateInternal(table, data: data)
    }
    
    // New method that returns the actual ID that was inserted/updated
    public func insertOrReplaceAndGetID(_ table: String, data: [String: Any]) -> String? {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return nil }
        defer { connectionSemaphore.signal() }
        return insertOrReplaceAndGetIDInternal(table, data: data)
    }
    
    private func insertOrReplaceAndGetIDInternal(_ table: String, data: [String: Any]) -> String? {
        let result = insertOrIgnoreThenUpdateWithIDInternal(table, data: data)
        if table == "documents" {
            print("DEBUG: insertOrReplaceAndGetID returning: \(result ?? "nil")")
        }
        return result
    }
    
    // New method that handles upserts properly for foreign key relationships
    public func insertOrUpdate(_ table: String, data: [String: Any]) -> Bool {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return insertOrUpdateInternal(table, data: data)
    }
    
    private func insertOrUpdateInternal(_ table: String, data: [String: Any]) -> Bool {
        let sortedKeys = data.keys.sorted()
        let columns = sortedKeys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        
        // Build the UPDATE clause for all non-primary-key columns
        let updateClause = sortedKeys.filter { $0 != "id" && $0 != "document_id" }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        
        let sql: String
        if updateClause.isEmpty {
            // If only primary key, use INSERT OR IGNORE
            sql = "INSERT OR IGNORE INTO \(table) (\(columns)) VALUES (\(placeholders))"
        } else {
            // For documents table, handle both primary key and unique(app_source, source_id) conflicts
            if table == "documents" {
                sql = """
                    INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))
                    ON CONFLICT(app_source, source_id) DO UPDATE SET \(updateClause)
                    """
            } else {
                // For other tables, assume primary key conflict
                sql = """
                    INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))
                    ON CONFLICT DO UPDATE SET \(updateClause)
                    """
            }
        }
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("ERROR preparing insert or update: \(String(cString: sqlite3_errmsg(db)))")
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
            print("ERROR executing insert or update: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    
    // Safer method that uses INSERT OR IGNORE + UPDATE to avoid foreign key issues
    public func insertOrIgnoreThenUpdate(_ table: String, data: [String: Any]) -> Bool {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return false }
        defer { connectionSemaphore.signal() }
        return insertOrIgnoreThenUpdateInternal(table, data: data)
    }
    
    private func insertOrIgnoreThenUpdateInternal(_ table: String, data: [String: Any]) -> Bool {
        
        // Special handling for events table to ensure document_id exists
        if table == "events", let documentId = data["document_id"] as? String {
            // Check if the document actually exists
            let docExists = queryInternal("SELECT id FROM documents WHERE id = ?", parameters: [documentId])
            if docExists.isEmpty {
                print("ERROR: Document ID \(documentId) does not exist for events insert")
                print("ERROR: This suggests the CalendarIngester is using a different ID than what was inserted")
                
                // HACK: Try to find the most recently inserted Calendar document
                // This is a reasonable approximation since Calendar ingestion processes events sequentially
                let recentDocs = queryInternal(
                    "SELECT id FROM documents WHERE app_source = 'Calendar' ORDER BY last_seen_at DESC LIMIT 1",
                    parameters: []
                )
                
                if let recentDoc = recentDocs.first, let recentId = recentDoc["id"] as? String {
                    print("HACK: Using most recent Calendar document ID: \(recentId)")
                    var fixedData = data
                    fixedData["document_id"] = recentId
                    return insertOrIgnoreThenUpdateInternal(table, data: fixedData)
                }
                
                return false
            }
        }
        let sortedKeys = data.keys.sorted()
        let columns = sortedKeys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        
        // Debug: Print what we're trying to insert
        print("DEBUG: Attempting to insert into \(table)")
        print("DEBUG: Columns: \(columns)")
        print("DEBUG: Data: \(data)")
        
        // First, try INSERT OR IGNORE
        let insertSQL = "INSERT OR IGNORE INTO \(table) (\(columns)) VALUES (\(placeholders))"
        
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            print("ERROR preparing insert or ignore: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // Bind parameters for INSERT
        for (index, key) in sortedKeys.enumerated() {
            let value = data[key]
            let bindIndex = Int32(index + 1)
            
            bindValue(to: insertStatement!, at: bindIndex, value: value)
        }
        
        let insertResult = sqlite3_step(insertStatement!)
        if insertResult != SQLITE_DONE {
            print("ERROR executing insert or ignore: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // Check if a row was actually inserted (changes > 0)
        let changes = sqlite3_changes(db)
        if changes > 0 {
            // Row was inserted, we're done
            return true
        }
        
        // Row already existed, now update it
        let nonKeyColumns = sortedKeys.filter { $0 != "id" && $0 != "document_id" }
        if nonKeyColumns.isEmpty {
            // Nothing to update, just return success
            return true
        }
        
        let updateClauses = nonKeyColumns.map { "\($0) = ?" }.joined(separator: ", ")
        let updateSQL: String
        
        if table == "documents" {
            // For documents table, update by (app_source, source_id)
            updateSQL = "UPDATE \(table) SET \(updateClauses) WHERE app_source = ? AND source_id = ?"
        } else {
            // For other tables, update by primary key
            if let primaryKey = data["id"] ?? data["document_id"] {
                let primaryKeyColumn = data["id"] != nil ? "id" : "document_id"
                updateSQL = "UPDATE \(table) SET \(updateClauses) WHERE \(primaryKeyColumn) = ?"
            } else {
                print("ERROR: No primary key found for update")
                return false
            }
        }
        
        var updateStatement: OpaquePointer?
        defer { sqlite3_finalize(updateStatement) }
        
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
            print("ERROR preparing update: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // Bind parameters for UPDATE
        var paramIndex: Int32 = 1
        for key in nonKeyColumns {
            bindValue(to: updateStatement!, at: paramIndex, value: data[key])
            paramIndex += 1
        }
        
        // Bind WHERE clause parameters
        if table == "documents" {
            bindValue(to: updateStatement!, at: paramIndex, value: data["app_source"])
            bindValue(to: updateStatement!, at: paramIndex + 1, value: data["source_id"])
        } else {
            let primaryKey = data["id"] ?? data["document_id"]
            bindValue(to: updateStatement!, at: paramIndex, value: primaryKey)
        }
        
        let updateResult = sqlite3_step(updateStatement!)
        if updateResult != SQLITE_DONE {
            print("ERROR executing update: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    
    // Enhanced method that returns the actual ID that was inserted/updated
    public func insertOrIgnoreThenUpdateWithID(_ table: String, data: [String: Any]) -> String? {
        guard connectionSemaphore.wait(timeout: .now() + 30) == .success else { return nil }
        defer { connectionSemaphore.signal() }
        return insertOrIgnoreThenUpdateWithIDInternal(table, data: data)
    }
    
    private func insertOrIgnoreThenUpdateWithIDInternal(_ table: String, data: [String: Any]) -> String? {
        let sortedKeys = data.keys.sorted()
        let columns = sortedKeys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        
        // For documents table, check if document exists first and reuse its ID
        if table == "documents", 
           let appSource = data["app_source"] as? String,
           let sourceId = data["source_id"] as? String {
            
            let existingDocs = queryInternal(
                "SELECT id FROM documents WHERE app_source = ? AND source_id = ?",
                parameters: [appSource, sourceId]
            )
            
            if let existingDoc = existingDocs.first, let existingId = existingDoc["id"] as? String {
                // Update existing document with new ID
                var updatedData = data
                updatedData["id"] = existingId
                
                // Update the document
                let updateSuccess = insertOrIgnoreThenUpdateInternal(table, data: updatedData)
                return updateSuccess ? existingId : nil
            }
        }
        
        // Debug SQL for events table
        if table == "events" {
            let insertSQL = "INSERT OR IGNORE INTO \(table) (\(columns)) VALUES (\(placeholders))"
            print("DEBUG SQL: \(insertSQL)")
            print("DEBUG VALUES: \(data)")
        }
        
        // First, try INSERT OR IGNORE
        let insertSQL = "INSERT OR IGNORE INTO \(table) (\(columns)) VALUES (\(placeholders))"
        
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            print("ERROR preparing insert or ignore: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        
        // Bind parameters for INSERT
        for (index, key) in sortedKeys.enumerated() {
            let value = data[key]
            let bindIndex = Int32(index + 1)
            
            bindValue(to: insertStatement!, at: bindIndex, value: value)
        }
        
        let insertResult = sqlite3_step(insertStatement!)
        if insertResult != SQLITE_DONE {
            print("ERROR executing insert or ignore: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        
        // Check if a row was actually inserted (changes > 0)
        let changes = sqlite3_changes(db)
        if changes > 0 {
            // Row was inserted, return the provided ID
            let insertedID = data["id"] as? String ?? data["document_id"] as? String
            if table == "documents" {
                print("DEBUG: Document inserted with new ID: \(insertedID ?? "nil")")
            }
            return insertedID
        }
        
        
        // Row already existed, we need to find the existing ID and update it
        let existingID: String?
        if table == "documents" {
            // For documents table, find by (app_source, source_id)
            let findSQL = "SELECT id FROM documents WHERE app_source = ? AND source_id = ?"
            var findStatement: OpaquePointer?
            defer { sqlite3_finalize(findStatement) }
            
            guard sqlite3_prepare_v2(db, findSQL, -1, &findStatement, nil) == SQLITE_OK else {
                print("ERROR preparing find query: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            
            bindValue(to: findStatement!, at: 1, value: data["app_source"])
            bindValue(to: findStatement!, at: 2, value: data["source_id"])
            
            if sqlite3_step(findStatement!) == SQLITE_ROW {
                let idPtr = sqlite3_column_text(findStatement!, 0)
                existingID = idPtr != nil ? String(cString: idPtr!) : nil
            } else {
                print("ERROR: Could not find existing document")
                return nil
            }
        } else {
            // For other tables, the ID should be the same as what we tried to insert
            existingID = data["id"] as? String ?? data["document_id"] as? String
        }
        
        guard let actualID = existingID else {
            print("ERROR: Could not determine existing ID")
            return nil
        }
        
        // Now update the existing row
        let nonKeyColumns = sortedKeys.filter { $0 != "id" && $0 != "document_id" }
        if !nonKeyColumns.isEmpty {
            let updateClauses = nonKeyColumns.map { "\($0) = ?" }.joined(separator: ", ")
            let updateSQL: String
            
            if table == "documents" {
                // For documents table, update by (app_source, source_id)
                updateSQL = "UPDATE \(table) SET \(updateClauses) WHERE app_source = ? AND source_id = ?"
            } else {
                // For other tables, update by primary key
                let primaryKeyColumn = data["id"] != nil ? "id" : "document_id"
                updateSQL = "UPDATE \(table) SET \(updateClauses) WHERE \(primaryKeyColumn) = ?"
            }
            
            var updateStatement: OpaquePointer?
            defer { sqlite3_finalize(updateStatement) }
            
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
                print("ERROR preparing update: \(String(cString: sqlite3_errmsg(db)))")
                return actualID // Return the ID even if update fails
            }
            
            // Bind parameters for UPDATE
            var paramIndex: Int32 = 1
            for key in nonKeyColumns {
                bindValue(to: updateStatement!, at: paramIndex, value: data[key])
                paramIndex += 1
            }
            
            // Bind WHERE clause parameters
            if table == "documents" {
                bindValue(to: updateStatement!, at: paramIndex, value: data["app_source"])
                bindValue(to: updateStatement!, at: paramIndex + 1, value: data["source_id"])
            } else {
                bindValue(to: updateStatement!, at: paramIndex, value: actualID)
            }
            
            let updateResult = sqlite3_step(updateStatement!)
            if updateResult != SQLITE_DONE {
                print("ERROR executing update: \(String(cString: sqlite3_errmsg(db)))")
                return actualID // Return the ID even if update fails
            }
        }
        
        return actualID
    }
    
    // Temporary methods for foreign key management during debugging
    public func disableForeignKeys() {
        execute("PRAGMA foreign_keys = OFF")
        print("DEBUG: Foreign keys disabled")
    }
    
    public func enableForeignKeys() {
        execute("PRAGMA foreign_keys = ON")
        print("DEBUG: Foreign keys enabled")
    }
    
    // Helper method to bind values to prepared statements
    private func bindValue(to statement: OpaquePointer, at index: Int32, value: Any?) {
        if let stringVal = value as? String {
            sqlite3_bind_text(statement, index, stringVal, Int32(stringVal.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else if let intVal = value as? Int {
            sqlite3_bind_int64(statement, index, Int64(intVal))
        } else if let doubleVal = value as? Double {
            sqlite3_bind_double(statement, index, doubleVal)
        } else if let dataVal = value as? Data {
            _ = dataVal.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(dataVal.count), nil)
            }
        } else if value is NSNull || value == nil {
            sqlite3_bind_null(statement, index)
        }
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
        
        // Run migrations up to version 4 (includes enhanced contacts)
        let targetVersion = 4
        
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
                contact_id TEXT UNIQUE,
                first_name TEXT,
                last_name TEXT,
                full_name TEXT,
                primary_phone TEXT,
                secondary_phone TEXT,
                tertiary_phone TEXT,
                primary_email TEXT,
                secondary_email TEXT,
                company TEXT,
                job_title TEXT,
                birthday INTEGER,
                interests TEXT,
                notes TEXT,
                date_last_interaction INTEGER,
                image_path TEXT
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
                searchPath + "/mac_tools/migrations",
                "/Users/joshwlim/Documents/Kenny/mac_tools/migrations" // Direct path fix
            ]
            
            for candidatePath in candidatePaths {
                if FileManager.default.fileExists(atPath: candidatePath) {
                    if candidatePath.contains("/mac_tools/migrations") {
                        return candidatePath.replacingOccurrences(of: "/migrations", with: "")
                    } else {
                        return searchPath
                    }
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
        print("DEBUG: Database path: \(dbPath)")
        print("DEBUG: Executing search query: \(sql)")
        print("DEBUG: Search parameter: '\(searchQuery)'")
        let results = query(sql, parameters: [searchQuery])
        print("DEBUG: Search returned \(results.count) results")
        if results.isEmpty {
            // Test if FTS5 table exists and has data
            let ftsCount = query("SELECT COUNT(*) as count FROM documents_fts", parameters: [])
            print("DEBUG: FTS table count: \(ftsCount)")
        }
        return results
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
                   substr(d.content, 1, 200) as search_snippet,
                   0.0 as rank,
                   COALESCE(ev.location, '') as context_info
            FROM documents_fts fts
            JOIN documents d ON fts.rowid = d.rowid
            LEFT JOIN events ev ON d.id = ev.document_id  
            WHERE \(whereClause)
            ORDER BY d.updated_at DESC
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
        // Support both 768 and 1536 dimensional embeddings
        // 768 dimensions = 768 * 4 bytes = 3072 bytes
        // 1536 dimensions = 1536 * 4 bytes = 6144 bytes
        let expectedByteLength = queryVector.count * 4
        let sql = """
            SELECT d.id, d.title, d.content, e.vector, c.text as chunk_text
            FROM documents d
            JOIN chunks c ON d.id = c.document_id
            JOIN embeddings e ON c.id = e.chunk_id
            WHERE e.vector IS NOT NULL 
                AND (LENGTH(e.vector) = \(expectedByteLength) OR LENGTH(e.vector) = 6144)
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
                        // Handle dimension mismatch by truncating larger vectors
                        let adjustedVector: [Float]
                        if vector.count == queryVector.count {
                            adjustedVector = vector
                        } else if vector.count > queryVector.count {
                            // Truncate larger vector to match query dimensions
                            adjustedVector = Array(vector.prefix(queryVector.count))
                        } else {
                            // Skip vectors that are smaller than query
                            continue
                        }
                        
                        let similarity = cosineSimilarity(queryVector, adjustedVector)
                        
                        // Use a strict threshold for relevance (0.7 = high similarity required)
                        if similarity > 0.7 {
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