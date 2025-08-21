#!/usr/bin/env swift

import Foundation
import EventKit

// Test calendar ingestion logic similar to IngestManager
let eventStore = EKEventStore()

print("🔍 Debug: Calendar Ingestion Logic")
print("==================================")

// Check authorization status
let status = EKEventStore.authorizationStatus(for: .event)
print("Authorization status: \(status.rawValue)")

switch status {
case .notDetermined:
    print("❌ Not determined")
case .restricted:
    print("❌ Restricted")
case .denied:
    print("❌ Denied")
case .authorized:
    print("✅ Authorized")
case .fullAccess:
    print("✅ Full access")
case .writeOnly:
    print("⚠️  Write only")
@unknown default:
    print("❓ Unknown: \(status.rawValue)")
}

// Get calendars
let calendars = eventStore.calendars(for: .event)
print("\nFound \(calendars.count) calendars:")
for calendar in calendars {
    print("  - \(calendar.title) (source: \(calendar.source.title))")
}

// Set date range like IngestManager does for full sync
let startDate = Date().addingTimeInterval(-2 * 365 * 24 * 60 * 60) // 2 years back
let endDate = Date().addingTimeInterval(365 * 24 * 60 * 60) // 1 year forward

print("\nDate range: \(startDate) to \(endDate)")

// Get events using predicate like IngestManager
let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
let events = eventStore.events(matching: predicate)

print("Found \(events.count) events to process")

if events.count > 0 {
    print("\nFirst 5 events:")
    for (i, event) in events.prefix(5).enumerated() {
        print("  \(i+1). \(event.title ?? "Untitled") - \(event.startDate)")
        print("      ID: \(event.eventIdentifier ?? "no-id")")
        print("      Calendar: \(event.calendar.title)")
    }
} else {
    print("\n❌ No events found!")
    print("Possible issues:")
    print("1. Date range doesn't cover your events")
    print("2. Events are in calendars not accessible")
    print("3. Authorization issue")
}

// Test January 2025 specifically
let calendar = Calendar.current
let jan2025Start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let jan2025End = calendar.date(from: DateComponents(year: 2025, month: 1, day: 31))!

print("\n🗓️  Testing January 2025 specifically:")
let jan2025Predicate = eventStore.predicateForEvents(withStart: jan2025Start, end: jan2025End, calendars: calendars)
let jan2025Events = eventStore.events(matching: jan2025Predicate)
print("January 2025 events: \(jan2025Events.count)")