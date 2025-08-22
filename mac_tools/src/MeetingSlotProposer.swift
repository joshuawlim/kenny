import Foundation

/// MeetingSlotProposer: Intelligent meeting time suggestions with conflict avoidance
/// Uses participant availability, preferences, and machine learning heuristics
public class MeetingSlotProposer {
    private let database: Database
    private let conflictDetector: CalendarConflictDetector
    
    public init(database: Database, conflictDetector: CalendarConflictDetector) {
        self.database = database
        self.conflictDetector = conflictDetector
    }
    
    // MARK: - Core Slot Proposal
    
    /// Propose optimal meeting slots for participants
    public func proposeSlots(
        participants: [String],
        duration: TimeInterval,
        availability: [String: [TimeRange]]? = nil,
        preferredTimeRanges: [TimeRange]? = nil,
        excludeWeekends: Bool = true,
        maxSuggestions: Int = 5
    ) async throws -> [MeetingSlot] {
        
        // Get participant availability if not provided
        let participantAvailability: [String: [TimeRange]]
        if let availability = availability {
            participantAvailability = availability
        } else {
            participantAvailability = await getParticipantAvailability(
                participants: participants,
                lookAheadDays: 14
            )
        }
        
        // Get historical meeting preferences for participants
        let preferences = await getParticipantPreferences(participants)
        
        // Generate time slots based on availability and preferences
        let candidateSlots = generateCandidateSlots(
            participants: participants,
            duration: duration,
            availability: participantAvailability,
            preferences: preferences,
            preferredTimeRanges: preferredTimeRanges,
            excludeWeekends: excludeWeekends
        )
        
        // Score and rank slots
        let scoredSlots = await scoreSlots(candidateSlots, preferences: preferences)
        
        // Return top suggestions
        return Array(scoredSlots.prefix(maxSuggestions))
    }
    
    /// Propose slots for recurring meetings
    public func proposeRecurringSlots(
        participants: [String],
        duration: TimeInterval,
        pattern: RecurrencePattern,
        startDate: Date,
        occurrences: Int = 10,
        excludeWeekends: Bool = true
    ) async throws -> [RecurringMeetingProposal] {
        
        let availability = await getParticipantAvailability(
            participants: participants,
            lookAheadDays: occurrences * (pattern.frequency == .daily ? 1 : pattern.frequency == .weekly ? 7 : 30)
        )
        
        let preferences = await getParticipantPreferences(participants)
        
        var proposals: [RecurringMeetingProposal] = []
        let calendar = Calendar.current
        
        // Generate multiple time options for the series
        let baseSlots = generateBaseRecurringSlots(
            duration: duration,
            preferences: preferences,
            excludeWeekends: excludeWeekends
        )
        
        for baseSlot in baseSlots {
            let conflicts = try await checkRecurringConflicts(
                baseTime: baseSlot,
                participants: participants,
                pattern: pattern,
                startDate: startDate,
                occurrences: occurrences,
                duration: duration
            )
            
            let proposal = RecurringMeetingProposal(
                baseSlot: baseSlot,
                pattern: pattern,
                participants: participants,
                conflictSummary: conflicts,
                score: calculateRecurringScore(baseSlot, conflicts: conflicts, preferences: preferences)
            )
            
            proposals.append(proposal)
        }
        
        return proposals.sorted { $0.score > $1.score }
    }
    
    /// Smart rescheduling with minimal participant impact
    public func proposeRescheduleSlots(
        originalSlot: MeetingSlot,
        conflictedParticipants: [String],
        reschedulingConstraints: ReschedulingConstraints
    ) async throws -> [MeetingSlot] {
        
        let allParticipants = originalSlot.participants
        let availableParticipants = allParticipants.filter { !conflictedParticipants.contains($0) }
        
        // Get updated availability
        let availability = await getParticipantAvailability(
            participants: allParticipants,
            lookAheadDays: reschedulingConstraints.maxDaysFromOriginal
        )
        
        // Generate alternative slots near the original time
        let alternativeSlots = generateNearbySlots(
            originalSlot: originalSlot,
            constraints: reschedulingConstraints,
            availability: availability
        )
        
        // Score alternatives based on minimal disruption
        return await scoreRescheduleSlots(
            alternatives: alternativeSlots,
            originalSlot: originalSlot,
            conflictedParticipants: conflictedParticipants,
            availableParticipants: availableParticipants
        )
    }
    
    /// Propose meeting windows for complex multi-participant scheduling
    public func proposeMeetingWindows(
        participants: [String],
        duration: TimeInterval,
        windowDuration: TimeInterval, // How long the window should be (e.g., 2 hours)
        flexibility: FlexibilityLevel = .medium
    ) async throws -> [MeetingWindow] {
        
        let availability = await getParticipantAvailability(participants: participants, lookAheadDays: 14)
        let preferences = await getParticipantPreferences(participants)
        
        // Find large continuous availability windows
        let windows = findContinuousWindows(
            availability: availability,
            windowDuration: windowDuration,
            flexibility: flexibility
        )
        
        // Generate multiple slot options within each window
        return windows.map { window in
            let slotsInWindow = generateSlotsInWindow(
                window: window,
                duration: duration,
                participants: participants,
                preferences: preferences
            )
            
            return MeetingWindow(
                timeRange: window,
                participants: participants,
                availableSlots: slotsInWindow.sorted { $0.confidence > $1.confidence },
                flexibility: flexibility
            )
        }.sorted { $0.score > $1.score }
    }
    
    // MARK: - Private Implementation
    
    private func getParticipantAvailability(participants: [String], lookAheadDays: Int) async -> [String: [TimeRange]] {
        let endDate = Calendar.current.date(byAdding: .day, value: lookAheadDays, to: Date()) ?? Date()
        let dateRange = DateInterval(start: Date(), end: endDate)
        
        do {
            let busyTimes = try await conflictDetector.getParticipantAvailability(
                participants: participants,
                dateRange: dateRange
            )
            
            // Convert BusyTime to TimeRange
            return busyTimes.mapValues { busyTimeArray in
                busyTimeArray.map { $0.timeRange }
            }
        } catch {
            print("⚠️ Error getting participant availability: \(error)")
            return [:]
        }
    }
    
    private func getParticipantPreferences(_ participants: [String]) async -> [String: ParticipantPreferences] {
        var preferences: [String: ParticipantPreferences] = [:]
        
        for participant in participants {
            preferences[participant] = await analyzeParticipantPreferences(participant)
        }
        
        return preferences
    }
    
    private func analyzeParticipantPreferences(_ participant: String) async -> ParticipantPreferences {
        // Analyze historical meeting patterns for this participant
        let sql = """
            SELECT 
                e.start_time, e.end_time, e.calendar_name,
                COUNT(*) as frequency
            FROM events e
            JOIN documents d ON e.document_id = d.id
            WHERE (e.attendees LIKE ? OR e.organizer_email = ?)
            AND e.start_time >= ?
            AND e.status = 'confirmed'
            GROUP BY 
                strftime('%H', datetime(e.start_time, 'unixepoch')) / 2 * 2, -- 2-hour buckets
                strftime('%w', datetime(e.start_time, 'unixepoch'))
            ORDER BY frequency DESC
        """
        
        let threeMonthsAgo = Date().addingTimeInterval(-90 * 24 * 3600)
        let results = database.query(sql, parameters: [
            "%\(participant)%",
            participant,
            Int(threeMonthsAgo.timeIntervalSince1970)
        ])
        
        var hourPreferences: [Int: Double] = [:]
        var dayPreferences: [Int: Double] = [:]
        var totalMeetings = 0
        
        for row in results {
            guard let startTime = row["start_time"] as? Int,
                  let frequency = row["frequency"] as? Int else {
                continue
            }
            
            let date = Date(timeIntervalSince1970: TimeInterval(startTime))
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: date)
            let weekday = calendar.component(.weekday, from: date)
            
            hourPreferences[hour, default: 0] += Double(frequency)
            dayPreferences[weekday, default: 0] += Double(frequency)
            totalMeetings += frequency
        }
        
        // Normalize preferences
        if totalMeetings > 0 {
            for hour in hourPreferences.keys {
                hourPreferences[hour]! = hourPreferences[hour]! / Double(totalMeetings)
            }
            for day in dayPreferences.keys {
                dayPreferences[day]! = dayPreferences[day]! / Double(totalMeetings)
            }
        }
        
        return ParticipantPreferences(
            preferredHours: hourPreferences,
            preferredDays: dayPreferences,
            meetingFrequency: totalMeetings,
            averageMeetingDuration: calculateAverageMeetingDuration(participant)
        )
    }
    
    private func generateCandidateSlots(
        participants: [String],
        duration: TimeInterval,
        availability: [String: [TimeRange]],
        preferences: [String: ParticipantPreferences],
        preferredTimeRanges: [TimeRange]?,
        excludeWeekends: Bool
    ) -> [MeetingSlot] {
        
        var candidates: [MeetingSlot] = []
        let calendar = Calendar.current
        
        // Generate slots for next 14 days
        for dayOffset in 0..<14 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            
            let weekday = calendar.component(.weekday, from: date)
            if excludeWeekends && (weekday == 1 || weekday == 7) { continue }
            
            // Generate hourly slots during business hours
            for hour in 8..<18 {
                guard let slotStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else { continue }
                let slotEnd = slotStart.addingTimeInterval(duration)
                let timeRange = TimeRange(start: slotStart, end: slotEnd)
                
                // Check if all participants are available
                let isAvailable = participants.allSatisfy { participant in
                    let busyTimes = availability[participant] ?? []
                    return !busyTimes.contains { $0.overlaps(with: timeRange) }
                }
                
                if isAvailable {
                    let slot = MeetingSlot(
                        startTime: slotStart,
                        endTime: slotEnd,
                        participants: participants,
                        confidence: 0.5 // Base confidence, will be updated by scoring
                    )
                    candidates.append(slot)
                }
            }
        }
        
        // Filter by preferred time ranges if specified
        if let preferredRanges = preferredTimeRanges {
            candidates = candidates.filter { slot in
                preferredRanges.contains { range in
                    range.overlaps(with: TimeRange(start: slot.startTime, end: slot.endTime))
                }
            }
        }
        
        return candidates
    }
    
    private func scoreSlots(_ slots: [MeetingSlot], preferences: [String: ParticipantPreferences]) async -> [MeetingSlot] {
        return slots.map { slot in
            let score = calculateSlotScore(slot, preferences: preferences)
            return MeetingSlot(
                startTime: slot.startTime,
                endTime: slot.endTime,
                participants: slot.participants,
                confidence: score
            )
        }.sorted { $0.confidence > $1.confidence }
    }
    
    private func calculateSlotScore(_ slot: MeetingSlot, preferences: [String: ParticipantPreferences]) -> Double {
        var totalScore: Double = 0
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: slot.startTime)
        let weekday = calendar.component(.weekday, from: slot.startTime)
        
        for participant in slot.participants {
            guard let pref = preferences[participant] else { continue }
            
            var participantScore: Double = 0.5 // Base score
            
            // Hour preference scoring
            if let hourPref = pref.preferredHours[hour] {
                participantScore += hourPref * 0.3
            }
            
            // Day preference scoring
            if let dayPref = pref.preferredDays[weekday] {
                participantScore += dayPref * 0.2
            }
            
            // General time preferences
            if hour >= 9 && hour <= 11 { // Morning preference
                participantScore += 0.1
            } else if hour >= 14 && hour <= 16 { // Early afternoon
                participantScore += 0.05
            }
            
            // Avoid lunch time
            if hour == 12 || hour == 13 {
                participantScore -= 0.15
            }
            
            totalScore += participantScore
        }
        
        return min(totalScore / Double(slot.participants.count), 1.0)
    }
    
    private func generateBaseRecurringSlots(
        duration: TimeInterval,
        preferences: [String: ParticipantPreferences],
        excludeWeekends: Bool
    ) -> [MeetingSlot] {
        
        var baseSlots: [MeetingSlot] = []
        let calendar = Calendar.current
        let today = Date()
        
        // Generate slots for each day of the week and common hours
        for weekday in (excludeWeekends ? 2...6 : 1...7) {
            for hour in 9...17 {
                guard let date = calendar.nextDate(after: today, matching: DateComponents(hour: hour, weekday: weekday), matchingPolicy: .nextTime) else { continue }
                
                let endTime = date.addingTimeInterval(duration)
                baseSlots.append(MeetingSlot(
                    startTime: date,
                    endTime: endTime,
                    participants: [], // Will be filled later
                    confidence: 0.5
                ))
            }
        }
        
        return baseSlots
    }
    
    private func checkRecurringConflicts(
        baseTime: MeetingSlot,
        participants: [String],
        pattern: RecurrencePattern,
        startDate: Date,
        occurrences: Int,
        duration: TimeInterval
    ) async throws -> RecurrenceConflictSummary {
        
        var conflictCount = 0
        var conflictedParticipants: Set<String> = []
        
        for i in 0..<occurrences {
            let calendar = Calendar.current
            let occurrenceDate = pattern.nextDate(after: startDate, occurrence: i, calendar: calendar)
            let timeRange = TimeRange(
                start: occurrenceDate,
                end: occurrenceDate.addingTimeInterval(duration)
            )
            
            let conflicts = try await conflictDetector.findConflicts(
                participants: participants,
                timeRange: timeRange
            )
            
            if !conflicts.isEmpty {
                conflictCount += 1
                conflictedParticipants.formUnion(conflicts.map { $0.participant })
            }
        }
        
        return RecurrenceConflictSummary(
            totalOccurrences: occurrences,
            conflictedOccurrences: conflictCount,
            conflictedParticipants: Array(conflictedParticipants),
            conflictPercentage: Double(conflictCount) / Double(occurrences)
        )
    }
    
    private func calculateRecurringScore(_ baseSlot: MeetingSlot, conflicts: RecurrenceConflictSummary, preferences: [String: ParticipantPreferences]) -> Double {
        let baseScore = calculateSlotScore(baseSlot, preferences: preferences)
        let conflictPenalty = conflicts.conflictPercentage * 0.5
        return max(baseScore - conflictPenalty, 0.1)
    }
    
    private func generateNearbySlots(
        originalSlot: MeetingSlot,
        constraints: ReschedulingConstraints,
        availability: [String: [TimeRange]]
    ) -> [MeetingSlot] {
        
        var alternatives: [MeetingSlot] = []
        let calendar = Calendar.current
        
        // Generate slots within time constraints
        for dayOffset in -constraints.maxDaysFromOriginal...constraints.maxDaysFromOriginal {
            guard let newDate = calendar.date(byAdding: .day, value: dayOffset, to: originalSlot.startTime) else { continue }
            
            for hourOffset in -4...4 { // Within 4 hours of original time
                guard let newStartTime = calendar.date(byAdding: .hour, value: hourOffset, to: newDate) else { continue }
                
                let duration = originalSlot.endTime.timeIntervalSince(originalSlot.startTime)
                let newEndTime = newStartTime.addingTimeInterval(duration)
                let timeRange = TimeRange(start: newStartTime, end: newEndTime)
                
                // Check availability for all participants
                let isAvailable = originalSlot.participants.allSatisfy { participant in
                    let busyTimes = availability[participant] ?? []
                    return !busyTimes.contains { $0.overlaps(with: timeRange) }
                }
                
                if isAvailable {
                    alternatives.append(MeetingSlot(
                        startTime: newStartTime,
                        endTime: newEndTime,
                        participants: originalSlot.participants,
                        confidence: 0.5
                    ))
                }
            }
        }
        
        return alternatives
    }
    
    private func scoreRescheduleSlots(
        alternatives: [MeetingSlot],
        originalSlot: MeetingSlot,
        conflictedParticipants: [String],
        availableParticipants: [String]
    ) async -> [MeetingSlot] {
        
        return alternatives.map { slot in
            var score: Double = 0.5
            
            // Minimize time difference from original
            let timeDiff = abs(slot.startTime.timeIntervalSince(originalSlot.startTime))
            let daysDiff = timeDiff / (24 * 3600)
            score -= min(daysDiff * 0.1, 0.3) // Max 0.3 penalty
            
            // Prefer keeping same day of week
            let calendar = Calendar.current
            let originalWeekday = calendar.component(.weekday, from: originalSlot.startTime)
            let newWeekday = calendar.component(.weekday, from: slot.startTime)
            if originalWeekday == newWeekday {
                score += 0.1
            }
            
            // Prefer keeping similar time of day
            let originalHour = calendar.component(.hour, from: originalSlot.startTime)
            let newHour = calendar.component(.hour, from: slot.startTime)
            let hourDiff = abs(newHour - originalHour)
            score -= Double(hourDiff) * 0.02
            
            return MeetingSlot(
                startTime: slot.startTime,
                endTime: slot.endTime,
                participants: slot.participants,
                confidence: max(score, 0.1)
            )
        }.sorted { $0.confidence > $1.confidence }
    }
    
    private func findContinuousWindows(
        availability: [String: [TimeRange]],
        windowDuration: TimeInterval,
        flexibility: FlexibilityLevel
    ) -> [TimeRange] {
        
        // This is a simplified implementation
        // In practice, this would be more sophisticated
        var windows: [TimeRange] = []
        let calendar = Calendar.current
        
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            
            let dayStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
            let dayEnd = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: date) ?? date
            
            let window = TimeRange(start: dayStart, end: dayStart.addingTimeInterval(windowDuration))
            if window.end <= dayEnd {
                windows.append(window)
            }
        }
        
        return windows
    }
    
    private func generateSlotsInWindow(
        window: TimeRange,
        duration: TimeInterval,
        participants: [String],
        preferences: [String: ParticipantPreferences]
    ) -> [MeetingSlot] {
        
        var slots: [MeetingSlot] = []
        let interval: TimeInterval = 1800 // 30-minute intervals
        
        var currentTime = window.start
        while currentTime.addingTimeInterval(duration) <= window.end {
            let slot = MeetingSlot(
                startTime: currentTime,
                endTime: currentTime.addingTimeInterval(duration),
                participants: participants,
                confidence: calculateSlotScore(
                    MeetingSlot(startTime: currentTime, endTime: currentTime.addingTimeInterval(duration), participants: participants, confidence: 0.5),
                    preferences: preferences
                )
            )
            slots.append(slot)
            currentTime = currentTime.addingTimeInterval(interval)
        }
        
        return slots
    }
    
    private func calculateAverageMeetingDuration(_ participant: String) -> TimeInterval {
        let sql = """
            SELECT AVG(e.end_time - e.start_time) as avg_duration
            FROM events e
            WHERE e.attendees LIKE ? OR e.organizer_email = ?
        """
        
        let results = database.query(sql, parameters: ["%\(participant)%", participant])
        return results.first?["avg_duration"] as? TimeInterval ?? 3600 // Default 1 hour
    }
}

// MARK: - Data Structures

public struct MeetingSlot {
    public let startTime: Date
    public let endTime: Date
    public let participants: [String]
    public let confidence: Double
}

public struct ParticipantPreferences {
    let preferredHours: [Int: Double]
    let preferredDays: [Int: Double]
    let meetingFrequency: Int
    let averageMeetingDuration: TimeInterval
}

public struct RecurringMeetingProposal {
    let baseSlot: MeetingSlot
    let pattern: RecurrencePattern
    let participants: [String]
    let conflictSummary: RecurrenceConflictSummary
    let score: Double
}

public struct RecurrenceConflictSummary {
    let totalOccurrences: Int
    let conflictedOccurrences: Int
    let conflictedParticipants: [String]
    let conflictPercentage: Double
}

public struct ReschedulingConstraints {
    let maxDaysFromOriginal: Int
    let maxHoursFromOriginal: Int
    let mustKeepSameDayOfWeek: Bool
    let mustKeepSameTimeOfDay: Bool
    
    static let flexible = ReschedulingConstraints(
        maxDaysFromOriginal: 7,
        maxHoursFromOriginal: 8,
        mustKeepSameDayOfWeek: false,
        mustKeepSameTimeOfDay: false
    )
    
    static let strict = ReschedulingConstraints(
        maxDaysFromOriginal: 2,
        maxHoursFromOriginal: 2,
        mustKeepSameDayOfWeek: true,
        mustKeepSameTimeOfDay: true
    )
}

public struct MeetingWindow {
    let timeRange: TimeRange
    let participants: [String]
    let availableSlots: [MeetingSlot]
    let flexibility: FlexibilityLevel
    
    var score: Double {
        return availableSlots.map { $0.confidence }.max() ?? 0.0
    }
}

public enum FlexibilityLevel {
    case low
    case medium
    case high
}