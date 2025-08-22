#!/usr/bin/env swift

import Foundation
import EventKit

print("🔧 Testing Fixed EventKit Implementation...")

let eventStore = EKEventStore()

// Check current authorization status with new enum values
let status = EKEventStore.authorizationStatus(for: .event)
print("Current authorization status: \(status.rawValue)")

switch status {
case .notDetermined:
    print("❌ Not determined - need to request access")
case .restricted:
    print("❌ Restricted")
case .denied:
    print("❌ Denied")
case .authorized:
    print("✅ Authorized (legacy)")
case .fullAccess:
    print("✅ Full access granted")
case .writeOnly:
    print("⚠️  Write-only access - CANNOT READ EVENTS")
@unknown default:
    print("❓ Unknown status: \(status.rawValue)")
}

// Function to request full access (iOS 17+/macOS 14+)
func requestFullAccess() async -> Bool {
    print("\n🔐 Requesting full calendar access...")
    
    // Check if new API is available
    if #available(macOS 14.0, iOS 17.0, *) {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            print("Full access request result: \(granted)")
            return granted
        } catch {
            print("Error requesting full access: \(error)")
            return false
        }
    } else {
        // Fallback to legacy API
        print("Using legacy requestAccess API...")
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error = error {
                    print("Legacy access error: \(error)")
                    continuation.resume(returning: false)
                } else {
                    print("Legacy access granted: \(granted)")
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

// Main async function
func testCalendarAccess() async {
    let currentStatus = EKEventStore.authorizationStatus(for: .event)
    
    // Only request if we don't have full access
    if currentStatus != .fullAccess && currentStatus != .authorized {
        let granted = await requestFullAccess()
        if !granted {
            print("❌ Calendar access not granted, exiting...")
            return
        }
        
        // Important: Reset the event store after getting new permissions
        print("🔄 Resetting EventStore after authorization...")
        eventStore.reset()
    }
    
    print("\n📅 Testing calendar access...")
    
    // Get all calendars
    let calendars = eventStore.calendars(for: .event)
    print("Found \(calendars.count) calendars:")
    for calendar in calendars {
        print("  - \(calendar.title) (source: \(calendar.source.title))")
    }
    
    // Test January 2025 events with explicit calendar array
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
    let endDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 31))!
    
    print("\n🔍 Searching January 2025 events...")
    print("Date range: \(startDate) to \(endDate)")
    
    // Pass explicit calendars array (not nil)
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = eventStore.events(matching: predicate)
    
    print("Found \(events.count) events in January 2025:")
    
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    
    for event in events.prefix(10) {
        print("  📅 \(event.title ?? "Untitled") - \(formatter.string(from: event.startDate))")
        if let location = event.location, !location.isEmpty {
            print("     📍 \(location)")
        }
    }
    
    if events.count > 10 {
        print("  ... and \(events.count - 10) more events")
    }
}

// Run the test
Task {
    await testCalendarAccess()
    exit(0)
}

// Keep the script running
RunLoop.main.run()