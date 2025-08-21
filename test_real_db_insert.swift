#!/usr/bin/env swift

import Foundation
import SQLite3

// Test insertion into the actual Kenny database
func testRealDatabaseInsert() {
    let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
    
    guard FileManager.default.fileExists(atPath: dbPath) else {
        print("ERROR: Kenny database not found at \(dbPath)")
        return
    }
    
    var db: OpaquePointer?
    let result = sqlite3_open(dbPath, &db)
    
    if result != SQLITE_OK {
        print("ERROR: Failed to open database: \(result)")
        return
    }
    
    defer { sqlite3_close(db) }
    
    print("Connected to Kenny database successfully")
    
    // Check current schema
    let schemaSQL = "PRAGMA table_info(documents)"
    var schemaStatement: OpaquePointer?
    defer { sqlite3_finalize(schemaStatement) }
    
    if sqlite3_prepare_v2(db, schemaSQL, -1, &schemaStatement, nil) == SQLITE_OK {
        print("\\nDocuments table schema:")
        while sqlite3_step(schemaStatement) == SQLITE_ROW {
            let columnName = String(cString: sqlite3_column_text(schemaStatement, 1))
            let columnType = String(cString: sqlite3_column_text(schemaStatement, 2))
            let notNull = sqlite3_column_int(schemaStatement, 3)
            print("  \(columnName): \(columnType) \(notNull == 1 ? "NOT NULL" : "")")
        }
    }
    
    // Test inserting the same data structure as MessagesIngester creates
    let testId = "test-debug-\(UUID().uuidString)"
    let testData: [String: Any] = [
        "id": testId,
        "type": "message",
        "title": "DEBUG: Test Message from MessagesIngester", 
        "content": "DEBUG: This is test content\\nService: iMessage\\nFrom: TestUser",
        "app_source": "Messages",
        "source_id": "debug-guid-\(UUID().uuidString)",
        "source_path": "sms:conversation/test",
        "hash": "testhash123",
        "created_at": Int(Date().timeIntervalSince1970),
        "updated_at": Int(Date().timeIntervalSince1970),
        "last_seen_at": Int(Date().timeIntervalSince1970),
        "deleted": false,
        "metadata_json": NSNull()
    ]
    
    print("\\nInserting test document with MessagesIngester structure...")
    
    // Use the exact same insertion logic as Database.insert()
    let sortedKeys = testData.keys.sorted()
    let columns = sortedKeys.joined(separator: ", ")
    let placeholders = Array(repeating: "?", count: testData.count).joined(separator: ", ")
    let sql = "INSERT INTO documents (\(columns)) VALUES (\(placeholders))"
    
    print("SQL: \(sql)")
    
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        print("ERROR preparing insert: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    
    // Bind parameters with detailed logging
    for (index, key) in sortedKeys.enumerated() {
        let value = testData[key]!
        let bindIndex = Int32(index + 1)
        
        if let stringVal = value as? String {
            sqlite3_bind_text(statement, bindIndex, stringVal, -1, nil)
            print("Bound [\(bindIndex)] \(key) = '\(stringVal)'")
        } else if let intVal = value as? Int {
            sqlite3_bind_int64(statement, bindIndex, Int64(intVal))
            print("Bound [\(bindIndex)] \(key) = \(intVal)")
        } else if let boolVal = value as? Bool {
            sqlite3_bind_int(statement, bindIndex, boolVal ? 1 : 0)
            print("Bound [\(bindIndex)] \(key) = \(boolVal)")
        } else if value is NSNull {
            sqlite3_bind_null(statement, bindIndex)
            print("Bound [\(bindIndex)] \(key) = NULL")
        }
    }
    
    // Execute
    let stepResult = sqlite3_step(statement)
    if stepResult != SQLITE_DONE {
        print("ERROR executing insert: \(String(cString: sqlite3_errmsg(db))) (code: \(stepResult))")
        return
    }
    
    print("\\n✅ Insert completed! Retrieving data...")
    
    // Retrieve the data
    let selectSQL = "SELECT id, type, title, content, app_source FROM documents WHERE id = ?"
    var selectStatement: OpaquePointer?
    defer { sqlite3_finalize(selectStatement) }
    
    if sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK {
        sqlite3_bind_text(selectStatement, 1, testId, -1, nil)
        
        if sqlite3_step(selectStatement) == SQLITE_ROW {
            let id = if let cString = sqlite3_column_text(selectStatement, 0) {
                String(cString: cString)
            } else {
                "NULL"
            }
            let type = if let cString = sqlite3_column_text(selectStatement, 1) {
                String(cString: cString)
            } else {
                "NULL"
            }
            let title = if let cString = sqlite3_column_text(selectStatement, 2) {
                String(cString: cString)
            } else {
                "NULL"
            }
            let content = if let cString = sqlite3_column_text(selectStatement, 3) {
                String(cString: cString)
            } else {
                "NULL"
            }
            let appSource = if let cString = sqlite3_column_text(selectStatement, 4) {
                String(cString: cString)
            } else {
                "NULL"
            }
            
            print("\\nRetrieved data:")
            print("ID: '\(id)'")
            print("Type: '\(type)'") 
            print("Title: '\(title)' (length: \(title.count))")
            print("Content: '\(content)' (length: \(content.count))")
            print("App Source: '\(appSource)'")
            
            if title.contains("DEBUG: Test Message") && content.contains("DEBUG: This is test content") {
                print("\\n✅ SUCCESS: Direct insertion and retrieval working!")
            } else {
                print("\\n❌ FAILURE: Data corruption during insertion")
            }
        } else {
            print("ERROR: Could not retrieve inserted document")
        }
    } else {
        print("ERROR preparing select: \(String(cString: sqlite3_errmsg(db)))")
    }
}

testRealDatabaseInsert()