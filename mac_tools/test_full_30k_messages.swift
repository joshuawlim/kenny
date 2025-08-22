#!/usr/bin/env swift

import Foundation
import SQLite3

print("=== Kenny Full 30K Messages Ingestion ===")
print("Testing Messages ingestion with unlimited batch processing")
print("")

// Load the source files
let sourcePath = "\(FileManager.default.currentDirectoryPath)/src"
print("Loading Kenny from: \(sourcePath)")

// Add the source path to the module search path
var arguments = CommandLine.arguments
arguments.append(contentsOf: ["-I", sourcePath])

// We need to compile and run this differently
print("ℹ️  This script needs to be compiled with the Kenny sources.")
print("ℹ️  Run: swift -I src test_full_30k_messages.swift")
print("")

#if canImport(Database)
import Database
import MessagesIngester

// Initialize Kenny database  
let db = Database()
if !db.initialize() {
    print("❌ Failed to initialize database")
    exit(1)
}

print("✅ Database initialized")

// Check current message count
let beforeCount = db.query("SELECT COUNT(*) as count FROM messages")
let beforeMessages = beforeCount.first?["count"] as? Int64 ?? 0
print("📊 Current messages in DB: \(beforeMessages)")

// Check source Messages database
let messagesDbPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath
var sourceDb: OpaquePointer?
if sqlite3_open_v2(messagesDbPath, &sourceDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
    defer { sqlite3_close(sourceDb) }
    
    var stmt: OpaquePointer?
    let countQuery = "SELECT COUNT(*) FROM message WHERE text IS NOT NULL AND length(text) > 0"
    
    if sqlite3_prepare_v2(sourceDb, countQuery, -1, &stmt, nil) == SQLITE_OK {
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let totalAvailable = sqlite3_column_int64(stmt, 0)
            print("📊 Total messages available in source: \(totalAvailable)")
            print("📊 Messages to ingest: \(totalAvailable - beforeMessages)")
        }
    }
}

print("\nStarting enhanced Messages ingestion with unlimited processing...")
let messagesIngester = MessagesIngester(database: db)

// Configure for unlimited ingestion
let config = BatchProcessingConfig(
    batchSize: 1000,
    maxMessages: nil, // UNLIMITED
    enableDetailedLogging: true,
    continueOnBatchFailure: true
)

let startTime = Date()
let result = messagesIngester.ingestMessagesFromChatDB(config: config)

let duration = Date().timeIntervalSince(startTime)

print("\n✅ Enhanced ingestion complete!")
print("   - Discovered: \(result.discovered)")
print("   - Inserted: \(result.inserted)")
print("   - Failed: \(result.failed)")
print("   - Batches processed: \(result.batchesProcessed)")
print("   - Duration: \(String(format: "%.2f", duration))s")
print("   - Rate: \(String(format: "%.0f", Double(result.inserted) / duration)) messages/sec")

if !result.errors.isEmpty {
    print("\n⚠️  Errors encountered:")
    for (i, error) in result.errors.enumerated() {
        print("   \(i + 1). \(error)")
    }
}

// Query the database to verify final count
let afterCount = db.query("SELECT COUNT(*) as count FROM messages")
let afterMessages = afterCount.first?["count"] as? Int64 ?? 0
print("\n📊 Final verification:")
print("   - Messages before: \(beforeMessages)")
print("   - Messages after: \(afterMessages)")
print("   - Net increase: \(afterMessages - beforeMessages)")

// Test search for "Vinomofo"
print("\n🔍 Testing search for 'Vinomofo'...")
let vinomofoResults = db.search("Vinomofo", limit: 10)
print("   - Found: \(vinomofoResults.count) results")

for (i, result) in vinomofoResults.prefix(3).enumerated() {
    print("   \(i + 1). \(result["title"] ?? "No title") - \(result["app_source"] ?? "No source")")
}

print("\n✅ Full 30K Messages ingestion test complete!")

#else
print("❌ Kenny modules not available")
print("Run with: swift -I src test_full_30k_messages.swift")
exit(1)
#endif