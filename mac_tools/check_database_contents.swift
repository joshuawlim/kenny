#!/usr/bin/env swift

import Foundation
import SQLite3

print("=== Database Contents Analysis ===")

// Open the database (same location as Database.swift uses)
let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
print("Database path: \(dbPath)")

var db: OpaquePointer?
let result = sqlite3_open(dbPath, &db)

if result == SQLITE_OK {
    print("✅ Database opened successfully")
    
    // Query document types and counts
    print("\n📊 Document Types and Counts:")
    let typeQuery = "SELECT type, app_source, COUNT(*) as count FROM documents GROUP BY type, app_source ORDER BY count DESC"
    var stmt: OpaquePointer?
    
    if sqlite3_prepare_v2(db, typeQuery, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let type = String(cString: sqlite3_column_text(stmt, 0))
            let appSource = String(cString: sqlite3_column_text(stmt, 1))
            let count = sqlite3_column_int(stmt, 2)
            print("  \(type) (\(appSource)): \(count)")
        }
        sqlite3_finalize(stmt)
    }
    
    // Get top 10 entries for each data type we care about
    let dataTypes = ["message", "email", "event", "contact", "note", "reminder", "file"]
    
    for dataType in dataTypes {
        print("\n🔍 Top 10 \(dataType) entries:")
        let query = """
            SELECT id, type, title, app_source, created_at, length(content) as content_length 
            FROM documents 
            WHERE type = ? 
            ORDER BY created_at DESC 
            LIMIT 10
        """
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dataType, -1, nil)
            
            var rowCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowCount += 1
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let type = String(cString: sqlite3_column_text(stmt, 1))
                let title = String(cString: sqlite3_column_text(stmt, 2))
                let appSource = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = sqlite3_column_int(stmt, 4)
                let contentLength = sqlite3_column_int(stmt, 5)
                
                let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                
                print("  \(rowCount). [\(appSource)] \(title.prefix(50)) (content: \(contentLength) chars, \(formatter.string(from: date)))")
            }
            
            if rowCount == 0 {
                print("  ❌ No \(dataType) entries found")
            }
        }
        sqlite3_finalize(stmt)
    }
    
    // Check if there are any non-file entries at all
    print("\n🔍 Sample of recent non-file documents:")
    let recentQuery = """
        SELECT type, app_source, title, created_at, length(content) 
        FROM documents 
        WHERE type != 'file' 
        ORDER BY created_at DESC 
        LIMIT 20
    """
    
    if sqlite3_prepare_v2(db, recentQuery, -1, &stmt, nil) == SQLITE_OK {
        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            let type = String(cString: sqlite3_column_text(stmt, 0))
            let appSource = String(cString: sqlite3_column_text(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt = sqlite3_column_int(stmt, 3)
            let contentLength = sqlite3_column_int(stmt, 4)
            
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            
            print("  \(rowCount). [\(type)/\(appSource)] \(title.prefix(40)) (\(contentLength) chars, \(formatter.string(from: date)))")
        }
        
        if rowCount == 0 {
            print("  ❌ No non-file documents found")
        }
        sqlite3_finalize(stmt)
    }
    
    sqlite3_close(db)
} else {
    print("❌ Failed to open database: \(result)")
}