import Foundation

/// FollowUpTracker: SLA monitoring and automated follow-up management
/// Tracks unanswered emails, meeting responses, and scheduling threads with intelligent escalation
public class FollowUpTracker {
    private let database: Database
    private let emailThreadingService: EmailThreadingService
    
    public init(database: Database, emailThreadingService: EmailThreadingService) {
        self.database = database
        self.emailThreadingService = emailThreadingService
    }
    
    // MARK: - Follow-up Management
    
    /// Check if an email thread needs follow-up
    public func needsFollowUp(_ thread: EmailThread) -> Bool {
        let analysis = emailThreadingService.analyzeThreadForFollowUp(thread)
        return analysis.urgencyScore > 0.5 || analysis.hasPendingRSVP || analysis.hasUnansweredQuestions
    }
    
    /// Get all threads that are overdue for follow-up
    public func getOverdueTasks(slaHours: Int = 48) async throws -> [FollowUpAction] {
        let cutoffTime = Date().addingTimeInterval(-Double(slaHours * 3600))
        
        // Get meeting-related threads that haven't been followed up
        let threads = try await emailThreadingService.identifyMeetingThreads(since: cutoffTime)
        
        var overdueActions: [FollowUpAction] = []
        
        for thread in threads {
            let analysis = emailThreadingService.analyzeThreadForFollowUp(thread)
            
            if analysis.urgencyScore > 0.4 || thread.lastActivity < cutoffTime {
                let action = FollowUpAction(
                    threadId: thread.id,
                    type: determineFollowUpType(thread, analysis: analysis),
                    priority: determinePriority(analysis.urgencyScore, daysSince: analysis.daysSinceLastActivity),
                    dueDate: calculateDueDate(thread.lastActivity, slaHours: slaHours),
                    lastAttempt: findLastFollowUpAttempt(threadId: thread.id),
                    attemptCount: getFollowUpAttemptCount(threadId: thread.id),
                    suggestedAction: analysis.suggestedAction,
                    participants: thread.participants,
                    subject: thread.subject
                )
                
                overdueActions.append(action)
            }
        }
        
        return overdueActions.sorted { action1, action2 in
            if action1.priority != action2.priority {
                return action1.priority.rawValue > action2.priority.rawValue
            }
            return action1.dueDate < action2.dueDate
        }
    }
    
    /// Schedule a follow-up for specific recipients
    public func scheduleFollowUp(
        recipients: [String],
        subject: String,
        slaHours: Int = 48,
        followUpType: FollowUpType = .general
    ) async throws {
        
        let followUpId = UUID().uuidString
        let dueDate = Date().addingTimeInterval(Double(slaHours * 3600))
        
        // Store follow-up in database
        let sql = """
            INSERT OR REPLACE INTO follow_ups (
                id, recipients, subject, type, due_date, created_at, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        
        let recipientsJson = try JSONSerialization.data(withJSONObject: recipients)
        let recipientsString = String(data: recipientsJson, encoding: .utf8) ?? "[]"
        
        _ = database.execute(sql)
        
        print("📅 Scheduled follow-up for '\(subject)' in \(slaHours) hours")
    }
    
    /// Mark follow-up as completed
    public func markFollowUpCompleted(followUpId: String) -> Bool {
        let sql = "UPDATE follow_ups SET status = 'completed', completed_at = \(Int(Date().timeIntervalSince1970)) WHERE id = '\(followUpId)'"
        database.execute(sql)
        return true
    }
    
    /// Get follow-up statistics and metrics
    public func getFollowUpMetrics(since: Date? = nil) -> FollowUpMetrics {
        let sinceClause = if let since = since {
            "AND created_at >= \(Int(since.timeIntervalSince1970))"
        } else {
            ""
        }
        
        // Total follow-ups
        let totalSql = "SELECT COUNT(*) as total FROM follow_ups WHERE 1=1 \(sinceClause)"
        let totalResult = database.query(totalSql)
        let total = totalResult.first?["total"] as? Int ?? 0
        
        // Completed follow-ups
        let completedSql = "SELECT COUNT(*) as completed FROM follow_ups WHERE status = 'completed' \(sinceClause)"
        let completedResult = database.query(completedSql)
        let completed = completedResult.first?["completed"] as? Int ?? 0
        
        // Overdue follow-ups
        let overdueSql = "SELECT COUNT(*) as overdue FROM follow_ups WHERE due_date < ? AND status != 'completed' \(sinceClause)"
        let overdueResult = database.query(overdueSql, parameters: [Int(Date().timeIntervalSince1970)])
        let overdue = overdueResult.first?["overdue"] as? Int ?? 0
        
        // Average response time
        let avgTimeSql = """
            SELECT AVG(completed_at - created_at) as avg_time 
            FROM follow_ups 
            WHERE status = 'completed' AND completed_at IS NOT NULL \(sinceClause)
        """
        let avgTimeResult = database.query(avgTimeSql)
        let avgResponseTime = avgTimeResult.first?["avg_time"] as? Double ?? 0
        
        return FollowUpMetrics(
            totalFollowUps: total,
            completedFollowUps: completed,
            overdueFollowUps: overdue,
            completionRate: total > 0 ? Double(completed) / Double(total) : 0,
            averageResponseTime: avgResponseTime / 3600, // Convert to hours
            slaBreachCount: overdue
        )
    }
    
    /// Generate follow-up reminder notifications
    public func generateReminders(hoursBeforeDue: Int = 4) async throws -> [FollowUpReminder] {
        let reminderTime = Date().addingTimeInterval(Double(hoursBeforeDue * 3600))
        
        let sql = """
            SELECT id, recipients, subject, type, due_date
            FROM follow_ups
            WHERE due_date <= ? AND due_date > ? AND status != 'completed'
            ORDER BY due_date ASC
        """
        
        let results = database.query(sql, parameters: [
            Int(reminderTime.timeIntervalSince1970),
            Int(Date().timeIntervalSince1970)
        ])
        
        return results.compactMap { row in
            guard let id = row["id"] as? String,
                  let recipientsString = row["recipients"] as? String,
                  let subject = row["subject"] as? String,
                  let typeString = row["type"] as? String,
                  let dueDateInt = row["due_date"] as? Int,
                  let type = FollowUpType(rawValue: typeString),
                  let recipientsData = recipientsString.data(using: .utf8),
                  let recipients = try? JSONSerialization.jsonObject(with: recipientsData) as? [String] else {
                return nil
            }
            
            return FollowUpReminder(
                id: id,
                recipients: recipients,
                subject: subject,
                type: type,
                dueDate: Date(timeIntervalSince1970: TimeInterval(dueDateInt)),
                hoursUntilDue: Int(Date(timeIntervalSince1970: TimeInterval(dueDateInt)).timeIntervalSince(Date()) / 3600)
            )
        }
    }
    
    /// Auto-escalate overdue follow-ups
    public func escalateOverdueFollowUps(escalationThresholdHours: Int = 72) async throws -> [EscalatedFollowUp] {
        let escalationTime = Date().addingTimeInterval(-Double(escalationThresholdHours * 3600))
        
        let sql = """
            SELECT id, recipients, subject, type, due_date, created_at
            FROM follow_ups
            WHERE due_date < ? AND status != 'completed' AND escalated != 1
            ORDER BY due_date ASC
        """
        
        let results = database.query(sql, parameters: [Int(escalationTime.timeIntervalSince1970)])
        
        var escalations: [EscalatedFollowUp] = []
        
        for row in results {
            guard let id = row["id"] as? String,
                  let recipientsString = row["recipients"] as? String,
                  let subject = row["subject"] as? String,
                  let typeString = row["type"] as? String,
                  let dueDateInt = row["due_date"] as? Int,
                  let createdAtInt = row["created_at"] as? Int,
                  let type = FollowUpType(rawValue: typeString),
                  let recipientsData = recipientsString.data(using: .utf8),
                  let recipients = try? JSONSerialization.jsonObject(with: recipientsData) as? [String] else {
                continue
            }
            
            // Mark as escalated
            let updateSql = "UPDATE follow_ups SET escalated = 1, escalated_at = \(Int(Date().timeIntervalSince1970)) WHERE id = '\(id)'"
            _ = database.execute(updateSql)
            
            let escalation = EscalatedFollowUp(
                followUpId: id,
                recipients: recipients,
                subject: subject,
                type: type,
                originalDueDate: Date(timeIntervalSince1970: TimeInterval(dueDateInt)),
                daysPastDue: Int(Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(dueDateInt))) / 86400),
                escalationReason: "No response after \(escalationThresholdHours) hours",
                suggestedEscalationActions: generateEscalationActions(type: type, daysPastDue: Int(Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(dueDateInt))) / 86400))
            )
            
            escalations.append(escalation)
        }
        
        return escalations
    }
    
    // MARK: - SLA Management
    
    /// Set custom SLA for specific participants or meeting types
    public func setCustomSLA(
        participantPattern: String,
        slaHours: Int,
        meetingType: String? = nil
    ) {
        let sql = """
            INSERT OR REPLACE INTO custom_slas (
                participant_pattern, sla_hours, meeting_type, created_at
            ) VALUES (?, ?, ?, ?)
        """
        
        _ = database.execute(sql)
    }
    
    /// Get applicable SLA for specific context
    public func getSLA(participants: [String], meetingType: String? = nil) -> Int {
        let sql = """
            SELECT sla_hours FROM custom_slas
            WHERE (? LIKE participant_pattern OR participant_pattern = 'default')
            AND (meeting_type = ? OR meeting_type = 'default')
            ORDER BY 
                CASE WHEN participant_pattern != 'default' THEN 1 ELSE 2 END,
                CASE WHEN meeting_type != 'default' THEN 1 ELSE 2 END
            LIMIT 1
        """
        
        for participant in participants {
            let results = database.query(sql, parameters: [participant, meetingType ?? "default"])
            if let slaHours = results.first?["sla_hours"] as? Int {
                return slaHours
            }
        }
        
        return 48 // Default 48-hour SLA
    }
    
    // MARK: - Private Helper Methods
    
    private func determineFollowUpType(_ thread: EmailThread, analysis: FollowUpAnalysis) -> FollowUpType {
        if analysis.hasPendingRSVP { return .rsvp }
        if analysis.hasSchedulingRequest { return .reschedule }
        if analysis.hasUnansweredQuestions { return .confirmation }
        return .general
    }
    
    private func determinePriority(_ urgencyScore: Double, daysSince: Int) -> FollowUpPriority {
        if urgencyScore > 0.8 || daysSince > 5 { return .high }
        if urgencyScore > 0.5 || daysSince > 2 { return .medium }
        return .low
    }
    
    private func calculateDueDate(_ lastActivity: Date, slaHours: Int) -> Date {
        return lastActivity.addingTimeInterval(Double(slaHours * 3600))
    }
    
    private func findLastFollowUpAttempt(threadId: String) -> Date? {
        let sql = "SELECT MAX(created_at) as last_attempt FROM follow_up_attempts WHERE thread_id = ?"
        let results = database.query(sql, parameters: [threadId])
        
        if let lastAttemptInt = results.first?["last_attempt"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(lastAttemptInt))
        }
        return nil
    }
    
    private func getFollowUpAttemptCount(threadId: String) -> Int {
        let sql = "SELECT COUNT(*) as count FROM follow_up_attempts WHERE thread_id = ?"
        let results = database.query(sql, parameters: [threadId])
        return results.first?["count"] as? Int ?? 0
    }
    
    private func generateEscalationActions(type: FollowUpType, daysPastDue: Int) -> [String] {
        var actions: [String] = []
        
        switch type {
        case .rsvp:
            actions.append("Send urgent RSVP reminder with deadline")
            actions.append("Call participant directly")
            if daysPastDue > 3 {
                actions.append("Proceed without confirmation and note absence")
            }
            
        case .confirmation:
            actions.append("Send high-priority confirmation request")
            actions.append("Schedule brief call to confirm details")
            
        case .reschedule:
            actions.append("Provide final alternative times")
            actions.append("Set deadline for response")
            if daysPastDue > 5 {
                actions.append("Cancel meeting and reschedule when convenient")
            }
            
        case .general:
            actions.append("Send polite but firm follow-up")
            actions.append("Consider alternative communication channels")
        }
        
        if daysPastDue > 7 {
            actions.append("Escalate to manager or assistant")
        }
        
        return actions
    }
}

// MARK: - Database Schema Setup

extension FollowUpTracker {
    
    /// Create database tables for follow-up tracking
    public func createFollowUpTables() {
        let followUpsSql = """
            CREATE TABLE IF NOT EXISTS follow_ups (
                id TEXT PRIMARY KEY,
                recipients TEXT NOT NULL,
                subject TEXT NOT NULL,
                type TEXT NOT NULL,
                due_date INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                completed_at INTEGER,
                escalated INTEGER DEFAULT 0,
                escalated_at INTEGER,
                status TEXT DEFAULT 'scheduled'
            )
        """
        
        let customSlasSql = """
            CREATE TABLE IF NOT EXISTS custom_slas (
                participant_pattern TEXT NOT NULL,
                sla_hours INTEGER NOT NULL,
                meeting_type TEXT DEFAULT 'default',
                created_at INTEGER NOT NULL,
                PRIMARY KEY (participant_pattern, meeting_type)
            )
        """
        
        let attemptsSql = """
            CREATE TABLE IF NOT EXISTS follow_up_attempts (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                follow_up_id TEXT,
                attempt_type TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                result TEXT
            )
        """
        
        _ = database.execute(followUpsSql)
        _ = database.execute(customSlasSql)
        _ = database.execute(attemptsSql)
        
        // Create indexes
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_follow_ups_due_date ON follow_ups(due_date)")
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_follow_ups_status ON follow_ups(status)")
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_attempts_thread ON follow_up_attempts(thread_id)")
    }
}

// MARK: - Data Structures

public struct FollowUpAction {
    public let threadId: String
    public let type: FollowUpType
    public let priority: FollowUpPriority
    public let dueDate: Date
    public let lastAttempt: Date?
    public let attemptCount: Int
    public let suggestedAction: String
    public let participants: [String]
    public let subject: String
    
    public var isOverdue: Bool {
        return Date() > dueDate
    }
    
    public var daysPastDue: Int {
        guard isOverdue else { return 0 }
        return Int(Date().timeIntervalSince(dueDate) / 86400)
    }
}

public enum FollowUpPriority: Int, CaseIterable {
    case low = 1
    case medium = 2
    case high = 3
    
    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct FollowUpMetrics {
    public let totalFollowUps: Int
    public let completedFollowUps: Int
    public let overdueFollowUps: Int
    public let completionRate: Double
    public let averageResponseTime: Double // in hours
    public let slaBreachCount: Int
    
    public var summary: String {
        return """
        Follow-up Metrics:
        - Total: \(totalFollowUps)
        - Completed: \(completedFollowUps) (\(String(format: "%.1f", completionRate * 100))%)
        - Overdue: \(overdueFollowUps)
        - Avg Response Time: \(String(format: "%.1f", averageResponseTime)) hours
        - SLA Breaches: \(slaBreachCount)
        """
    }
}

public struct FollowUpReminder {
    let id: String
    let recipients: [String]
    let subject: String
    let type: FollowUpType
    let dueDate: Date
    let hoursUntilDue: Int
    
    var urgencyLevel: String {
        if hoursUntilDue <= 1 { return "Critical" }
        if hoursUntilDue <= 4 { return "High" }
        if hoursUntilDue <= 8 { return "Medium" }
        return "Low"
    }
}

public struct EscalatedFollowUp {
    let followUpId: String
    let recipients: [String]
    let subject: String
    let type: FollowUpType
    let originalDueDate: Date
    let daysPastDue: Int
    let escalationReason: String
    let suggestedEscalationActions: [String]
}