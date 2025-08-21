#!/usr/bin/env swift

import Foundation
import SQLite3

// Simple test of database functionality without complex dependencies
print("=== Testing SQLite Database Schema ===")

let testDBPath = "/tmp/test_assistant.db"

// Remove existing test DB
try? FileManager.default.removeItem(atPath: testDBPath)

// Open database
var db: OpaquePointer?
guard sqlite3_open(testDBPath, &db) == SQLITE_OK else {
    print("❌ Failed to open database")
    exit(1)
}
defer { sqlite3_close(db) }

print("✅ Database opened at: \(testDBPath)")

// Read and execute schema
let schemaPath = "/Users/joshwlim/Documents/Kenny/mac_tools/migrations/001_initial_schema.sql"
guard let schemaSQL = try? String(contentsOfFile: schemaPath) else {
    print("❌ Failed to read schema file")
    exit(1)
}

print("📋 Executing schema migration...")

// Execute schema (split by semicolon for multiple statements)
let statements = schemaSQL.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

for statement in statements {
    if statement.isEmpty || statement.hasPrefix("--") { continue }
    
    if sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
        let error = String(cString: sqlite3_errmsg(db))
        print("❌ Schema error: \(error)")
        print("Statement: \(statement)")
        exit(1)
    }
}

print("✅ Schema migration complete")

// Test basic operations
print("🔄 Testing basic database operations...")

// Insert test data
let insertSQL = """
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) 
VALUES ('test-1', 'email', 'Test Email', 'This is a test email content', 'Mail', 'msg-123', 'message://123', 'hash123', 1672531200, 1672531200, 1672531200, 0)
"""

if sqlite3_exec(db, insertSQL, nil, nil, nil) != SQLITE_OK {
    let error = String(cString: sqlite3_errmsg(db))
    print("❌ Insert failed: \(error)")
    exit(1)
}

print("✅ Test document inserted")

// Test FTS5 functionality
print("🔍 Testing FTS5 search...")

let searchSQL = "SELECT title, snippet(documents_fts, 1, '<mark>', '</mark>', '...', 10) as snippet FROM documents_fts WHERE documents_fts MATCH 'test'"

var statement: OpaquePointer?
if sqlite3_prepare_v2(db, searchSQL, -1, &statement, nil) == SQLITE_OK {
    if sqlite3_step(statement) == SQLITE_ROW {
        let title = String(cString: sqlite3_column_text(statement, 0))
        let snippet = String(cString: sqlite3_column_text(statement, 1))
        print("✅ FTS5 search result:")
        print("   Title: \(title)")
        print("   Snippet: \(snippet)")
    } else {
        print("❌ No search results found")
    }
} else {
    let error = String(cString: sqlite3_errmsg(db))
    print("❌ Search query failed: \(error)")
}
sqlite3_finalize(statement)

// Test table counts
print("📊 Database statistics:")

let tables = ["documents", "emails", "events", "contacts", "reminders", "notes", "files", "messages", "relationships"]

for table in tables {
    let countSQL = "SELECT COUNT(*) FROM \(table)"
    var countStatement: OpaquePointer?
    
    if sqlite3_prepare_v2(db, countSQL, -1, &countStatement, nil) == SQLITE_OK {
        if sqlite3_step(countStatement) == SQLITE_ROW {
            let count = sqlite3_column_int(countStatement, 0)
            print("   \(table): \(count) rows")
        }
    }
    sqlite3_finalize(countStatement)
}

print("\n🎉 Database test completed successfully!")
print("📁 Test database saved at: \(testDBPath)")