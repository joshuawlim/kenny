import Foundation
import EventKit

/// MeetingLinkGenerator: Automated meeting link generation for Zoom, FaceTime, etc.
/// Integrates with various video conferencing platforms and calendar systems
public class MeetingLinkGenerator {
    
    public init() {}
    
    // MARK: - Main Link Generation
    
    /// Generate meeting link based on type and meeting details
    public func generateLink(type: MeetingLinkType, meetingDetails: MeetingDetails) -> MeetingLink {
        switch type {
        case .zoom:
            return generateZoomLink(meetingDetails: meetingDetails)
        case .microsoftTeams:
            return generateTeamsLink(meetingDetails: meetingDetails)
        case .facetime:
            return generateFaceTimeLink(meetingDetails: meetingDetails)
        case .googleMeet:
            return generateGoogleMeetLink(meetingDetails: meetingDetails)
        case .phone:
            return generatePhoneConferenceLink(meetingDetails: meetingDetails)
        case .webex:
            return generateWebexLink(meetingDetails: meetingDetails)
        }
    }
    
    /// Auto-detect best meeting platform based on participants and preferences
    public func suggestOptimalPlatform(
        participants: [String],
        duration: TimeInterval,
        preferences: MeetingPlatformPreferences? = nil
    ) -> MeetingLinkType {
        
        // Check user preferences first
        if let prefs = preferences {
            if prefs.preferredPlatforms.contains(.zoom) { return .zoom }
            if prefs.preferredPlatforms.contains(.microsoftTeams) { return .microsoftTeams }
            if prefs.preferredPlatforms.contains(.googleMeet) { return .googleMeet }
        }
        
        // Auto-detect based on participant email domains
        let domains = extractDomains(from: participants)
        
        // Enterprise domain detection
        if domains.contains(where: { $0.contains("microsoft") || $0.contains("outlook") }) {
            return .microsoftTeams
        }
        
        if domains.contains(where: { $0.contains("google") || $0.contains("gmail") }) {
            return .googleMeet
        }
        
        // Apple ecosystem detection
        if participants.allSatisfy({ $0.contains("icloud") || $0.contains("me.com") || $0.contains("mac.com") }) {
            return .facetime
        }
        
        // Default to Zoom for broad compatibility
        return .zoom
    }
    
    /// Generate multiple platform options
    public func generateMultiplePlatformOptions(
        meetingDetails: MeetingDetails,
        platformCount: Int = 3
    ) -> [MeetingLink] {
        
        let suggestedPlatform = suggestOptimalPlatform(participants: meetingDetails.participants, duration: meetingDetails.duration)
        
        var platforms: [MeetingLinkType] = [suggestedPlatform]
        
        // Add complementary platforms
        let additionalPlatforms: [MeetingLinkType] = [.zoom, .microsoftTeams, .googleMeet, .facetime]
            .filter { $0 != suggestedPlatform }
        
        platforms.append(contentsOf: Array(additionalPlatforms.prefix(platformCount - 1)))
        
        return platforms.map { platform in
            generateLink(type: platform, meetingDetails: meetingDetails)
        }
    }
    
    /// Generate calendar event with meeting link
    public func generateCalendarEvent(
        meetingDetails: MeetingDetails,
        meetingLink: MeetingLink,
        startTime: Date,
        timeZone: TimeZone = TimeZone.current
    ) -> EKEvent? {
        
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        
        event.title = meetingDetails.title
        event.startDate = startTime
        event.endDate = startTime.addingTimeInterval(meetingDetails.duration)
        event.timeZone = timeZone
        
        // Add meeting link to notes
        var notes = "Join \(meetingLink.platform.displayName) Meeting:\n\(meetingLink.url)\n\n"
        
        if let dialIn = meetingLink.dialInInfo {
            notes += "Dial-in Information:\n\(dialIn)\n\n"
        }
        
        if let meetingId = meetingLink.meetingId {
            notes += "Meeting ID: \(meetingId)\n"
        }
        
        if let passcode = meetingLink.passcode {
            notes += "Passcode: \(passcode)\n"
        }
        
        event.notes = notes
        event.location = meetingLink.url
        
        // Add attendees (simplified - would need proper contact lookup in production)
        // for participant in meetingDetails.participants {
        //     // This would require proper contact integration
        // }
        
        return event
    }
    
    // MARK: - Platform-Specific Generators
    
    private func generateZoomLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // In a real implementation, this would integrate with Zoom API
        let meetingId = generateMeetingId(length: 10)
        let passcode = generatePasscode(length: 6)
        let url = "https://zoom.us/j/\(meetingId)?pwd=\(passcode)"
        
        return MeetingLink(
            platform: .zoom,
            url: url,
            meetingId: meetingId,
            passcode: passcode,
            dialInInfo: generateZoomDialIn(meetingId: meetingId, passcode: passcode),
            expirationTime: Calendar.current.date(byAdding: .month, value: 1, to: Date()),
            hostKey: generateHostKey(),
            waitingRoomEnabled: true
        )
    }
    
    private func generateTeamsLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // Microsoft Teams meeting link generation
        let conferenceId = generateMeetingId(length: 12)
        let url = "https://teams.microsoft.com/l/meetup-join/\(UUID().uuidString.lowercased())"
        
        return MeetingLink(
            platform: .microsoftTeams,
            url: url,
            meetingId: conferenceId,
            passcode: nil, // Teams typically doesn't use separate passcodes
            dialInInfo: generateTeamsDialIn(conferenceId: conferenceId),
            expirationTime: Calendar.current.date(byAdding: .month, value: 6, to: Date()),
            hostKey: nil,
            waitingRoomEnabled: true
        )
    }
    
    private func generateFaceTimeLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // FaceTime link generation (iOS 15+)
        let linkId = UUID().uuidString
        let url = "https://facetime.apple.com/join#v=1&p=\(linkId)&k=\(generateMeetingId(length: 8))"
        
        return MeetingLink(
            platform: .facetime,
            url: url,
            meetingId: linkId,
            passcode: nil,
            dialInInfo: nil, // FaceTime doesn't have traditional dial-in
            expirationTime: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
            hostKey: nil,
            waitingRoomEnabled: false
        )
    }
    
    private func generateGoogleMeetLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // Google Meet link generation
        let meetingCode = generateMeetingCode()
        let url = "https://meet.google.com/\(meetingCode)"
        
        return MeetingLink(
            platform: .googleMeet,
            url: url,
            meetingId: meetingCode,
            passcode: nil,
            dialInInfo: generateGoogleMeetDialIn(meetingCode: meetingCode),
            expirationTime: Calendar.current.date(byAdding: .month, value: 3, to: Date()),
            hostKey: nil,
            waitingRoomEnabled: false
        )
    }
    
    private func generatePhoneConferenceLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // Phone conference setup
        let conferenceNumber = "+1-555-CONFERENCE"
        let accessCode = generateMeetingId(length: 7)
        
        return MeetingLink(
            platform: .phone,
            url: "tel:\(conferenceNumber.replacingOccurrences(of: "-", with: ""))",
            meetingId: accessCode,
            passcode: nil,
            dialInInfo: "Dial: \(conferenceNumber)\nAccess Code: \(accessCode)",
            expirationTime: nil,
            hostKey: generateHostKey(),
            waitingRoomEnabled: false
        )
    }
    
    private func generateWebexLink(meetingDetails: MeetingDetails) -> MeetingLink {
        // Cisco Webex meeting link
        let meetingNumber = generateMeetingId(length: 9)
        let url = "https://company.webex.com/meet/\(meetingNumber)"
        
        return MeetingLink(
            platform: .webex,
            url: url,
            meetingId: meetingNumber,
            passcode: generatePasscode(length: 8),
            dialInInfo: generateWebexDialIn(meetingNumber: meetingNumber),
            expirationTime: Calendar.current.date(byAdding: .month, value: 1, to: Date()),
            hostKey: generateHostKey(),
            waitingRoomEnabled: true
        )
    }
    
    // MARK: - Dial-in Information Generators
    
    private func generateZoomDialIn(meetingId: String, passcode: String) -> String {
        return """
        Dial-in Numbers:
        US: +1 669 900 9128
        International: +1 346 248 7799
        
        Meeting ID: \(meetingId)
        Passcode: \(passcode)
        
        Find your local number: https://zoom.us/u/ab1234567
        """
    }
    
    private func generateTeamsDialIn(conferenceId: String) -> String {
        return """
        Dial-in Number: +1 323 849 4874
        Conference ID: \(conferenceId)
        
        Find a local number: https://dialin.teams.microsoft.com
        """
    }
    
    private func generateGoogleMeetDialIn(meetingCode: String) -> String {
        return """
        Dial-in Number: +1 470 381 2552
        PIN: \(generateMeetingId(length: 9))
        
        More phone numbers: https://tel.meet/\(meetingCode)?hl=en&hs=7
        """
    }
    
    private func generateWebexDialIn(meetingNumber: String) -> String {
        return """
        Dial-in Number: +1 408 418 9388
        Access Code: \(meetingNumber)
        
        Global call-in numbers: https://company.webex.com/globalcallin
        """
    }
    
    // MARK: - Utility Methods
    
    private func generateMeetingId(length: Int) -> String {
        let digits = "0123456789"
        return String((0..<length).map { _ in digits.randomElement()! })
    }
    
    private func generatePasscode(length: Int) -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
    
    private func generateHostKey() -> String {
        return generateMeetingId(length: 6)
    }
    
    private func generateMeetingCode() -> String {
        // Google Meet format: xxx-xxxx-xxx
        let part1 = generateMeetingId(length: 3)
        let part2 = generateMeetingId(length: 4)
        let part3 = generateMeetingId(length: 3)
        return "\(part1)-\(part2)-\(part3)"
    }
    
    private func extractDomains(from participants: [String]) -> [String] {
        return participants.compactMap { email in
            let components = email.components(separatedBy: "@")
            return components.count == 2 ? components[1].lowercased() : nil
        }
    }
}

// MARK: - Data Structures

public struct MeetingLink {
    public let platform: MeetingLinkType
    public let url: String
    public let meetingId: String?
    public let passcode: String?
    public let dialInInfo: String?
    public let expirationTime: Date?
    public let hostKey: String?
    public let waitingRoomEnabled: Bool
    
    /// Convert to dictionary for JSON serialization
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "platform": platform.rawValue,
            "url": url,
            "waitingRoomEnabled": waitingRoomEnabled
        ]
        
        if let meetingId = meetingId { dict["meetingId"] = meetingId }
        if let passcode = passcode { dict["passcode"] = passcode }
        if let dialInInfo = dialInInfo { dict["dialInInfo"] = dialInInfo }
        if let expirationTime = expirationTime { 
            dict["expirationTime"] = ISO8601DateFormatter().string(from: expirationTime)
        }
        if let hostKey = hostKey { dict["hostKey"] = hostKey }
        
        return dict
    }
}

public enum MeetingLinkType: String, CaseIterable {
    case zoom = "zoom"
    case microsoftTeams = "microsoft_teams"
    case facetime = "facetime"
    case googleMeet = "google_meet"
    case phone = "phone"
    case webex = "webex"
    
    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .microsoftTeams: return "Microsoft Teams"
        case .facetime: return "FaceTime"
        case .googleMeet: return "Google Meet"
        case .phone: return "Phone Conference"
        case .webex: return "Cisco Webex"
        }
    }
    
    public var supportsDialIn: Bool {
        switch self {
        case .zoom, .microsoftTeams, .googleMeet, .phone, .webex: return true
        case .facetime: return false
        }
    }
    
    public var requiresAccount: Bool {
        switch self {
        case .zoom, .microsoftTeams, .webex: return true
        case .facetime, .googleMeet, .phone: return false
        }
    }
}

public struct MeetingPlatformPreferences {
    let preferredPlatforms: [MeetingLinkType]
    let avoidPlatforms: [MeetingLinkType]
    let requireDialIn: Bool
    let requireWaitingRoom: Bool
    let maxMeetingDuration: TimeInterval?
    
    public static let standard = MeetingPlatformPreferences(
        preferredPlatforms: [.zoom, .microsoftTeams],
        avoidPlatforms: [],
        requireDialIn: true,
        requireWaitingRoom: true,
        maxMeetingDuration: nil
    )
    
    public static let casual = MeetingPlatformPreferences(
        preferredPlatforms: [.facetime, .googleMeet],
        avoidPlatforms: [],
        requireDialIn: false,
        requireWaitingRoom: false,
        maxMeetingDuration: 3600 // 1 hour
    )
}

/// Meeting link validation and testing
public extension MeetingLink {
    
    /// Validate the meeting link format
    func isValid() -> Bool {
        guard !url.isEmpty,
              let url = URL(string: self.url),
              let scheme = url.scheme else {
            return false
        }
        
        switch platform {
        case .zoom:
            return url.host?.contains("zoom") == true
        case .microsoftTeams:
            return url.host?.contains("teams.microsoft.com") == true
        case .facetime:
            return url.host?.contains("facetime.apple.com") == true
        case .googleMeet:
            return url.host?.contains("meet.google.com") == true
        case .phone:
            return scheme == "tel"
        case .webex:
            return url.host?.contains("webex.com") == true
        }
    }
    
    /// Check if link has expired
    func hasExpired() -> Bool {
        guard let expirationTime = expirationTime else { return false }
        return Date() > expirationTime
    }
    
    /// Get formatted meeting instructions
    func getFormattedInstructions() -> String {
        var instructions = "Join the \(platform.displayName) meeting:\n\(url)\n\n"
        
        if let meetingId = meetingId {
            instructions += "Meeting ID: \(meetingId)\n"
        }
        
        if let passcode = passcode {
            instructions += "Passcode: \(passcode)\n"
        }
        
        if let dialIn = dialInInfo, platform.supportsDialIn {
            instructions += "\nDial-in option:\n\(dialIn)\n"
        }
        
        return instructions
    }
}