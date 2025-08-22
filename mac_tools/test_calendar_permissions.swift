#!/usr/bin/env swift

import Foundation
import EventKit

// Test Calendar permissions and basic EventKit functionality
func testCalendarPermissions() async {
    print("Testing Calendar permissions and EventKit functionality...")
    
    let eventStore = EKEventStore()
    
    // Check current authorization status
    let status = EKEventStore.authorizationStatus(for: .event)
    print("Current authorization status: \(status.rawValue)")
    
    switch status {
    case .notDetermined:
        print("Status: Not determined - need to request access")
    case .restricted:
        print("Status: Restricted")
    case .denied:
        print("Status: Denied")
    case .authorized:
        print("Status: Authorized (legacy)")
    case .writeOnly:
        print("Status: Write only")
    case .fullAccess:
        print("Status: Full access")
    @unknown default:
        print("Status: Unknown (\(status.rawValue))")
    }
    
    // Try to access calendars
    let calendars = eventStore.calendars(for: .event)
    print("Found \(calendars.count) calendars:")
    
    for calendar in calendars.prefix(5) {
        print("  - \(calendar.title) (type: \(calendar.type.rawValue), source: \(calendar.source.title))")
    }
    
    // Try to fetch some events (last 30 days to next 30 days)
    let startDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    let endDate = Date().addingTimeInterval(30 * 24 * 60 * 60)
    
    print("\nFetching events from \(startDate) to \(endDate)...")
    
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = eventStore.events(matching: predicate)
    
    print("Found \(events.count) events:")
    
    for event in events.prefix(5) {
        print("  - \(event.title ?? "Untitled") (\(event.startDate) - \(event.endDate ?? Date()))")
        if let location = event.location, !location.isEmpty {
            print("    Location: \(location)")
        }
        if let notes = event.notes, !notes.isEmpty {
            print("    Notes: \(notes.prefix(100))...")
        }
    }
}

// Run the test
Task {
    await testCalendarPermissions()
    exit(0)
}

RunLoop.main.run()