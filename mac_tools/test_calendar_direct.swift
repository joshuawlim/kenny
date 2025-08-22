#!/usr/bin/env swift

import Foundation
import EventKit

// Import our modules
import Cocoa

// Add the build path to find our modules
let buildPath = ".build/arm64-apple-macosx/debug"
if FileManager.default.fileExists(atPath: buildPath) {
    print("Build path exists, attempting to load modules...")
} else {
    print("Build path does not exist. Need to build the project first.")
    exit(1)
}

print("Testing direct Calendar functionality...")

// Test basic EventKit access
let eventStore = EKEventStore()
let calendars = eventStore.calendars(for: .event)
print("Found \(calendars.count) calendars")

// Get events from the last 30 days
let startDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
let endDate = Date().addingTimeInterval(30 * 24 * 60 * 60)

let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

print("Found \(events.count) events in the last 60 days")

// Show first few events with detailed information
for (index, event) in events.prefix(3).enumerated() {
    print("\nEvent \(index + 1):")
    print("  Title: \(event.title ?? "No title")")
    print("  Start: \(event.startDate)")
    print("  End: \(event.endDate ?? Date())")
    print("  All day: \(event.isAllDay)")
    print("  Calendar: \(event.calendar.title)")
    print("  Location: \(event.location ?? "No location")")
    print("  Notes: \(event.notes?.prefix(100) ?? "No notes")")
    print("  Event ID: \(event.eventIdentifier ?? "No ID")")
    
    if let attendees = event.attendees {
        print("  Attendees: \(attendees.count)")
        for attendee in attendees.prefix(3) {
            print("    - \(attendee.name ?? "Unknown") (\(attendee.url.absoluteString))")
        }
    }
}

print("\nCalendar ingestion test complete!")