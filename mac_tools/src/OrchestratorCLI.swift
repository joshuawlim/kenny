import Foundation
import ArgumentParser
import DatabaseCore
import os.log

/// Command-line interface for testing the Orchestrator
@main
struct OrchestratorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchestrator_cli",
        abstract: "Test CLI for Kenny Orchestrator",
        version: "0.1.0",
        subcommands: [
            SearchCommand.self,
            IngestCommand.self,
            StatusCommand.self,
            PlanCommand.self,
            ExecuteCommand.self,
            MeetingConciergeCommand.self,
            ProactiveCommand.self
        ]
    )
}

// MARK: - Search Command

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search across all data sources"
    )
    
    @Argument(help: "Search query")
    var query: String
    
    @Option(help: "Maximum number of results")
    var limit: Int = 20
    
    @Option(help: "Filter by data types (comma-separated)")
    var types: String = ""
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let typeFilter = types.isEmpty ? [] : types.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let request = UserRequest(
            type: .search,
            parameters: [
                "query": query,
                "limit": limit,
                "types": typeFilter
            ]
        )
        
        do {
            let response = try await orchestrator.processRequest(request)
            printResponse(response)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Ingest Command

struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Ingest data from Apple apps using unified coordinator"
    )
    
    @Option(help: "Data sources to ingest (comma-separated)")
    var sources: String = ""
    
    @Flag(name: .customLong("full-sync"), help: "Perform full sync (otherwise incremental)")
    var fullSync: Bool = false
    
    @Flag(name: .customLong("enable-backup"), help: "Create database backup before ingestion")
    var enableBackup: Bool = true
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("🚀 Kenny Unified Ingestion System")
        print("Using centralized IngestCoordinator to prevent database locking...")
        
        do {
            // Initialize the unified coordinator
            let coordinator = IngestCoordinator(enableBackup: enableBackup)
            try coordinator.initialize(dbPath: dbPath)
            
            let summary: IngestSummary
            
            if sources.isEmpty {
                // Run comprehensive ingestion for all sources
                print("Running comprehensive ingestion for all sources...")
                summary = try await coordinator.runComprehensiveIngest()
            } else {
                // Run ingestion for specific sources only
                let sourceList = sources.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                print("Running ingestion for sources: \(sourceList.joined(separator: ", "))")
                summary = try await coordinator.runSourceIngestion(sourceList)
            }
            
            // Convert to compatible response format
            let response = convertSummaryToResponse(summary)
            printResponse(response)
            
        } catch {
            print("❌ Unified ingestion failed: \(error.localizedDescription)")
            
            // Create error response
            let errorResponse = UserResponse(
                success: false,
                type: .dataIngest,
                message: "Ingestion failed: \(error.localizedDescription)",
                data: [:],
                timestamp: Date()
            )
            printResponse(errorResponse)
            throw ExitCode.failure
        }
    }
    
    /// Convert IngestSummary to UserResponse for compatibility
    private func convertSummaryToResponse(_ summary: IngestSummary) -> UserResponse {
        let duration = summary.endTime?.timeIntervalSince(summary.startTime ?? Date()) ?? 0
        let successfulSources = summary.sourceResults.values.filter { $0.status == .success }.count
        let totalSources = summary.sourceResults.count
        
        var responseData: [String: Any] = [
            "duration_seconds": duration,
            "successful_sources": successfulSources,
            "total_sources": totalSources,
            "source_results": summary.sourceResults.mapValues { result in
                [
                    "status": result.status.rawValue,
                    "items_processed": result.stats.itemsProcessed,
                    "items_created": result.stats.itemsCreated,
                    "errors": result.errors.count
                ]
            }
        ]
        
        if let backupResult = summary.backupResult {
            responseData["backup_status"] = backupResult.status.rawValue
            responseData["backup_path"] = summary.backupPath
        }
        
        if let finalStats = summary.finalStats {
            responseData["final_document_count"] = finalStats["total_documents"]
        }
        
        let success = successfulSources == totalSources && summary.backupResult?.status != .failed
        let message = success ? 
            "Unified ingestion completed successfully: \(successfulSources)/\(totalSources) sources" :
            "Ingestion completed with \(totalSources - successfulSources) failures"
        
        return UserResponse(
            success: success,
            type: .dataIngest,
            message: message,
            data: responseData,
            timestamp: Date()
        )
    }
}

// MARK: - Status Command

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get system status"
    )
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let request = UserRequest(type: .status)
        
        do {
            let response = try await orchestrator.processRequest(request)
            printResponse(response)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Week 5: Planning Commands

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Create an execution plan for a complex query"
    )
    
    @Argument(help: "User query to create a plan for")
    var query: String
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("🧠 Creating execution plan for: '\(query)'")
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, verbose: true)
        
        do {
            let plan = try await assistantCore.createPlan(for: query)
            
            print("📋 Plan created successfully!")
            print("Plan ID: \(plan.id)")
            print("Steps: \(plan.steps.count)")
            print("Risks: \(plan.risks.count)")
            print("Content Origin: \(plan.contentOrigin.rawValue)")
            
            if let hash = plan.operationHash {
                print("Operation Hash: \(hash)")
            }
            
            // Output plan details as JSON
            let jsonData = try JSONSerialization.data(
                withJSONObject: plan.toDictionary(), 
                options: [.prettyPrinted]
            )
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            print(jsonString)
            
        } catch {
            print("❌ Plan creation failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct ExecuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "execute",
        abstract: "Execute a plan by ID with optional confirmation hash"
    )
    
    @Argument(help: "Plan ID to execute")
    var planId: String
    
    @Option(name: .customLong("hash"), help: "User confirmation hash")
    var confirmationHash: String?
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("⚡ Executing plan: \(planId)")
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, verbose: true)
        
        do {
            let response = try await assistantCore.confirmAndExecutePlan(planId, userHash: confirmationHash)
            
            if response.success {
                print("✅ Plan executed successfully!")
            } else {
                print("❌ Plan execution failed: \(response.error ?? "Unknown error")")
            }
            
            // Output execution result as JSON
            let jsonData = try JSONSerialization.data(
                withJSONObject: response.toDictionary(),
                options: [.prettyPrinted]
            )
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            print(jsonString)
            
        } catch {
            print("❌ Plan execution failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Helper Functions

private func printResponse(_ response: UserResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    let responseData: [String: Any] = [
        "success": response.success,
        "type": response.type.rawValue,
        "message": response.message,
        "data": response.data,
        "timestamp": ISO8601DateFormatter().string(from: response.timestamp)
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: responseData, options: [.prettyPrinted, .sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        print("Response: \(response)")
    }
    
    // No need to exit explicitly in async context
}

// MARK: - Meeting Concierge Command

struct MeetingConciergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting",
        abstract: "Meeting Concierge - Email and calendar mastery for management workflows",
        subcommands: [
            AnalyzeThreadsCommand.self,
            ProposeSlotsCommand.self,
            DraftEmailCommand.self,
            FollowUpCommand.self,
            CoordinateCommand.self
        ]
    )
}

// MARK: - Meeting Concierge Subcommands

struct AnalyzeThreadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze-threads",
        abstract: "Analyze email threads for meeting coordination opportunities"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(help: "Analyze threads since this many days ago")
    var sinceDays: Int = 7
    
    func run() async throws {
        let database = Database(path: dbPath)
        let concierge = MeetingConcierge(database: database)
        
        let sinceDate = Calendar.current.date(byAdding: .day, value: -sinceDays, to: Date())
        
        do {
            let threads = try await concierge.analyzeMeetingThreads(since: sinceDate)
            
            print("🧵 Found \(threads.count) meeting threads:")
            
            for thread in threads.prefix(10) {
                print("\n📧 Thread: \(thread.subject)")
                print("   Participants: \(thread.participants.joined(separator: ", "))")
                print("   RSVP Status: \(thread.rsvpStatus)")
                print("   Needs Follow-up: \(thread.needsFollowUp)")
                print("   Suggested Action: \(thread.suggestedAction)")
                print("   Last Activity: \(formatDate(thread.lastActivity))")
            }
            
            if threads.count > 10 {
                print("\n... and \(threads.count - 10) more threads")
            }
            
        } catch {
            print("❌ Error analyzing threads: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct ProposeSlotsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "propose-slots",
        abstract: "Propose meeting slots avoiding conflicts"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Argument(help: "Participants (comma-separated)")
    var participants: String
    
    @Option(help: "Duration in minutes")
    var duration: Int = 60
    
    @Option(help: "Maximum suggestions")
    var maxSuggestions: Int = 5
    
    func run() async throws {
        let database = Database(path: dbPath)
        let concierge = MeetingConcierge(database: database)
        
        let participantList = participants.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let durationSeconds = TimeInterval(duration * 60)
        
        do {
            let slots = try await concierge.proposeMeetingSlots(
                participants: participantList,
                duration: durationSeconds,
                preferredTimeRanges: nil,
                excludeWeekends: true
            )
            
            print("📅 Proposed meeting slots for \(participantList.joined(separator: ", ")):")
            
            for (index, slot) in slots.prefix(maxSuggestions).enumerated() {
                print("\n\(index + 1). \(formatDateTime(slot.startTime)) - \(formatTime(slot.endTime))")
                print("   Confidence: \(String(format: "%.1f", slot.confidence * 100))%")
                print("   Duration: \(duration) minutes")
            }
            
            if slots.isEmpty {
                print("❌ No available slots found for all participants")
            }
            
        } catch {
            print("❌ Error proposing slots: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct DraftEmailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft-email",
        abstract: "Draft meeting coordination email"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(help: "Email type (invitation, followUp, reschedule, confirmation, cancellation, reminder)")
    var type: String = "invitation"
    
    @Argument(help: "Recipients (comma-separated)")
    var recipients: String
    
    @Option(help: "Meeting title")
    var title: String?
    
    @Option(help: "Additional context")
    var context: String?
    
    func run() async throws {
        let database = Database(path: dbPath)
        let concierge = MeetingConcierge(database: database)
        
        let recipientList = recipients.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        guard let emailType = MeetingEmailType(rawValue: type) else {
            print("❌ Invalid email type. Use: invitation, followUp, reschedule, confirmation, cancellation, reminder")
            throw ExitCode.failure
        }
        
        let draft = concierge.draftMeetingEmail(
            type: emailType,
            participants: recipientList,
            proposedSlots: nil,
            meetingTitle: title,
            context: context
        )
        
        print("📧 Email Draft:")
        print("To: \(draft.to.joined(separator: ", "))")
        print("Subject: \(draft.subject)")
        print("Priority: \(draft.priority.rawValue)")
        print("Suggested Send Time: \(formatDateTime(draft.suggestedSendTime))")
        print("\nBody:")
        print("---")
        print(draft.body)
        print("---")
    }
}

struct FollowUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "follow-up",
        abstract: "Track and manage follow-ups with SLA monitoring"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(help: "SLA hours")
    var slaHours: Int = 48
    
    @Flag(help: "Show metrics only")
    var metricsOnly: Bool = false
    
    func run() async throws {
        let database = Database(path: dbPath)
        let concierge = MeetingConcierge(database: database)
        
        // Create follow-up tables if they don't exist
        let followUpTracker = concierge.followUpTracker
        followUpTracker.createFollowUpTables()
        
        if metricsOnly {
            let metrics = followUpTracker.getFollowUpMetrics()
            print("📊 Follow-up Metrics:")
            print(metrics.summary)
            return
        }
        
        do {
            let actions = try await concierge.getFollowUpActions(slaHours: slaHours)
            
            print("📋 Follow-up Actions (\(actions.count) items):")
            
            for action in actions.prefix(10) {
                let status = action.isOverdue ? "🔴 OVERDUE" : "🟡 Due Soon"
                print("\n\(status) \(action.subject)")
                print("   Priority: \(action.priority.displayName)")
                print("   Participants: \(action.participants.joined(separator: ", "))")
                print("   Due: \(formatDateTime(action.dueDate))")
                print("   Attempts: \(action.attemptCount)")
                print("   Suggested: \(action.suggestedAction)")
                
                if action.isOverdue {
                    print("   ⚠️ \(action.daysPastDue) days overdue")
                }
            }
            
            if actions.count > 10 {
                print("\n... and \(actions.count - 10) more actions")
            }
            
            if actions.isEmpty {
                print("✅ No follow-up actions needed")
            }
            
        } catch {
            print("❌ Error getting follow-ups: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct CoordinateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coordinate",
        abstract: "Comprehensive meeting coordination workflow"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Argument(help: "Meeting title")
    var title: String
    
    @Argument(help: "Participants (comma-separated)")
    var participants: String
    
    @Option(help: "Duration in minutes")
    var duration: Int = 60
    
    @Option(help: "Preferred start time (ISO format)")
    var startTime: String?
    
    @Option(help: "Meeting platform (zoom, microsoftTeams, facetime, googleMeet)")
    var platform: String = "zoom"
    
    @Option(help: "Additional context")
    var context: String?
    
    func run() async throws {
        let database = Database(path: dbPath)
        let concierge = MeetingConcierge(database: database)
        
        let participantList = participants.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let durationSeconds = TimeInterval(duration * 60)
        
        let proposedStartTime: Date
        if let startTimeString = startTime,
           let date = ISO8601DateFormatter().date(from: startTimeString) {
            proposedStartTime = date
        } else {
            // Default to tomorrow at 2 PM
            proposedStartTime = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        }
        
        let proposedEndTime = proposedStartTime.addingTimeInterval(durationSeconds)
        
        guard let linkType = MeetingLinkType(rawValue: platform) else {
            print("❌ Invalid platform. Use: zoom, microsoftTeams, facetime, googleMeet")
            throw ExitCode.failure
        }
        
        let request = MeetingCoordinationRequest(
            title: title,
            participants: participantList,
            duration: durationSeconds,
            proposedTimeRange: TimeRange(start: proposedStartTime, end: proposedEndTime),
            preferredTimeRanges: nil,
            excludeWeekends: true,
            preferredLinkType: linkType,
            context: context,
            followUpSLAHours: 48
        )
        
        do {
            let result = try await concierge.coordinateMeeting(request: request)
            
            print("🎯 Meeting Coordination Result:")
            print("Success: \(result.success)")
            print("Duration: \(String(format: "%.2f", result.duration))s")
            
            print("\n📅 Proposed Slots:")
            for (index, slot) in result.proposedSlots.prefix(3).enumerated() {
                print("\(index + 1). \(formatDateTime(slot.startTime)) - \(formatTime(slot.endTime)) (confidence: \(String(format: "%.1f", slot.confidence * 100))%)")
            }
            
            if !result.conflicts.isEmpty {
                print("\n⚠️ Conflicts Found:")
                for conflict in result.conflicts.prefix(3) {
                    print("- \(conflict.participant): \(conflict.conflictingEvent.title) (\(conflict.severity))")
                }
            }
            
            print("\n📧 Email Draft:")
            print("To: \(result.emailDraft.to.joined(separator: ", "))")
            print("Subject: \(result.emailDraft.subject)")
            print("\nBody Preview:")
            let bodyLines = result.emailDraft.body.components(separatedBy: "\n")
            print(bodyLines.prefix(5).joined(separator: "\n"))
            if bodyLines.count > 5 {
                print("... (\(bodyLines.count - 5) more lines)")
            }
            
            if let meetingLink = result.meetingLink {
                print("\n🔗 Meeting Link:")
                print("Platform: \(meetingLink.platform.displayName)")
                print("URL: \(meetingLink.url)")
                if let meetingId = meetingLink.meetingId {
                    print("Meeting ID: \(meetingId)")
                }
            }
            
            if result.followUpScheduled {
                print("\n📅 Follow-up scheduled for 48 hours")
            }
            
        } catch {
            print("❌ Error coordinating meeting: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Date Formatting Helpers

private func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter.string(from: date)
}

// MARK: - Proactive Assistant Types

public struct ProactiveSuggestion: Codable {
    public let id: String
    public let type: SuggestionType
    public let title: String
    public let description: String
    public let confidence: Double
    public let actionable: Bool
    public let suggestedActions: [String]
    public let createdAt: Date
    
    public var priorityScore: Double {
        return confidence * (actionable ? 1.0 : 0.5)
    }
}

public enum SuggestionType: String, Codable, CaseIterable {
    case meetingOptimization = "meeting_optimization"
    case timezoneOptimization = "timezone_optimization"
    case followUpReminder = "followup_reminder"
    case calendarOptimization = "calendar_optimization"
    case taskReminder = "task_reminder"
    case emailOrganization = "email_organization"
    case contactManagement = "contact_management"
    case workflowOptimization = "workflow_optimization"
    
    public var displayName: String {
        switch self {
        case .meetingOptimization:
            return "Meeting Optimization"
        case .timezoneOptimization:
            return "Timezone Coordination"
        case .followUpReminder:
            return "Follow-up Reminder"
        case .calendarOptimization:
            return "Calendar Optimization"
        case .taskReminder:
            return "Task Reminder"
        case .emailOrganization:
            return "Email Organization"
        case .contactManagement:
            return "Contact Management"
        case .workflowOptimization:
            return "Workflow Optimization"
        }
    }
}

// Simple ProactiveAssistant for CLI use
class SimpleProactiveAssistant {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func analyzeMeetingPatterns() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            let query = """
            SELECT content, source_path, created_at 
            FROM documents 
            WHERE app_source = 'Mail' 
            AND (content LIKE '%meeting%' OR content LIKE '%schedule%' OR content LIKE '%available%')
            AND created_at > (strftime('%s', 'now') - 604800)
            ORDER BY created_at DESC
            LIMIT 50
            """
            
            let results = database.query(query)
            
            if results.count > 5 {
                let suggestion = ProactiveSuggestion(
                    id: UUID().uuidString,
                    type: .meetingOptimization,
                    title: "Meeting Coordination Pattern Detected",
                    description: "You've had \(results.count) meeting-related emails this week. Consider using Kenny's Meeting Concierge for automated scheduling.",
                    confidence: 0.8,
                    actionable: true,
                    suggestedActions: [
                        "Run: orchestrator_cli meeting propose-slots",
                        "Set up recurring meeting blocks",
                        "Enable proactive conflict detection"
                    ],
                    createdAt: Date()
                )
                suggestions.append(suggestion)
            }
            
        } catch {
            print("Error analyzing meeting patterns: \(error.localizedDescription)")
        }
        
        return suggestions
    }
    
    func analyzeEmailPatterns() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            let query = """
            SELECT content, source_path, created_at,
                   ((strftime('%s', 'now') - created_at) / 86400.0) as days_ago
            FROM documents 
            WHERE app_source = 'Mail' 
            AND (content LIKE '%?%' OR content LIKE '%please%' OR content LIKE '%need%')
            AND created_at > (strftime('%s', 'now') - 1209600)
            AND created_at < (strftime('%s', 'now') - 172800)
            ORDER BY created_at DESC
            LIMIT 20
            """
            
            let results = database.query(query)
            
            let needsFollowup = results.filter { result in
                let daysAgo = result["days_ago"] as? Double ?? 0
                return daysAgo > 3
            }
            
            if needsFollowup.count > 0 {
                let suggestion = ProactiveSuggestion(
                    id: UUID().uuidString,
                    type: .followUpReminder,
                    title: "Emails May Need Follow-up",
                    description: "Found \(needsFollowup.count) emails from the past 2 weeks that might need responses.",
                    confidence: 0.6,
                    actionable: true,
                    suggestedActions: [
                        "Review recent email threads",
                        "Draft follow-up responses",
                        "Set up email response tracking"
                    ],
                    createdAt: Date()
                )
                suggestions.append(suggestion)
            }
            
        } catch {
            print("Error analyzing email patterns: \(error.localizedDescription)")
        }
        
        return suggestions
    }
    
    func analyzeCalendarConflicts() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            let query = """
            SELECT title, content, source_path, created_at
            FROM documents 
            WHERE app_source = 'Calendar'
            AND created_at > strftime('%s', 'now')
            AND created_at < (strftime('%s', 'now') + 604800)
            ORDER BY created_at ASC
            """
            
            let results = database.query(query)
            
            var eventsByDate: [String: Int] = [:]
            
            for result in results {
                if let createdAtString = result["created_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: createdAtString) {
                        let dayFormatter = DateFormatter()
                        dayFormatter.dateFormat = "yyyy-MM-dd"
                        let dayKey = dayFormatter.string(from: date)
                        eventsByDate[dayKey] = (eventsByDate[dayKey] ?? 0) + 1
                    }
                }
            }
            
            for (day, count) in eventsByDate {
                if count >= 4 {
                    let suggestion = ProactiveSuggestion(
                        id: UUID().uuidString,
                        type: .calendarOptimization,
                        title: "Busy Day Detected: \(day)",
                        description: "You have \(count) events scheduled. Consider review for potential conflicts or breaks.",
                        confidence: 0.75,
                        actionable: true,
                        suggestedActions: [
                            "Review schedule for \(day)",
                            "Add buffer time between meetings",
                            "Consider rescheduling non-critical events"
                        ],
                        createdAt: Date()
                    )
                    suggestions.append(suggestion)
                }
            }
            
        } catch {
            print("Error analyzing calendar conflicts: \(error.localizedDescription)")
        }
        
        return suggestions
    }
    
    func analyzeTaskReminders() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            let query = """
            SELECT content, source_path, created_at, app_source
            FROM documents 
            WHERE (content LIKE '%deadline%' OR content LIKE '%due%' OR content LIKE '%by %day%' 
                   OR content LIKE '%next week%' OR content LIKE '%tomorrow%')
            AND created_at > (strftime('%s', 'now') - 604800)
            ORDER BY created_at DESC
            LIMIT 15
            """
            
            let results = database.query(query)
            
            if results.count > 0 {
                let suggestion = ProactiveSuggestion(
                    id: UUID().uuidString,
                    type: .taskReminder,
                    title: "Potential Deadlines Mentioned",
                    description: "Found \(results.count) mentions of deadlines or due dates in recent messages.",
                    confidence: 0.65,
                    actionable: true,
                    suggestedActions: [
                        "Review mentioned deadlines",
                        "Add important dates to calendar",
                        "Set up deadline tracking system"
                    ],
                    createdAt: Date()
                )
                suggestions.append(suggestion)
            }
            
        } catch {
            print("Error analyzing task reminders: \(error.localizedDescription)")
        }
        
        return suggestions
    }
    
    func getCurrentSuggestions() async -> [ProactiveSuggestion] {
        async let meetingSuggestions = analyzeMeetingPatterns()
        async let emailSuggestions = analyzeEmailPatterns()
        async let calendarSuggestions = analyzeCalendarConflicts()
        async let taskSuggestions = analyzeTaskReminders()
        
        let allSuggestions = await meetingSuggestions + emailSuggestions + calendarSuggestions + taskSuggestions
        
        return allSuggestions.sorted { first, second in
            if first.confidence != second.confidence {
                return first.confidence > second.confidence
            }
            return first.createdAt > second.createdAt
        }
    }
    
    func getSuggestions(ofType type: SuggestionType) async -> [ProactiveSuggestion] {
        let allSuggestions = await getCurrentSuggestions()
        return allSuggestions.filter { $0.type == type }
    }
    
    func getTopSuggestions(limit: Int = 5) async -> [ProactiveSuggestion] {
        let allSuggestions = await getCurrentSuggestions()
        return Array(allSuggestions.prefix(limit))
    }
}

// MARK: - Proactive Assistant Command

struct ProactiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proactive",
        abstract: "Proactive AI assistant suggestions and analysis",
        subcommands: [
            SuggestionsCommand.self,
            AnalyzeCommand.self,
            TriggerCommand.self
        ]
    )
}

struct SuggestionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggestions",
        abstract: "Get proactive suggestions based on patterns"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(help: "Suggestion type filter")
    var type: String?
    
    @Option(help: "Maximum number of suggestions")
    var limit: Int = 10
    
    @Option(help: "Minimum confidence threshold (0.0-1.0)")
    var minConfidence: Double = 0.5
    
    func run() async throws {
        let database = Database(path: dbPath)
        let assistant = SimpleProactiveAssistant(database: database)
        
        let suggestions: [ProactiveSuggestion]
        
        if let typeString = type,
           let suggestionType = SuggestionType(rawValue: typeString) {
            suggestions = await assistant.getSuggestions(ofType: suggestionType)
        } else {
            suggestions = await assistant.getCurrentSuggestions()
        }
        
        let filteredSuggestions = suggestions
            .filter { $0.confidence >= minConfidence }
            .prefix(limit)
        
        if filteredSuggestions.isEmpty {
            print("✨ No proactive suggestions available (confidence threshold: \(Int(minConfidence * 100))%)")
            return
        }
        
        print("🤖 Kenny's Proactive Suggestions:")
        print("=================================")
        
        for (index, suggestion) in filteredSuggestions.enumerated() {
            let confidencePercent = Int(suggestion.confidence * 100)
            let priorityIcon = suggestion.actionable ? "🎯" : "💡"
            
            print("\n\(index + 1). \(priorityIcon) \(suggestion.title)")
            print("   Type: \(suggestion.type.displayName)")
            print("   Confidence: \(confidencePercent)%")
            print("   \(suggestion.description)")
            
            if suggestion.actionable && !suggestion.suggestedActions.isEmpty {
                print("   Suggested Actions:")
                for action in suggestion.suggestedActions {
                    print("   • \(action)")
                }
            }
            
            print("   Created: \(formatDateTime(suggestion.createdAt))")
        }
        
        print("\n💡 Use 'orchestrator_cli proactive analyze' to trigger fresh analysis")
    }
}

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Trigger comprehensive pattern analysis"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Flag(help: "Show detailed analysis progress")
    var verbose: Bool = false
    
    func run() async throws {
        let database = Database(path: dbPath)
        let assistant = SimpleProactiveAssistant(database: database)
        
        print("🔍 Analyzing patterns for proactive suggestions...")
        
        if verbose {
            print("• Analyzing meeting coordination patterns")
            print("• Checking email response patterns")
            print("• Detecting calendar conflicts")
            print("• Generating follow-up reminders")
        }
        
        // Get fresh suggestions
        
        // Wait a moment for analysis to begin
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let suggestions = await assistant.getTopSuggestions(limit: 5)
        
        print("\n✅ Analysis complete!")
        print("Found \(suggestions.count) actionable suggestions")
        
        if !suggestions.isEmpty {
            print("\nTop Suggestions:")
            for (index, suggestion) in suggestions.enumerated() {
                let confidencePercent = Int(suggestion.confidence * 100)
                print("\(index + 1). \(suggestion.title) (\(confidencePercent)% confidence)")
            }
            
            print("\n💡 Run 'orchestrator_cli proactive suggestions' to see details")
        }
    }
}

struct TriggerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trigger",
        abstract: "Manually trigger specific analysis types"
    )
    
    @Option(help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(help: "Analysis type (meetings, emails, calendar, followups, all)")
    var analysisType: String = "all"
    
    func run() async throws {
        let database = Database(path: dbPath)
        let assistant = SimpleProactiveAssistant(database: database)
        
        switch analysisType.lowercased() {
        case "meetings":
            print("🤝 Analyzing meeting patterns...")
            let suggestions = await assistant.getSuggestions(ofType: .meetingOptimization)
            print("Found \(suggestions.count) meeting-related suggestions")
            
        case "emails":
            print("📧 Analyzing email patterns...")
            let suggestions = await assistant.getSuggestions(ofType: .followUpReminder)
            print("Found \(suggestions.count) email-related suggestions")
            
        case "calendar":
            print("📅 Analyzing calendar conflicts...")
            let suggestions = await assistant.getSuggestions(ofType: .calendarOptimization)
            print("Found \(suggestions.count) calendar-related suggestions")
            
        case "followups":
            print("📋 Checking follow-up reminders...")
            let suggestions = await assistant.getSuggestions(ofType: .taskReminder)
            print("Found \(suggestions.count) follow-up reminders")
            
        case "all":
            print("🔄 Running comprehensive analysis...")
            // Since SimpleProactiveAssistant doesn't have a trigger method, just get suggestions
            
            try await Task.sleep(nanoseconds: 3_000_000_000)
            
            let allSuggestions = await assistant.getCurrentSuggestions()
            print("Analysis complete! Found \(allSuggestions.count) total suggestions")
            
            // Show breakdown by type
            let typeBreakdown = Dictionary(grouping: allSuggestions) { $0.type }
            for (type, suggestions) in typeBreakdown {
                print("• \(type.displayName): \(suggestions.count)")
            }
            
        default:
            print("❌ Invalid analysis type. Use: meetings, emails, calendar, followups, all")
            throw ExitCode.failure
        }
    }
}