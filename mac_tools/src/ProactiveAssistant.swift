import Foundation
import os.log

/// Week 9: Proactive Assistant - Analyzes patterns and provides suggestions
public class ProactiveAssistant {
    public static let shared = ProactiveAssistant()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "proactive_assistant")
    private let database: Database
    private let backgroundProcessor = BackgroundProcessor.shared
    private var analysisTimer: Timer?
    
    private init() {
        self.database = Database.shared
        startProactiveAnalysis()
    }
    
    // MARK: - Proactive Analysis
    
    /// Start background analysis for proactive suggestions
    private func startProactiveAnalysis() {
        // Run analysis every hour
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.triggerProactiveAnalysis()
        }
        
        // Run initial analysis after startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.triggerProactiveAnalysis()
        }
    }
    
    /// Trigger comprehensive proactive analysis
    public func triggerProactiveAnalysis() {
        os_log("Starting proactive analysis", log: logger, type: .info)
        
        // Submit analysis jobs to background processor
        _ = backgroundProcessor.submitTask(name: "Meeting Pattern Analysis", priority: .normal) {
            return await self.analyzeMeetingPatterns()
        }
        
        _ = backgroundProcessor.submitTask(name: "Email Response Analysis", priority: .normal) {
            return await self.analyzeEmailResponsePatterns()
        }
        
        _ = backgroundProcessor.submitTask(name: "Calendar Conflict Detection", priority: .high) {
            return await self.detectUpcomingConflicts()
        }
        
        _ = backgroundProcessor.submitTask(name: "Follow-up Reminders", priority: .normal) {
            return await self.generateFollowupReminders()
        }
    }
    
    // MARK: - Meeting Pattern Analysis
    
    private func analyzeMeetingPatterns() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            // Analyze recent meeting coordination emails
            let query = """
            SELECT content, source_path, created_at 
            FROM documents 
            WHERE app_source = 'Mail' 
            AND (content LIKE '%meeting%' OR content LIKE '%schedule%' OR content LIKE '%available%')
            AND created_at > datetime('now', '-7 days')
            ORDER BY created_at DESC
            LIMIT 50
            """
            
            let results = try database.executeQuery(query)
            
            // Pattern 1: Frequent meeting coordination suggests need for better scheduling
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
            
            // Pattern 2: Detect time zone confusion in scheduling
            let timezoneKeywords = ["PST", "EST", "UTC", "timezone", "time zone"]
            let timezoneEmails = results.filter { result in
                let content = result["content"] as? String ?? ""
                return timezoneKeywords.contains { content.lowercased().contains($0.lowercased()) }
            }
            
            if timezoneEmails.count > 2 {
                let suggestion = ProactiveSuggestion(
                    id: UUID().uuidString,
                    type: .timezoneOptimization,
                    title: "Time Zone Coordination Detected",
                    description: "Multiple emails mention timezones. Consider setting default meeting times that work across zones.",
                    confidence: 0.7,
                    actionable: true,
                    suggestedActions: [
                        "Create timezone-aware meeting templates",
                        "Set preferred meeting hours by timezone",
                        "Use world clock in meeting proposals"
                    ],
                    createdAt: Date()
                )
                suggestions.append(suggestion)
            }
            
        } catch {
            os_log("Error analyzing meeting patterns: %{public}s", log: logger, type: .error, error.localizedDescription)
        }
        
        return suggestions
    }
    
    // MARK: - Email Response Analysis
    
    private func analyzeEmailResponsePatterns() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            // Find emails that might need follow-up
            let query = """
            SELECT content, source_path, created_at,
                   (julianday('now') - julianday(created_at)) as days_ago
            FROM documents 
            WHERE app_source = 'Mail' 
            AND (content LIKE '%?%' OR content LIKE '%please%' OR content LIKE '%need%')
            AND created_at > datetime('now', '-14 days')
            AND created_at < datetime('now', '-2 days')
            ORDER BY created_at DESC
            LIMIT 20
            """
            
            let results = try database.executeQuery(query)
            
            // Find emails older than 3 days that seem to require response
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
            os_log("Error analyzing email patterns: %{public}s", log: logger, type: .error, error.localizedDescription)
        }
        
        return suggestions
    }
    
    // MARK: - Calendar Conflict Detection
    
    private func detectUpcomingConflicts() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            // Look for potential calendar conflicts in the next 7 days
            let query = """
            SELECT title, content, source_path, created_at
            FROM documents 
            WHERE app_source = 'Calendar'
            AND created_at > datetime('now')
            AND created_at < datetime('now', '+7 days')
            ORDER BY created_at ASC
            """
            
            let results = try database.executeQuery(query)
            
            // Group events by date to detect overlaps
            var eventsByDate: [String: [(String, Date)]] = [:]
            
            for result in results {
                let title = result["title"] as? String ?? ""
                if let createdAtString = result["created_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: createdAtString) {
                        let dayFormatter = DateFormatter()
                        dayFormatter.dateFormat = "yyyy-MM-dd"
                        let dayKey = dayFormatter.string(from: date)
                        
                        if eventsByDate[dayKey] == nil {
                            eventsByDate[dayKey] = []
                        }
                        eventsByDate[dayKey]?.append((title, date))
                    }
                }
            }
            
            // Look for days with many events (potential conflicts)
            for (day, events) in eventsByDate {
                if events.count >= 4 {
                    let suggestion = ProactiveSuggestion(
                        id: UUID().uuidString,
                        type: .calendarOptimization,
                        title: "Busy Day Detected: \(day)",
                        description: "You have \(events.count) events scheduled. Consider review for potential conflicts or breaks.",
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
            os_log("Error detecting calendar conflicts: %{public}s", log: logger, type: .error, error.localizedDescription)
        }
        
        return suggestions
    }
    
    // MARK: - Follow-up Reminders
    
    private func generateFollowupReminders() async -> [ProactiveSuggestion] {
        var suggestions: [ProactiveSuggestion] = []
        
        do {
            // Find mentions of deadlines or commitments in recent messages
            let query = """
            SELECT content, source_path, created_at, app_source
            FROM documents 
            WHERE (content LIKE '%deadline%' OR content LIKE '%due%' OR content LIKE '%by %day%' 
                   OR content LIKE '%next week%' OR content LIKE '%tomorrow%')
            AND created_at > datetime('now', '-7 days')
            ORDER BY created_at DESC
            LIMIT 15
            """
            
            let results = try database.executeQuery(query)
            
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
            os_log("Error generating follow-up reminders: %{public}s", log: logger, type: .error, error.localizedDescription)
        }
        
        return suggestions
    }
    
    // MARK: - Public API
    
    /// Get current proactive suggestions
    public func getCurrentSuggestions() async -> [ProactiveSuggestion] {
        // For now, trigger fresh analysis
        // In production, this would return cached suggestions
        async let meetingSuggestions = analyzeMeetingPatterns()
        async let emailSuggestions = analyzeEmailResponsePatterns()
        async let calendarSuggestions = detectUpcomingConflicts()
        async let followupSuggestions = generateFollowupReminders()
        
        let allSuggestions = await meetingSuggestions + emailSuggestions + calendarSuggestions + followupSuggestions
        
        // Sort by confidence and recency
        return allSuggestions.sorted { first, second in
            if first.confidence != second.confidence {
                return first.confidence > second.confidence
            }
            return first.createdAt > second.createdAt
        }
    }
    
    /// Get suggestions by type
    public func getSuggestions(ofType type: SuggestionType) async -> [ProactiveSuggestion] {
        let allSuggestions = await getCurrentSuggestions()
        return allSuggestions.filter { $0.type == type }
    }
    
    /// Get top priority suggestions
    public func getTopSuggestions(limit: Int = 5) async -> [ProactiveSuggestion] {
        let allSuggestions = await getCurrentSuggestions()
        return Array(allSuggestions.prefix(limit))
    }
    
    deinit {
        analysisTimer?.invalidate()
    }
}

// MARK: - Supporting Types

public struct ProactiveSuggestion: Codable {
    public let id: String
    public let type: SuggestionType
    public let title: String
    public let description: String
    public let confidence: Double // 0.0 to 1.0
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

public enum ValidationError: Error, LocalizedError {
    case invalidInput(String)
    case missingRequiredField(String)
    case invalidFormat(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidFormat(let message):
            return "Invalid format: \(message)"
        }
    }
}