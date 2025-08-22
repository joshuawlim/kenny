#!/usr/bin/env swift

// Minimal test of just calendar ingestion to isolate the issue

import Foundation
import EventKit

let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"

print("🧪 Testing Calendar Ingestion Only")
print("===============================")

// Test database connection first
let task = Process()
task.launchPath = "/usr/bin/sqlite3"
task.arguments = [dbPath, "SELECT COUNT(*) FROM documents;"]

let pipe = Pipe()
task.standardOutput = pipe

task.launch()
task.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
if let output = String(data: data, encoding: .utf8) {
    print("Database accessible - documents: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
} else {
    print("❌ Cannot access database")
    exit(1)
}

// Test EventKit directly  
let eventStore = EKEventStore()
let calendars = eventStore.calendars(for: .event)
print("✅ EventKit access: \(calendars.count) calendars available")

// Get a few events
let cal = Calendar.current
let startDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let endDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 7))!

let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

print("Found \(events.count) events for first week of Jan 2025")

if events.count > 0 {
    let event = events[0]
    print("First event: \(event.title ?? "No title")")
    
    // Try inserting just ONE event manually into database
    let documentId = "test-\(UUID().uuidString.prefix(8))"
    let now = Int(Date().timeIntervalSince1970)
    
    // Simplified insert
    let insertSQL = """
    INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted)
    VALUES ('\(documentId)', 'event', '\(event.title ?? "Test Event")', 'Test content', 'Calendar', '\(event.eventIdentifier ?? "test-id")', 'calshow:test', 'testhash', \(now), \(now), \(now), 0)
    """
    
    print("\n🔧 Testing manual event insert...")
    let insertTask = Process()
    insertTask.launchPath = "/usr/bin/sqlite3"
    insertTask.arguments = [dbPath, insertSQL]
    
    let insertPipe = Pipe()
    insertTask.standardOutput = insertPipe
    insertTask.standardError = insertPipe
    
    insertTask.launch()
    insertTask.waitUntilExit()
    
    if insertTask.terminationStatus == 0 {
        print("✅ Manual insert successful")
        
        // Check result
        let checkTask = Process()
        checkTask.launchPath = "/usr/bin/sqlite3"
        checkTask.arguments = [dbPath, "SELECT COUNT(*) FROM documents WHERE type='event';"]
        
        let checkPipe = Pipe()
        checkTask.standardOutput = checkPipe
        
        checkTask.launch()
        checkTask.waitUntilExit()
        
        let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
        if let count = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("Total events in database now: \(count)")
        }
    } else {
        let errorData = insertPipe.fileHandleForReading.readDataToEndOfFile()
        if let error = String(data: errorData, encoding: .utf8) {
            print("❌ Insert failed: \(error)")
        }
    }
} else {
    print("❌ No events found to test with")
}

print("\n✅ Manual calendar test completed")