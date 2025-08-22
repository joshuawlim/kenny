import Foundation
import EventKit

/// Week 6: Meeting Concierge - Email and calendar mastery for management workflows
/// Comprehensive meeting management system with threading, RSVP parsing, conflict detection,
/// automated coordination, and follow-up tracking with SLA monitoring.
public class MeetingConcierge {
    private let database: Database
    private let emailThreadingService: EmailThreadingService
    private let rsvpParser: RSVPParser
    private let conflictDetector: CalendarConflictDetector
    private let slotProposer: MeetingSlotProposer
    private let emailDrafter: EmailDrafter
    private let linkGenerator: MeetingLinkGenerator
    public let followUpTracker: FollowUpTracker
    
    public init(database: Database) {
        self.database = database
        self.emailThreadingService = EmailThreadingService(database: database)
        self.rsvpParser = RSVPParser(database: database)
        self.conflictDetector = CalendarConflictDetector(database: database)
        self.slotProposer = MeetingSlotProposer(database: database, conflictDetector: conflictDetector)
        self.emailDrafter = EmailDrafter()
        self.linkGenerator = MeetingLinkGenerator()
        self.followUpTracker = FollowUpTracker(database: database, emailThreadingService: emailThreadingService)
    }
    
    // MARK: - Core Meeting Concierge Operations
    
    /// Analyze email threads for meeting coordination opportunities
    public func analyzeMeetingThreads(since: Date? = nil) async throws -> [MeetingThread] {
        let threads = try await emailThreadingService.identifyMeetingThreads(since: since)
        return threads.map { thread in
            let rsvpStatus = rsvpParser.parseRSVPFromThread(thread)
            let needsFollowUp = followUpTracker.needsFollowUp(thread)
            
            return MeetingThread(
                id: thread.id,
                subject: thread.subject,
                participants: thread.participants,
                lastActivity: thread.lastActivity,
                rsvpStatus: rsvpStatus,
                needsFollowUp: needsFollowUp,
                suggestedAction: determineSuggestedAction(thread, rsvpStatus, needsFollowUp)
            )
        }
    }
    
    /// Propose meeting slots avoiding conflicts
    public func proposeMeetingSlots(
        participants: [String],
        duration: TimeInterval,
        preferredTimeRanges: [TimeRange]? = nil,
        excludeWeekends: Bool = true
    ) async throws -> [MeetingSlot] {
        
        // Get participant availability from calendar data
        let participantAvailability = try await getParticipantAvailability(participants)
        
        // Generate slot proposals
        return try await slotProposer.proposeSlots(
            participants: participants,
            duration: duration,
            availability: participantAvailability,
            preferredTimeRanges: preferredTimeRanges,
            excludeWeekends: excludeWeekends
        )
    }
    
    /// Draft meeting coordination email
    public func draftMeetingEmail(
        type: MeetingEmailType,
        participants: [String],
        proposedSlots: [MeetingSlot]? = nil,
        meetingTitle: String? = nil,
        context: String? = nil
    ) -> MeetingEmailDraft {
        return emailDrafter.draftEmail(
            type: type,
            participants: participants,
            proposedSlots: proposedSlots,
            meetingTitle: meetingTitle,
            context: context
        )
    }
    
    /// Generate meeting links (Zoom/FaceTime) for scheduled meetings
    public func generateMeetingLink(type: MeetingLinkType, meetingDetails: MeetingDetails) -> MeetingLink {
        return linkGenerator.generateLink(type: type, meetingDetails: meetingDetails)
    }
    
    /// Track and manage follow-ups with SLA monitoring
    public func getFollowUpActions(slaHours: Int = 48) async throws -> [FollowUpAction] {
        return try await followUpTracker.getOverdueTasks(slaHours: slaHours)
    }
    
    /// Comprehensive meeting workflow: propose + coordinate + track
    public func coordinateMeeting(request: MeetingCoordinationRequest) async throws -> MeetingCoordinationResult {
        let startTime = Date()
        
        // Step 1: Check for conflicts
        let conflicts = try await conflictDetector.findConflicts(
            participants: request.participants,
            timeRange: request.proposedTimeRange
        )
        
        // Step 2: Propose alternative slots if conflicts exist
        let finalSlots: [MeetingSlot]
        if !conflicts.isEmpty {
            finalSlots = try await proposeMeetingSlots(
                participants: request.participants,
                duration: request.duration,
                preferredTimeRanges: request.preferredTimeRanges,
                excludeWeekends: request.excludeWeekends
            )
        } else {
            finalSlots = [MeetingSlot(
                startTime: request.proposedTimeRange.start,
                endTime: request.proposedTimeRange.end,
                participants: request.participants,
                confidence: 1.0
            )]
        }
        
        // Step 3: Generate meeting link if requested
        let meetingLink: MeetingLink?
        if let linkType = request.preferredLinkType {
            let meetingDetails = MeetingDetails(
                title: request.title,
                duration: request.duration,
                participants: request.participants
            )
            meetingLink = generateMeetingLink(type: linkType, meetingDetails: meetingDetails)
        } else {
            meetingLink = nil
        }
        
        // Step 4: Draft coordination email
        let emailDraft = draftMeetingEmail(
            type: .invitation,
            participants: request.participants,
            proposedSlots: finalSlots,
            meetingTitle: request.title,
            context: request.context
        )
        
        // Step 5: Set up follow-up tracking
        try await followUpTracker.scheduleFollowUp(
            recipients: request.participants,
            subject: request.title,
            slaHours: request.followUpSLAHours ?? 48
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        return MeetingCoordinationResult(
            success: true,
            proposedSlots: finalSlots,
            conflicts: conflicts,
            emailDraft: emailDraft,
            meetingLink: meetingLink,
            followUpScheduled: true,
            duration: duration
        )
    }
    
    // MARK: - Helper Methods
    
    private func getParticipantAvailability(_ participants: [String]) async throws -> [String: [TimeRange]] {
        var availability: [String: [TimeRange]] = [:]
        
        for participant in participants {
            // Query calendar events for participant to determine busy times
            let sql = """
                SELECT start_time, end_time FROM events e
                JOIN documents d ON e.document_id = d.id
                WHERE (e.attendees LIKE ? OR e.organizer_email = ?)
                AND e.start_time >= ?
                AND e.start_time <= ?
                ORDER BY start_time
            """
            
            let now = Date()
            let twoWeeksFromNow = now.addingTimeInterval(14 * 24 * 3600)
            
            let results = database.query(
                sql,
                parameters: [
                    "%\(participant)%",
                    participant,
                    Int(now.timeIntervalSince1970),
                    Int(twoWeeksFromNow.timeIntervalSince1970)
                ]
            )
            
            let busyTimes = results.compactMap { row -> TimeRange? in
                guard let startTime = row["start_time"] as? Int,
                      let endTime = row["end_time"] as? Int else {
                    return nil
                }
                
                return TimeRange(
                    start: Date(timeIntervalSince1970: TimeInterval(startTime)),
                    end: Date(timeIntervalSince1970: TimeInterval(endTime))
                )
            }
            
            availability[participant] = busyTimes
        }
        
        return availability
    }
    
    private func determineSuggestedAction(
        _ thread: EmailThread,
        _ rsvpStatus: RSVPStatus,
        _ needsFollowUp: Bool
    ) -> MeetingSuggestion {
        
        if needsFollowUp && rsvpStatus == .pending {
            return .sendFollowUp("RSVP reminder needed")
        }
        
        if rsvpStatus == .needsReschedule {
            return .proposeNewSlots("Conflicts detected, suggest alternatives")
        }
        
        if thread.containsMeetingRequest && rsvpStatus == .none {
            return .sendInvitation("Send formal meeting invitation")
        }
        
        return .none
    }
}

// MARK: - Supporting Data Structures

public struct MeetingCoordinationRequest {
    public let title: String
    public let participants: [String]
    public let duration: TimeInterval
    public let proposedTimeRange: TimeRange
    public let preferredTimeRanges: [TimeRange]?
    public let excludeWeekends: Bool
    public let preferredLinkType: MeetingLinkType?
    public let context: String?
    public let followUpSLAHours: Int?
    
    public init(title: String, participants: [String], duration: TimeInterval, proposedTimeRange: TimeRange, preferredTimeRanges: [TimeRange]?, excludeWeekends: Bool, preferredLinkType: MeetingLinkType?, context: String?, followUpSLAHours: Int?) {
        self.title = title
        self.participants = participants
        self.duration = duration
        self.proposedTimeRange = proposedTimeRange
        self.preferredTimeRanges = preferredTimeRanges
        self.excludeWeekends = excludeWeekends
        self.preferredLinkType = preferredLinkType
        self.context = context
        self.followUpSLAHours = followUpSLAHours
    }
}

public struct MeetingCoordinationResult {
    public let success: Bool
    public let proposedSlots: [MeetingSlot]
    public let conflicts: [CalendarConflict]
    public let emailDraft: MeetingEmailDraft
    public let meetingLink: MeetingLink?
    public let followUpScheduled: Bool
    public let duration: TimeInterval
}

public struct MeetingThread {
    public let id: String
    public let subject: String
    public let participants: [String]
    public let lastActivity: Date
    public let rsvpStatus: RSVPStatus
    public let needsFollowUp: Bool
    public let suggestedAction: MeetingSuggestion
}

public struct MeetingDetails {
    let title: String
    let duration: TimeInterval
    let participants: [String]
}

public struct TimeRange {
    public let start: Date
    public let end: Date
    
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
    
    public func overlaps(with other: TimeRange) -> Bool {
        return start < other.end && end > other.start
    }
}

public enum MeetingSuggestion {
    case none
    case sendFollowUp(String)
    case proposeNewSlots(String)
    case sendInvitation(String)
}