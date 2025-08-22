import Foundation

/// EmailDrafter: Automated meeting coordination email generation
/// Creates professional, context-aware emails for invitations, follow-ups, and rescheduling
public class EmailDrafter {
    
    public init() {}
    
    // MARK: - Main Drafting Methods
    
    /// Draft meeting coordination email
    public func draftEmail(
        type: MeetingEmailType,
        participants: [String],
        proposedSlots: [MeetingSlot]? = nil,
        meetingTitle: String? = nil,
        context: String? = nil,
        organizer: String? = nil,
        meetingLink: MeetingLink? = nil
    ) -> MeetingEmailDraft {
        
        let subject = generateSubject(type: type, title: meetingTitle)
        let body = generateBody(
            type: type,
            participants: participants,
            proposedSlots: proposedSlots,
            meetingTitle: meetingTitle,
            context: context,
            organizer: organizer,
            meetingLink: meetingLink
        )
        
        return MeetingEmailDraft(
            to: participants,
            cc: [],
            subject: subject,
            body: body,
            type: type,
            priority: determinePriority(type: type),
            suggestedSendTime: suggestOptimalSendTime()
        )
    }
    
    /// Draft follow-up email for pending responses
    public func draftFollowUpEmail(
        originalThread: EmailThread,
        followUpType: FollowUpType,
        daysSinceLastActivity: Int,
        urgency: UrgencyLevel = .medium
    ) -> MeetingEmailDraft {
        
        let subject = generateFollowUpSubject(
            originalSubject: originalThread.subject,
            type: followUpType,
            urgency: urgency
        )
        
        let body = generateFollowUpBody(
            thread: originalThread,
            type: followUpType,
            daysSince: daysSinceLastActivity,
            urgency: urgency
        )
        
        return MeetingEmailDraft(
            to: originalThread.participants,
            cc: [],
            subject: subject,
            body: body,
            type: .followUp,
            priority: urgency == .high ? .high : .normal,
            suggestedSendTime: suggestOptimalSendTime()
        )
    }
    
    /// Draft rescheduling email with alternative slots
    public func draftReschedulingEmail(
        originalSlot: MeetingSlot,
        alternativeSlots: [MeetingSlot],
        reason: String? = nil,
        affectedParticipants: [String]? = nil
    ) -> MeetingEmailDraft {
        
        let subject = "Rescheduling Required - Meeting Coordination"
        let body = generateReschedulingBody(
            originalSlot: originalSlot,
            alternatives: alternativeSlots,
            reason: reason,
            affectedParticipants: affectedParticipants
        )
        
        return MeetingEmailDraft(
            to: originalSlot.participants,
            cc: [],
            subject: subject,
            body: body,
            type: .reschedule,
            priority: .high,
            suggestedSendTime: suggestOptimalSendTime()
        )
    }
    
    /// Draft cancellation email
    public func draftCancellationEmail(
        meetingSlot: MeetingSlot,
        reason: String,
        offerReschedule: Bool = true
    ) -> MeetingEmailDraft {
        
        let subject = "Meeting Cancellation"
        let body = generateCancellationBody(
            slot: meetingSlot,
            reason: reason,
            offerReschedule: offerReschedule
        )
        
        return MeetingEmailDraft(
            to: meetingSlot.participants,
            cc: [],
            subject: subject,
            body: body,
            type: .cancellation,
            priority: .high,
            suggestedSendTime: Date()
        )
    }
    
    // MARK: - Subject Generation
    
    private func generateSubject(type: MeetingEmailType, title: String?) -> String {
        let meetingTitle = title ?? "Meeting"
        
        switch type {
        case .invitation:
            return "Invitation: \(meetingTitle)"
        case .followUp:
            return "Follow-up: \(meetingTitle)"
        case .reschedule:
            return "Reschedule Request: \(meetingTitle)"
        case .confirmation:
            return "Confirmed: \(meetingTitle)"
        case .cancellation:
            return "Cancelled: \(meetingTitle)"
        case .reminder:
            return "Reminder: \(meetingTitle) - Tomorrow"
        }
    }
    
    private func generateFollowUpSubject(
        originalSubject: String,
        type: FollowUpType,
        urgency: UrgencyLevel
    ) -> String {
        
        let prefix = urgency == .high ? "URGENT - " : ""
        
        switch type {
        case .rsvp:
            return "\(prefix)RSVP Required: \(originalSubject)"
        case .confirmation:
            return "\(prefix)Please confirm: \(originalSubject)"
        case .reschedule:
            return "\(prefix)Rescheduling needed: \(originalSubject)"
        case .general:
            return "\(prefix)Follow-up: \(originalSubject)"
        }
    }
    
    // MARK: - Body Generation
    
    private func generateBody(
        type: MeetingEmailType,
        participants: [String],
        proposedSlots: [MeetingSlot]?,
        meetingTitle: String?,
        context: String?,
        organizer: String?,
        meetingLink: MeetingLink?
    ) -> String {
        
        switch type {
        case .invitation:
            return generateInvitationBody(
                participants: participants,
                proposedSlots: proposedSlots,
                meetingTitle: meetingTitle,
                context: context,
                organizer: organizer,
                meetingLink: meetingLink
            )
        case .confirmation:
            return generateConfirmationBody(
                proposedSlots: proposedSlots,
                meetingTitle: meetingTitle,
                meetingLink: meetingLink
            )
        case .reminder:
            return generateReminderBody(
                proposedSlots: proposedSlots,
                meetingTitle: meetingTitle,
                meetingLink: meetingLink
            )
        default:
            return generateGenericBody(type: type, context: context)
        }
    }
    
    private func generateInvitationBody(
        participants: [String],
        proposedSlots: [MeetingSlot]?,
        meetingTitle: String?,
        context: String?,
        organizer: String?,
        meetingLink: MeetingLink?
    ) -> String {
        
        var body = "Hello,\n\n"
        
        // Context/purpose
        if let context = context {
            body += "\(context)\n\n"
        } else {
            body += "I'd like to schedule a meeting to discuss \(meetingTitle ?? "our upcoming project").\n\n"
        }
        
        // Proposed times
        if let slots = proposedSlots, !slots.isEmpty {
            body += "I have a few time slots available:\n\n"
            
            for (index, slot) in slots.prefix(3).enumerated() {
                let formatter = DateFormatter()
                formatter.dateStyle = .full
                formatter.timeStyle = .short
                
                body += "\(index + 1). \(formatter.string(from: slot.startTime))"
                
                let duration = slot.endTime.timeIntervalSince(slot.startTime)
                let durationMinutes = Int(duration / 60)
                body += " (\(durationMinutes) minutes)\n"
            }
            
            body += "\nPlease let me know which time works best for you, or suggest an alternative if none of these work.\n\n"
        } else {
            body += "Could you please let me know your availability for the next week or two?\n\n"
        }
        
        // Meeting link
        if let link = meetingLink {
            body += "\(link.platform.displayName) Link: \(link.url)\n"
            if let dialIn = link.dialInInfo {
                body += "Dial-in: \(dialIn)\n"
            }
            body += "\n"
        }
        
        body += "Looking forward to hearing from you.\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateFollowUpBody(
        thread: EmailThread,
        type: FollowUpType,
        daysSince: Int,
        urgency: UrgencyLevel
    ) -> String {
        
        var body = "Hello,\n\n"
        
        // Reference original message
        body += "I wanted to follow up on my previous email"
        if daysSince > 1 {
            body += " from \(daysSince) days ago"
        }
        body += " regarding \(thread.subject.lowercased()).\n\n"
        
        // Specific follow-up based on type
        switch type {
        case .rsvp:
            body += "I haven't yet received your RSVP for the proposed meeting time"
            if urgency == .high {
                body += ", and I need to confirm attendance to finalize the arrangements"
            }
            body += ".\n\n"
            body += "Could you please let me know if you're available at the proposed time, or suggest an alternative?\n\n"
            
        case .confirmation:
            body += "I'm still awaiting confirmation of the meeting details.\n\n"
            body += "Please confirm your attendance so I can send out calendar invites.\n\n"
            
        case .reschedule:
            body += "I understand there may be scheduling conflicts with the original time.\n\n"
            body += "Would you be able to suggest a few alternative times that work better for you?\n\n"
            
        case .general:
            body += "I'd appreciate your response when you have a moment.\n\n"
        }
        
        if urgency == .high {
            body += "This is time-sensitive, so I'd be grateful for a quick response.\n\n"
        }
        
        body += "Thank you for your time.\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateReschedulingBody(
        originalSlot: MeetingSlot,
        alternatives: [MeetingSlot],
        reason: String?,
        affectedParticipants: [String]?
    ) -> String {
        
        var body = "Hello,\n\n"
        
        // Explain need to reschedule
        body += "I need to reschedule our upcoming meeting"
        
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        body += " originally planned for \(formatter.string(from: originalSlot.startTime))"
        
        if let reason = reason {
            body += " due to \(reason.lowercased())"
        }
        body += ".\n\n"
        
        // Apologize for inconvenience
        body += "I apologize for any inconvenience this may cause.\n\n"
        
        // Offer alternatives
        if !alternatives.isEmpty {
            body += "I have the following alternative times available:\n\n"
            
            for (index, slot) in alternatives.prefix(3).enumerated() {
                body += "\(index + 1). \(formatter.string(from: slot.startTime))\n"
            }
            
            body += "\nPlease let me know which of these times works best for everyone"
            if let affected = affectedParticipants, !affected.isEmpty {
                body += ", particularly for \(affected.joined(separator: ", "))"
            }
            body += ".\n\n"
        } else {
            body += "Could you please suggest a few alternative times that work for everyone?\n\n"
        }
        
        body += "Thank you for your flexibility.\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateConfirmationBody(
        proposedSlots: [MeetingSlot]?,
        meetingTitle: String?,
        meetingLink: MeetingLink?
    ) -> String {
        
        var body = "Hello,\n\n"
        
        body += "This is to confirm our meeting"
        if let title = meetingTitle {
            body += " - \(title)"
        }
        
        if let slots = proposedSlots, let firstSlot = slots.first {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            
            body += " scheduled for \(formatter.string(from: firstSlot.startTime))"
            
            let duration = firstSlot.endTime.timeIntervalSince(firstSlot.startTime)
            let durationMinutes = Int(duration / 60)
            body += " (\(durationMinutes) minutes)"
        }
        
        body += ".\n\n"
        
        if let link = meetingLink {
            body += "Meeting details:\n"
            body += "Platform: \(link.platform.displayName)\n"
            body += "Link: \(link.url)\n"
            if let dialIn = link.dialInInfo {
                body += "Dial-in: \(dialIn)\n"
            }
            body += "\n"
        }
        
        body += "Looking forward to speaking with you.\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateReminderBody(
        proposedSlots: [MeetingSlot]?,
        meetingTitle: String?,
        meetingLink: MeetingLink?
    ) -> String {
        
        var body = "Hello,\n\n"
        
        body += "This is a friendly reminder about our meeting"
        if let title = meetingTitle {
            body += " - \(title)"
        }
        body += " tomorrow.\n\n"
        
        if let slots = proposedSlots, let firstSlot = slots.first {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            body += "Time: \(formatter.string(from: firstSlot.startTime))\n"
        }
        
        if let link = meetingLink {
            body += "Join via \(link.platform.displayName): \(link.url)\n"
        }
        
        body += "\nSee you tomorrow!\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateCancellationBody(
        slot: MeetingSlot,
        reason: String,
        offerReschedule: Bool
    ) -> String {
        
        var body = "Hello,\n\n"
        
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        
        body += "I regret to inform you that I need to cancel our meeting scheduled for \(formatter.string(from: slot.startTime))"
        body += " due to \(reason.lowercased()).\n\n"
        
        body += "I sincerely apologize for the short notice and any inconvenience this may cause.\n\n"
        
        if offerReschedule {
            body += "I would very much like to reschedule this meeting. Could you please let me know your availability for the next week or two, and I'll send you some alternative times?\n\n"
        }
        
        body += "Thank you for your understanding.\n\n"
        body += "Best regards"
        
        return body
    }
    
    private func generateGenericBody(type: MeetingEmailType, context: String?) -> String {
        var body = "Hello,\n\n"
        
        if let context = context {
            body += "\(context)\n\n"
        }
        
        switch type {
        case .followUp:
            body += "I wanted to follow up on our previous correspondence.\n\n"
        case .reschedule:
            body += "I need to discuss rescheduling our upcoming meeting.\n\n"
        default:
            body += "I hope this email finds you well.\n\n"
        }
        
        body += "Please let me know your thoughts.\n\n"
        body += "Best regards"
        
        return body
    }
    
    // MARK: - Utility Methods
    
    private func determinePriority(type: MeetingEmailType) -> EmailPriority {
        switch type {
        case .cancellation, .reschedule:
            return .high
        case .reminder:
            return .normal
        case .followUp:
            return .normal
        default:
            return .normal
        }
    }
    
    private func suggestOptimalSendTime() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        
        // If it's outside business hours, suggest next business day at 9 AM
        if hour < 8 || hour > 17 {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? now
        }
        
        // If it's during business hours, suggest immediate sending
        return now
    }
}

// MARK: - Data Structures

public struct MeetingEmailDraft {
    public let to: [String]
    public let cc: [String]
    public let subject: String
    public let body: String
    public let type: MeetingEmailType
    public let priority: EmailPriority
    public let suggestedSendTime: Date
    
    /// Convert to dictionary for JSON serialization
    public func toDictionary() -> [String: Any] {
        return [
            "to": to,
            "cc": cc,
            "subject": subject,
            "body": body,
            "type": type.rawValue,
            "priority": priority.rawValue,
            "suggestedSendTime": ISO8601DateFormatter().string(from: suggestedSendTime)
        ]
    }
}

public enum MeetingEmailType: String, CaseIterable {
    case invitation = "invitation"
    case followUp = "follow_up"
    case reschedule = "reschedule"
    case confirmation = "confirmation"
    case cancellation = "cancellation"
    case reminder = "reminder"
}

public enum EmailPriority: String, CaseIterable {
    case low = "low"
    case normal = "normal"
    case high = "high"
}

public enum UrgencyLevel {
    case low
    case medium
    case high
}