import Foundation
import os.log

// Import LLMWarmUpManager - assuming it's in the same module
// If it's in a separate module, this import may need adjustment

/// Cross-source summarization service that aggregates search results and generates intelligent summaries
/// Uses LLM for summary generation with fallback to extractive summarization
public class SummarizationService {
    private let llmService: LLMService
    private let cacheManager: CacheManager
    private let maxTokensPerContext: Int = 4000 // Token budget for LLM context
    private let timeoutInterval: TimeInterval = 2.0 // 2s timeout for summarization
    private let logger = Logger(subsystem: "Kenny.Summarization", category: "Service")
    
    public init(
        llmService: LLMService = LLMService(),
        cacheManager: CacheManager = CacheManager.shared
    ) {
        self.llmService = llmService
        self.cacheManager = cacheManager
    }
    
    /// Generate comprehensive summary from search results across multiple sources
    public func summarizeSearchResults(
        _ results: [HybridSearchResult],
        query: String,
        summaryLength: SummaryLength = .medium,
        includeSourceAttribution: Bool = true
    ) async throws -> SearchSummary {
        let startTime = Date()
        
        // Check cache first
        let cacheKey = generateCacheKey(results: results, query: query, length: summaryLength)
        if let cached = getCachedSummary(cacheKey) {
            PerformanceMonitor.shared.recordMetric(name: "summarization.cache_hit", value: 1)
            return cached
        }
        
        // Aggregate and prepare context
        let aggregation = aggregateResults(results, query: query)
        let context = prepareContext(from: aggregation, tokenBudget: maxTokensPerContext)
        
        // Automatically warm up LLM if not already warmed up (with quiet progress)
        let warmUpSuccess = await LLMWarmUpManager.shared.warmUpIfNeeded(llmService: llmService, showProgress: false)
        if !warmUpSuccess {
            logger.warning("LLM warm-up failed for summarization - falling back to extractive summarization")
        }
        
        // Try LLM summarization with timeout
        do {
            let summary = try await withTimeout(timeoutInterval) {
                try await self.generateLLMSummary(
                    context: context,
                    query: query,
                    length: summaryLength,
                    includeAttribution: includeSourceAttribution
                )
            }
            
            let searchSummary = SearchSummary(
                query: query,
                summary: summary,
                summaryLength: summaryLength,
                sourceCount: aggregation.sourceBreakdown.count,
                resultCount: results.count,
                sources: aggregation.sourceBreakdown,
                keyTopics: aggregation.keyTopics,
                generationMethod: .llm,
                confidence: 0.85
            )
            
            // Cache the result
            cacheSummary(cacheKey, searchSummary)
            
            let duration = Date().timeIntervalSince(startTime)
            PerformanceMonitor.shared.recordMetric(name: "summarization.llm_success", value: 1)
            PerformanceMonitor.shared.recordMetric(name: "summarization.duration_ms", value: duration * 1000)
            
            return searchSummary
            
        } catch {
            logger.warning("LLM summarization failed, falling back to extractive: \(error.localizedDescription)")
            
            // Fallback to extractive summarization
            let extractiveSummary = generateExtractiveSummary(
                from: aggregation,
                query: query,
                length: summaryLength,
                includeAttribution: includeSourceAttribution
            )
            
            let searchSummary = SearchSummary(
                query: query,
                summary: extractiveSummary,
                summaryLength: summaryLength,
                sourceCount: aggregation.sourceBreakdown.count,
                resultCount: results.count,
                sources: aggregation.sourceBreakdown,
                keyTopics: aggregation.keyTopics,
                generationMethod: .extractive,
                confidence: 0.6
            )
            
            // Cache with shorter TTL for fallback
            cacheSummary(cacheKey, searchSummary, ttl: 300) // 5 minutes
            
            let duration = Date().timeIntervalSince(startTime)
            PerformanceMonitor.shared.recordMetric(name: "summarization.fallback", value: 1)
            PerformanceMonitor.shared.recordMetric(name: "summarization.duration_ms", value: duration * 1000)
            
            return searchSummary
        }
    }
    
    /// Generate topic-based summary grouping results by common themes
    public func summarizeByTopic(
        _ results: [HybridSearchResult],
        query: String
    ) async throws -> TopicSummary {
        let aggregation = aggregateResults(results, query: query)
        let topics = aggregation.keyTopics
        
        var topicSummaries: [String: String] = [:]
        
        for topic in topics.prefix(5) { // Limit to top 5 topics
            let topicResults = results.filter { result in
                result.content.lowercased().contains(topic.lowercased()) ||
                result.title.lowercased().contains(topic.lowercased()) ||
                result.snippet.lowercased().contains(topic.lowercased())
            }
            
            if !topicResults.isEmpty {
                let topicContext = prepareTopicContext(topicResults, topic: topic)
                
                do {
                    // Ensure LLM is warmed up for topic summaries
                    let warmUpSuccess = await LLMWarmUpManager.shared.warmUpIfNeeded(llmService: llmService, showProgress: false)
                    if !warmUpSuccess {
                        logger.warning("LLM warm-up failed for topic summary of '\(topic)' - falling back to extractive")
                    }
                    let summary = try await self.generateTopicSummary(topic: topic, context: topicContext)
                    topicSummaries[topic] = summary
                } catch {
                    // Fallback to extractive for this topic
                    let extractive = generateTopicExtractiveSummary(topicResults, topic: topic)
                    topicSummaries[topic] = extractive
                }
            }
        }
        
        return TopicSummary(
            query: query,
            topicSummaries: topicSummaries,
            resultCount: results.count,
            topicsFound: topics.count
        )
    }
    
    // MARK: - Result Aggregation
    
    private func aggregateResults(_ results: [HybridSearchResult], query: String) -> ResultAggregation {
        var sourceBreakdown: [String: SourceInfo] = [:]
        var allContent: [String] = []
        var keyTopics: [String] = []
        
        // Group by source and collect content
        for result in results {
            let source = result.appSource
            
            if sourceBreakdown[source] == nil {
                sourceBreakdown[source] = SourceInfo(
                    sourceName: source,
                    resultCount: 0,
                    topResult: result,
                    relevanceScore: 0.0
                )
            }
            
            sourceBreakdown[source]?.resultCount += 1
            sourceBreakdown[source]?.relevanceScore += result.score
            
            // Collect content for topic extraction
            allContent.append(result.snippet)
            if !result.content.isEmpty && result.content.count < 500 {
                allContent.append(result.content)
            }
        }
        
        // Calculate average relevance scores
        for source in sourceBreakdown.keys {
            if let sourceInfo = sourceBreakdown[source] {
                sourceBreakdown[source]?.relevanceScore = sourceInfo.relevanceScore / Float(sourceInfo.resultCount)
            }
        }
        
        // Extract key topics
        keyTopics = extractKeyTopics(from: allContent, query: query)
        
        return ResultAggregation(
            sourceBreakdown: sourceBreakdown,
            keyTopics: keyTopics,
            totalResults: results.count,
            averageScore: results.reduce(0) { $0 + $1.score } / Float(results.count)
        )
    }
    
    private func extractKeyTopics(from content: [String], query: String) -> [String] {
        let combinedContent = content.joined(separator: " ").lowercased()
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        // Extract frequent meaningful words
        let words = combinedContent.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 } // Minimum word length
            .filter { !stopWords.contains($0) }
            .filter { !queryWords.contains($0) } // Exclude query words
        
        // Count word frequencies
        var wordCounts: [String: Int] = [:]
        for word in words {
            wordCounts[word, default: 0] += 1
        }
        
        // Return top topics
        return wordCounts.sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }
    
    // MARK: - Context Preparation
    
    private func prepareContext(from aggregation: ResultAggregation, tokenBudget: Int) -> SummarizationContext {
        var contextItems: [ContextItem] = []
        let estimatedTokensPerItem = 100 // Rough estimation
        let maxItems = tokenBudget / estimatedTokensPerItem
        
        // Sort sources by relevance
        let sortedSources = aggregation.sourceBreakdown.values.sorted { $0.relevanceScore > $1.relevanceScore }
        
        var itemCount = 0
        for sourceInfo in sortedSources {
            if itemCount >= maxItems { break }
            
            let item = ContextItem(
                source: sourceInfo.sourceName,
                content: sourceInfo.topResult.snippet,
                title: sourceInfo.topResult.title,
                relevanceScore: sourceInfo.topResult.score,
                resultCount: sourceInfo.resultCount
            )
            contextItems.append(item)
            itemCount += 1
        }
        
        return SummarizationContext(
            items: contextItems,
            keyTopics: aggregation.keyTopics,
            totalSources: aggregation.sourceBreakdown.count,
            estimatedTokens: itemCount * estimatedTokensPerItem
        )
    }
    
    private func prepareTopicContext(_ results: [HybridSearchResult], topic: String) -> [ContextItem] {
        return results.map { result in
            ContextItem(
                source: result.appSource,
                content: result.snippet,
                title: result.title,
                relevanceScore: result.score,
                resultCount: 1
            )
        }
    }
    
    // MARK: - LLM Summary Generation
    
    private func generateLLMSummary(
        context: SummarizationContext,
        query: String,
        length: SummaryLength,
        includeAttribution: Bool
    ) async throws -> String {
        let prompt = buildSummaryPrompt(context: context, query: query, length: length, includeAttribution: includeAttribution)
        let response = try await llmService.generateResponse(prompt: prompt)
        
        return cleanSummaryResponse(response)
    }
    
    private func generateTopicSummary(topic: String, context: [ContextItem]) async throws -> String {
        let prompt = buildTopicPrompt(topic: topic, context: context)
        let response = try await llmService.generateResponse(prompt: prompt)
        
        return cleanSummaryResponse(response)
    }
    
    private func buildSummaryPrompt(
        context: SummarizationContext,
        query: String,
        length: SummaryLength,
        includeAttribution: Bool
    ) -> String {
        let lengthInstruction = lengthInstructions[length] ?? "2-3 sentences"
        let attributionInstruction = includeAttribution ? "\n\nInclude source attribution (e.g., 'According to your messages...' or 'From your calendar...')." : ""
        
        var contextText = ""
        for (index, item) in context.items.enumerated() {
            contextText += "Source \(index + 1) (\(item.source)): \(item.title)\n\(item.content)\n\n"
        }
        
        return """
        Summarize the following search results for the user query: "\(query)"
        
        Provide a \(lengthInstruction) summary that:
        1. Directly answers the user's question if possible
        2. Highlights the most relevant findings
        3. Synthesizes information across multiple sources
        4. Uses clear, natural language\(attributionInstruction)
        
        Search Results:
        \(contextText)
        
        Key Topics: \(context.keyTopics.prefix(5).joined(separator: ", "))
        
        Summary:
        """
    }
    
    private func buildTopicPrompt(topic: String, context: [ContextItem]) -> String {
        var contextText = ""
        for item in context {
            contextText += "\(item.title): \(item.content)\n"
        }
        
        return """
        Summarize what the user's data reveals about the topic: "\(topic)"
        
        Provide a 1-2 sentence summary focusing on:
        - Key insights about this topic
        - Important details or patterns
        - Relevant context from the data
        
        Data about \(topic):
        \(contextText)
        
        Summary:
        """
    }
    
    private func cleanSummaryResponse(_ response: String) -> String {
        return response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Summary:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Extractive Summarization (Fallback)
    
    private func generateExtractiveSummary(
        from aggregation: ResultAggregation,
        query: String,
        length: SummaryLength,
        includeAttribution: Bool
    ) -> String {
        let sortedSources = aggregation.sourceBreakdown.values.sorted { $0.relevanceScore > $1.relevanceScore }
        let sentenceCount = sentenceCounts[length] ?? 2
        
        var summaryParts: [String] = []
        var usedSentences = 0
        
        for sourceInfo in sortedSources.prefix(3) { // Top 3 sources
            if usedSentences >= sentenceCount { break }
            
            let snippet = sourceInfo.topResult.snippet
            let sentences = extractSentences(from: snippet)
            
            if let bestSentence = selectBestSentence(sentences, query: query) {
                let attribution = includeAttribution ? "From your \(sourceInfo.sourceName.lowercased()): " : ""
                summaryParts.append("\(attribution)\(bestSentence)")
                usedSentences += 1
            }
        }
        
        if summaryParts.isEmpty {
            return "Found \(aggregation.totalResults) results across \(aggregation.sourceBreakdown.count) sources. Key topics include: \(aggregation.keyTopics.prefix(3).joined(separator: ", "))."
        }
        
        return summaryParts.joined(separator: " ")
    }
    
    private func generateTopicExtractiveSummary(_ results: [HybridSearchResult], topic: String) -> String {
        let sentences = results.flatMap { result in
            extractSentences(from: result.snippet + " " + result.content)
        }
        
        let topicSentences = sentences.filter { sentence in
            sentence.lowercased().contains(topic.lowercased())
        }
        
        if let bestSentence = topicSentences.first {
            return bestSentence
        }
        
        return "Found \(results.count) references to \(topic)."
    }
    
    private func extractSentences(from text: String) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 }
        
        return sentences
    }
    
    private func selectBestSentence(_ sentences: [String], query: String) -> String? {
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        return sentences.max { sentence1, sentence2 in
            let words1 = Set(sentence1.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let words2 = Set(sentence2.lowercased().components(separatedBy: .whitespacesAndNewlines))
            
            let overlap1 = queryWords.intersection(words1).count
            let overlap2 = queryWords.intersection(words2).count
            
            return overlap1 < overlap2
        }
    }
    
    // MARK: - Caching
    
    private func generateCacheKey(results: [HybridSearchResult], query: String, length: SummaryLength) -> String {
        let resultIds = results.prefix(20).map { $0.documentId }.joined()
        let content = "\(query):\(length.rawValue):\(resultIds)"
        return "summary:\(content.sha256())"
    }
    
    private func getCachedSummary(_ cacheKey: String) -> SearchSummary? {
        return cacheManager.get(cacheKey, type: SearchSummary.self)
    }
    
    private func cacheSummary(_ cacheKey: String, _ summary: SearchSummary, ttl: TimeInterval = 1800) {
        cacheManager.set(cacheKey, value: summary, ttl: ttl) // 30 minutes default
    }
    
    // MARK: - Utilities
    
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SummarizationError.timeout
            }
            
            for try await result in group {
                group.cancelAll()
                return result
            }
            
            throw SummarizationError.timeout
        }
    }
    
    // MARK: - Constants
    
    private let stopWords = Set([
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
        "by", "from", "up", "about", "into", "through", "during", "before", "after",
        "above", "below", "between", "among", "this", "that", "these", "those", "i",
        "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours"
    ])
    
    private let lengthInstructions: [SummaryLength: String] = [
        .short: "1 sentence",
        .medium: "2-3 sentences", 
        .long: "4-5 sentences",
        .detailed: "6-8 sentences"
    ]
    
    private let sentenceCounts: [SummaryLength: Int] = [
        .short: 1,
        .medium: 2,
        .long: 3,
        .detailed: 4
    ]
}

// MARK: - Data Structures

public enum SummaryLength: String, Codable, CaseIterable {
    case short = "short"
    case medium = "medium" 
    case long = "long"
    case detailed = "detailed"
}

public enum SummaryMethod: String, Codable {
    case llm = "llm"
    case extractive = "extractive"
}

public struct SearchSummary: Codable {
    public let query: String
    public let summary: String
    public let summaryLength: SummaryLength
    public let sourceCount: Int
    public let resultCount: Int
    public let sources: [String: SourceInfo]
    public let keyTopics: [String]
    public let generationMethod: SummaryMethod
    public let confidence: Double
    
    public init(
        query: String,
        summary: String,
        summaryLength: SummaryLength,
        sourceCount: Int,
        resultCount: Int,
        sources: [String: SourceInfo],
        keyTopics: [String],
        generationMethod: SummaryMethod,
        confidence: Double
    ) {
        self.query = query
        self.summary = summary
        self.summaryLength = summaryLength
        self.sourceCount = sourceCount
        self.resultCount = resultCount
        self.sources = sources
        self.keyTopics = keyTopics
        self.generationMethod = generationMethod
        self.confidence = confidence
    }
}

public struct TopicSummary: Codable {
    public let query: String
    public let topicSummaries: [String: String]
    public let resultCount: Int
    public let topicsFound: Int
}

public struct SourceInfo: Codable {
    public let sourceName: String
    public var resultCount: Int
    public let topResult: HybridSearchResult
    public var relevanceScore: Float
    
    public init(sourceName: String, resultCount: Int, topResult: HybridSearchResult, relevanceScore: Float) {
        self.sourceName = sourceName
        self.resultCount = resultCount
        self.topResult = topResult
        self.relevanceScore = relevanceScore
    }
}

public struct ResultAggregation {
    public let sourceBreakdown: [String: SourceInfo]
    public let keyTopics: [String]
    public let totalResults: Int
    public let averageScore: Float
}

public struct SummarizationContext {
    public let items: [ContextItem]
    public let keyTopics: [String]
    public let totalSources: Int
    public let estimatedTokens: Int
}

public struct ContextItem {
    public let source: String
    public let content: String
    public let title: String
    public let relevanceScore: Float
    public let resultCount: Int
}

// MARK: - Extensions

extension HybridSearchResult: Codable {
    enum CodingKeys: String, CodingKey {
        case documentId, chunkId, title, content, snippet, score
        case bm25Score, embeddingScore, sourcePath, appSource, metadata
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentId = try container.decode(String.self, forKey: .documentId)
        chunkId = try container.decode(String.self, forKey: .chunkId)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        snippet = try container.decode(String.self, forKey: .snippet)
        score = try container.decode(Float.self, forKey: .score)
        bm25Score = try container.decode(Float.self, forKey: .bm25Score)
        embeddingScore = try container.decode(Float.self, forKey: .embeddingScore)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        appSource = try container.decode(String.self, forKey: .appSource)
        // Simplified metadata handling for JSON compatibility
        if container.contains(.metadata) {
            metadata = [:]
        } else {
            metadata = [:]
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentId, forKey: .documentId)
        try container.encode(chunkId, forKey: .chunkId)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(score, forKey: .score)
        try container.encode(bm25Score, forKey: .bm25Score)
        try container.encode(embeddingScore, forKey: .embeddingScore)
        try container.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try container.encode(appSource, forKey: .appSource)
        // Note: metadata encoding is simplified for JSON compatibility
    }
}

// MARK: - Errors

public enum SummarizationError: Error, LocalizedError {
    case timeout
    case insufficientContext
    case aggregationFailed(String)
    case llmGenerationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Summarization timed out"
        case .insufficientContext:
            return "Insufficient context for summarization"
        case .aggregationFailed(let message):
            return "Result aggregation failed: \(message)"
        case .llmGenerationFailed(let message):
            return "LLM summary generation failed: \(message)"
        }
    }
}