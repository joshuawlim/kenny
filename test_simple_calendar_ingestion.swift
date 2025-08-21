#!/usr/bin/env swift

// Add this to the Swift file search paths if needed
#if canImport(Darwin)
import Darwin
#endif

import Foundation
import EventKit

// Simple test to see if EventKit can find and iterate through events
print("🧪 Simple Calendar Ingestion Test")
print("=================================")

let eventStore = EKEventStore()

// Get a small set of events from January 2025
let cal = Calendar.current
let startDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let endDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 7))!  // Just first week

let calendars = eventStore.calendars(for: .event)
print("Using \(calendars.count) calendars")

let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

print("Found \(events.count) events in first week of January 2025")

for (i, event) in events.enumerated() {
    print("\n--- Event \(i+1) ---")
    print("Title: \(event.title ?? "No title")")
    print("Start: \(event.startDate)")
    print("End: \(event.endDate?.description ?? "No end")")
    print("Location: \(event.location ?? "No location")")
    print("Event ID: \(event.eventIdentifier ?? "No ID")")
    print("Calendar: \(event.calendar.title)")
    print("All Day: \(event.isAllDay)")
    
    // Try to create what would be inserted into database
    let documentId = "cal-\(UUID().uuidString.prefix(8))"
    print("Would create document ID: \(documentId)")
    
    // Check for any nil values that might cause issues
    if event.eventIdentifier == nil {
        print("⚠️  WARNING: Event has no identifier!")
    }
    if event.title == nil {
        print("⚠️  WARNING: Event has no title!")
    }
}