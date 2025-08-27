#!/usr/bin/env swift

import Foundation
import SQLite3

print("=== Analyzing Message Content Columns ===")

let messagesDBPath = "\(NSHomeDirectory())/Library/Messages/chat.db"
var db: OpaquePointer?
sqlite3_open_v2(messagesDBPath, &db, SQLITE_OPEN_READONLY, nil)
sqlite3_busy_timeout(db, 10000)

// Check what columns actually contain text content
print("1. Checking content in different text columns...")

let queries = [
    ("Recent messages with text", "SELECT COUNT(*) FROM message WHERE text IS NOT NULL AND length(text) > 0 AND date > 7.7e17"),
    ("Recent messages with attributedBody", "SELECT COUNT(*) FROM message WHERE attributedBody IS NOT NULL AND length(attributedBody) > 0 AND date > 7.7e17"),
    ("Recent messages with payload_data", "SELECT COUNT(*) FROM message WHERE payload_data IS NOT NULL AND date > 7.7e17"),
    ("Recent messages total", "SELECT COUNT(*) FROM message WHERE date > 7.7e17"),
]

var stmt: OpaquePointer?
for (description, query) in queries {
    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_step(stmt)
        let count = sqlite3_column_int(stmt, 0)
        print("   \(description): \(count)")
        sqlite3_finalize(stmt)
    }
}

// Check sample of messages with actual content
print("\n2. Sample of messages that DO have content...")

let contentQuery = """
    SELECT guid, text, attributedBody, length(text) as text_len, length(attributedBody) as attr_len, date
    FROM message 
    WHERE (text IS NOT NULL AND length(text) > 0) OR (attributedBody IS NOT NULL AND length(attributedBody) > 0)
    ORDER BY date DESC 
    LIMIT 5
"""

if sqlite3_prepare_v2(db, contentQuery, -1, &stmt, nil) == SQLITE_OK {
    var rowCount = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        rowCount += 1
        
        let guid = sqlite3_column_text(stmt, 0)
        let text = sqlite3_column_text(stmt, 1) 
        let attrBody = sqlite3_column_text(stmt, 2)
        let textLen = sqlite3_column_int(stmt, 3)
        let attrLen = sqlite3_column_int(stmt, 4)
        let date = sqlite3_column_double(stmt, 5)
        
        let guidStr = guid != nil ? String(cString: guid!) : "NULL"
        let textStr = text != nil ? String(cString: text!) : "NULL"
        let attrStr = attrBody != nil ? String(cString: attrBody!) : "NULL"
        
        let unixTime = (date / 1_000_000_000) + 978307200
        let dateObj = Date(timeIntervalSince1970: unixTime)
        
        print("   Message \(rowCount):")
        print("     GUID: \(guidStr)")
        print("     Text (\(textLen) chars): \(textStr.prefix(100))")
        print("     AttrBody (\(attrLen) chars): \(attrStr.prefix(100))")
        print("     Date: \(dateObj)")
        print()
    }
    sqlite3_finalize(stmt)
}

// Check if there are other content columns we might be missing
print("3. Checking message table schema...")
let schemaQuery = "PRAGMA table_info(message)"

if sqlite3_prepare_v2(db, schemaQuery, -1, &stmt, nil) == SQLITE_OK {
    print("   Message table columns:")
    while sqlite3_step(stmt) == SQLITE_ROW {
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let type = String(cString: sqlite3_column_text(stmt, 2))
        print("     - \(name) (\(type))")
    }
    sqlite3_finalize(stmt)
}

sqlite3_close(db)
print("\n=== Analysis Complete ===")