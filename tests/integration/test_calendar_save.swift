#!/usr/bin/env swift

import Foundation
import EventKit
import SQLite3

print("🔍 Testing Calendar Ingestion with Database Saving")
print("=================================================")

let eventStore = EKEventStore()

// Get January 2025 events (we know these exist)
let calendar = Calendar.current
let startDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let endDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 31))!

let calendars = eventStore.calendars(for: .event)
let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

print("Found \(events.count) events in January 2025")

// Test database connection
let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
print("Database path: \(dbPath)")

var db: OpaquePointer?
let result = sqlite3_open(dbPath, &db)

if result != SQLITE_OK {
    print("❌ Failed to open database")
    exit(1)
}

print("✅ Database opened successfully")

// Test inserting the first event
if let firstEvent = events.first {
    print("\n📅 Testing insert for first event:")
    print("Title: \(firstEvent.title ?? "Untitled")")
    print("Start: \(firstEvent.startDate)")
    print("ID: \(firstEvent.eventIdentifier ?? "no-id")")
    
    let documentId = "test-event-\(UUID().uuidString)"
    let now = Int(Date().timeIntervalSince1970)
    
    // Try inserting into documents table
    let docInsertSQL = """
        INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    
    var docStatement: OpaquePointer?
    if sqlite3_prepare_v2(db, docInsertSQL, -1, &docStatement, nil) == SQLITE_OK {
        sqlite3_bind_text(docStatement, 1, documentId, -1, nil)
        sqlite3_bind_text(docStatement, 2, "event", -1, nil)
        sqlite3_bind_text(docStatement, 3, firstEvent.title ?? "Untitled", -1, nil)
        sqlite3_bind_text(docStatement, 4, "Test event content", -1, nil)
        sqlite3_bind_text(docStatement, 5, "Calendar", -1, nil)
        sqlite3_bind_text(docStatement, 6, firstEvent.eventIdentifier, -1, nil)
        sqlite3_bind_text(docStatement, 7, "calshow:\(firstEvent.eventIdentifier ?? "")", -1, nil)
        sqlite3_bind_text(docStatement, 8, "test-hash", -1, nil)
        sqlite3_bind_int(docStatement, 9, Int32(now))
        sqlite3_bind_int(docStatement, 10, Int32(now))
        sqlite3_bind_int(docStatement, 11, Int32(now))
        sqlite3_bind_int(docStatement, 12, 0)
        
        if sqlite3_step(docStatement) == SQLITE_DONE {
            print("✅ Successfully inserted document")
            
            // Now try inserting into events table
            let eventInsertSQL = """
                INSERT INTO events (document_id, start_time, end_time, location)
                VALUES (?, ?, ?, ?)
            """
            
            var eventStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, eventInsertSQL, -1, &eventStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(eventStatement, 1, documentId, -1, nil)
                sqlite3_bind_int(eventStatement, 2, Int32(firstEvent.startDate.timeIntervalSince1970))
                if let endDate = firstEvent.endDate {
                    sqlite3_bind_int(eventStatement, 3, Int32(endDate.timeIntervalSince1970))
                } else {
                    sqlite3_bind_null(eventStatement, 3)
                }
                sqlite3_bind_text(eventStatement, 4, firstEvent.location ?? "", -1, nil)
                
                if sqlite3_step(eventStatement) == SQLITE_DONE {
                    print("✅ Successfully inserted event data")
                } else {
                    let error = String(cString: sqlite3_errmsg(db))
                    print("❌ Failed to insert event: \(error)")
                }
            } else {
                let error = String(cString: sqlite3_errmsg(db))
                print("❌ Failed to prepare event statement: \(error)")
            }
            sqlite3_finalize(eventStatement)
            
        } else {
            let error = String(cString: sqlite3_errmsg(db))
            print("❌ Failed to insert document: \(error)")
        }
    } else {
        let error = String(cString: sqlite3_errmsg(db))
        print("❌ Failed to prepare document statement: \(error)")
    }
    sqlite3_finalize(docStatement)
}

sqlite3_close(db)

print("\n🔍 Checking final database state...")

// Check if our test insert worked
let checkCmd = "sqlite3 \"\(dbPath)\" \"SELECT COUNT(*) FROM documents WHERE type = 'event';\""
let task = Process()
task.launchPath = "/bin/sh"
task.arguments = ["-c", checkCmd]

let pipe = Pipe()
task.standardOutput = pipe
task.launch()
task.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
if let output = String(data: data, encoding: .utf8) {
    print("Total events in database: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
}