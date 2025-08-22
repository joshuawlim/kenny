#!/usr/bin/env swift

import Foundation
import SQLite3

print("=== Finding Readable Message Content ===")

let messagesDBPath = "\(NSHomeDirectory())/Library/Messages/chat.db"
var db: OpaquePointer?
sqlite3_open_v2(messagesDBPath, &db, SQLITE_OPEN_READONLY, nil)

// Check various text columns for readable content
let testColumns = ["text", "subject", "group_title", "cache_roomnames"]

var stmt: OpaquePointer?
for column in testColumns {
    print("\nChecking \(column) column:")
    
    let query = """
        SELECT \(column), length(\(column)) as len
        FROM message 
        WHERE \(column) IS NOT NULL AND length(\(column)) > 0
        ORDER BY date DESC 
        LIMIT 3
    """
    
    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            count += 1
            let text = sqlite3_column_text(stmt, 0)
            let len = sqlite3_column_int(stmt, 1)
            let content = text != nil ? String(cString: text!) : "NULL"
            print("   \(count). (\(len) chars) \(content.prefix(100))")
        }
        if count == 0 {
            print("   No content found in \(column)")
        }
        sqlite3_finalize(stmt)
    }
}

// Check if there's a relationship with attachment table that might have text
print("\nChecking attachment table for text content:")
let attachQuery = """
    SELECT filename, mime_type, total_bytes
    FROM attachment 
    WHERE mime_type LIKE '%text%' OR filename LIKE '%.txt'
    LIMIT 5
"""

if sqlite3_prepare_v2(db, attachQuery, -1, &stmt, nil) == SQLITE_OK {
    var count = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        count += 1
        let filename = sqlite3_column_text(stmt, 0)
        let mimeType = sqlite3_column_text(stmt, 1)  
        let bytes = sqlite3_column_int(stmt, 2)
        
        let filenameStr = filename != nil ? String(cString: filename!) : "NULL"
        let mimeStr = mimeType != nil ? String(cString: mimeType!) : "NULL"
        
        print("   \(count). \(filenameStr) (\(mimeStr), \(bytes) bytes)")
    }
    if count == 0 {
        print("   No text attachments found")
    }
    sqlite3_finalize(stmt)
}

// Let's try to understand the attributedBody BLOB structure
print("\nAnalyzing attributedBody BLOB structure:")
let blobQuery = """
    SELECT guid, hex(substr(attributedBody, 1, 50)) as hex_start, length(attributedBody) as len
    FROM message 
    WHERE attributedBody IS NOT NULL 
    ORDER BY date DESC 
    LIMIT 3
"""

if sqlite3_prepare_v2(db, blobQuery, -1, &stmt, nil) == SQLITE_OK {
    var count = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        count += 1
        let guid = sqlite3_column_text(stmt, 0)
        let hexStart = sqlite3_column_text(stmt, 1)
        let len = sqlite3_column_int(stmt, 2)
        
        let guidStr = guid != nil ? String(cString: guid!) : "NULL"
        let hexStr = hexStart != nil ? String(cString: hexStart!) : "NULL"
        
        print("   \(count). GUID: \(guidStr)")
        print("      Length: \(len) bytes")
        print("      Hex start: \(hexStr)")
    }
    sqlite3_finalize(stmt)
}

sqlite3_close(db)
print("\n=== Analysis Complete ===")
print("We need to either decode the BLOB or find alternative text sources.")