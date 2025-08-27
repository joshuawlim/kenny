#!/usr/bin/env swift

import Foundation
import SQLite3

print("=== Examining the 1 Message Entry ===")

// Use the same database path as Database class
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let assistantDir = appSupport.appendingPathComponent("Assistant")
let dbPath = assistantDir.appendingPathComponent("assistant.db").path

var db: OpaquePointer?
let result = sqlite3_open(dbPath, &db)

if result == SQLITE_OK {
    print("✅ Database opened successfully")
    
    // Query the message entries in documents table
    print("\n1. Messages in documents table:")
    let docQuery = """
        SELECT id, type, title, content, app_source, source_id, created_at, length(content) as content_len
        FROM documents 
        WHERE type = 'message' OR app_source = 'Messages'
        ORDER BY created_at DESC
    """
    
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, docQuery, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let type = String(cString: sqlite3_column_text(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let appSource = String(cString: sqlite3_column_text(stmt, 4))
            let sourceId = String(cString: sqlite3_column_text(stmt, 5))
            let createdAt = sqlite3_column_int(stmt, 6)
            let contentLen = sqlite3_column_int(stmt, 7)
            
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            
            print("   📱 [\(type)/\(appSource)] \(title)")
            print("      ID: \(id)")
            print("      Source ID: \(sourceId)")
            print("      Content (\(contentLen) chars): \(content.prefix(200))")
            print("      Created: \(formatter.string(from: date))")
            print("")
        }
        sqlite3_finalize(stmt)
    }
    
    // Query the messages table entries
    print("\n2. Entries in messages table:")
    let msgQuery = """
        SELECT document_id, thread_id, from_contact, date_sent, is_from_me, service, chat_name
        FROM messages
        ORDER BY date_sent DESC
    """
    
    if sqlite3_prepare_v2(db, msgQuery, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let docId = String(cString: sqlite3_column_text(stmt, 0))
            let threadId = String(cString: sqlite3_column_text(stmt, 1))
            let fromContact = String(cString: sqlite3_column_text(stmt, 2))
            let dateSent = sqlite3_column_int(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let service = String(cString: sqlite3_column_text(stmt, 5))
            let chatName = sqlite3_column_text(stmt, 6)
            
            let date = Date(timeIntervalSince1970: TimeInterval(dateSent))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            
            print("   💬 Message Details:")
            print("      Document ID: \(docId)")
            print("      Thread: \(threadId)")  
            print("      From: \(fromContact) (is_from_me: \(isFromMe))")
            print("      Service: \(service)")
            print("      Chat: \(chatName != nil ? String(cString: chatName!) : "nil")")
            print("      Date: \(formatter.string(from: date))")
            print("")
        }
        sqlite3_finalize(stmt)
    }
    
    // Check recent documents by type
    print("\n3. Recent documents by type:")
    let recentQuery = """
        SELECT type, COUNT(*), MAX(created_at) as latest
        FROM documents 
        GROUP BY type 
        ORDER BY latest DESC
    """
    
    if sqlite3_prepare_v2(db, recentQuery, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let type = String(cString: sqlite3_column_text(stmt, 0))
            let count = sqlite3_column_int(stmt, 1)
            let latest = sqlite3_column_int(stmt, 2)
            
            let date = Date(timeIntervalSince1970: TimeInterval(latest))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            
            print("   \(type): \(count) documents (latest: \(formatter.string(from: date)))")
        }
        sqlite3_finalize(stmt)
    }
    
    sqlite3_close(db)
} else {
    print("❌ Failed to open database: \(result)")
}

print("\n=== Examination Complete ===")
print("This will show us exactly what data is being ingested and why so little.")