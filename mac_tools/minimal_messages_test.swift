#!/usr/bin/env swift

import Foundation
import SQLite3

// Minimal reproduction of Database class
class MinimalDatabase {
    func insert(_ table: String, data: [String: Any]) -> Bool {
        print("DEBUG: Would insert into \(table): \(data)")
        return true
    }
    
    func query(_ sql: String, parameters: [Any] = []) -> [[String: Any]] {
        print("DEBUG: Would execute query: \(sql)")
        return []
    }
}

// IngestStats struct
struct IngestStats {
    var source: String
    var itemsProcessed: Int = 0
    var itemsCreated: Int = 0 
    var errors: Int = 0
    
    init(source: String) {
        self.source = source
    }
}

// Test direct MessagesIngester without full CLI overhead
print("=== Direct MessagesIngester Test ===")

let db = MinimalDatabase()
let messagesDB = "\(NSHomeDirectory())/Library/Messages/chat.db"

// Test just opening and querying - no processing
var sqliteDB: OpaquePointer?
let result = sqlite3_open_v2(messagesDB, &sqliteDB, SQLITE_OPEN_READONLY, nil)

if result == SQLITE_OK {
    sqlite3_busy_timeout(sqliteDB, 10000)
    
    let query = """
        SELECT m.ROWID, m.guid, m.text, m.service, h.id as handle_id
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.text IS NOT NULL AND length(m.text) > 0 AND m.associated_message_type = 0
        ORDER BY m.date DESC 
        LIMIT 3
    """
    
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(sqliteDB, query, -1, &stmt, nil) == SQLITE_OK {
        print("✅ Query prepared")
        
        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            
            var messageData: [String: Any] = [:]
            let columnCount = sqlite3_column_count(stmt)
            
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, i) {
                        messageData[columnName] = String(cString: text)
                    }
                case SQLITE_INTEGER:
                    messageData[columnName] = sqlite3_column_int64(stmt, i)
                default:
                    break
                }
            }
            
            print("Message \(rowCount) data keys: \(messageData.keys)")
            let textContent = messageData["text"] as? String ?? ""
            print("  Text: '\(textContent.prefix(50))...'")
            
            // Simulate the processing that might be causing issues
            if !textContent.isEmpty {
                let docData: [String: Any] = [
                    "id": UUID().uuidString,
                    "content": textContent,
                    "app_source": "Messages"
                ]
                _ = db.insert("documents", data: docData)
            }
        }
        
        print("✅ Processed \(rowCount) messages without crash")
        sqlite3_finalize(stmt)
    }
    
    sqlite3_close(sqliteDB)
} else {
    print("❌ Failed to open Messages DB")
}

print("=== Test Complete - No Crash ===")
