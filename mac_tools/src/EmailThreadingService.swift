import Foundation

/// EmailThreadingService: Advanced email conversation analysis and threading
/// Identifies conversation threads, meeting-related discussions, and follow-up opportunities
public class EmailThreadingService {
    private let database: Database
    
    public init(database: Database) {
        self.database = database
    }
    
    // MARK: - Thread Identification
    
    /// Identify email threads that contain meeting coordination
    public func identifyMeetingThreads(since: Date? = nil) async throws -> [EmailThread] {
        let sinceClause = if let since = since {
            "AND e.date_received >= \(Int(since.timeIntervalSince1970))"
        } else {
            ""
        }
        
        // Query emails that likely contain meeting coordination
        let sql = """
            SELECT 
                e.document_id, e.message_id, e.from_address, e.from_name,
                e.to_addresses, e.date_received, d.title, d.content
            FROM emails e 
            JOIN documents d ON e.document_id = d.id
            WHERE (
                d.title LIKE '%meeting%' OR d.title LIKE '%invite%' OR 
                d.title LIKE '%schedule%' OR d.title LIKE '%calendar%' OR
                d.content LIKE '%RSVP%' OR d.content LIKE '%accept%' OR 
                d.content LIKE '%decline%' OR d.content LIKE '%reschedule%' OR
                d.content LIKE '%available%' OR d.content LIKE '%time slot%' OR
                d.content LIKE '%zoom%' OR d.content LIKE '%teams%' OR
                d.content LIKE '%facetime%' OR d.content LIKE '%call%'
            )
            \(sinceClause)
            ORDER BY e.date_received DESC
        """
        
        let results = database.query(sql)
        return try await processEmailsIntoThreads(results)
    }
    
    /// Group emails into conversation threads based on subject and participants
    private func processEmailsIntoThreads(_ emailResults: [[String: Any]]) async throws -> [EmailThread] {
        var threads: [String: EmailThread] = [:]
        
        for row in emailResults {
            guard let messageId = row["message_id"] as? String,
                  let fromAddress = row["from_address"] as? String,
                  let subject = row["title"] as? String,
                  let content = row["content"] as? String,
                  let dateReceived = row["date_received"] as? Int else {
                continue
            }
            
            let email = ThreadEmail(
                messageId: messageId,
                fromAddress: fromAddress,
                fromName: row["from_name"] as? String,
                toAddresses: parseEmailList(row["to_addresses"] as? String),
                subject: subject,
                content: content,
                dateReceived: Date(timeIntervalSince1970: TimeInterval(dateReceived))
            )
            
            // Generate thread key based on normalized subject and participants
            let threadKey = generateThreadKey(subject: subject, participants: email.allParticipants)
            
            if var existingThread = threads[threadKey] {
                existingThread.emails.append(email)
                existingThread.lastActivity = max(existingThread.lastActivity, email.dateReceived)
                threads[threadKey] = existingThread
            } else {
                threads[threadKey] = EmailThread(
                    id: threadKey,
                    subject: normalizeSubject(subject),
                    emails: [email],
                    participants: email.allParticipants,
                    firstActivity: email.dateReceived,
                    lastActivity: email.dateReceived,
                    containsMeetingRequest: containsMeetingLanguage(content)
                )
            }
        }
        
        // Sort threads by last activity
        return Array(threads.values).sorted { $0.lastActivity > $1.lastActivity }
    }
    
    // MARK: - Thread Analysis
    
    /// Analyze thread for follow-up opportunities
    public func analyzeThreadForFollowUp(_ thread: EmailThread) -> FollowUpAnalysis {
        let lastEmail = thread.emails.max { $0.dateReceived < $1.dateReceived }
        let daysSinceLastActivity = Date().timeIntervalSince(thread.lastActivity) / 86400
        
        // Check for unanswered questions
        let hasUnansweredQuestions = thread.emails.contains { email in
            containsQuestions(email.content) && !hasFollowUpResponse(thread, after: email)
        }
        
        // Check for pending RSVP
        let hasPendingRSVP = thread.emails.contains { email in
            containsRSVPRequest(email.content)
        } && !thread.emails.contains { email in
            containsRSVPResponse(email.content)
        }
        
        // Check for scheduling requests
        let hasSchedulingRequest = thread.emails.contains { email in
            containsSchedulingLanguage(email.content)
        }
        
        let urgencyScore = calculateUrgencyScore(
            daysSince: daysSinceLastActivity,
            hasQuestions: hasUnansweredQuestions,
            hasPendingRSVP: hasPendingRSVP,
            hasScheduling: hasSchedulingRequest
        )
        
        return FollowUpAnalysis(
            threadId: thread.id,
            daysSinceLastActivity: Int(daysSinceLastActivity),
            hasUnansweredQuestions: hasUnansweredQuestions,
            hasPendingRSVP: hasPendingRSVP,
            hasSchedulingRequest: hasSchedulingRequest,
            urgencyScore: urgencyScore,
            suggestedAction: determineSuggestedFollowUpAction(
                urgency: urgencyScore,
                hasQuestions: hasUnansweredQuestions,
                hasPendingRSVP: hasPendingRSVP,
                hasScheduling: hasSchedulingRequest
            )
        )
    }
    
    /// Update thread_id in database for emails
    public func updateEmailThreadIds() async throws -> Int {
        print("🧵 Updating email thread IDs...")
        
        // Get all emails for threading analysis
        let sql = """
            SELECT document_id, message_id, from_address, to_addresses, date_received, d.title
            FROM emails e
            JOIN documents d ON e.document_id = d.id
            ORDER BY date_received DESC
        """
        
        let results = database.query(sql)
        var updatedCount = 0
        
        // Group emails by thread and update database
        let threadGroups = groupEmailsByThread(results)
        
        for (threadId, emailIds) in threadGroups {
            let updateSql = "UPDATE emails SET thread_id = '\(threadId)' WHERE document_id IN ('\(emailIds.joined(separator: "','"))')"
            database.execute(updateSql)
            updatedCount += 1
        }
        
        print("🧵 Updated thread IDs for \(updatedCount) emails across \(threadGroups.count) threads")
        return updatedCount
    }
    
    // MARK: - Helper Methods
    
    private func generateThreadKey(subject: String, participants: [String]) -> String {
        let normalizedSubject = normalizeSubject(subject)
        let sortedParticipants = participants.sorted().joined(separator: "|")
        return "\(normalizedSubject)|\(sortedParticipants)".data(using: .utf8)?.base64EncodedString() ?? UUID().uuidString
    }
    
    private func normalizeSubject(_ subject: String) -> String {
        return subject
            .replacingOccurrences(of: "^(Re:|Fwd?:|FWD:)\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
    
    private func parseEmailList(_ emailsString: String?) -> [String] {
        guard let emailsString = emailsString,
              let data = emailsString.data(using: .utf8),
              let emails = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return emails
    }
    
    private func containsMeetingLanguage(_ content: String) -> Bool {
        let meetingKeywords = [
            "meeting", "schedule", "calendar", "invite", "RSVP", "available",
            "time slot", "zoom", "teams", "facetime", "call", "conference"
        ]
        
        return meetingKeywords.contains { keyword in
            content.localizedCaseInsensitiveContains(keyword)
        }
    }
    
    private func containsQuestions(_ content: String) -> Bool {
        return content.contains("?") || 
               content.localizedCaseInsensitiveContains("when") ||
               content.localizedCaseInsensitiveContains("what time") ||
               content.localizedCaseInsensitiveContains("available")
    }
    
    private func containsRSVPRequest(_ content: String) -> Bool {
        return content.localizedCaseInsensitiveContains("RSVP") ||
               content.localizedCaseInsensitiveContains("please confirm") ||
               content.localizedCaseInsensitiveContains("accept") ||
               content.localizedCaseInsensitiveContains("decline")
    }
    
    private func containsRSVPResponse(_ content: String) -> Bool {
        return content.localizedCaseInsensitiveContains("I accept") ||
               content.localizedCaseInsensitiveContains("I decline") ||
               content.localizedCaseInsensitiveContains("I'll be there") ||
               content.localizedCaseInsensitiveContains("can't make it")
    }
    
    private func containsSchedulingLanguage(_ content: String) -> Bool {
        return content.localizedCaseInsensitiveContains("schedule") ||
               content.localizedCaseInsensitiveContains("reschedule") ||
               content.localizedCaseInsensitiveContains("time slot") ||
               content.localizedCaseInsensitiveContains("available times")
    }
    
    private func hasFollowUpResponse(_ thread: EmailThread, after email: ThreadEmail) -> Bool {
        return thread.emails.contains { otherEmail in
            otherEmail.dateReceived > email.dateReceived &&
            otherEmail.fromAddress != email.fromAddress
        }
    }
    
    private func calculateUrgencyScore(daysSince: Double, hasQuestions: Bool, hasPendingRSVP: Bool, hasScheduling: Bool) -> Double {
        var score: Double = 0
        
        // Time-based urgency (exponential decay)
        if daysSince > 7 { score += 0.8 }
        else if daysSince > 3 { score += 0.5 }
        else if daysSince > 1 { score += 0.3 }
        
        // Content-based urgency
        if hasQuestions { score += 0.4 }
        if hasPendingRSVP { score += 0.6 }
        if hasScheduling { score += 0.7 }
        
        return min(score, 1.0)
    }
    
    private func determineSuggestedFollowUpAction(urgency: Double, hasQuestions: Bool, hasPendingRSVP: Bool, hasScheduling: Bool) -> String {
        if urgency > 0.8 {
            if hasPendingRSVP { return "Send urgent RSVP reminder" }
            if hasScheduling { return "Follow up on scheduling request" }
            return "Send high-priority follow-up"
        } else if urgency > 0.5 {
            if hasQuestions { return "Answer pending questions" }
            return "Send gentle follow-up"
        }
        return "Monitor thread"
    }
    
    private func groupEmailsByThread(_ results: [[String: Any]]) -> [String: [String]] {
        var threadGroups: [String: [String]] = [:]
        
        for row in results {
            guard let documentId = row["document_id"] as? String,
                  let fromAddress = row["from_address"] as? String,
                  let subject = row["title"] as? String else {
                continue
            }
            
            let toAddresses = parseEmailList(row["to_addresses"] as? String)
            let allParticipants = ([fromAddress] + toAddresses).map { $0.lowercased() }
            
            let threadId = generateThreadKey(subject: subject, participants: allParticipants)
            
            if threadGroups[threadId] == nil {
                threadGroups[threadId] = []
            }
            threadGroups[threadId]?.append(documentId)
        }
        
        return threadGroups
    }
}

// MARK: - Data Structures

public struct EmailThread {
    let id: String
    let subject: String
    var emails: [ThreadEmail]
    let participants: [String]
    let firstActivity: Date
    var lastActivity: Date
    let containsMeetingRequest: Bool
}

public struct ThreadEmail {
    let messageId: String
    let fromAddress: String
    let fromName: String?
    let toAddresses: [String]
    let subject: String
    let content: String
    let dateReceived: Date
    
    var allParticipants: [String] {
        return ([fromAddress] + toAddresses).map { $0.lowercased() }
    }
}

public struct FollowUpAnalysis {
    let threadId: String
    let daysSinceLastActivity: Int
    let hasUnansweredQuestions: Bool
    let hasPendingRSVP: Bool
    let hasSchedulingRequest: Bool
    let urgencyScore: Double
    let suggestedAction: String
}