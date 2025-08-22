#!/usr/bin/env swift

import Foundation
import SQLite3
import EventKit

// Simple test to manually ingest some Calendar events
func testCalendarIngestion() {
    print("Starting simple Calendar ingestion test...")
    
    // Open the database
    var db: OpaquePointer?
    let result = sqlite3_open("kenny.db", &db)
    guard result == SQLITE_OK else {
        print("Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    defer { sqlite3_close(db) }
    
    // Count existing events
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1, &stmt, nil)
    sqlite3_step(stmt)
    let existingCount = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    print("Existing events in database: \(existingCount)")
    
    // Get some Calendar events
    let eventStore = EKEventStore()
    let calendars = eventStore.calendars(for: .event)
    
    let startDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // Last week
    let endDate = Date().addingTimeInterval(7 * 24 * 60 * 60)   // Next week
    
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = eventStore.events(matching: predicate)
    
    print("Found \(events.count) events to process")
    
    // Process first 5 events
    let eventsToProcess = Array(events.prefix(5))
    
    for (index, event) in eventsToProcess.enumerated() {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        let title = event.title ?? "Untitled Event"
        let content = [
            event.notes ?? "",
            event.location.map { "Location: \($0)" } ?? "",
            event.organizer?.name.map { "Organizer: \($0)" } ?? ""
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        
        let sourceId = event.eventIdentifier ?? "no-id-\(documentId)"
        
        print("Processing event \(index + 1): \(title)")
        
        // Insert into documents table
        let docSQL = """
            INSERT OR REPLACE INTO documents 
            (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        sqlite3_prepare_v2(db, docSQL, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, documentId, -1, nil)
        sqlite3_bind_text(stmt, 2, "event", -1, nil)
        sqlite3_bind_text(stmt, 3, title, -1, nil)
        sqlite3_bind_text(stmt, 4, content, -1, nil)
        sqlite3_bind_text(stmt, 5, "Calendar", -1, nil)
        sqlite3_bind_text(stmt, 6, sourceId, -1, nil)
        sqlite3_bind_text(stmt, 7, "calshow:\(sourceId)", -1, nil)
        sqlite3_bind_text(stmt, 8, "\(title)\(content)\(now)".hashValue.description, -1, nil)
        sqlite3_bind_int(stmt, 9, Int32(event.creationDate?.timeIntervalSince1970 ?? Double(now)))
        sqlite3_bind_int(stmt, 10, Int32(event.lastModifiedDate?.timeIntervalSince1970 ?? Double(now)))
        sqlite3_bind_int(stmt, 11, Int32(now))
        sqlite3_bind_int(stmt, 12, 0) // not deleted
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("  ✅ Inserted document")
        } else {
            print("  ❌ Failed to insert document: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        
        // Insert into events table
        let eventSQL = """
            INSERT OR REPLACE INTO events 
            (document_id, start_time, end_time, location)
            VALUES (?, ?, ?, ?)
        """
        
        sqlite3_prepare_v2(db, eventSQL, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, documentId, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(event.startDate.timeIntervalSince1970))
        if let endDate = event.endDate {
            sqlite3_bind_int(stmt, 3, Int32(endDate.timeIntervalSince1970))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, event.location ?? "", -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("  ✅ Inserted event record")
        } else {
            print("  ❌ Failed to insert event: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
    }
    
    // Count final events
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1, &stmt, nil)
    sqlite3_step(stmt)
    let finalCount = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    print("\nFinal events count: \(finalCount)")
    
    // Show some sample data
    let selectSQL = "SELECT d.title, e.start_time, e.location FROM documents d JOIN events e ON d.id = e.document_id LIMIT 3"
    sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil)
    
    print("\nSample inserted events:")
    while sqlite3_step(stmt) == SQLITE_ROW {
        let title = String(cString: sqlite3_column_text(stmt, 0))
        let startTime = sqlite3_column_int(stmt, 1)
        let location = String(cString: sqlite3_column_text(stmt, 2))
        let date = Date(timeIntervalSince1970: TimeInterval(startTime))
        print("  - \(title) at \(date) (\(location))")
    }
    sqlite3_finalize(stmt)
}

testCalendarIngestion()