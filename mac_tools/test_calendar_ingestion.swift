#!/usr/bin/env swift

import Foundation

// Add the src directory to the module search path
#if canImport(Database)
import Database
#else
print("Error: Database module not found. Please build the project first.")
exit(1)
#endif

@main
struct CalendarIngestionTest {
    static func main() async {
        print("Testing Calendar ingestion...")
        
        do {
            // Open the database
            let database = try Database(path: "kenny.db")
            
            // Create an IngestManager
            let ingestManager = IngestManager(database: database)
            
            // Test Calendar ingestion
            print("Starting Calendar ingestion...")
            let stats = try await ingestManager.ingestCalendar(isFullSync: true)
            
            print("Calendar ingestion completed:")
            print("  Items processed: \(stats.itemsProcessed)")
            print("  Items created: \(stats.itemsCreated)")
            print("  Items updated: \(stats.itemsUpdated)")
            print("  Errors: \(stats.errors)")
            
            // Check the results in the database
            let eventCount = database.query("SELECT COUNT(*) as count FROM events").first?["count"] as? Int64 ?? 0
            let documentCount = database.query("SELECT COUNT(*) as count FROM documents WHERE type = 'event'").first?["count"] as? Int64 ?? 0
            
            print("\nDatabase verification:")
            print("  Events table: \(eventCount) records")
            print("  Documents table (event type): \(documentCount) records")
            
            // Show a few sample events
            let sampleEvents = database.query("SELECT title, start_time, location FROM documents d JOIN events e ON d.id = e.document_id LIMIT 5")
            print("\nSample events:")
            for event in sampleEvents {
                let title = event["title"] as? String ?? "No title"
                let startTime = event["start_time"] as? Int64 ?? 0
                let location = event["location"] as? String ?? ""
                let date = Date(timeIntervalSince1970: TimeInterval(startTime))
                print("  - \(title) at \(date) \(location.isEmpty ? "" : "(\(location))")")
            }
            
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}