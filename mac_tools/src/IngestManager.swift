import Foundation
import EventKit
import Contacts

public class IngestManager {
    private let database: Database
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    
    public init(database: Database) {
        self.database = database
    }
    
    // MARK: - Full Ingest (Initial Sync)
    public func runFullIngest() async throws {
        let startTime = Date()
        print("Starting full ingest...")
        
        var stats = IngestStats()
        
        // Ingest all data sources SEQUENTIALLY to prevent database locking issues
        // (Previously parallel execution caused WAL mode conflicts)
        print("Running sequential ingestion to prevent database locking...")
        
        let mailStats = await safeIngest { try await ingestMail(isFullSync: true) }
        let eventStats = await safeIngest { try await ingestCalendar(isFullSync: true) }
        let reminderStats = await safeIngest { try await ingestReminders(isFullSync: true) }
        let noteStats = await safeIngest { try await ingestNotes(isFullSync: true) }
        let fileStats = await safeIngest { try await ingestFiles(isFullSync: true) }
        let messageStats = await safeIngest { try await ingestMessages(isFullSync: true) }
        let contactStats = await safeIngest { try await ingestContacts(isFullSync: true) }
        let whatsappStats = await safeIngest { try await ingestWhatsApp(isFullSync: true) }
        
        let results = [
            mailStats, eventStats, reminderStats, 
            noteStats, fileStats, messageStats, contactStats, whatsappStats
        ]
        
        // Combine stats
        for result in results {
            stats.combine(with: result)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        stats.duration = duration
        
        // Log results
        logIngestResults("full_ingest", stats: stats)
        
        print("Full ingest completed in \(duration)s: \(stats.itemsProcessed) items, \(stats.itemsCreated) created, \(stats.itemsUpdated) updated")
    }
    
    // MARK: - Incremental Ingest (Delta Updates)
    public func runIncrementalIngest() async throws {
        let startTime = Date()
        print("Starting incremental ingest...")
        
        var stats = IngestStats()
        
        // Get last ingest time for each source
        let lastIngestTimes = getLastIngestTimes()
        
        // Run incremental updates SEQUENTIALLY to prevent database locking
        print("Running sequential incremental updates to prevent database locking...")
        
        let mailStats = try await ingestMail(isFullSync: false, since: lastIngestTimes["mail"])
        let eventStats = try await ingestCalendar(isFullSync: false, since: lastIngestTimes["events"])
        let reminderStats = try await ingestReminders(isFullSync: false, since: lastIngestTimes["reminders"])
        let noteStats = try await ingestNotes(isFullSync: false, since: lastIngestTimes["notes"])
        let fileStats = try await ingestFiles(isFullSync: false, since: lastIngestTimes["files"])
        let messageStats = try await ingestMessages(isFullSync: false, since: lastIngestTimes["messages"])
        let contactStats = try await ingestContacts(isFullSync: false, since: lastIngestTimes["contacts"])
        let whatsappStats = try await ingestWhatsApp(isFullSync: false, since: lastIngestTimes["whatsapp"])
        
        let results = [
            mailStats, eventStats, reminderStats,
            noteStats, fileStats, messageStats, contactStats, whatsappStats
        ]
        
        for result in results {
            stats.combine(with: result)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        stats.duration = duration
        
        logIngestResults("incremental_ingest", stats: stats)
        
        print("Incremental ingest completed in \(duration)s: \(stats.itemsProcessed) items, \(stats.itemsCreated) created, \(stats.itemsUpdated) updated")
    }
    
    // MARK: - Mail Ingestion
    public func ingestMail(isFullSync: Bool, since: Date? = nil, batchSize: Int = 500, maxMessages: Int = 0) async throws -> IngestStats {
        let mailIngester = MailIngester(database: database)
        return try await mailIngester.ingestMail(isFullSync: isFullSync, since: since, batchSize: batchSize, maxMessages: maxMessages)
    }
    
    // MARK: - Calendar Ingestion
    public func ingestCalendar(isFullSync: Bool, since: Date? = nil, batchSize: Int = 100, maxEvents: Int? = nil) async throws -> IngestStats {
        // Use the existing legacy Calendar implementation for now
        return try await ingestCalendarLegacy(isFullSync: isFullSync, since: since)
    }
    
    // Legacy Calendar ingestion method (deprecated - use CalendarIngester directly)
    private func ingestCalendarLegacy(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "calendar")
        
        // Request calendar access with modern API
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
        
        let calendars = eventStore.calendars(for: .event)
        
        // Set date range based on sync type
        let startDate: Date
        let endDate = Date().addingTimeInterval(365 * 24 * 60 * 60) // 1 year from now
        
        if isFullSync {
            // For full sync, go back 2 years to get historical events
            startDate = Date().addingTimeInterval(-2 * 365 * 24 * 60 * 60)
        } else {
            // For incremental, use since date or last 30 days
            startDate = since ?? Date().addingTimeInterval(-30 * 24 * 60 * 60)
        }
        
        print("Calendar ingest: \(calendars.count) calendars, date range \(startDate) to \(endDate)")
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        
        print("Found \(events.count) calendar events to process")
        
        for event in events {
            // Skip if we've already processed this event (incremental sync)
            if !isFullSync {
                let sourceId = event.eventIdentifier ?? "no-id"
                let existingEvent = database.query(
                    "SELECT id FROM documents WHERE app_source = ? AND source_id = ?",
                    parameters: ["Calendar", sourceId]
                )
                if !existingEvent.isEmpty {
                    // Check if event was modified since last sync
                    let lastModified = event.lastModifiedDate ?? event.creationDate ?? Date()
                    if let since = since, lastModified < since {
                        continue // Skip unmodified event
                    }
                    stats.itemsUpdated += 1
                } else {
                    stats.itemsCreated += 1
                }
            } else {
                stats.itemsCreated += 1
            }
            
            let documentId = UUID().uuidString
            let now = Int(Date().timeIntervalSince1970)
            
            // Create rich content for search
            var contentParts: [String] = []
            if let notes = event.notes, !notes.isEmpty {
                contentParts.append(notes)
            }
            if let location = event.location, !location.isEmpty {
                contentParts.append("Location: \(location)")
            }
            if let attendees = event.attendees, !attendees.isEmpty {
                let attendeeNames = attendees.compactMap { $0.name }.joined(separator: ", ")
                contentParts.append("Attendees: \(attendeeNames)")
            }
            if let organizer = event.organizer?.name {
                contentParts.append("Organizer: \(organizer)")
            }
            
            let content = contentParts.joined(separator: "\n")
            
            let sourceId = event.eventIdentifier ?? "no-id-\(documentId)"
            let hashString = "\(event.title ?? "")\(event.startDate)\(event.endDate ?? Date())\(content)"
            
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
            
            if self.database.insertOrReplace("documents", data: docData) {
                // Prepare attendees with full details
                let attendees = event.attendees?.map { attendee in
                    return [
                        "name": attendee.name ?? "",
                        "email": extractEmailFromURL(attendee.url),
                        "status": participantStatusString(attendee.participantStatus),
                        "type": participantTypeString(attendee.participantType),
                        "role": participantRoleString(attendee.participantRole)
                    ]
                } ?? []
                
                let eventData: [String: Any] = [
                    "document_id": documentId,
                    "start_time": Int(event.startDate.timeIntervalSince1970),
                    "end_time": event.endDate != nil ? Int(event.endDate!.timeIntervalSince1970) : NSNull(),
                    "location": event.location ?? ""
                ]
                
                if !self.database.insertOrReplace("events", data: eventData) {
                    stats.errors += 1
                }
            } else {
                stats.errors += 1
            }
            
            stats.itemsProcessed += 1
        }
        
        print("Calendar ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.itemsUpdated) updated, \(stats.errors) errors")
        return stats
    }
    
    // MARK: - Reminders Ingestion
    func ingestReminders(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "reminders")
        
        // Request reminders access
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != .authorized {
            try await requestRemindersAccess()
        }
        
        let calendars = eventStore.calendars(for: .reminder)
        print("Reminders ingest: \(calendars.count) reminder lists found")
        
        // Get reminders from all lists
        for calendar in calendars {
            let predicate = eventStore.predicateForReminders(in: [calendar])
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    defer { continuation.resume() }
                    
                    guard let reminders = reminders else {
                        stats.errors += 1
                        return
                    }
                    
                    print("Processing \(reminders.count) reminders from \(calendar.title)")
                    
                    for reminder in reminders {
                        // Skip if we've already processed this reminder (incremental sync)
                        if !isFullSync {
                            if let existingReminder = self.database.query(
                                "SELECT id FROM documents WHERE app_source = ? AND source_id = ?",
                                parameters: ["Reminders", reminder.calendarItemIdentifier]
                            ).first {
                                // Check if reminder was modified since last sync
                                let lastModified = reminder.lastModifiedDate ?? reminder.creationDate ?? Date()
                                if let since = since, lastModified < since {
                                    continue // Skip unmodified reminder
                                }
                                stats.itemsUpdated += 1
                            } else {
                                stats.itemsCreated += 1
                            }
                        } else {
                            stats.itemsCreated += 1
                        }
                        
                        self.processReminder(reminder, calendar: calendar, stats: &stats)
                    }
                }
            }
        }
        
        print("Reminders ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.itemsUpdated) updated, \(stats.errors) errors")
        return stats
    }
    
    private func processReminder(_ reminder: EKReminder, calendar: EKCalendar, stats: inout IngestStats) {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        // Create rich searchable content
        var contentParts: [String] = []
        if let notes = reminder.notes, !notes.isEmpty {
            contentParts.append(notes)
        }
        contentParts.append("List: \(calendar.title)")
        if reminder.isCompleted {
            contentParts.append("Status: Completed")
            if let completionDate = reminder.completionDate {
                contentParts.append("Completed: \(completionDate)")
            }
        } else {
            contentParts.append("Status: Pending")
        }
        if let dueDate = reminder.dueDateComponents {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            if let date = Calendar.current.date(from: dueDate) {
                contentParts.append("Due: \(formatter.string(from: date))")
            }
        }
        
        let content = contentParts.joined(separator: "\n")
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "reminder",
            "title": reminder.title ?? "Untitled Reminder",
            "content": content,
            "app_source": "Reminders",
            "source_id": reminder.calendarItemIdentifier,
            "source_path": "x-apple-reminder://\(reminder.calendarItemIdentifier)",
            "hash": "\(reminder.title ?? "")\(content)\(reminder.isCompleted)".sha256(),
            "created_at": Int(reminder.creationDate?.timeIntervalSince1970 ?? Double(now)),
            "updated_at": Int(reminder.lastModifiedDate?.timeIntervalSince1970 ?? Double(now)),
            "last_seen_at": now,
            "deleted": false
        ]
        
        if database.insertOrReplace("documents", data: docData) {
            var dueDate: Int? = nil
            if let dueDateComponents = reminder.dueDateComponents,
               let date = Calendar.current.date(from: dueDateComponents) {
                dueDate = Int(date.timeIntervalSince1970)
            }
            
            var completedDate: Int? = nil
            if let completionDate = reminder.completionDate {
                completedDate = Int(completionDate.timeIntervalSince1970)
            }
            
            let reminderData: [String: Any] = [
                "document_id": documentId,
                "due_date": dueDate ?? NSNull(),
                "is_completed": reminder.isCompleted,
                "completed_date": completedDate ?? NSNull(),
                "priority": reminder.priority,
                "list_name": calendar.title,
                "notes": reminder.notes ?? NSNull()
            ]
            
            if !database.insertOrReplace("reminders", data: reminderData) {
                stats.errors += 1
            }
        } else {
            stats.errors += 1
        }
        
        stats.itemsProcessed += 1
    }
    
    private func requestRemindersAccess() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .reminder) { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if !granted {
                    continuation.resume(throwing: IngestError.permissionDenied("Reminders"))
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
    func ingestNotes(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        let notesIngester = NotesIngester(database: database)
        return try await notesIngester.ingestNotes(isFullSync: isFullSync, since: since)
    }
    
    func ingestFiles(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        let filesIngester = FilesIngester(database: database)
        return try await filesIngester.ingestFiles(isFullSync: isFullSync, since: since)
    }
    
    public func ingestMessages(isFullSync: Bool, since: Date? = nil, batchSize: Int = 500, maxMessages: Int? = nil) async throws -> IngestStats {
        let messagesIngester = MessagesIngester(database: database)
        
        // Use the proven legacy method with fixed 50K limit for full 30K message ingestion
        print("[IngestManager] Using legacy Messages ingestion with increased limit: batchSize=\(batchSize), maxMessages=\(maxMessages?.description ?? "unlimited")")
        
        return try await messagesIngester.ingestMessages(isFullSync: isFullSync, since: since)
    }
    
    public func ingestWhatsApp(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        let whatsappIngester = WhatsAppIngester(database: database)
        return try await whatsappIngester.ingestWhatsApp(isFullSync: isFullSync, since: since)
    }
    
    public func ingestContacts(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "contacts")
        print("DEBUG: Starting Contacts ingestion...")
        
        // Request contacts access
        let status = CNContactStore.authorizationStatus(for: .contacts)
        print("DEBUG: Contacts permission status: \(status.rawValue)")
        if status != .authorized {
            print("DEBUG: Requesting contacts access...")
            try await requestContactsAccess()
        }
        
        // Get all available keys for comprehensive contact data
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey,
            CNContactPostalAddressesKey, CNContactBirthdayKey,
            CNContactNoteKey, CNContactImageDataKey,
            CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey
        ] as [CNKeyDescriptor]
        
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        print("DEBUG: Starting contact enumeration with async wrapper...")
        
        // For full sync, clear existing Contacts data to prevent unique constraint failures
        if isFullSync {
            print("DEBUG: Clearing existing Contacts data for full sync...")
            // Delete contacts first (referencing documents), then documents
            let deletedContacts = database.execute("DELETE FROM contacts WHERE document_id IN (SELECT id FROM documents WHERE app_source = 'Contacts')")
            let deletedDocs = database.execute("DELETE FROM documents WHERE app_source = 'Contacts'")
            print("DEBUG: Cleared existing Contacts data - contacts: \(deletedContacts), docs: \(deletedDocs)")
        }
        
        // Wrap enumeration in proper async pattern to keep runloop alive
        return try await withCheckedThrowingContinuation { continuation in
            var enumCount = 0
            var hasResumed = false
            
            DispatchQueue.global().async {
                do {
                    try self.contactStore.enumerateContacts(with: request) { contact, stopPointer in
                        enumCount += 1
                        if enumCount <= 3 || enumCount % 100 == 0 {
                            print("DEBUG: Processing contact \(enumCount): \([contact.givenName, contact.familyName].compactMap{$0}.joined(separator: " "))")
                        }
                        
                        let documentId = UUID().uuidString
                        let now = Int(Date().timeIntervalSince1970)
                        
                        let fullName = [contact.givenName, contact.middleName, contact.familyName]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }
                            .joined(separator: " ")
                        
                        // Create searchable content from all contact fields
                        var contentParts: [String] = []
                        contentParts.append(contact.organizationName)
                        contentParts.append(contact.jobTitle)
                        if contact.isKeyAvailable(CNContactNoteKey) {
                            contentParts.append(contact.note)
                        }
                        contentParts.append(contact.emailAddresses.map { $0.value as String }.joined(separator: " "))
                        contentParts.append(contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: " "))
                        
                        let content = contentParts.compactMap { $0.isEmpty == false ? $0 : nil }.joined(separator: " ")
                        
                        let docData: [String: Any] = [
                            "id": documentId,
                            "type": "contact",
                            "title": fullName.isEmpty ? "Unnamed Contact" : fullName,
                            "content": content,
                            "app_source": "Contacts",
                            "source_id": contact.identifier,
                            "source_path": "addressbook://\(contact.identifier)",
                            "hash": "\(fullName)\(contact.organizationName)\(contact.jobTitle)\(now)".sha256(),
                            "created_at": now,
                            "updated_at": now,
                            "last_seen_at": now,
                            "deleted": false
                        ]
                        
                        if self.database.insertOrReplace("documents", data: docData) {
                            // Extract and standardize phone numbers
                            let rawPhones = contact.phoneNumbers.map { $0.value.stringValue }
                            let standardizedPhones = rawPhones.map { self.standardizePhoneNumber($0) }
                            
                            // Extract email addresses
                            let emailAddresses = contact.emailAddresses.map { $0.value as String }
                            
                            // Process birthday
                            var birthday: Int? = nil
                            if let bday = contact.birthday {
                                let calendar = Calendar.current
                                if let year = bday.year, year != NSDateComponentUndefined {
                                    let dateComponents = DateComponents(year: year, month: bday.month, day: bday.day)
                                    birthday = Int(calendar.date(from: dateComponents)?.timeIntervalSince1970 ?? 0)
                                }
                            }
                            
                            // Extract interests from social profiles and notes
                            var interests: [String] = []
                            if contact.isKeyAvailable(CNContactSocialProfilesKey) {
                                interests.append(contentsOf: contact.socialProfiles.map { $0.value.service })
                            }
                            
                            // Create unique contact_id for threading
                            let contactId = "contact_\(contact.identifier)"
                            
                            let contactData: [String: Any] = [
                                "document_id": documentId,
                                "contact_id": contactId,
                                "first_name": contact.givenName ?? "",
                                "last_name": contact.familyName ?? "",
                                "full_name": fullName,
                                "primary_phone": standardizedPhones.count > 0 ? standardizedPhones[0] : NSNull(),
                                "secondary_phone": standardizedPhones.count > 1 ? standardizedPhones[1] : NSNull(),
                                "tertiary_phone": standardizedPhones.count > 2 ? standardizedPhones[2] : NSNull(),
                                "primary_email": emailAddresses.count > 0 ? emailAddresses[0] : NSNull(),
                                "secondary_email": emailAddresses.count > 1 ? emailAddresses[1] : NSNull(),
                                "company": contact.organizationName ?? "",
                                "job_title": contact.jobTitle ?? "",
                                "birthday": birthday ?? NSNull(),
                                "interests": interests.isEmpty ? NSNull() : interests.joined(separator: ", "),
                                "notes": contact.isKeyAvailable(CNContactNoteKey) ? contact.note : "",
                                "date_last_interaction": now,
                                "image_path": contact.imageData != nil ? "contact_image_\(contact.identifier)" : NSNull()
                            ]
                            
                            if self.database.insertOrReplace("contacts", data: contactData) {
                                stats.itemsCreated += 1
                                
                                // Save contact image if available
                                if let imageData = contact.imageData {
                                    let imagePath = "\(NSHomeDirectory())/Library/Application Support/Assistant/contact_images/\(contact.identifier).jpg"
                                    let imageDir = URL(fileURLWithPath: imagePath).deletingLastPathComponent()
                                    try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                                    try? imageData.write(to: URL(fileURLWithPath: imagePath))
                                }
                            } else {
                                stats.errors += 1
                            }
                        } else {
                            stats.errors += 1
                        }
                        
                        stats.itemsProcessed += 1
                    }
                    
                    print("DEBUG: Enumeration complete. Enumerated \(enumCount) contacts")
                    print("Contacts ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
                    
                    // Resume continuation on main queue to avoid race conditions
                    DispatchQueue.main.async {
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(returning: stats)
                        }
                    }
                    
                } catch {
                    print("DEBUG: Contact enumeration failed: \(error)")
                    stats.errors += 1
                    DispatchQueue.main.async {
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    // Safely run an ingester function, catching errors to prevent one failure from stopping others
    private func safeIngest(_ ingester: () async throws -> IngestStats) async -> IngestStats {
        do {
            let result = try await ingester()
            print("DEBUG: Ingester completed with \(result.itemsCreated) items created, \(result.errors) errors")
            return result
        } catch {
            print("⚠️  Ingester failed: \(error)")
            var errorStats = IngestStats()
            errorStats.errors = 1
            return errorStats
        }
    }
    
    private func requestCalendarAccess() async throws {
        // Use modern API for macOS 14+ if available
        if #available(macOS 14.0, iOS 17.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                if !granted {
                    throw IngestError.permissionDenied("Calendar - Full access required to read events")
                }
            } catch {
                throw IngestError.permissionDenied("Calendar - \(error.localizedDescription)")
            }
        } else {
            // Fallback to legacy API
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if !granted {
                        continuation.resume(throwing: IngestError.permissionDenied("Calendar"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func requestContactsAccess() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if !granted {
                    continuation.resume(throwing: IngestError.permissionDenied("Contacts"))
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
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
    
    private func standardizePhoneNumber(_ phone: String) -> String {
        // Remove all non-digit characters except +
        let cleaned = phone.replacingOccurrences(of: "[^0-9+]", with: "", options: .regularExpression)
        
        // If already has country code, return as-is
        if cleaned.hasPrefix("+") {
            return cleaned
        }
        
        // Australian mobile numbers (start with 04, total 10 digits)
        if cleaned.hasPrefix("04") && cleaned.count == 10 {
            return "+61" + String(cleaned.dropFirst()) // Remove leading 0, add +61
        }
        
        // Singapore mobile numbers (8 digits, likely mobile if starts with 8 or 9)
        if cleaned.count == 8 && (cleaned.hasPrefix("8") || cleaned.hasPrefix("9")) {
            return "+65" + cleaned
        }
        
        // Australian landline (8 digits starting with non-mobile prefix)
        if cleaned.count == 8 && !cleaned.hasPrefix("04") {
            return "+61" + cleaned // Assume Sydney/Melbourne area
        }
        
        // If 11 digits starting with 61, assume already formatted Australian without +
        if cleaned.count == 11 && cleaned.hasPrefix("61") {
            return "+" + cleaned
        }
        
        // Default: return cleaned number (may need manual review)
        return cleaned.isEmpty ? phone : cleaned
    }
    
    private func getLastIngestTimes() -> [String: Date] {
        let sql = """
            SELECT type, MAX(completed_at) as last_run
            FROM jobs 
            WHERE status = 'completed' AND type LIKE 'ingest_%'
            GROUP BY type
        """
        
        let results = database.query(sql)
        var times: [String: Date] = [:]
        
        for row in results {
            if let type = row["type"] as? String,
               let timestamp = row["last_run"] as? Int64 {
                let source = type.replacingOccurrences(of: "ingest_", with: "")
                times[source] = Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
        }
        
        return times
    }
    
    private func logIngestResults(_ jobType: String, stats: IngestStats) {
        let logEntry: [String: Any] = [
            "job_type": jobType,
            "source": stats.source,
            "items_processed": stats.itemsProcessed,
            "items_created": stats.itemsCreated,  
            "items_updated": stats.itemsUpdated,
            "errors": stats.errors,
            "duration_ms": Int(stats.duration * 1000),
            "timestamp": Int(Date().timeIntervalSince1970)
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: logEntry),
           let jsonString = String(data: data, encoding: .utf8) {
            let logPath = "\(NSHomeDirectory())/Library/Logs/Assistant/ingest.ndjson"
            let output = jsonString + "\n"
            
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(output.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? output.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
        }
    }
}

// MARK: - Data Structures
public struct IngestStats {
    public var source: String = ""
    public var itemsProcessed: Int = 0
    public var itemsCreated: Int = 0
    public var itemsUpdated: Int = 0
    public var errors: Int = 0
    public var duration: TimeInterval = 0
    
    public init(source: String = "") {
        self.source = source
    }
    
    public mutating func combine(with other: IngestStats) {
        itemsProcessed += other.itemsProcessed
        itemsCreated += other.itemsCreated
        itemsUpdated += other.itemsUpdated
        errors += other.errors
    }
}

// IngestError and sha256() extensions are defined in Utilities.swift

#if canImport(CommonCrypto)
import CommonCrypto
#endif