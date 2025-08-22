import Foundation
import ArgumentParser
import DatabaseCore

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
            MeetingConciergeCommand.self
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
        abstract: "Ingest data from Apple apps"
    )
    
    @Option(help: "Data sources to ingest (comma-separated)")
    var sources: String = ""
    
    @Flag(name: .customLong("full-sync"), help: "Perform full sync (otherwise incremental)")
    var fullSync: Bool = false
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let sourceFilter = sources.isEmpty ? [] : sources.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let request = UserRequest(
            type: .dataIngest,
            parameters: [
                "sources": sourceFilter,
                "full_sync": fullSync
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