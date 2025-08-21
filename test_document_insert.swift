#!/usr/bin/env swift

import Foundation
import SQLite3

// Test document insertion directly
func testDocumentInsertion() {
    let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/test_insert.db"
    
    // Remove existing test database
    try? FileManager.default.removeItem(atPath: dbPath)
    
    var db: OpaquePointer?
    let result = sqlite3_open(dbPath, &db)
    
    if result != SQLITE_OK {
        print("ERROR: Failed to create test database: \(result)")
        return
    }
    
    defer { sqlite3_close(db) }
    
    // Create documents table
    let createTable = """
    CREATE TABLE documents (
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
    
    if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
        print("ERROR: Failed to create table: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    
    print("Created test database and table successfully")
    
    // Test inserting a document with the same data structure as MessagesIngester
    let testData: [String: Any] = [
        "id": "test-message-1",
        "type": "message", 
        "title": "Test Message from John",
        "content": "This is a test message\\nService: iMessage\\nFrom: John",
        "app_source": "Messages",
        "source_id": "test-guid-123",
        "created_at": 1755757877,
        "updated_at": 1755757877,
        "last_seen_at": 1755757877,
        "deleted": false
    ]
    
    print("\\nInserting test document:")
    print("Title: '\(testData["title"] as! String)'")
    print("Content: '\(testData["content"] as! String)'")
    
    // Manual insert using the same logic as Database.insert()
    let sortedKeys = testData.keys.sorted()
    let columns = sortedKeys.joined(separator: ", ")
    let placeholders = Array(repeating: "?", count: testData.count).joined(separator: ", ")
    let sql = "INSERT INTO documents (\(columns)) VALUES (\(placeholders))"
    
    print("\\nSQL: \(sql)")
    
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        print("ERROR preparing insert: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    
    // Bind parameters
    for (index, key) in sortedKeys.enumerated() {
        let value = testData[key]!
        let bindIndex = Int32(index + 1)
        
        if let stringVal = value as? String {
            sqlite3_bind_text(statement, bindIndex, stringVal, -1, nil)
            print("Binding [\(index + 1)] \(key) = '\(stringVal)'")
        } else if let intVal = value as? Int {
            sqlite3_bind_int64(statement, bindIndex, Int64(intVal))
            print("Binding [\(index + 1)] \(key) = \(intVal)")
        } else if let boolVal = value as? Bool {
            sqlite3_bind_int(statement, bindIndex, boolVal ? 1 : 0)
            print("Binding [\(index + 1)] \(key) = \(boolVal)")
        }
    }
    
    if sqlite3_step(statement) != SQLITE_DONE {
        print("ERROR executing insert: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    
    print("\\nInsert successful! Verifying data...")
    
    // First check if ANY documents exist
    let countSQL = "SELECT COUNT(*) FROM documents"
    var countStatement: OpaquePointer?
    defer { sqlite3_finalize(countStatement) }
    
    if sqlite3_prepare_v2(db, countSQL, -1, &countStatement, nil) == SQLITE_OK {
        if sqlite3_step(countStatement) == SQLITE_ROW {
            let count = sqlite3_column_int(countStatement, 0)
            print("Total documents in table: \(count)")
        }
    }
    
    // Query all data back to see what's there
    let selectSQL = "SELECT id, type, title, content, app_source FROM documents"
    var selectStatement: OpaquePointer?
    defer { sqlite3_finalize(selectStatement) }
    
    if sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK {
        if sqlite3_step(selectStatement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(selectStatement, 0))
            let type = String(cString: sqlite3_column_text(selectStatement, 1))
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
            print("ID: \(id)")
            print("Type: \(type)")
            print("Title: '\(title)' (length: \(title.count))")
            print("Content: '\(content)' (length: \(content.count))")
            print("App Source: \(appSource)")
            
            if title == "Test Message from John" && content.contains("This is a test message") {
                print("\\n✅ SUCCESS: Document insertion and retrieval working correctly!")
            } else {
                print("\\n❌ FAILURE: Data was corrupted during insertion")
            }
        } else {
            print("ERROR: No data found after insertion")
        }
    } else {
        print("ERROR preparing select: \(String(cString: sqlite3_errmsg(db)))")
    }
}

testDocumentInsertion()