import Foundation

/// Enhanced hybrid search that integrates query enhancement and summarization capabilities
/// Combines the existing HybridSearch with AI-powered query optimization and result summarization
public class EnhancedHybridSearch {
    private let hybridSearch: HybridSearch
    private let queryEnhancer: QueryEnhancementService
    private let summarizer: SummarizationService
    private let database: Database
    private let performanceMonitor: PerformanceMonitor
    
    public init(
        database: Database,
        embeddingsService: EmbeddingsService,
        bm25Weight: Float = 0.5,
        embeddingWeight: Float = 0.5
    ) {
        self.database = database
        self.hybridSearch = HybridSearch(
            database: database,
            embeddingsService: embeddingsService,
            bm25Weight: bm25Weight,
            embeddingWeight: embeddingWeight
        )
        self.queryEnhancer = QueryEnhancementService()
        self.summarizer = SummarizationService()
        self.performanceMonitor = PerformanceMonitor.shared
    }
    
    /// Enhanced search with query optimization and optional summarization
    public func enhancedSearch(
        query: String,
        limit: Int = 10,
        includeSummary: Bool = false,
        summaryLength: SummaryLength = .medium
    ) async throws -> EnhancedSearchResult {
        let startTime = Date()
        
        return try await performanceMonitor.recordAsyncOperation("enhanced_search.full") {
            // Step 1: Enhance the query
            let enhancedQuery = try await performanceMonitor.recordAsyncOperation("enhanced_search.query_enhancement") {
                return try await queryEnhancer.enhanceQuery(query)
            }
            
            // Step 2: Perform multi-query search with variations
            let searchResults = try await performanceMonitor.recordAsyncOperation("enhanced_search.multi_query") {
                return try await performMultiQuerySearch(enhancedQuery, limit: limit)
            }
            
            // Step 3: Optional summarization
            var summary: SearchSummary?
            if includeSummary && !searchResults.isEmpty {
                summary = try await performanceMonitor.recordAsyncOperation("enhanced_search.summarization") {
                    return try await summarizer.summarizeSearchResults(
                        searchResults,
                        query: query,
                        summaryLength: summaryLength,
                        includeSourceAttribution: true
                    )
                }
            }
            
            let totalDuration = Date().timeIntervalSince(startTime)
            performanceMonitor.recordMetric(name: "enhanced_search.total_duration_ms", value: totalDuration * 1000)
            
            return EnhancedSearchResult(
                originalQuery: query,
                enhancedQuery: enhancedQuery,
                results: searchResults,
                summary: summary,
                searchMetadata: SearchMetadata(
                    totalDuration: totalDuration,
                    queryEnhancementMethod: enhancedQuery.enhancementMethod,
                    resultCount: searchResults.count,
                    sourcesSearched: extractUniqueSources(from: searchResults)
                )
            )
        }
    }
    
    /// Focused search with intent-based optimization
    public func intentBasedSearch(
        query: String,
        limit: Int = 10
    ) async throws -> IntentSearchResult {
        let enhancedQuery = try await queryEnhancer.enhanceQuery(query)
        
        return try await performanceMonitor.recordAsyncOperation("enhanced_search.intent_based") {
            switch enhancedQuery.intent {
            case .search:
                return try await handleSearchIntent(enhancedQuery, limit: limit)
            case .filter:
                return try await handleFilterIntent(enhancedQuery, limit: limit)
            case .question:
                return try await handleQuestionIntent(enhancedQuery, limit: limit)
            case .command:
                return try await handleCommandIntent(enhancedQuery)
            }
        }
    }
    
    /// Search with automatic query expansion using variations
    public func expandedSearch(
        query: String,
        limit: Int = 10,
        maxVariations: Int = 3
    ) async throws -> [HybridSearchResult] {
        return try await performanceMonitor.recordAsyncOperation("enhanced_search.expanded") {
            // Get original search results
            let originalResults = try await hybridSearch.search(query: query, limit: limit)
            
            // Generate query variations
            let variations = try await queryEnhancer.generateQueryVariations(query, maxVariations: maxVariations)
            
            // Search with variations
            var allResults: [HybridSearchResult] = originalResults
            let seenDocuments = Set(originalResults.map { $0.documentId })
            
            for variation in variations {
                let variationResults = try await hybridSearch.search(query: variation, limit: limit / 2)
                
                // Add new results not seen before
                for result in variationResults {
                    if !seenDocuments.contains(result.documentId) {
                        allResults.append(result)
                    }
                }
            }
            
            // Re-rank combined results and return top N
            return rankCombinedResults(allResults, originalQuery: query).prefix(limit).map { $0 }
        }
    }
    
    /// Topic-focused search with summarization by themes
    public func topicSearch(
        query: String,
        limit: Int = 20
    ) async throws -> TopicSearchResult {
        return try await performanceMonitor.recordAsyncOperation("enhanced_search.topic") {
            // Enhanced search with larger result set
            let enhancedQuery = try await queryEnhancer.enhanceQuery(query)
            let results = try await performMultiQuerySearch(enhancedQuery, limit: limit)
            
            // Generate topic-based summary
            let topicSummary = try await summarizer.summarizeByTopic(results, query: query)
            
            // Group results by source for better organization
            let groupedResults = groupResultsBySource(results)
            
            return TopicSearchResult(
                query: query,
                enhancedQuery: enhancedQuery,
                topicSummary: topicSummary,
                resultsBySource: groupedResults,
                totalResults: results.count
            )
        }
    }
    
    // MARK: - Intent Handlers
    
    private func handleSearchIntent(_ enhancedQuery: EnhancedQuery, limit: Int) async throws -> IntentSearchResult {
        let results = try await performMultiQuerySearch(enhancedQuery, limit: limit)
        
        return IntentSearchResult(
            intent: .search,
            query: enhancedQuery.originalQuery,
            results: results,
            intentSpecificData: [
                "search_terms": enhancedQuery.searchTerms,
                "entities": enhancedQuery.entities.map { entityToString($0) }
            ]
        )
    }
    
    private func handleFilterIntent(_ enhancedQuery: EnhancedQuery, limit: Int) async throws -> IntentSearchResult {
        // Perform search with enhanced filtering
        let results = try await performMultiQuerySearch(enhancedQuery, limit: limit * 2)
        let filteredResults = applyEnhancedFilters(results, enhancedQuery: enhancedQuery)
        
        return IntentSearchResult(
            intent: .filter,
            query: enhancedQuery.originalQuery,
            results: Array(filteredResults.prefix(limit)),
            intentSpecificData: [
                "filters_applied": describeAppliedFilters(enhancedQuery),
                "pre_filter_count": results.count,
                "post_filter_count": filteredResults.count
            ]
        )
    }
    
    private func handleQuestionIntent(_ enhancedQuery: EnhancedQuery, limit: Int) async throws -> IntentSearchResult {
        // Get relevant context for question answering
        let results = try await performMultiQuerySearch(enhancedQuery, limit: limit)
        
        // Generate focused answer
        let answer = try await generateQuestionAnswer(enhancedQuery.originalQuery, results: results)
        
        return IntentSearchResult(
            intent: .question,
            query: enhancedQuery.originalQuery,
            results: results,
            intentSpecificData: [
                "answer": answer,
                "confidence": 0.8,
                "answer_type": "generated"
            ]
        )
    }
    
    private func handleCommandIntent(_ enhancedQuery: EnhancedQuery) async throws -> IntentSearchResult {
        // Commands are not fully implemented yet, return placeholder
        return IntentSearchResult(
            intent: .command,
            query: enhancedQuery.originalQuery,
            results: [],
            intentSpecificData: [
                "status": "not_implemented",
                "message": "Command execution not yet available"
            ]
        )
    }
    
    // MARK: - Multi-Query Search
    
    private func performMultiQuerySearch(_ enhancedQuery: EnhancedQuery, limit: Int) async throws -> [HybridSearchResult] {
        var allResults: [HybridSearchResult] = []
        let seenDocuments = NSMutableSet()
        
        // Primary search with enhanced query
        let primaryResults = try await hybridSearch.search(query: enhancedQuery.enhancedQuery, limit: limit)
        for result in primaryResults {
            if !seenDocuments.contains(result.documentId) {
                allResults.append(result)
                seenDocuments.add(result.documentId)
            }
        }
        
        // Secondary searches with individual search terms (if different from primary)
        if enhancedQuery.searchTerms.count > 1 && allResults.count < limit {
            let remainingLimit = limit - allResults.count
            let termLimit = max(1, remainingLimit / enhancedQuery.searchTerms.count)
            
            for searchTerm in enhancedQuery.searchTerms.prefix(3) { // Limit to 3 terms to control latency
                if searchTerm != enhancedQuery.enhancedQuery {
                    let termResults = try await hybridSearch.search(query: searchTerm, limit: termLimit)
                    
                    for result in termResults {
                        if !seenDocuments.contains(result.documentId) {
                            allResults.append(result)
                            seenDocuments.add(result.documentId)
                        }
                    }
                }
            }
        }
        
        // Re-rank and return top results
        return rankCombinedResults(allResults, originalQuery: enhancedQuery.originalQuery)
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Result Processing
    
    private func rankCombinedResults(_ results: [HybridSearchResult], originalQuery: String) -> [HybridSearchResult] {
        let queryWords = Set(originalQuery.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        return results.sorted { result1, result2 in
            // Primary sort by original hybrid score
            if abs(result1.score - result2.score) > 0.1 {
                return result1.score > result2.score
            }
            
            // Secondary sort by query term overlap
            let overlap1 = calculateQueryOverlap(result1, queryWords: queryWords)
            let overlap2 = calculateQueryOverlap(result2, queryWords: queryWords)
            
            return overlap1 > overlap2
        }
    }
    
    private func calculateQueryOverlap(_ result: HybridSearchResult, queryWords: Set<String>) -> Int {
        let resultWords = Set((result.title + " " + result.snippet).lowercased()
            .components(separatedBy: .whitespacesAndNewlines))
        return queryWords.intersection(resultWords).count
    }
    
    private func applyEnhancedFilters(_ results: [HybridSearchResult], enhancedQuery: EnhancedQuery) -> [HybridSearchResult] {
        var filtered = results
        
        // Apply source filters
        if !enhancedQuery.sourceHints.isEmpty {
            filtered = filtered.filter { result in
                enhancedQuery.sourceHints.contains { hint in
                    result.appSource.lowercased().contains(hint.lowercased())
                }
            }
        }
        
        // Apply entity filters (basic implementation)
        for entity in enhancedQuery.entities {
            switch entity {
            case .person(let name):
                filtered = filtered.filter { result in
                    result.title.localizedCaseInsensitiveContains(name) ||
                    result.content.localizedCaseInsensitiveContains(name) ||
                    result.snippet.localizedCaseInsensitiveContains(name)
                }
            case .topic(let topic):
                filtered = filtered.filter { result in
                    result.title.localizedCaseInsensitiveContains(topic) ||
                    result.content.localizedCaseInsensitiveContains(topic) ||
                    result.snippet.localizedCaseInsensitiveContains(topic)
                }
            case .location(let location):
                filtered = filtered.filter { result in
                    result.title.localizedCaseInsensitiveContains(location) ||
                    result.content.localizedCaseInsensitiveContains(location) ||
                    result.snippet.localizedCaseInsensitiveContains(location)
                }
            case .organization(let org):
                filtered = filtered.filter { result in
                    result.title.localizedCaseInsensitiveContains(org) ||
                    result.content.localizedCaseInsensitiveContains(org) ||
                    result.snippet.localizedCaseInsensitiveContains(org)
                }
            }
        }
        
        return filtered
    }
    
    private func groupResultsBySource(_ results: [HybridSearchResult]) -> [String: [HybridSearchResult]] {
        return Dictionary(grouping: results) { $0.appSource }
    }
    
    private func extractUniqueSources(from results: [HybridSearchResult]) -> [String] {
        return Array(Set(results.map { $0.appSource }))
    }
    
    // MARK: - Question Answering
    
    private func generateQuestionAnswer(_ question: String, results: [HybridSearchResult]) async throws -> String {
        guard !results.isEmpty else {
            return "No relevant information found to answer the question."
        }
        
        // Use the top 3 results for context
        let contextResults = Array(results.prefix(3))
        
        return try await summarizer.summarizeSearchResults(
            contextResults,
            query: question,
            summaryLength: .medium,
            includeSourceAttribution: true
        ).summary
    }
    
    // MARK: - Utility Functions
    
    private func entityToString(_ entity: EntityFilter) -> String {
        switch entity {
        case .person(let name): return "person:\(name)"
        case .topic(let topic): return "topic:\(topic)"
        case .location(let location): return "location:\(location)"
        case .organization(let org): return "organization:\(org)"
        }
    }
    
    private func describeAppliedFilters(_ enhancedQuery: EnhancedQuery) -> [String] {
        var filters: [String] = []
        
        if !enhancedQuery.sourceHints.isEmpty {
            filters.append("Sources: \(enhancedQuery.sourceHints.joined(separator: ", "))")
        }
        
        for entity in enhancedQuery.entities {
            filters.append(entityToString(entity))
        }
        
        if enhancedQuery.timeFilter != nil {
            filters.append("Time filter applied")
        }
        
        return filters
    }
}

// MARK: - Data Structures

public struct EnhancedSearchResult {
    public let originalQuery: String
    public let enhancedQuery: EnhancedQuery
    public let results: [HybridSearchResult]
    public let summary: SearchSummary?
    public let searchMetadata: SearchMetadata
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "original_query": originalQuery,
            "enhanced_query": [
                "query": enhancedQuery.enhancedQuery,
                "intent": enhancedQuery.intent.rawValue,
                "method": enhancedQuery.enhancementMethod.rawValue
            ],
            "results": results.map { $0.toDictionary() },
            "metadata": [
                "result_count": results.count,
                "total_duration_ms": searchMetadata.totalDuration * 1000,
                "sources_searched": searchMetadata.sourcesSearched
            ]
        ]
        
        if let summary = summary {
            dict["summary"] = [
                "text": summary.summary,
                "method": summary.generationMethod.rawValue,
                "confidence": summary.confidence,
                "key_topics": summary.keyTopics
            ]
        }
        
        return dict
    }
}

public struct IntentSearchResult {
    public let intent: QueryIntentType
    public let query: String
    public let results: [HybridSearchResult]
    public let intentSpecificData: [String: Any]
    
    public func toDictionary() -> [String: Any] {
        return [
            "intent": intent.rawValue,
            "query": query,
            "results": results.map { $0.toDictionary() },
            "intent_data": intentSpecificData,
            "result_count": results.count
        ]
    }
}

public struct TopicSearchResult {
    public let query: String
    public let enhancedQuery: EnhancedQuery
    public let topicSummary: TopicSummary
    public let resultsBySource: [String: [HybridSearchResult]]
    public let totalResults: Int
    
    public func toDictionary() -> [String: Any] {
        var sourceResults: [String: Any] = [:]
        for (source, results) in resultsBySource {
            sourceResults[source] = results.map { $0.toDictionary() }
        }
        
        return [
            "query": query,
            "topic_summaries": topicSummary.topicSummaries,
            "results_by_source": sourceResults,
            "total_results": totalResults,
            "topics_found": topicSummary.topicsFound
        ]
    }
}

public struct SearchMetadata {
    public let totalDuration: TimeInterval
    public let queryEnhancementMethod: EnhancementMethod
    public let resultCount: Int
    public let sourcesSearched: [String]
}

// MARK: - Error Handling

public enum EnhancedSearchError: Error, LocalizedError {
    case queryEnhancementFailed(String)
    case searchExecutionFailed(String)
    case summarizationFailed(String)
    case intentProcessingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .queryEnhancementFailed(let message):
            return "Query enhancement failed: \(message)"
        case .searchExecutionFailed(let message):
            return "Search execution failed: \(message)"
        case .summarizationFailed(let message):
            return "Summarization failed: \(message)"
        case .intentProcessingFailed(let message):
            return "Intent processing failed: \(message)"
        }
    }
}