#!/usr/bin/env swift

import Foundation
import SQLite3

// Simple Messages database test
func testMessagesDatabase() {
    let messagesDBPath = "\(NSHomeDirectory())/Library/Messages/chat.db"
    
    guard FileManager.default.fileExists(atPath: messagesDBPath) else {
        print("ERROR: Messages database not found at \(messagesDBPath)")
        return
    }
    
    print("Messages database found at: \(messagesDBPath)")
    
    var db: OpaquePointer?
    let result = sqlite3_open_v2(messagesDBPath, &db, SQLITE_OPEN_READONLY, nil)
    
    if result != SQLITE_OK {
        print("ERROR: Failed to open Messages database: \(result)")
        return
    }
    
    defer { sqlite3_close(db) }
    
    // Test the exact query that MessagesIngester uses
    let query = """
    SELECT 
        m.ROWID as message_id,
        m.guid,
        m.text,
        m.service,
        m.account,
        m.date,
        m.is_from_me,
        m.is_read,
        m.is_delivered,
        m.is_finished,
        h.id as handle_id,
        c.chat_identifier,
        c.display_name as chat_name,
        c.service_name
    FROM message m
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
    LEFT JOIN chat c ON cmj.chat_id = c.ROWID
    WHERE m.date > 0.0 
    ORDER BY m.date DESC 
    LIMIT 5
    """
    
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        print("ERROR: Failed to prepare query")
        return
    }
    
    print("\\nRecent Messages:")
    var count = 0
    while sqlite3_step(statement) == SQLITE_ROW {
        count += 1
        
        let messageId = sqlite3_column_int64(statement, 0)
        
        let guid = if let cString = sqlite3_column_text(statement, 1) {
            String(cString: cString)
        } else {
            "NULL"
        }
        
        let text = if let cString = sqlite3_column_text(statement, 2) {
            String(cString: cString)
        } else {
            ""
        }
        
        let service = if let cString = sqlite3_column_text(statement, 3) {
            String(cString: cString)
        } else {
            "NULL"
        }
        
        let date = sqlite3_column_int64(statement, 5)
        let isFromMe = sqlite3_column_int(statement, 6)
        
        print("Message \(count):")
        print("  - ID: \(messageId)")
        print("  - GUID: \(guid)")
        print("  - Text: '\(text)' (length: \(text.count))")
        print("  - Service: \(service)")
        print("  - Date: \(date)")
        print("  - From Me: \(isFromMe == 1)")
        print()
    }
    
    if count == 0 {
        print("No messages found with the query!")
    }
}

testMessagesDatabase()