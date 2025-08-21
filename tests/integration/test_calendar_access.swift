#!/usr/bin/env swift

import Foundation
import EventKit

print("🗓️  Testing Calendar Access...")

let eventStore = EKEventStore()

// Check current authorization status
let status = EKEventStore.authorizationStatus(for: .event)
print("Current Calendar authorization status: \(status.rawValue)")

switch status {
case .notDetermined:
    print("❌ Calendar access not determined - requesting permission...")
case .restricted:
    print("❌ Calendar access restricted")
case .denied:
    print("❌ Calendar access denied")
case .authorized:
    print("✅ Calendar access authorized")
case .fullAccess:
    print("✅ Calendar full access granted")
case .writeOnly:
    print("⚠️  Calendar write-only access")
@unknown default:
    print("❓ Unknown authorization status")
}

// Try to get calendars
let calendars = eventStore.calendars(for: .event)
print("Found \(calendars.count) calendars:")
for calendar in calendars {
    print("  - \(calendar.title) (\(calendar.source.title))")
}

// Try to get events for January 2025
let calendar = Calendar.current
let startDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let endDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 31))!

let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
let events = eventStore.events(matching: predicate)

print("\nFound \(events.count) events in January 2025:")
for event in events.prefix(10) {  // Show first 10 events
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    
    print("  📅 \(event.title ?? "Untitled") - \(formatter.string(from: event.startDate))")
    if let location = event.location {
        print("     📍 \(location)")
    }
}

if events.count > 10 {
    print("  ... and \(events.count - 10) more events")
}