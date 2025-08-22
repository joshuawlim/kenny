#!/usr/bin/env swift

import Foundation
import EventKit
import CommonCrypto

// SHA256 extension for hash generation
extension String {
    func sha256() -> String {
        let data = self.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

print("🧪 Manual Calendar Event Database Test")
print("======================================")

let eventStore = EKEventStore()

// Get one real event from your calendar
let cal = Calendar.current
let startDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let endDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 7))!

let calendars = eventStore.calendars(for: .event)
let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

guard let event = events.first else {
    print("❌ No events found")
    exit(1)
}

print("📅 Using event: \(event.title ?? "No title")")
print("Start: \(event.startDate)")

// Replicate IngestManager logic exactly
let documentId = "manual-test-\(UUID().uuidString.prefix(8))"
let now = Int(Date().timeIntervalSince1970)

// Create content like IngestManager does
var contentParts: [String] = []
if let location = event.location, !location.isEmpty {
    contentParts.append("Location: \(location)")
}
if event.isAllDay {
    contentParts.append("All day event")
}
if let attendees = event.attendees, !attendees.isEmpty {
    let attendeeNames = attendees.compactMap { $0.name }.joined(separator: ", ")
    contentParts.append("Attendees: \(attendeeNames)")
}
if let organizer = event.organizer?.name {
    contentParts.append("Organizer: \(organizer)")
}

let content = contentParts.joined(separator: "\n")

print("Generated content: \(content)")

// Create document data exactly like IngestManager
let docData: [String: Any] = [
    "id": documentId,
    "type": "event",
    "title": event.title ?? "Untitled Event",
    "content": content,
    "app_source": "Calendar",
    "source_id": event.eventIdentifier ?? "no-id",
    "source_path": "calshow:\(event.eventIdentifier ?? "")",
    "hash": "\(event.title ?? "")\(event.startDate)\(event.endDate ?? Date())\(content)".sha256(),
    "created_at": Int(event.creationDate?.timeIntervalSince1970 ?? Double(now)),
    "updated_at": Int(event.lastModifiedDate?.timeIntervalSince1970 ?? Double(now)),
    "last_seen_at": now,
    "deleted": false
]

print("\nDocument data prepared:")
for (key, value) in docData {
    print("  \(key): \(value)")
}

// Now manually insert using sqlite3 command
let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"

// Insert document
let insertDocSQL = """
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted)
VALUES ('\(docData["id"]!)', '\(docData["type"]!)', '\(docData["title"]!)', '\(docData["content"]!)', '\(docData["app_source"]!)', '\(docData["source_id"]!)', '\(docData["source_path"]!)', '\(docData["hash"]!)', \(docData["created_at"]!), \(docData["updated_at"]!), \(docData["last_seen_at"]!), \(docData["deleted"]!))
"""

print("\n🔧 Executing document insert...")
let docTask = Process()
docTask.launchPath = "/usr/bin/sqlite3"
docTask.arguments = [dbPath, insertDocSQL]

let docPipe = Pipe()
docTask.standardOutput = docPipe
docTask.standardError = docPipe

docTask.launch()
docTask.waitUntilExit()

if docTask.terminationStatus == 0 {
    print("✅ Document inserted successfully")
    
    // Insert into events table
    let eventData: [String: Any] = [
        "document_id": documentId,
        "start_time": Int(event.startDate.timeIntervalSince1970),
        "end_time": event.endDate != nil ? Int(event.endDate!.timeIntervalSince1970) : 0,
        "location": event.location ?? ""
    ]
    
    let insertEventSQL = """
    INSERT INTO events (document_id, start_time, end_time, location)
    VALUES ('\(eventData["document_id"]!)', \(eventData["start_time"]!), \(eventData["end_time"]!), '\(eventData["location"]!)')
    """
    
    print("\n🔧 Executing events insert...")
    let eventTask = Process()
    eventTask.launchPath = "/usr/bin/sqlite3"
    eventTask.arguments = [dbPath, insertEventSQL]
    
    let eventPipe = Pipe()
    eventTask.standardOutput = eventPipe
    eventTask.standardError = eventPipe
    
    eventTask.launch()
    eventTask.waitUntilExit()
    
    if eventTask.terminationStatus == 0 {
        print("✅ Event data inserted successfully")
    } else {
        let errorData = eventPipe.fileHandleForReading.readDataToEndOfFile()
        if let errorOutput = String(data: errorData, encoding: .utf8) {
            print("❌ Event insert failed: \(errorOutput)")
        }
    }
} else {
    let errorData = docPipe.fileHandleForReading.readDataToEndOfFile()
    if let errorOutput = String(data: errorData, encoding: .utf8) {
        print("❌ Document insert failed: \(errorOutput)")
    }
}

// Check final state
print("\n🔍 Checking final database state...")
let checkTask = Process()
checkTask.launchPath = "/usr/bin/sqlite3"
checkTask.arguments = [dbPath, "SELECT COUNT(*) FROM documents WHERE type='event';"]

let checkPipe = Pipe()
checkTask.standardOutput = checkPipe

checkTask.launch()
checkTask.waitUntilExit()

let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
if let count = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
    print("Total event documents: \(count)")
}