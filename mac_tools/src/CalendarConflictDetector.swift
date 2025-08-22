import Foundation

/// CalendarConflictDetector: Intelligent scheduling conflict identification
/// Analyzes calendar events, participant availability, and time zones to detect conflicts
public class CalendarConflictDetector {
    private let database: Database
    
    public init(database: Database) {
        self.database = database
    }
    
    // MARK: - Conflict Detection
    
    /// Find scheduling conflicts for proposed meeting time and participants
    public func findConflicts(participants: [String], timeRange: TimeRange) async throws -> [CalendarConflict] {
        var conflicts: [CalendarConflict] = []
        
        // Check each participant's calendar for conflicts
        for participant in participants {
            let participantConflicts = try await findParticipantConflicts(
                participant: participant,
                timeRange: timeRange
            )
            conflicts.append(contentsOf: participantConflicts)
        }
        
        // Check for meeting room conflicts if location is specified
        // This would be enhanced with room booking system integration
        
        return conflicts.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }
    
    /// Find all busy times for participants in a given date range
    public func getParticipantAvailability(
        participants: [String],
        dateRange: DateInterval
    ) async throws -> [String: [BusyTime]] {
        
        var availability: [String: [BusyTime]] = [:]
        
        for participant in participants {
            availability[participant] = try await getBusyTimes(
                participant: participant,
                dateRange: dateRange
            )
        }
        
        return availability
    }
    
    /// Identify optimal meeting windows for multiple participants
    public func findAvailableSlots(
        participants: [String],
        duration: TimeInterval,
        dateRange: DateInterval,
        workingHours: WorkingHours = WorkingHours.standard
    ) async throws -> [AvailableSlot] {
        
        let availability = try await getParticipantAvailability(
            participants: participants,
            dateRange: dateRange
        )
        
        return calculateAvailableSlots(
            availability: availability,
            duration: duration,
            dateRange: dateRange,
            workingHours: workingHours
        )
    }
    
    /// Check for recurring meeting conflicts
    public func findRecurringConflicts(
        participants: [String],
        recurringPattern: RecurrencePattern,
        startDate: Date,
        duration: TimeInterval,
        occurrenceCount: Int = 52
    ) async throws -> [RecurringConflict] {
        
        var conflicts: [RecurringConflict] = []
        let calendar = Calendar.current
        
        for i in 0..<occurrenceCount {
            let occurrenceDate = recurringPattern.nextDate(after: startDate, occurrence: i, calendar: calendar)
            let timeRange = TimeRange(
                start: occurrenceDate,
                end: occurrenceDate.addingTimeInterval(duration)
            )
            
            let occurenceConflicts = try await findConflicts(
                participants: participants,
                timeRange: timeRange
            )
            
            if !occurenceConflicts.isEmpty {
                conflicts.append(RecurringConflict(
                    date: occurrenceDate,
                    occurrence: i + 1,
                    conflicts: occurenceConflicts
                ))
            }
        }
        
        return conflicts
    }
    
    // MARK: - Private Methods
    
    private func findParticipantConflicts(
        participant: String,
        timeRange: TimeRange
    ) async throws -> [CalendarConflict] {
        
        let sql = """
            SELECT 
                e.document_id, e.start_time, e.end_time, e.location, e.status,
                d.title, e.attendees, e.organizer_email, e.calendar_name
            FROM events e
            JOIN documents d ON e.document_id = d.id
            WHERE (
                e.attendees LIKE ? OR 
                e.organizer_email = ?
            )
            AND e.status != 'cancelled'
            AND e.start_time < ?
            AND e.end_time > ?
        """
        
        let results = database.query(sql, parameters: [
            "%\(participant)%",
            participant,
            Int(timeRange.end.timeIntervalSince1970),
            Int(timeRange.start.timeIntervalSince1970)
        ])
        
        return results.compactMap { row in
            guard let startTime = row["start_time"] as? Int,
                  let endTime = row["end_time"] as? Int,
                  let title = row["title"] as? String else {
                return nil
            }
            
            let conflictTimeRange = TimeRange(
                start: Date(timeIntervalSince1970: TimeInterval(startTime)),
                end: Date(timeIntervalSince1970: TimeInterval(endTime))
            )
            
            let severity = calculateConflictSeverity(
                proposedTime: timeRange,
                existingTime: conflictTimeRange,
                status: row["status"] as? String
            )
            
            return CalendarConflict(
                participant: participant,
                conflictingEvent: ConflictingEvent(
                    title: title,
                    timeRange: conflictTimeRange,
                    location: row["location"] as? String,
                    status: row["status"] as? String ?? "confirmed",
                    organizer: row["organizer_email"] as? String,
                    calendar: row["calendar_name"] as? String
                ),
                proposedTime: timeRange,
                severity: severity,
                resolutionSuggestions: generateResolutionSuggestions(
                    proposed: timeRange,
                    conflicting: conflictTimeRange,
                    severity: severity
                )
            )
        }
    }
    
    private func getBusyTimes(
        participant: String,
        dateRange: DateInterval
    ) async throws -> [BusyTime] {
        
        let sql = """
            SELECT e.start_time, e.end_time, d.title, e.status, e.location
            FROM events e
            JOIN documents d ON e.document_id = d.id
            WHERE (
                e.attendees LIKE ? OR 
                e.organizer_email = ?
            )
            AND e.status != 'cancelled'
            AND e.start_time >= ?
            AND e.start_time <= ?
            ORDER BY e.start_time
        """
        
        let results = database.query(sql, parameters: [
            "%\(participant)%",
            participant,
            Int(dateRange.start.timeIntervalSince1970),
            Int(dateRange.end.timeIntervalSince1970)
        ])
        
        return results.compactMap { row in
            guard let startTime = row["start_time"] as? Int,
                  let endTime = row["end_time"] as? Int,
                  let title = row["title"] as? String else {
                return nil
            }
            
            return BusyTime(
                timeRange: TimeRange(
                    start: Date(timeIntervalSince1970: TimeInterval(startTime)),
                    end: Date(timeIntervalSince1970: TimeInterval(endTime))
                ),
                title: title,
                location: row["location"] as? String,
                status: row["status"] as? String ?? "confirmed"
            )
        }
    }
    
    private func calculateAvailableSlots(
        availability: [String: [BusyTime]],
        duration: TimeInterval,
        dateRange: DateInterval,
        workingHours: WorkingHours
    ) -> [AvailableSlot] {
        
        var availableSlots: [AvailableSlot] = []
        let calendar = Calendar.current
        let timeZone = TimeZone.current
        
        // Iterate through each day in the date range
        var currentDate = dateRange.start
        while currentDate < dateRange.end {
            // Skip weekends if specified
            let weekday = calendar.component(.weekday, from: currentDate)
            if workingHours.excludeWeekends && (weekday == 1 || weekday == 7) {
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
                continue
            }
            
            // Get working hours for this day
            let dayStart = calendar.date(bySettingHour: workingHours.startHour, minute: 0, second: 0, of: currentDate) ?? currentDate
            let dayEnd = calendar.date(bySettingHour: workingHours.endHour, minute: 0, second: 0, of: currentDate) ?? currentDate
            
            // Find available slots during this day
            let daySlots = findDayAvailableSlots(
                date: currentDate,
                dayStart: dayStart,
                dayEnd: dayEnd,
                duration: duration,
                allBusyTimes: availability
            )
            
            availableSlots.append(contentsOf: daySlots)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        
        return availableSlots.sorted { $0.score > $1.score }
    }
    
    private func findDayAvailableSlots(
        date: Date,
        dayStart: Date,
        dayEnd: Date,
        duration: TimeInterval,
        allBusyTimes: [String: [BusyTime]]
    ) -> [AvailableSlot] {
        
        // Combine all participants' busy times for this day
        var allBusy: [TimeRange] = []
        for busyTimes in allBusyTimes.values {
            let dayBusy = busyTimes.filter { busyTime in
                busyTime.timeRange.start >= dayStart && busyTime.timeRange.start < dayEnd
            }.map { $0.timeRange }
            allBusy.append(contentsOf: dayBusy)
        }
        
        // Sort and merge overlapping busy times
        let mergedBusy = mergeOverlappingTimes(allBusy.sorted { $0.start < $1.start })
        
        var availableSlots: [AvailableSlot] = []
        var currentTime = dayStart
        
        for busyTime in mergedBusy {
            // Check if there's a gap before this busy time
            if currentTime < busyTime.start {
                let gapDuration = busyTime.start.timeIntervalSince(currentTime)
                if gapDuration >= duration {
                    // Calculate optimal start time within this gap
                    let optimalStart = calculateOptimalSlotStart(
                        gapStart: currentTime,
                        gapEnd: busyTime.start,
                        duration: duration
                    )
                    
                    let slot = AvailableSlot(
                        timeRange: TimeRange(
                            start: optimalStart,
                            end: optimalStart.addingTimeInterval(duration)
                        ),
                        participants: Array(allBusyTimes.keys),
                        score: calculateSlotScore(
                            time: optimalStart,
                            duration: duration,
                            busyTimes: allBusyTimes
                        )
                    )
                    availableSlots.append(slot)
                }
            }
            
            currentTime = max(currentTime, busyTime.end)
        }
        
        // Check for availability after the last busy time
        if currentTime < dayEnd {
            let remainingDuration = dayEnd.timeIntervalSince(currentTime)
            if remainingDuration >= duration {
                let optimalStart = calculateOptimalSlotStart(
                    gapStart: currentTime,
                    gapEnd: dayEnd,
                    duration: duration
                )
                
                let slot = AvailableSlot(
                    timeRange: TimeRange(
                        start: optimalStart,
                        end: optimalStart.addingTimeInterval(duration)
                    ),
                    participants: Array(allBusyTimes.keys),
                    score: calculateSlotScore(
                        time: optimalStart,
                        duration: duration,
                        busyTimes: allBusyTimes
                    )
                )
                availableSlots.append(slot)
            }
        }
        
        return availableSlots
    }
    
    private func calculateConflictSeverity(
        proposedTime: TimeRange,
        existingTime: TimeRange,
        status: String?
    ) -> ConflictSeverity {
        
        let overlapDuration = min(proposedTime.end, existingTime.end).timeIntervalSince(max(proposedTime.start, existingTime.start))
        let proposedDuration = proposedTime.end.timeIntervalSince(proposedTime.start)
        let overlapPercentage = overlapDuration / proposedDuration
        
        if status == "tentative" && overlapPercentage < 0.5 {
            return .minor
        } else if overlapPercentage >= 0.8 {
            return .critical
        } else if overlapPercentage >= 0.5 {
            return .major
        } else {
            return .minor
        }
    }
    
    private func generateResolutionSuggestions(
        proposed: TimeRange,
        conflicting: TimeRange,
        severity: ConflictSeverity
    ) -> [String] {
        
        var suggestions: [String] = []
        
        switch severity {
        case .critical:
            suggestions.append("Move meeting to different time slot")
            suggestions.append("Reschedule conflicting appointment if possible")
        case .major:
            suggestions.append("Consider shortening meeting duration")
            suggestions.append("Move to earlier or later time")
        case .minor:
            suggestions.append("Check if conflicting event can be moved")
            suggestions.append("Consider if participant can attend both")
        }
        
        // Add time-specific suggestions
        if proposed.start < conflicting.start {
            suggestions.append("End meeting before \(formatTime(conflicting.start))")
        } else {
            suggestions.append("Start meeting after \(formatTime(conflicting.end))")
        }
        
        return suggestions
    }
    
    private func mergeOverlappingTimes(_ times: [TimeRange]) -> [TimeRange] {
        guard !times.isEmpty else { return [] }
        
        var merged: [TimeRange] = [times.first!]
        
        for current in times.dropFirst() {
            let last = merged.removeLast()
            
            if last.end >= current.start {
                // Overlapping - merge them
                merged.append(TimeRange(
                    start: last.start,
                    end: max(last.end, current.end)
                ))
            } else {
                // Non-overlapping - keep both
                merged.append(last)
                merged.append(current)
            }
        }
        
        return merged
    }
    
    private func calculateOptimalSlotStart(
        gapStart: Date,
        gapEnd: Date,
        duration: TimeInterval
    ) -> Date {
        
        let gapDuration = gapEnd.timeIntervalSince(gapStart)
        let extraTime = gapDuration - duration
        
        if extraTime <= 900 { // 15 minutes or less - use start of gap
            return gapStart
        } else {
            // Position meeting optimally within gap (preferring earlier times)
            let offset = min(extraTime * 0.3, 1800) // Max 30 minute offset or 30% of extra time
            return gapStart.addingTimeInterval(offset)
        }
    }
    
    private func calculateSlotScore(
        time: Date,
        duration: TimeInterval,
        busyTimes: [String: [BusyTime]]
    ) -> Double {
        
        var score: Double = 0.5 // Base score
        
        let hour = Calendar.current.component(.hour, from: time)
        
        // Prefer times during typical working hours
        if hour >= 9 && hour <= 17 {
            score += 0.3
        } else if hour >= 8 && hour <= 18 {
            score += 0.1
        }
        
        // Prefer morning meetings slightly
        if hour >= 9 && hour <= 11 {
            score += 0.1
        }
        
        // Avoid lunch hours
        if hour >= 12 && hour <= 13 {
            score -= 0.2
        }
        
        // Bonus for having buffer time around the meeting
        let bufferTime: TimeInterval = 900 // 15 minutes
        let startWithBuffer = time.addingTimeInterval(-bufferTime)
        let endWithBuffer = time.addingTimeInterval(duration + bufferTime)
        
        let hasStartBuffer = !busyTimes.values.flatMap { $0 }.contains { busyTime in
            busyTime.timeRange.overlaps(with: TimeRange(start: startWithBuffer, end: time))
        }
        
        let hasEndBuffer = !busyTimes.values.flatMap { $0 }.contains { busyTime in
            busyTime.timeRange.overlaps(with: TimeRange(start: time.addingTimeInterval(duration), end: endWithBuffer))
        }
        
        if hasStartBuffer { score += 0.1 }
        if hasEndBuffer { score += 0.1 }
        
        return min(score, 1.0)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Data Structures

public struct CalendarConflict {
    public let participant: String
    public let conflictingEvent: ConflictingEvent
    public let proposedTime: TimeRange
    public let severity: ConflictSeverity
    public let resolutionSuggestions: [String]
}

public struct ConflictingEvent {
    public let title: String
    public let timeRange: TimeRange
    public let location: String?
    public let status: String
    public let organizer: String?
    public let calendar: String?
}

public enum ConflictSeverity: Int, CaseIterable {
    case minor = 1
    case major = 2
    case critical = 3
}

public struct BusyTime {
    let timeRange: TimeRange
    let title: String
    let location: String?
    let status: String
}

public struct AvailableSlot {
    let timeRange: TimeRange
    let participants: [String]
    let score: Double
}

public struct WorkingHours {
    let startHour: Int
    let endHour: Int
    let excludeWeekends: Bool
    
    public static let standard = WorkingHours(startHour: 9, endHour: 17, excludeWeekends: true)
    public static let flexible = WorkingHours(startHour: 8, endHour: 18, excludeWeekends: false)
}

public struct RecurrencePattern {
    let frequency: RecurrenceFrequency
    let interval: Int
    let daysOfWeek: [Int]? // 1 = Sunday, 2 = Monday, etc.
    
    func nextDate(after startDate: Date, occurrence: Int, calendar: Calendar) -> Date {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval * occurrence, to: startDate) ?? startDate
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: interval * occurrence, to: startDate) ?? startDate
        case .monthly:
            return calendar.date(byAdding: .month, value: interval * occurrence, to: startDate) ?? startDate
        }
    }
}

public enum RecurrenceFrequency {
    case daily
    case weekly
    case monthly
}

public struct RecurringConflict {
    let date: Date
    let occurrence: Int
    let conflicts: [CalendarConflict]
}