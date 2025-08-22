import Foundation

/// RSVPParser: Extracts meeting responses and status from email content
/// Identifies acceptance, decline, tentative responses, and scheduling conflicts
public class RSVPParser {
    private let database: Database
    
    public init(database: Database) {
        self.database = database
    }
    
    // MARK: - RSVP Analysis
    
    /// Parse RSVP status from an email thread
    public func parseRSVPFromThread(_ thread: EmailThread) -> RSVPStatus {
        var responses: [String: RSVPResponse] = [:]
        
        // Analyze each email in the thread for RSVP content
        for email in thread.emails {
            if let response = parseRSVPFromEmail(email) {
                responses[email.fromAddress] = response
            }
        }
        
        return consolidateRSVPResponses(responses, threadParticipants: thread.participants)
    }
    
    /// Parse RSVP response from individual email content
    public func parseRSVPFromEmail(_ email: ThreadEmail) -> RSVPResponse? {
        let content = email.content.lowercased()
        let subject = email.subject.lowercased()
        
        // Check for explicit calendar responses first
        if let calendarResponse = parseCalendarResponse(content: content, subject: subject) {
            return calendarResponse
        }
        
        // Parse natural language responses
        if let naturalResponse = parseNaturalLanguageResponse(content: content) {
            return naturalResponse
        }
        
        // Check for scheduling conflict indicators
        if containsSchedulingConflict(content: content) {
            return RSVPResponse(
                participant: email.fromAddress,
                status: .declined,
                reason: extractConflictReason(content),
                timestamp: email.dateReceived,
                confidence: 0.8
            )
        }
        
        return nil
    }
    
    /// Extract meeting details from invitation emails
    public func parseMeetingInvitation(_ email: ThreadEmail) -> MeetingInvitation? {
        let content = email.content
        
        // Extract meeting time
        let meetingTime = extractMeetingTime(from: content)
        
        // Extract location (physical or virtual)
        let location = extractLocation(from: content)
        
        // Extract meeting type (Zoom, Teams, FaceTime, etc.)
        let meetingType = extractMeetingType(from: content)
        
        // Extract participants
        let participants = extractParticipants(from: content, email: email)
        
        guard meetingTime != nil || location != nil else {
            return nil
        }
        
        return MeetingInvitation(
            subject: email.subject,
            organizer: email.fromAddress,
            participants: participants,
            proposedTime: meetingTime,
            location: location,
            meetingType: meetingType,
            originalEmail: email
        )
    }
    
    /// Identify follow-up requests in emails
    public func parseFollowUpRequests(_ thread: EmailThread) -> [FollowUpRequest] {
        var requests: [FollowUpRequest] = []
        
        for email in thread.emails {
            if let request = parseFollowUpFromEmail(email) {
                requests.append(request)
            }
        }
        
        return requests.sorted { $0.timestamp > $1.timestamp }
    }
    
    // MARK: - Private Parsing Methods
    
    private func parseCalendarResponse(content: String, subject: String) -> RSVPResponse? {
        // Check subject line for calendar app responses
        if subject.contains("accepted:") {
            return RSVPResponse(
                participant: "",
                status: .accepted,
                reason: nil,
                timestamp: Date(),
                confidence: 0.95
            )
        } else if subject.contains("declined:") {
            return RSVPResponse(
                participant: "",
                status: .declined,
                reason: extractDeclineReason(content),
                timestamp: Date(),
                confidence: 0.95
            )
        } else if subject.contains("tentative:") {
            return RSVPResponse(
                participant: "",
                status: .tentative,
                reason: nil,
                timestamp: Date(),
                confidence: 0.9
            )
        }
        
        return nil
    }
    
    private func parseNaturalLanguageResponse(content: String) -> RSVPResponse? {
        let acceptPatterns = [
            "i accept", "i'll be there", "count me in", "i can make it",
            "yes, i'll attend", "i'll join", "i'm in", "sounds good"
        ]
        
        let declinePatterns = [
            "i decline", "i can't make it", "i won't be able to", "i'm not available",
            "i have a conflict", "sorry, i can't", "i'll have to pass", "i'm busy"
        ]
        
        let tentativePatterns = [
            "i might be able to", "tentatively yes", "probably", "i'll try to make it",
            "i should be able to", "let me check", "pending"
        ]
        
        if acceptPatterns.contains(where: { content.contains($0) }) {
            return RSVPResponse(
                participant: "",
                status: .accepted,
                reason: nil,
                timestamp: Date(),
                confidence: 0.7
            )
        } else if declinePatterns.contains(where: { content.contains($0) }) {
            return RSVPResponse(
                participant: "",
                status: .declined,
                reason: extractDeclineReason(content),
                timestamp: Date(),
                confidence: 0.7
            )
        } else if tentativePatterns.contains(where: { content.contains($0) }) {
            return RSVPResponse(
                participant: "",
                status: .tentative,
                reason: nil,
                timestamp: Date(),
                confidence: 0.6
            )
        }
        
        return nil
    }
    
    private func containsSchedulingConflict(content: String) -> Bool {
        let conflictPatterns = [
            "double booked", "scheduling conflict", "already have a meeting",
            "prior commitment", "overlapping", "conflict", "busy at that time"
        ]
        
        return conflictPatterns.contains { pattern in
            content.contains(pattern)
        }
    }
    
    private func extractConflictReason(_ content: String) -> String? {
        let sentences = content.components(separatedBy: ". ")
        
        for sentence in sentences {
            if sentence.localizedCaseInsensitiveContains("conflict") ||
               sentence.localizedCaseInsensitiveContains("busy") ||
               sentence.localizedCaseInsensitiveContains("meeting") {
                return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    private func extractDeclineReason(_ content: String) -> String? {
        let sentences = content.components(separatedBy: ". ")
        
        for sentence in sentences {
            if sentence.localizedCaseInsensitiveContains("because") ||
               sentence.localizedCaseInsensitiveContains("since") ||
               sentence.localizedCaseInsensitiveContains("due to") {
                return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    private func extractMeetingTime(from content: String) -> Date? {
        // Use regex patterns to extract date/time information
        let datePatterns = [
            "\\d{1,2}/\\d{1,2}/\\d{4}\\s+\\d{1,2}:\\d{2}\\s*(AM|PM)",
            "\\w+,\\s+\\w+\\s+\\d{1,2},\\s+\\d{4}\\s+at\\s+\\d{1,2}:\\d{2}\\s*(AM|PM)",
            "\\d{1,2}:\\d{2}\\s*(AM|PM)\\s+on\\s+\\w+"
        ]
        
        for pattern in datePatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(content.startIndex..., in: content)
            
            if let match = regex?.firstMatch(in: content, options: [], range: range) {
                let matchedString = String(content[Range(match.range, in: content)!])
                return parseDateTime(from: matchedString)
            }
        }
        
        return nil
    }
    
    private func extractLocation(from content: String) -> String? {
        // Look for common location indicators
        let locationPatterns = [
            "location:\\s*(.+)",
            "where:\\s*(.+)",
            "address:\\s*(.+)",
            "zoom link:\\s*(.+)",
            "teams link:\\s*(.+)",
            "meet at:\\s*(.+)"
        ]
        
        for pattern in locationPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(content.startIndex..., in: content)
            
            if let match = regex?.firstMatch(in: content, options: [], range: range),
               match.numberOfRanges > 1 {
                let locationRange = Range(match.range(at: 1), in: content)!
                return String(content[locationRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    private func extractMeetingType(from content: String) -> MeetingType? {
        let lowerContent = content.lowercased()
        
        if lowerContent.contains("zoom") {
            return .zoom
        } else if lowerContent.contains("teams") || lowerContent.contains("microsoft teams") {
            return .microsoftTeams
        } else if lowerContent.contains("facetime") {
            return .facetime
        } else if lowerContent.contains("phone") || lowerContent.contains("call") {
            return .phone
        } else if lowerContent.contains("in person") || lowerContent.contains("office") {
            return .inPerson
        }
        
        return nil
    }
    
    private func extractParticipants(from content: String, email: ThreadEmail) -> [String] {
        var participants = email.allParticipants
        
        // Extract additional participants from content
        let emailRegex = try? NSRegularExpression(pattern: "[\\w\\.-]+@[\\w\\.-]+\\.[A-Za-z]{2,}", options: [])
        let range = NSRange(content.startIndex..., in: content)
        
        emailRegex?.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
            if let match = match, let emailRange = Range(match.range, in: content) {
                let extractedEmail = String(content[emailRange]).lowercased()
                if !participants.contains(extractedEmail) {
                    participants.append(extractedEmail)
                }
            }
        }
        
        return participants
    }
    
    private func parseFollowUpFromEmail(_ email: ThreadEmail) -> FollowUpRequest? {
        let content = email.content.lowercased()
        
        let followUpPatterns = [
            "please confirm", "let me know", "rsvp", "respond by",
            "need to hear back", "waiting for your response", "follow up"
        ]
        
        if followUpPatterns.contains(where: { content.contains($0) }) {
            return FollowUpRequest(
                fromEmail: email.fromAddress,
                subject: email.subject,
                requestType: determineRequestType(content),
                deadline: extractDeadline(content),
                timestamp: email.dateReceived
            )
        }
        
        return nil
    }
    
    private func consolidateRSVPResponses(_ responses: [String: RSVPResponse], threadParticipants: [String]) -> RSVPStatus {
        if responses.isEmpty {
            return .none
        }
        
        let acceptedCount = responses.values.filter { $0.status == .accepted }.count
        let declinedCount = responses.values.filter { $0.status == .declined }.count
        let tentativeCount = responses.values.filter { $0.status == .tentative }.count
        
        if declinedCount > 0 {
            return .needsReschedule
        } else if acceptedCount > 0 && tentativeCount == 0 {
            return .confirmed
        } else if tentativeCount > 0 {
            return .pending
        } else {
            return .pending
        }
    }
    
    private func parseDateTime(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy h:mm a"
        return formatter.date(from: string)
    }
    
    private func determineRequestType(_ content: String) -> FollowUpType {
        if content.contains("rsvp") { return .rsvp }
        if content.contains("confirm") { return .confirmation }
        if content.contains("reschedule") { return .reschedule }
        return .general
    }
    
    private func extractDeadline(_ content: String) -> Date? {
        // Simple deadline extraction - could be enhanced
        if content.contains("by friday") {
            return nextFriday()
        } else if content.contains("by tomorrow") {
            return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        }
        return nil
    }
    
    private func nextFriday() -> Date {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilFriday = (6 - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntilFriday == 0 ? 7 : daysUntilFriday, to: today) ?? today
    }
}

// MARK: - Data Structures

public enum RSVPStatus {
    case none
    case pending
    case confirmed
    case needsReschedule
}

public struct RSVPResponse {
    let participant: String
    let status: RSVPResponseStatus
    let reason: String?
    let timestamp: Date
    let confidence: Double
}

public enum RSVPResponseStatus {
    case accepted
    case declined
    case tentative
}

public struct MeetingInvitation {
    let subject: String
    let organizer: String
    let participants: [String]
    let proposedTime: Date?
    let location: String?
    let meetingType: MeetingType?
    let originalEmail: ThreadEmail
}

public enum MeetingType {
    case zoom
    case microsoftTeams
    case facetime
    case phone
    case inPerson
}

public struct FollowUpRequest {
    let fromEmail: String
    let subject: String
    let requestType: FollowUpType
    let deadline: Date?
    let timestamp: Date
}

public enum FollowUpType: String, CaseIterable {
    case rsvp = "rsvp"
    case confirmation = "confirmation"
    case reschedule = "reschedule"
    case general = "general"
}