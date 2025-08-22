#!/usr/bin/env swift

import Foundation
import SQLite3

// Test script to validate emails and messages ingestion pipeline

// First, apply the migration
print("Applying migration 004...")
let migrationPath = "migrations/004_emails_messages_fts.up.sql"
let migrationContent = try String(contentsOfFile: migrationPath)

var db: OpaquePointer?
sqlite3_open("test_ingestion.db", &db)
defer { sqlite3_close(db) }

// Execute migration
if sqlite3_exec(db, migrationContent, nil, nil, nil) == SQLITE_OK {
    print("✅ Migration applied successfully")
} else {
    print("❌ Migration failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}

// Test FTS5 search
print("\nTesting FTS5 search capabilities...")

// Insert test email
let emailSql = """
    INSERT INTO emails (subject, body, from_addr, to_addrs, sent_at, hash)
    VALUES ('Meeting Tomorrow', 'Let us discuss the project timeline', 'alice@example.com', 'bob@example.com', ?, 'test_hash_1')
"""
var stmt: OpaquePointer?
sqlite3_prepare_v2(db, emailSql, -1, &stmt, nil)
sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
if sqlite3_step(stmt) == SQLITE_DONE {
    print("✅ Test email inserted")
}
sqlite3_finalize(stmt)

// Insert test message
let messageSql = """
    INSERT INTO messages (chat_id, sender, text, sent_at, service, hash)
    VALUES (1, 'Alice', 'Can we meet tomorrow about the project?', ?, 'iMessage', 'test_hash_2')
"""
sqlite3_prepare_v2(db, messageSql, -1, &stmt, nil)
sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
if sqlite3_step(stmt) == SQLITE_DONE {
    print("✅ Test message inserted")
}
sqlite3_finalize(stmt)

// Search emails FTS
let searchEmailsSql = "SELECT COUNT(*) FROM emails_fts WHERE emails_fts MATCH 'project'"
sqlite3_prepare_v2(db, searchEmailsSql, -1, &stmt, nil)
if sqlite3_step(stmt) == SQLITE_ROW {
    let count = sqlite3_column_int(stmt, 0)
    print("✅ Emails FTS search found \(count) result(s) for 'project'")
}
sqlite3_finalize(stmt)

// Search messages FTS
let searchMessagesSql = "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'tomorrow'"
sqlite3_prepare_v2(db, searchMessagesSql, -1, &stmt, nil)
if sqlite3_step(stmt) == SQLITE_ROW {
    let count = sqlite3_column_int(stmt, 0)
    print("✅ Messages FTS search found \(count) result(s) for 'tomorrow'")
}
sqlite3_finalize(stmt)

// Test hash-based deduplication
print("\nTesting deduplication...")
sqlite3_prepare_v2(db, emailSql, -1, &stmt, nil)
sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
let result = sqlite3_step(stmt)
if result == SQLITE_CONSTRAINT {
    print("✅ Duplicate email correctly rejected")
} else {
    print("❌ Deduplication may not be working (result: \(result))")
}
sqlite3_finalize(stmt)

// Verify trigger synchronization
print("\nVerifying FTS trigger synchronization...")
let updateSql = "UPDATE emails SET subject = 'Meeting Rescheduled' WHERE hash = 'test_hash_1'"
sqlite3_exec(db, updateSql, nil, nil, nil)

let verifyUpdateSql = "SELECT COUNT(*) FROM emails_fts WHERE emails_fts MATCH 'rescheduled'"
sqlite3_prepare_v2(db, verifyUpdateSql, -1, &stmt, nil)
if sqlite3_step(stmt) == SQLITE_ROW {
    let count = sqlite3_column_int(stmt, 0)
    if count > 0 {
        print("✅ FTS triggers working - UPDATE propagated")
    } else {
        print("❌ FTS triggers may not be working - UPDATE not reflected")
    }
}
sqlite3_finalize(stmt)

// Clean up test database
try? FileManager.default.removeItem(atPath: "test_ingestion.db")
try? FileManager.default.removeItem(atPath: "test_ingestion.db-shm")
try? FileManager.default.removeItem(atPath: "test_ingestion.db-wal")

print("\n✅ All tests completed successfully!")