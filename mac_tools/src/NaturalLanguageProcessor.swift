import Foundation

public enum QueryIntent {
    case search(SearchQuery)
    case filter(FilterQuery)  
    case ask(QuestionQuery)
    case command(CommandQuery)
}

public struct SearchQuery {
    public let content: String
    public let entityFilters: [EntityFilter]
    public let timeFilter: TimeFilter?
    public let sourceFilter: [String]?
    public let limit: Int
}

public struct FilterQuery {
    public let baseQuery: String
    public let filters: [QueryFilter]
}

public struct QuestionQuery {
    public let question: String
    public let context: String?
    public let expectedAnswerType: AnswerType
}

public struct CommandQuery {
    public let action: ActionType
    public let target: String
    public let parameters: [String: Any]
}

public enum EntityFilter {
    case person(String)
    case location(String) 
    case topic(String)
    case organization(String)
}

public enum TimeFilter {
    case relative(RelativeTime)
    case absolute(DateRange)
    case keyword(String) // "last month", "this week", etc.
}

public enum RelativeTime {
    case lastDays(Int)
    case lastWeeks(Int)
    case lastMonths(Int)
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
}

public struct DateRange {
    let start: Date
    let end: Date
}

public enum QueryFilter {
    case contentType([String])
    case dateRange(DateRange)
    case sender(String)
    case recipient(String)
    case hasAttachments(Bool)
}

public enum AnswerType {
    case person
    case date
    case location
    case summary
    case count
    case list
}

public enum ActionType {
    case draft
    case schedule
    case create
    case update
    case delete
}

public class NaturalLanguageProcessor {
    private let patterns: [QueryPattern]
    
    public init() {
        self.patterns = Self.buildPatterns()
    }
    
    public func parseQuery(_ query: String) -> QueryIntent {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to match against known patterns
        for pattern in patterns {
            if let intent = pattern.match(normalizedQuery) {
                return intent
            }
        }
        
        // Fallback to general search
        return .search(SearchQuery(
            content: query,
            entityFilters: extractEntities(from: normalizedQuery),
            timeFilter: extractTimeFilter(from: normalizedQuery),
            sourceFilter: extractSourceFilter(from: normalizedQuery),
            limit: 10
        ))
    }
    
    private func extractEntities(from query: String) -> [EntityFilter] {
        var entities: [EntityFilter] = []
        
        // Extract person names (capitalized words or quoted names)
        let personPatterns = [
            #"\\b[A-Z][a-z]+\\b"#,  // Capitalized words
            #""([^"]+)""#             // Quoted names
        ]
        
        for pattern in personPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: query, options: [], range: NSRange(location: 0, length: query.count))
                for match in matches {
                    if let range = Range(match.range, in: query) {
                        let name = String(query[range])
                        if isLikelyPersonName(name) {
                            entities.append(.person(name))
                        }
                    }
                }
            }
        }
        
        // Extract topics/subjects
        let topicKeywords = ["about", "regarding", "concerning", "on", "re:"]
        for keyword in topicKeywords {
            if let range = query.range(of: keyword) {
                let afterKeyword = String(query[range.upperBound...])
                let topic = afterKeyword.components(separatedBy: .whitespacesAndNewlines)
                    .prefix(3)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty {
                    entities.append(.topic(topic))
                }
            }
        }
        
        return entities
    }
    
    private func extractTimeFilter(from query: String) -> TimeFilter? {
        let timePatterns: [(String, RelativeTime)] = [
            ("today", .today),
            ("yesterday", .yesterday),
            ("this week", .thisWeek),
            ("last week", .lastWeek),
            ("this month", .thisMonth),
            ("last month", .lastMonth),
            ("last 7 days", .lastDays(7)),
            ("last week", .lastDays(7)),
            ("last 30 days", .lastDays(30)),
            ("last month", .lastDays(30))
        ]
        
        for (pattern, time) in timePatterns {
            if query.contains(pattern) {
                return .relative(time)
            }
        }
        
        return nil
    }
    
    private func extractSourceFilter(from query: String) -> [String]? {
        let sourceKeywords: [String: [String]] = [
            "messages": ["Messages", "message"],
            "emails": ["Mail", "email"],
            "calendar": ["Calendar", "Events", "event"],
            "contacts": ["Contacts", "contact"],
            "notes": ["Notes", "note"],
            "files": ["Files", "file"]
        ]
        
        for (keyword, sources) in sourceKeywords {
            if query.contains(keyword) {
                return sources
            }
        }
        
        return nil
    }
    
    private func isLikelyPersonName(_ name: String) -> Bool {
        // Simple heuristics for person names
        let commonWords = ["the", "and", "or", "but", "with", "about", "from", "to", "in", "on", "at", "by"]
        return !commonWords.contains(name.lowercased()) && 
               name.count > 2 && 
               name.first?.isUppercase == true
    }
    
    private static func buildPatterns() -> [QueryPattern] {
        return [
            // Search patterns
            QueryPattern(
                regex: #"show me (messages|emails|events|contacts|files) about (.+)"#,
                builder: { matches in
                    let sourceType = matches[1]
                    let topic = matches[2]
                    return .search(SearchQuery(
                        content: topic,
                        entityFilters: [.topic(topic)],
                        timeFilter: nil,
                        sourceFilter: [sourceType.capitalized],
                        limit: 20
                    ))
                }
            ),
            
            // Person + content patterns
            QueryPattern(
                regex: #"(messages|emails) from ([A-Za-z ]+) about (.+)"#,
                builder: { matches in
                    let sourceType = matches[1]
                    let person = matches[2]
                    let topic = matches[3]
                    return .search(SearchQuery(
                        content: topic,
                        entityFilters: [.person(person), .topic(topic)],
                        timeFilter: nil,
                        sourceFilter: [sourceType.capitalized],
                        limit: 10
                    ))
                }
            ),
            
            // Question patterns
            QueryPattern(
                regex: #"(who|what|when|where) (was|is|were|are) (.+)\\?"#,
                builder: { matches in
                    let questionWord = matches[1]
                    let context = matches[3]
                    let answerType: AnswerType = {
                        switch questionWord {
                        case "who": return .person
                        case "when": return .date
                        case "where": return .location
                        default: return .summary
                        }
                    }()
                    return .ask(QuestionQuery(
                        question: context,
                        context: nil,
                        expectedAnswerType: answerType
                    ))
                }
            ),
            
            // Time-based patterns
            QueryPattern(
                regex: #"(.+) (last month|this week|yesterday|today)"#,
                builder: { matches in
                    let content = matches[1]
                    let timePhrase = matches[2]
                    let timeFilter: RelativeTime = {
                        switch timePhrase {
                        case "last month": return .lastMonth
                        case "this week": return .thisWeek
                        case "yesterday": return .yesterday
                        case "today": return .today
                        default: return .lastWeek
                        }
                    }()
                    return .search(SearchQuery(
                        content: content,
                        entityFilters: [],
                        timeFilter: .relative(timeFilter),
                        sourceFilter: nil,
                        limit: 15
                    ))
                }
            )
        ]
    }
}

private struct QueryPattern {
    let regex: NSRegularExpression
    let builder: ([String]) -> QueryIntent
    
    init(regex pattern: String, builder: @escaping ([String]) -> QueryIntent) {
        self.regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        self.builder = builder
    }
    
    func match(_ query: String) -> QueryIntent? {
        let matches = regex.matches(in: query, options: [], range: NSRange(location: 0, length: query.count))
        
        guard let match = matches.first else { return nil }
        
        var captureGroups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let range = Range(match.range(at: i), in: query) {
                captureGroups.append(String(query[range]))
            }
        }
        
        return builder(captureGroups)
    }
}

// MARK: - Query Execution Engine

public class QueryExecutor {
    private let hybridSearch: HybridSearch
    private let database: Database
    
    public init(hybridSearch: HybridSearch, database: Database) {
        self.hybridSearch = hybridSearch
        self.database = database
    }
    
    public func execute(_ intent: QueryIntent) async throws -> QueryResult {
        switch intent {
        case .search(let searchQuery):
            return try await executeSearch(searchQuery)
        case .filter(let filterQuery):
            return try await executeFilter(filterQuery)
        case .ask(let questionQuery):
            return try await executeQuestion(questionQuery)
        case .command(let commandQuery):
            return try await executeCommand(commandQuery)
        }
    }
    
    private func executeSearch(_ query: SearchQuery) async throws -> QueryResult {
        // Build enhanced search query
        var searchTerms = [query.content]
        
        // Add entity filters to search terms
        for entity in query.entityFilters {
            switch entity {
            case .person(let name):
                searchTerms.append(name)
            case .topic(let topic):
                searchTerms.append(topic)
            case .location(let location):
                searchTerms.append(location)
            case .organization(let org):
                searchTerms.append(org)
            }
        }
        
        let searchQuery = searchTerms.joined(separator: " ")
        let results = try await hybridSearch.search(query: searchQuery, limit: query.limit)
        
        // Apply post-search filtering
        let filteredResults = applyFilters(results, query: query)
        
        return .search(NLPSearchResult(
            query: query.content,
            results: filteredResults,
            totalCount: filteredResults.count,
            appliedFilters: describeFilters(query)
        ))
    }
    
    private func executeFilter(_ query: FilterQuery) async throws -> QueryResult {
        // Implementation for filter queries
        let results = try await hybridSearch.search(query: query.baseQuery)
        return .search(NLPSearchResult(
            query: query.baseQuery,
            results: results,
            totalCount: results.count,
            appliedFilters: []
        ))
    }
    
    private func executeQuestion(_ query: QuestionQuery) async throws -> QueryResult {
        // Implementation for question answering
        let searchResults = try await hybridSearch.search(query: query.question, limit: 5)
        
        return .answer(AnswerResult(
            question: query.question,
            answer: generateAnswer(from: searchResults, type: query.expectedAnswerType),
            confidence: 0.8,
            sources: searchResults
        ))
    }
    
    private func executeCommand(_ query: CommandQuery) async throws -> QueryResult {
        // Implementation for commands (draft email, schedule meeting, etc.)
        return .command(CommandResult(
            action: query.action,
            status: "not_implemented",
            message: "Command execution not yet implemented"
        ))
    }
    
    private func applyFilters(_ results: [HybridSearchResult], query: SearchQuery) -> [HybridSearchResult] {
        var filtered = results
        
        // Apply source filter
        if let sourceFilter = query.sourceFilter, !sourceFilter.isEmpty {
            filtered = filtered.filter { result in
                sourceFilter.contains { source in
                    result.appSource.lowercased().contains(source.lowercased())
                }
            }
        }
        
        // Apply time filter (would need document timestamps)
        // if let timeFilter = query.timeFilter {
        //     // Implementation depends on document timestamp fields
        // }
        
        return filtered
    }
    
    private func describeFilters(_ query: SearchQuery) -> [String] {
        var filters: [String] = []
        
        for entity in query.entityFilters {
            switch entity {
            case .person(let name):
                filters.append("Person: \(name)")
            case .topic(let topic):
                filters.append("Topic: \(topic)")
            case .location(let location):
                filters.append("Location: \(location)")
            case .organization(let org):
                filters.append("Organization: \(org)")
            }
        }
        
        if let sourceFilter = query.sourceFilter {
            filters.append("Sources: \(sourceFilter.joined(separator: ", "))")
        }
        
        if let timeFilter = query.timeFilter {
            switch timeFilter {
            case .relative(let relTime):
                filters.append("Time: \(describeRelativeTime(relTime))")
            case .absolute(let range):
                filters.append("Date range: \(range.start) - \(range.end)")
            case .keyword(let keyword):
                filters.append("Time: \(keyword)")
            }
        }
        
        return filters
    }
    
    private func describeRelativeTime(_ time: RelativeTime) -> String {
        switch time {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .lastDays(let days): return "Last \(days) days"
        case .lastWeeks(let weeks): return "Last \(weeks) weeks"
        case .lastMonths(let months): return "Last \(months) months"
        }
    }
    
    private func generateAnswer(from results: [HybridSearchResult], type: AnswerType) -> String {
        switch type {
        case .person:
            let people = results.compactMap { result in
                result.title.contains("Message from") ? extractPersonFromTitle(result.title) : nil
            }.prefix(3)
            return people.isEmpty ? "No specific people found" : people.joined(separator: ", ")
            
        case .count:
            return "Found \(results.count) results"
            
        case .summary:
            let topResult = results.first
            return topResult?.snippet ?? "No summary available"
            
        case .date, .location, .list:
            return "Answer type not fully implemented yet"
        }
    }
    
    private func extractPersonFromTitle(_ title: String) -> String? {
        if title.hasPrefix("Message from ") {
            let name = title.replacingOccurrences(of: "Message from ", with: "")
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

// MARK: - Results

public enum QueryResult {
    case search(NLPSearchResult)
    case answer(AnswerResult)
    case command(CommandResult)
}

public struct NLPSearchResult {
    public let query: String
    public let results: [HybridSearchResult]
    public let totalCount: Int
    public let appliedFilters: [String]
}

public struct AnswerResult {
    public let question: String
    public let answer: String
    public let confidence: Double
    public let sources: [HybridSearchResult]
}

public struct CommandResult {
    public let action: ActionType
    public let status: String
    public let message: String
}