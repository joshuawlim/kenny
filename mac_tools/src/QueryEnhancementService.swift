import Foundation
import os.log

// Import LLMWarmUpManager - assuming it's in the same module
// If it's in a separate module, this import may need adjustment

/// Enhanced query processing service that uses local LLM for query optimization
/// Provides query enhancement, intent detection, and entity extraction with caching
public class QueryEnhancementService {
    private let llmService: LLMService
    private let nlpProcessor: NaturalLanguageProcessor
    private let cacheManager: CacheManager
    private let timeoutInterval: TimeInterval = 2.0 // 2s timeout for local LLM
    private let logger = Logger(subsystem: "Kenny.QueryEnhancement", category: "Service")
    
    public init(
        llmService: LLMService = LLMService(),
        nlpProcessor: NaturalLanguageProcessor = NaturalLanguageProcessor(),
        cacheManager: CacheManager = CacheManager.shared
    ) {
        self.llmService = llmService
        self.nlpProcessor = nlpProcessor
        self.cacheManager = cacheManager
    }
    
    /// Enhance a user query with LLM-powered optimization and fallback to basic NLP
    public func enhanceQuery(_ query: String) async throws -> EnhancedQuery {
        let startTime = Date()
        
        // Try cache first
        if let cached = getCachedEnhancement(query) {
            PerformanceMonitor.shared.recordMetric(name: "query_enhancement.cache_hit", value: 1)
            return cached
        }
        
        // Automatically warm up LLM if not already warmed up (with quiet progress)
        let warmUpSuccess = await LLMWarmUpManager.shared.warmUpIfNeeded(llmService: llmService, showProgress: false)
        if !warmUpSuccess {
            logger.warning("LLM warm-up failed for query enhancement - falling back to basic NLP")
        }
        
        // Try LLM enhancement with timeout
        do {
            let enhanced = try await withTimeout(timeoutInterval) {
                try await self.enhanceWithLLM(query)
            }
            
            // Cache the result
            cacheEnhancement(query, enhanced)
            
            let duration = Date().timeIntervalSince(startTime)
            PerformanceMonitor.shared.recordMetric(name: "query_enhancement.llm_success", value: 1)
            PerformanceMonitor.shared.recordMetric(name: "query_enhancement.duration_ms", value: duration * 1000)
            
            return enhanced
        } catch {
            // Fallback to basic NLP processing
            logger.warning("LLM query enhancement failed, falling back to basic NLP: \(error.localizedDescription)")
            
            let basicEnhanced = enhanceWithBasicNLP(query)
            
            // Cache the fallback result with shorter TTL
            cacheEnhancement(query, basicEnhanced, ttl: 60) // 1 minute TTL for fallback
            
            let duration = Date().timeIntervalSince(startTime)
            PerformanceMonitor.shared.recordMetric(name: "query_enhancement.fallback", value: 1)
            PerformanceMonitor.shared.recordMetric(name: "query_enhancement.duration_ms", value: duration * 1000)
            
            return basicEnhanced
        }
    }
    
    /// Generate query variations for expanded search coverage
    public func generateQueryVariations(_ query: String, maxVariations: Int = 3) async throws -> [String] {
        let cacheKey = "variations:\(query.sha256())"
        
        if let cached: [String] = cacheManager.get(cacheKey, type: [String].self) {
            return cached
        }
        
        // Automatically warm up LLM if not already warmed up (with quiet progress)
        let warmUpSuccess = await LLMWarmUpManager.shared.warmUpIfNeeded(llmService: llmService, showProgress: false)
        if !warmUpSuccess {
            logger.warning("LLM warm-up failed for query variations - falling back to basic generation")
        }
        
        do {
            let variations = try await withTimeout(timeoutInterval) {
                try await self.generateVariationsWithLLM(query, maxVariations: maxVariations)
            }
            
            cacheManager.set(cacheKey, value: variations, ttl: 600) // 10 minutes
            return variations
        } catch {
            // Fallback to basic variations
            let variations = generateBasicVariations(query)
            cacheManager.set(cacheKey, value: variations, ttl: 300) // 5 minutes for fallback
            return variations
        }
    }
    
    // MARK: - LLM Enhancement
    
    private func enhanceWithLLM(_ query: String) async throws -> EnhancedQuery {
        let prompt = buildEnhancementPrompt(query)
        let response = try await llmService.generateResponse(prompt: prompt)
        
        return try parseEnhancementResponse(response, originalQuery: query)
    }
    
    private func generateVariationsWithLLM(_ query: String, maxVariations: Int) async throws -> [String] {
        let prompt = buildVariationsPrompt(query, maxVariations: maxVariations)
        let response = try await llmService.generateResponse(prompt: prompt)
        
        return try parseVariationsResponse(response)
    }
    
    private func buildEnhancementPrompt(_ query: String) -> String {
        return """
        Analyze this search query and enhance it for better search results.
        Return ONLY a JSON response with the following structure:
        
        {
            "enhanced_query": "optimized search terms",
            "intent": "search|filter|question|command",
            "entities": {
                "people": ["person names"],
                "topics": ["topic keywords"],
                "locations": ["places"],
                "organizations": ["companies/orgs"]
            },
            "time_filter": {
                "type": "relative|absolute|none",
                "value": "today|yesterday|this_week|last_month|etc"
            },
            "search_terms": ["key", "search", "terms"],
            "source_hints": ["mail|messages|calendar|contacts|notes|files"]
        }
        
        User query: "\(query)"
        
        Focus on extracting searchable terms and identifying user intent. Keep enhanced_query concise but comprehensive.
        """
    }
    
    private func buildVariationsPrompt(_ query: String, maxVariations: Int) -> String {
        return """
        Generate \(maxVariations) alternative phrasings of this search query that would find similar content.
        Return ONLY a JSON array of strings:
        
        ["alternative phrasing 1", "alternative phrasing 2", "alternative phrasing 3"]
        
        Original query: "\(query)"
        
        Make variations that use:
        - Synonyms and related terms
        - Different grammatical structures
        - More specific or general terms
        - Domain-specific terminology
        """
    }
    
    private func parseEnhancementResponse(_ response: String, originalQuery: String) throws -> EnhancedQuery {
        guard let data = response.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QueryEnhancementError.invalidLLMResponse("Could not parse JSON response")
        }
        
        let enhancedQuery = json["enhanced_query"] as? String ?? originalQuery
        let intentString = json["intent"] as? String ?? "search"
        let intent = QueryIntent.from(string: intentString)
        
        // Parse entities
        var entities: [EntityFilter] = []
        if let entitiesJson = json["entities"] as? [String: Any] {
            if let people = entitiesJson["people"] as? [String] {
                entities.append(contentsOf: people.map { EntityFilter.person($0) })
            }
            if let topics = entitiesJson["topics"] as? [String] {
                entities.append(contentsOf: topics.map { EntityFilter.topic($0) })
            }
            if let locations = entitiesJson["locations"] as? [String] {
                entities.append(contentsOf: locations.map { EntityFilter.location($0) })
            }
            if let orgs = entitiesJson["organizations"] as? [String] {
                entities.append(contentsOf: orgs.map { EntityFilter.organization($0) })
            }
        }
        
        // Parse time filter
        var timeFilter: TimeFilter?
        if let timeJson = json["time_filter"] as? [String: Any],
           let type = timeJson["type"] as? String,
           type != "none",
           let value = timeJson["value"] as? String {
            timeFilter = TimeFilter.from(type: type, value: value)
        }
        
        // Parse search terms and source hints
        let searchTerms = json["search_terms"] as? [String] ?? [enhancedQuery]
        let sourceHints = json["source_hints"] as? [String] ?? []
        
        return EnhancedQuery(
            originalQuery: originalQuery,
            enhancedQuery: enhancedQuery,
            intent: intent,
            entities: entities,
            timeFilter: timeFilter,
            searchTerms: searchTerms,
            sourceHints: sourceHints,
            enhancementMethod: .llm
        )
    }
    
    private func parseVariationsResponse(_ response: String) throws -> [String] {
        guard let data = response.data(using: .utf8),
              let variations = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw QueryEnhancementError.invalidLLMResponse("Could not parse variations JSON")
        }
        
        return variations
    }
    
    // MARK: - Fallback NLP Enhancement
    
    private func enhanceWithBasicNLP(_ query: String) -> EnhancedQuery {
        let intent = nlpProcessor.parseQuery(query)
        
        switch intent {
        case .search(let searchQuery):
            return EnhancedQuery(
                originalQuery: query,
                enhancedQuery: searchQuery.content,
                intent: .search,
                entities: searchQuery.entityFilters,
                timeFilter: searchQuery.timeFilter,
                searchTerms: extractSearchTerms(searchQuery.content),
                sourceHints: searchQuery.sourceFilter ?? [],
                enhancementMethod: .basicNLP
            )
        default:
            return EnhancedQuery(
                originalQuery: query,
                enhancedQuery: query,
                intent: .search,
                entities: [],
                timeFilter: nil,
                searchTerms: extractSearchTerms(query),
                sourceHints: [],
                enhancementMethod: .basicNLP
            )
        }
    }
    
    private func generateBasicVariations(_ query: String) -> [String] {
        let words = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
        var variations: [String] = []
        
        // Add synonym variations (basic)
        let synonyms: [String: [String]] = [
            "email": ["message", "mail", "correspondence"],
            "meeting": ["appointment", "call", "conference"],
            "contact": ["person", "colleague", "friend"],
            "document": ["file", "note", "text"],
            "project": ["work", "task", "assignment"]
        ]
        
        for (word, syns) in synonyms {
            if words.contains(word) {
                for synonym in syns.prefix(2) {
                    let variation = query.replacingOccurrences(of: word, with: synonym, options: .caseInsensitive)
                    variations.append(variation)
                }
            }
        }
        
        // Add more specific/general variations
        if query.count > 10 {
            let shortVersion = String(query.prefix(query.count / 2))
            variations.append(shortVersion.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return Array(variations.prefix(3)) // Limit to 3 variations
    }
    
    private func extractSearchTerms(_ query: String) -> [String] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
        
        let stopWords = Set(["the", "and", "or", "but", "with", "about", "from", "to", "in", "on", "at", "by"])
        return words.filter { !stopWords.contains($0) }
    }
    
    // MARK: - Caching
    
    private func getCachedEnhancement(_ query: String) -> EnhancedQuery? {
        let cacheKey = "enhancement:\(query.sha256())"
        return cacheManager.get(cacheKey, type: EnhancedQuery.self)
    }
    
    private func cacheEnhancement(_ query: String, _ enhanced: EnhancedQuery, ttl: TimeInterval = 1800) {
        let cacheKey = "enhancement:\(query.sha256())"
        cacheManager.set(cacheKey, value: enhanced, ttl: ttl) // 30 minutes default
    }
    
    // MARK: - Utilities
    
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw QueryEnhancementError.timeout
            }
            
            for try await result in group {
                group.cancelAll()
                return result
            }
            
            throw QueryEnhancementError.timeout
        }
    }
}

// MARK: - Data Structures

public struct EnhancedQuery: Codable {
    public let originalQuery: String
    public let enhancedQuery: String
    public let intent: QueryIntentType
    public let entities: [EntityFilter]
    public let timeFilter: TimeFilter?
    public let searchTerms: [String]
    public let sourceHints: [String]
    public let enhancementMethod: EnhancementMethod
    
    public init(
        originalQuery: String,
        enhancedQuery: String,
        intent: QueryIntentType,
        entities: [EntityFilter],
        timeFilter: TimeFilter?,
        searchTerms: [String],
        sourceHints: [String],
        enhancementMethod: EnhancementMethod
    ) {
        self.originalQuery = originalQuery
        self.enhancedQuery = enhancedQuery
        self.intent = intent
        self.entities = entities
        self.timeFilter = timeFilter
        self.searchTerms = searchTerms
        self.sourceHints = sourceHints
        self.enhancementMethod = enhancementMethod
    }
}

public enum QueryIntentType: String, Codable {
    case search = "search"
    case filter = "filter" 
    case question = "question"
    case command = "command"
}

public enum EnhancementMethod: String, Codable {
    case llm = "llm"
    case basicNLP = "basic_nlp"
}

// MARK: - Extensions

extension EntityFilter: Codable {
    enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        
        switch type {
        case "person": self = .person(value)
        case "location": self = .location(value)
        case "topic": self = .topic(value)
        case "organization": self = .organization(value)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown entity type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .person(let value):
            try container.encode("person", forKey: .type)
            try container.encode(value, forKey: .value)
        case .location(let value):
            try container.encode("location", forKey: .type)
            try container.encode(value, forKey: .value)
        case .topic(let value):
            try container.encode("topic", forKey: .type)
            try container.encode(value, forKey: .value)
        case .organization(let value):
            try container.encode("organization", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

extension TimeFilter: Codable {
    enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        
        switch type {
        case "relative":
            if let relTime = RelativeTime.from(string: value) {
                self = .relative(relTime)
            } else {
                self = .keyword(value)
            }
        case "keyword":
            self = .keyword(value)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown time filter type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .relative(let relTime):
            try container.encode("relative", forKey: .type)
            try container.encode(relTime.toString(), forKey: .value)
        case .keyword(let keyword):
            try container.encode("keyword", forKey: .type)
            try container.encode(keyword, forKey: .value)
        case .absolute:
            try container.encode("absolute", forKey: .type)
            try container.encode("date_range", forKey: .value) // Simplified for now
        }
    }
    
    public static func from(type: String, value: String) -> TimeFilter? {
        switch type {
        case "relative":
            if let relTime = RelativeTime.from(string: value) {
                return .relative(relTime)
            }
            return nil
        case "keyword":
            return .keyword(value)
        default:
            return nil
        }
    }
}

extension QueryIntent {
    public static func from(string: String) -> QueryIntentType {
        switch string.lowercased() {
        case "search": return .search
        case "filter": return .filter
        case "question": return .question
        case "command": return .command
        default: return .search
        }
    }
}

extension RelativeTime {
    public static func from(string: String) -> RelativeTime? {
        switch string.lowercased() {
        case "today": return .today
        case "yesterday": return .yesterday
        case "this_week": return .thisWeek
        case "last_week": return .lastWeek
        case "this_month": return .thisMonth
        case "last_month": return .lastMonth
        default: return nil
        }
    }
    
    public func toString() -> String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this_week"
        case .lastWeek: return "last_week"
        case .thisMonth: return "this_month"
        case .lastMonth: return "last_month"
        case .lastDays(let days): return "last_\(days)_days"
        case .lastWeeks(let weeks): return "last_\(weeks)_weeks"
        case .lastMonths(let months): return "last_\(months)_months"
        }
    }
}

// MARK: - Errors

public enum QueryEnhancementError: Error, LocalizedError {
    case timeout
    case invalidLLMResponse(String)
    case cachingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Query enhancement timed out"
        case .invalidLLMResponse(let message):
            return "Invalid LLM response: \(message)"
        case .cachingError(let message):
            return "Caching error: \(message)"
        }
    }
}