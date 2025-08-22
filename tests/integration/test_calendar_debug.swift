#!/usr/bin/env swift

import Foundation
import EventKit

print("🔍 Deep Calendar Debug...")

let eventStore = EKEventStore()

// Get ALL calendars from ALL sources
let allCalendars = eventStore.calendars(for: .event)
print("📅 Found \(allCalendars.count) total calendars:")

for calendar in allCalendars {
    print("  Calendar: '\(calendar.title)'")
    print("    Source: \(calendar.source.title) (\(calendar.source.sourceType.rawValue))")
    print("    Color: \(calendar.cgColor.debugDescription)")
    print("    Subscribed: \(calendar.isSubscribed)")
    print("    Immutable: \(calendar.isImmutable)")
    print("")
}

// Test multiple date ranges
let testRanges = [
    ("January 2025", 2025, 1),
    ("December 2024", 2024, 12),
    ("February 2025", 2025, 2),
    ("August 2024", 2024, 8)  // When development happened
]

for (name, year, month) in testRanges {
    print("🗓️  Checking \(name)...")
    
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    let endDate = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))!
    
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
    let events = eventStore.events(matching: predicate)
    
    print("  Found \(events.count) events")
    
    for event in events.prefix(3) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        print("    📅 \(event.title ?? "Untitled") - \(formatter.string(from: event.startDate))")
    }
    print("")
}

// Also check the next few days
print("🔍 Checking next 30 days from today...")
let now = Date()
let future = Calendar.current.date(byAdding: .day, value: 30, to: now)!
let predicate = eventStore.predicateForEvents(withStart: now, end: future, calendars: nil)
let upcomingEvents = eventStore.events(matching: predicate)

print("Found \(upcomingEvents.count) upcoming events:")
for event in upcomingEvents.prefix(5) {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    print("  📅 \(event.title ?? "Untitled") - \(formatter.string(from: event.startDate))")
    if let location = event.location {
        print("     📍 \(location)")
    }
}