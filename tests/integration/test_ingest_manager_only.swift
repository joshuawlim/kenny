#!/usr/bin/env swift

import Foundation
import EventKit

// Test JUST the calendar portion of IngestManager to see what fails

print("🧪 Testing IngestManager Calendar Logic Directly")
print("===============================================")

let eventStore = EKEventStore()

// Check authorization status
let status = EKEventStore.authorizationStatus(for: .event)
print("Calendar authorization status: \(status.rawValue)")

if #available(macOS 14.0, iOS 17.0, *) {
    print("Available statuses: authorized=3, fullAccess=4")
    if status == .fullAccess {
        print("✅ Have full access")
    } else if status == .authorized {
        print("⚠️ Have basic access only")
    } else {
        print("❌ No access: \(status)")
    }
} else {
    if status == .authorized {
        print("✅ Have access (pre-macOS 14)")
    } else {
        print("❌ No access: \(status)")
    }
}

// Test calendar enumeration
let calendars = eventStore.calendars(for: .event)
print("Available calendars: \(calendars.count)")
for (i, calendar) in calendars.enumerated() {
    print("  \(i+1). \(calendar.title) (source: \(calendar.source.title))")
}

// Test event predicate creation
let cal = Calendar.current
let startDate = cal.date(from: DateComponents(year: 2023, month: 1, day: 1))!
let endDate = Date().addingTimeInterval(365 * 24 * 60 * 60) // 1 year from now

print("\nDate range: \(startDate) to \(endDate)")

let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
print("✅ Created predicate successfully")

// Test event fetching
print("Fetching events...")
let events = eventStore.events(matching: predicate)
print("Found \(events.count) total events")

if events.count > 0 {
    print("\nFirst 3 events:")
    for (i, event) in events.prefix(3).enumerated() {
        print("  \(i+1). \(event.title ?? "No title") - \(event.startDate)")
        print("      ID: \(event.eventIdentifier ?? "No ID")")
        print("      Calendar: \(event.calendar.title)")
    }
} else {
    print("❌ No events found!")
}

print("\n✅ EventKit test completed successfully")