import Foundation
import EventKit

public class CalendarIngester {
    private let database: Database
    private let eventStore = EKEventStore()
    
    public init(database: Database) {
        self.database = database
    }
    
    // MARK: - Main Ingestion Method
    public func ingestCalendar(
        isFullSync: Bool = true,
        since: Date? = nil,
        batchSize: Int = 100,
        maxEvents: Int? = nil,
        config: CalendarBatchConfig = CalendarBatchConfig()
    ) async throws -> CalendarIngestionResult {
        
        let startTime = Date()
        var result = CalendarIngestionResult()
        
        if config.enableDetailedLogging {
            print("[CalendarIngester] Starting Calendar ingestion...")
            print("[CalendarIngester] Configuration: batchSize=\(batchSize), maxEvents=\(maxEvents?.description ?? "unlimited"), fullSync=\(isFullSync)")
        }
        
        // Request Calendar access
        try await requestCalendarAccessIfNeeded()
        
        // Get all calendars
        let calendars = eventStore.calendars(for: .event)
        if config.enableDetailedLogging {
            print("[CalendarIngester] Found \(calendars.count) calendars:")
            for calendar in calendars {
                print("[CalendarIngester]   - \(calendar.title) (type: \(calendar.type.rawValue))")
            }
        }
        
        // Set date range based on sync type
        let (startDate, endDate) = determineDateRange(isFullSync: isFullSync, since: since)
        if config.enableDetailedLogging {
            print("[CalendarIngester] Date range: \(startDate) to \(endDate)")
        }
        
        // Query events
        let events = queryEvents(calendars: calendars, startDate: startDate, endDate: endDate, maxEvents: maxEvents)
        result.totalEvents = events.count
        
        if config.enableDetailedLogging {
            print("[CalendarIngester] Found \(events.count) events to process")
        }
        
        // Process events in batches
        let batches = stride(from: 0, to: events.count, by: batchSize).map {
            Array(events[$0..<Swift.min($0 + batchSize, events.count)])
        }
        result.totalBatches = batches.count
        
        for (batchIndex, batch) in batches.enumerated() {
            let batchStartTime = Date()
            
            if config.enableDetailedLogging && (batchIndex < 3 || batchIndex % 10 == 0) {
                print("[CalendarIngester] Processing batch \(batchIndex + 1)/\(batches.count) (\(batch.count) events)")
            }
            
            do {
                let batchResult = try processBatch(batch, batchIndex: batchIndex, isFullSync: isFullSync, config: config)
                result.combine(with: batchResult)
                result.batchesProcessed += 1
                result.lastSuccessfulBatch = batchIndex
                
                let batchDuration = Date().timeIntervalSince(batchStartTime)
                if config.enableDetailedLogging && batchDuration > 1.0 {
                    print("[CalendarIngester] Batch \(batchIndex + 1) completed in \(String(format: "%.3f", batchDuration))s")
                }
                
            } catch {
                let errorMessage = "Batch \(batchIndex + 1) failed: \(error.localizedDescription)"
                result.errors.append(errorMessage)
                
                print("[CalendarIngester] ❌ \(errorMessage)")
                
                if !config.continueOnBatchFailure {
                    throw error
                }
            }
        }
        
        result.duration = Date().timeIntervalSince(startTime)
        
        if config.enableDetailedLogging {
            print("[CalendarIngester] Calendar ingestion completed:")
            print("[CalendarIngester]   Total events: \(result.totalEvents)")
            print("[CalendarIngester]   Items processed: \(result.itemsProcessed)")
            print("[CalendarIngester]   Items created: \(result.itemsCreated)")
            print("[CalendarIngester]   Items updated: \(result.itemsUpdated)")
            print("[CalendarIngester]   Batches processed: \(result.batchesProcessed)/\(result.totalBatches)")
            print("[CalendarIngester]   Errors: \(result.errors.count)")
            print("[CalendarIngester]   Duration: \(String(format: "%.3f", result.duration))s")
        }
        
        return result
    }
    
    // MARK: - Batch Processing
    private func processBatch(
        _ events: [EKEvent],
        batchIndex: Int,
        isFullSync: Bool,
        config: CalendarBatchConfig
    ) throws -> CalendarIngestionResult {
        
        var batchResult = CalendarIngestionResult()
        
        // Process events without explicit transactions for now
        // The Database class will handle individual insert operations
        
        for (eventIndex, event) in events.enumerated() {
            do {
                let processed = try processEvent(event, isFullSync: isFullSync)
                if processed.created {
                    batchResult.itemsCreated += 1
                } else if processed.updated {
                    batchResult.itemsUpdated += 1
                }
                batchResult.itemsProcessed += 1
                
                // Detailed logging for first few events or periodically
                if config.enableDetailedLogging && (batchIndex < 1 && eventIndex < 3) {
                    print("[CalendarIngester]     Event \(eventIndex + 1): \(event.title ?? "Untitled") - \(processed.created ? "created" : processed.updated ? "updated" : "skipped")")
                }
                
            } catch {
                let errorMessage = "Event '\(event.title ?? "Untitled")' failed: \(error.localizedDescription)"
                batchResult.errors.append(errorMessage)
                
                if config.enableDetailedLogging {
                    print("[CalendarIngester]     ❌ \(errorMessage)")
                }
            }
        }
        
        return batchResult
    }
    
    // MARK: - Event Processing
    private func processEvent(_ event: EKEvent, isFullSync: Bool) throws -> ProcessingResult {
        let sourceId = event.eventIdentifier ?? "no-id-\(UUID().uuidString)"
        
        // Check if event already exists (for incremental sync)
        if !isFullSync {
            if let existingDoc = database.query(
                "SELECT id, updated_at FROM documents WHERE app_source = ? AND source_id = ?",
                parameters: ["Calendar", sourceId]
            ).first {
                // Check if event was modified since last sync
                let lastModified = event.lastModifiedDate ?? event.creationDate ?? Date()
                let existingUpdatedAt = Date(timeIntervalSince1970: TimeInterval(existingDoc["updated_at"] as? Int64 ?? 0))
                
                if lastModified <= existingUpdatedAt {
                    return ProcessingResult(created: false, updated: false) // Skip unmodified
                }
                
                // Update existing event
                try updateEvent(event, documentId: existingDoc["id"] as! String)
                return ProcessingResult(created: false, updated: true)
            }
        }
        
        // Create new event
        try createEvent(event)
        return ProcessingResult(created: true, updated: false)
    }
    
    private func createEvent(_ event: EKEvent, forceDocumentId: String? = nil) throws {
        let documentId = forceDocumentId ?? UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        // Create rich searchable content
        let content = buildEventContent(event)
        let sourceId = event.eventIdentifier ?? "no-id-\(documentId)"
        let hashString = buildEventHash(event)
        
        // Insert into documents table
        let docData: [String: Any] = [
            "id": documentId,
            "type": "event",
            "title": event.title ?? "Untitled Event",
            "content": content,
            "app_source": "Calendar",
            "source_id": sourceId,
            "source_path": "calshow:\(sourceId)",
            "hash": hashString.hashValue.description,
            "created_at": Int(event.creationDate?.timeIntervalSince1970 ?? Double(now)),
            "updated_at": Int(event.lastModifiedDate?.timeIntervalSince1970 ?? Double(now)),
            "last_seen_at": now,
            "deleted": false
        ]
        
        guard database.insert("documents", data: docData) else {
            throw CalendarIngestionError.documentInsertFailed("Failed to insert document for event: \(event.title ?? "Untitled")")
        }
        
        // Insert into events table
        let eventData = buildEventData(event, documentId: documentId)
        guard database.insert("events", data: eventData) else {
            throw CalendarIngestionError.eventInsertFailed("Failed to insert event data for: \(event.title ?? "Untitled")")
        }
    }
    
    private func updateEvent(_ event: EKEvent, documentId: String) throws {
        // For now, just recreate the event instead of updating
        // The Database class doesn't have update methods, so we'll use INSERT OR REPLACE
        try createEvent(event, forceDocumentId: documentId)
    }
    
    // MARK: - Content Building
    private func buildEventContent(_ event: EKEvent) -> String {
        var contentParts: [String] = []
        
        if let notes = event.notes, !notes.isEmpty {
            contentParts.append(notes)
        }
        
        if let location = event.location, !location.isEmpty {
            contentParts.append("Location: \(location)")
        }
        
        if let attendees = event.attendees, !attendees.isEmpty {
            let attendeeNames = attendees.compactMap { $0.name }.filter { !$0.isEmpty }
            if !attendeeNames.isEmpty {
                contentParts.append("Attendees: \(attendeeNames.joined(separator: ", "))")
            }
        }
        
        if let organizer = event.organizer?.name, !organizer.isEmpty {
            contentParts.append("Organizer: \(organizer)")
        }
        
        if !event.calendar.title.isEmpty {
            contentParts.append("Calendar: \(event.calendar.title)")
        }
        
        return contentParts.joined(separator: "\n")
    }
    
    private func buildEventHash(_ event: EKEvent) -> String {
        return "\(event.title ?? "")\(event.startDate)\(event.endDate ?? Date())\(buildEventContent(event))"
    }
    
    private func buildEventData(_ event: EKEvent, documentId: String) -> [String: Any] {
        var eventData: [String: Any] = [
            "document_id": documentId,
            "start_time": Int(event.startDate.timeIntervalSince1970),
            "is_all_day": event.isAllDay,
            "location": event.location ?? "",
            "calendar_name": event.calendar.title,
            "status": eventStatusString(event.status),
            "timezone": event.timeZone?.identifier ?? "America/Los_Angeles"
        ]
        
        if let endDate = event.endDate {
            eventData["end_time"] = Int(endDate.timeIntervalSince1970)
        } else {
            eventData["end_time"] = NSNull()
        }
        
        // Process attendees
        if let attendees = event.attendees, !attendees.isEmpty {
            let attendeesData = attendees.map { attendee in
                return [
                    "name": attendee.name ?? "",
                    "email": extractEmailFromURL(attendee.url),
                    "status": participantStatusString(attendee.participantStatus),
                    "type": participantTypeString(attendee.participantType),
                    "role": participantRoleString(attendee.participantRole)
                ]
            }
            
            if let attendeesJSON = try? JSONSerialization.data(withJSONObject: attendeesData),
               let attendeesString = String(data: attendeesJSON, encoding: .utf8) {
                eventData["attendees"] = attendeesString
            }
        } else {
            eventData["attendees"] = ""
        }
        
        // Process organizer
        if let organizer = event.organizer {
            eventData["organizer_name"] = organizer.name ?? ""
            eventData["organizer_email"] = extractEmailFromURL(organizer.url) ?? ""
        } else {
            eventData["organizer_name"] = ""
            eventData["organizer_email"] = ""
        }
        
        // Process recurrence rule
        if let recurrenceRules = event.recurrenceRules, !recurrenceRules.isEmpty {
            // Note: EKRecurrenceRule doesn't have a direct string representation
            // For now, we'll store a simple description
            eventData["recurrence_rule"] = "RECURRING"
        } else {
            eventData["recurrence_rule"] = ""
        }
        
        return eventData
    }
    
    // MARK: - Helper Methods
    private func determineDateRange(isFullSync: Bool, since: Date?) -> (Date, Date) {
        let endDate = Date().addingTimeInterval(365 * 24 * 60 * 60) // 1 year from now
        
        let startDate: Date
        if isFullSync {
            // For full sync, go back 2 years to get historical events
            startDate = Date().addingTimeInterval(-2 * 365 * 24 * 60 * 60)
        } else {
            // For incremental, use since date or last 30 days
            startDate = since ?? Date().addingTimeInterval(-30 * 24 * 60 * 60)
        }
        
        return (startDate, endDate)
    }
    
    private func queryEvents(calendars: [EKCalendar], startDate: Date, endDate: Date, maxEvents: Int?) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        
        if let maxEvents = maxEvents {
            return Array(events.prefix(maxEvents))
        }
        
        return events
    }
    
    private func requestCalendarAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        var needsAccess = false
        
        if #available(macOS 14.0, iOS 17.0, *) {
            needsAccess = status != .authorized && status != .fullAccess
        } else {
            needsAccess = status != .authorized
        }
        
        if needsAccess {
            try await requestCalendarAccess()
            // Reset event store after authorization change
            eventStore.reset()
        }
    }
    
    private func requestCalendarAccess() async throws {
        // Use modern API for macOS 14+ if available
        if #available(macOS 14.0, iOS 17.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                if !granted {
                    throw CalendarIngestionError.permissionDenied("Calendar - Full access required to read events")
                }
            } catch {
                throw CalendarIngestionError.permissionDenied("Calendar - \(error.localizedDescription)")
            }
        } else {
            // Fallback to legacy API
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if !granted {
                        continuation.resume(throwing: CalendarIngestionError.permissionDenied("Calendar"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    // MARK: - Enum Helper Methods
    private func eventStatusString(_ status: EKEventStatus) -> String {
        switch status {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "cancelled"
        default: return "none"
        }
    }
    
    private func participantStatusString(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "pending"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    
    private func participantTypeString(_ type: EKParticipantType) -> String {
        switch type {
        case .person: return "person"
        case .room: return "room"
        case .resource: return "resource"
        case .group: return "group"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    
    private func participantRoleString(_ role: EKParticipantRole) -> String {
        switch role {
        case .chair: return "chair"
        case .required: return "required"
        case .optional: return "optional"
        case .nonParticipant: return "non_participant"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    
    private func extractEmailFromURL(_ url: URL?) -> String? {
        guard let url = url else { return nil }
        let urlString = url.absoluteString
        if urlString.hasPrefix("mailto:") {
            return String(urlString.dropFirst(7)) // Remove "mailto:"
        }
        return urlString
    }
}

// MARK: - Data Structures
public struct CalendarBatchConfig {
    public let batchSize: Int
    public let maxEvents: Int?
    public let enableDetailedLogging: Bool
    public let continueOnBatchFailure: Bool
    
    public init(
        batchSize: Int = 100,
        maxEvents: Int? = nil,
        enableDetailedLogging: Bool = true,
        continueOnBatchFailure: Bool = true
    ) {
        self.batchSize = batchSize
        self.maxEvents = maxEvents
        self.enableDetailedLogging = enableDetailedLogging
        self.continueOnBatchFailure = continueOnBatchFailure
    }
}

public struct CalendarIngestionResult {
    public var totalEvents: Int = 0
    public var totalBatches: Int = 0
    public var batchesProcessed: Int = 0
    public var lastSuccessfulBatch: Int = 0
    public var itemsProcessed: Int = 0
    public var itemsCreated: Int = 0
    public var itemsUpdated: Int = 0
    public var errors: [String] = []
    public var duration: TimeInterval = 0
    
    public init() {}
    
    public mutating func combine(with other: CalendarIngestionResult) {
        itemsProcessed += other.itemsProcessed
        itemsCreated += other.itemsCreated
        itemsUpdated += other.itemsUpdated
        errors.append(contentsOf: other.errors)
    }
    
    public var hasErrors: Bool {
        return !errors.isEmpty
    }
}

private struct ProcessingResult {
    let created: Bool
    let updated: Bool
}

public enum CalendarIngestionError: Error, LocalizedError {
    case permissionDenied(String)
    case documentInsertFailed(String)
    case documentUpdateFailed(String)
    case eventInsertFailed(String)
    case eventUpdateFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let message):
            return "Permission denied: \(message)"
        case .documentInsertFailed(let message):
            return "Document insert failed: \(message)"
        case .documentUpdateFailed(let message):
            return "Document update failed: \(message)"
        case .eventInsertFailed(let message):
            return "Event insert failed: \(message)"
        case .eventUpdateFailed(let message):
            return "Event update failed: \(message)"
        }
    }
}

// No additional extensions needed