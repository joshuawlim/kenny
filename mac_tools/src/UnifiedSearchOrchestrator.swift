import Foundation
import os.log

/// Unified Search Orchestrator that consolidates multiple search strategies
/// Combines HybridSearch, Database.searchMultiDomain, and query expansion
/// for consistent search experience across all data sources
public class UnifiedSearchOrchestrator {
    private let database: Database
    private let hybridSearch: HybridSearch?
    private let enhancedHybridSearch: EnhancedHybridSearch?
    private let logger = Logger(subsystem: "Kenny.UnifiedSearchOrchestrator", category: "Search")
    
    // Configuration
    private let maxResults: Int
    private let hybridWeight: Float = 0.6      // Weight for hybrid search results
    private let multidomain: Float = 0.3       // Weight for FTS search results  
    private let queryExpansionWeight: Float = 0.1 // Weight for expanded query results
    
    public init(database: Database, 
                hybridSearch: HybridSearch? = nil, 
                enhancedHybridSearch: EnhancedHybridSearch? = nil,
                maxResults: Int = 50) {
        self.database = database
        self.hybridSearch = hybridSearch
        self.enhancedHybridSearch = enhancedHybridSearch
        self.maxResults = maxResults
    }
    
    /// Main unified search method with query expansion and result ranking
    public func search(
        query: String, 
        limit: Int = 20, 
        sources: [String] = [],
        includeQueryExpansion: Bool = true
    ) async throws -> [UnifiedSearchResult] {
        
        let startTime = Date()
        logger.info("Starting unified search for: '\(query)' (limit: \(limit))")
        
        // 1. Query preprocessing and expansion
        let expandedQueries = includeQueryExpansion ? 
            expandQuery(query) : [query]
        
        // 2. Execute searches across all paths in parallel
        let searchTasks = await withTaskGroup(of: SearchPathResult.self) { group in
            var results: [SearchPathResult] = []
            
            // Path 1: Enhanced Hybrid Search (semantic + BM25)
            if let enhancedHybrid = enhancedHybridSearch {
                group.addTask { [self] in
                    await performEnhancedHybridSearch(
                        queries: expandedQueries, 
                        enhancedSearch: enhancedHybrid,
                        sources: sources,
                        limit: limit * 2
                    )
                }
            } else if let hybrid = hybridSearch {
                group.addTask { [self] in
                    await performHybridSearch(
                        queries: expandedQueries,
                        hybridSearch: hybrid, 
                        limit: limit * 2
                    )
                }
            }
            
            // Path 2: Multi-domain FTS Search (fast keyword search)
            group.addTask { [self] in
                await performMultiDomainSearch(
                    queries: expandedQueries,
                    sources: sources,
                    limit: limit * 2
                )
            }
            
            // Path 3: Broad SQL Search (maximum recall)
            group.addTask { [self] in
                await performBroadSQLSearch(
                    query: query,
                    limit: limit * 2
                )
            }
            
            // Collect all results
            for await result in group {
                results.append(result)
            }
            
            return results
        }
        
        // 3. Unify and rank all results
        let unifiedResults = unifyAndRankResults(
            searchResults: searchTasks, 
            originalQuery: query,
            limit: limit
        )
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("Unified search completed in \(String(format: "%.3f", duration))s - \(unifiedResults.count) results")
        
        return unifiedResults
    }
    
    // MARK: - Query Expansion
    
    private func expandQuery(_ query: String) -> [String] {
        var expandedQueries = [query]
        
        // Basic synonym expansion for common terms
        let synonyms: [String: [String]] = [
            "email": ["mail", "message", "correspondence"],
            "meeting": ["call", "conference", "session", "appointment"],
            "document": ["file", "doc", "paper"],
            "contact": ["person", "individual", "colleague"],
            "task": ["todo", "assignment", "work", "job"],
            "project": ["initiative", "effort", "work"],
            "deadline": ["due date", "deadline", "target date"],
            "schedule": ["calendar", "agenda", "timeline"]
        ]
        
        for (term, alternatives) in synonyms {
            if query.lowercased().contains(term) {
                for alt in alternatives {
                    let expandedQuery = query.replacingOccurrences(
                        of: term, 
                        with: alt, 
                        options: [.caseInsensitive]
                    )
                    if expandedQuery != query {
                        expandedQueries.append(expandedQuery)
                    }
                }
            }
        }
        
        // Add partial phrase variations
        let words = query.split(separator: " ").map(String.init)
        if words.count > 1 {
            // Add individual word searches for broader recall
            expandedQueries.append(contentsOf: words)
            
            // Add phrase variations (first + last word)
            if words.count > 2 {
                expandedQueries.append("\(words.first!) \(words.last!)")
            }
        }
        
        return Array(Set(expandedQueries)) // Remove duplicates
    }
    
    // MARK: - Search Path Implementations
    
    private func performEnhancedHybridSearch(
        queries: [String],
        enhancedSearch: EnhancedHybridSearch,
        sources: [String],
        limit: Int
    ) async -> SearchPathResult {
        do {
            var allResults: [UnifiedSearchResult] = []
            
            for query in queries {
                let results = try await enhancedSearch.intentBasedSearch(
                    query: query,
                    limit: limit / queries.count
                )
                
                let convertedResults = results.results.map { hybridResult in
                    UnifiedSearchResult(
                        id: hybridResult.documentId,
                        title: hybridResult.title,
                        content: hybridResult.snippet,
                        source: hybridResult.appSource,
                        score: Double(hybridResult.score),
                        searchPath: .enhancedHybrid,
                        metadata: [
                            "bm25_score": hybridResult.bm25Score,
                            "embedding_score": hybridResult.embeddingScore
                        ]
                    )
                }
                
                allResults.append(contentsOf: convertedResults)
            }
            
            // Remove duplicates and sort
            let uniqueResults = Dictionary(grouping: allResults) { $0.id }
                .compactMapValues { $0.max(by: { $0.score < $1.score }) }
                .values
                .sorted { (result1: UnifiedSearchResult, result2: UnifiedSearchResult) in
                result1.score > result2.score
            }
            
            return SearchPathResult(
                path: .enhancedHybrid,
                results: Array(uniqueResults.prefix(limit)),
                success: true
            )
        } catch {
            logger.error("Enhanced hybrid search failed: \(error.localizedDescription)")
            return SearchPathResult(path: .enhancedHybrid, results: [], success: false)
        }
    }
    
    private func performHybridSearch(
        queries: [String],
        hybridSearch: HybridSearch,
        limit: Int
    ) async -> SearchPathResult {
        do {
            var allResults: [UnifiedSearchResult] = []
            
            for query in queries {
                let results = try await hybridSearch.search(
                    query: query,
                    limit: limit / queries.count
                )
                
                let convertedResults = results.map { hybridResult in
                    UnifiedSearchResult(
                        id: hybridResult.documentId,
                        title: hybridResult.title,
                        content: hybridResult.snippet,
                        source: hybridResult.appSource,
                        score: Double(hybridResult.score),
                        searchPath: .hybrid,
                        metadata: [
                            "bm25_score": hybridResult.bm25Score,
                            "embedding_score": hybridResult.embeddingScore
                        ]
                    )
                }
                
                allResults.append(contentsOf: convertedResults)
            }
            
            // Remove duplicates and sort
            let uniqueResults = Dictionary(grouping: allResults) { $0.id }
                .compactMapValues { $0.max(by: { $0.score < $1.score }) }
                .values
                .sorted { (result1: UnifiedSearchResult, result2: UnifiedSearchResult) in
                result1.score > result2.score
            }
            
            return SearchPathResult(
                path: .hybrid,
                results: Array(uniqueResults.prefix(limit)),
                success: true
            )
        } catch {
            logger.error("Hybrid search failed: \(error.localizedDescription)")
            return SearchPathResult(path: .hybrid, results: [], success: false)
        }
    }
    
    private func performMultiDomainSearch(
        queries: [String],
        sources: [String],
        limit: Int
    ) async -> SearchPathResult {
        var allResults: [UnifiedSearchResult] = []
        
        for query in queries {
            let results = database.searchMultiDomain(
                query,
                types: sources,
                limit: limit / queries.count
            )
            
            let convertedResults = results.map { searchResult in
                UnifiedSearchResult(
                    id: searchResult.id,
                    title: searchResult.title,
                    content: searchResult.snippet,
                    source: searchResult.type,
                    score: searchResult.rank,
                    searchPath: .multiDomain,
                    metadata: [
                        "context_info": searchResult.contextInfo,
                        "source_path": searchResult.sourcePath as Any
                    ]
                )
            }
            
            allResults.append(contentsOf: convertedResults)
        }
        
        // Remove duplicates and sort
        let uniqueResults = Dictionary(grouping: allResults) { $0.id }
            .compactMapValues { $0.max(by: { $0.score < $1.score }) }
            .values
            .sorted { (result1: UnifiedSearchResult, result2: UnifiedSearchResult) in
                result1.score > result2.score
            }
        
        return SearchPathResult(
            path: .multiDomain,
            results: Array(uniqueResults.prefix(limit)),
            success: true
        )
    }
    
    private func performBroadSQLSearch(
        query: String,
        limit: Int
    ) async -> SearchPathResult {
        // Implement broad SQL search similar to Python's _sql_fallback_search
        let searchTerms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 }
        
        guard !searchTerms.isEmpty else {
            return SearchPathResult(path: .broadSQL, results: [], success: false)
        }
        
        let likeConditions = searchTerms.map { _ in 
            "(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)" 
        }.joined(separator: " OR ")
        
        let sql = """
            SELECT id, title, content, app_source, created_at
            FROM documents
            WHERE \(likeConditions)
            ORDER BY created_at DESC
            LIMIT ?
        """
        
        var parameters: [Any] = []
        for term in searchTerms {
            let wildcard = "%\(term)%"
            parameters.append(wildcard)
            parameters.append(wildcard)
        }
        parameters.append(limit)
        
        let rows = database.query(sql, parameters: parameters)
        
        let results = rows.compactMap { row -> UnifiedSearchResult? in
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let content = row["content"] as? String,
                  let source = row["app_source"] as? String else {
                return nil
            }
            
            // Calculate simple relevance score based on term frequency
            let lowerTitle = title.lowercased()
            let lowerContent = content.lowercased()
            
            var score = 0.0
            for term in searchTerms {
                if lowerTitle.contains(term) {
                    score += 2.0 // Title matches are more valuable
                }
                if lowerContent.contains(term) {
                    score += 1.0
                }
            }
            
            let snippet = content.count > 200 ? 
                String(content.prefix(200)) + "..." : content
            
            return UnifiedSearchResult(
                id: id,
                title: title,
                content: snippet,
                source: source,
                score: score / Double(searchTerms.count), // Normalize by number of terms
                searchPath: .broadSQL,
                metadata: [
                    "created_at": row["created_at"] as Any
                ]
            )
        }
        
        return SearchPathResult(
            path: .broadSQL,
            results: results.sorted { $0.score > $1.score },
            success: true
        )
    }
    
    // MARK: - Result Unification and Ranking
    
    private func unifyAndRankResults(
        searchResults: [SearchPathResult],
        originalQuery: String,
        limit: Int
    ) -> [UnifiedSearchResult] {
        
        // Combine all results from all search paths
        var allResults: [UnifiedSearchResult] = []
        
        for pathResult in searchResults {
            guard pathResult.success else { continue }
            
            // Apply path-specific weight adjustments
            let weightedResults = pathResult.results.map { result in
                var weightedResult = result
                weightedResult.score = adjustScoreForPath(
                    score: result.score,
                    path: pathResult.path
                )
                return weightedResult
            }
            
            allResults.append(contentsOf: weightedResults)
        }
        
        // Remove duplicates, keeping the highest scoring version
        let uniqueResults = Dictionary(grouping: allResults) { $0.id }
            .compactMapValues { (duplicates: [UnifiedSearchResult]) -> UnifiedSearchResult? in
                // For duplicates, use the result with highest score
                // and merge metadata from different paths
                guard let best = duplicates.max(by: { $0.score < $1.score }) else { return nil }
                
                var mergedResult = best
                mergedResult.metadata["search_paths"] = duplicates.map { $0.searchPath.rawValue }
                mergedResult.metadata["path_scores"] = duplicates.map { $0.score }
                
                return mergedResult
            }
            .values
        
        // Final ranking with query relevance
        let rankedResults = Array(uniqueResults)
            .map { result in
                var finalResult = result
                finalResult.score = calculateFinalRelevanceScore(
                    result: result,
                    originalQuery: originalQuery
                )
                return finalResult
            }
            .sorted { (result1: UnifiedSearchResult, result2: UnifiedSearchResult) in
                result1.score > result2.score
            }
        
        return Array(rankedResults.prefix(limit))
    }
    
    private func adjustScoreForPath(score: Double, path: SearchPath) -> Double {
        switch path {
        case .enhancedHybrid:
            return score * Double(hybridWeight)
        case .hybrid: 
            return score * Double(hybridWeight)
        case .multiDomain:
            return score * Double(multidomain)
        case .broadSQL:
            return score * Double(queryExpansionWeight)
        }
    }
    
    private func calculateFinalRelevanceScore(
        result: UnifiedSearchResult,
        originalQuery: String
    ) -> Double {
        var finalScore = result.score
        
        // Boost for query terms in title
        let queryTerms = originalQuery.lowercased().split(separator: " ").map(String.init)
        let lowerTitle = result.title.lowercased()
        let lowerContent = result.content.lowercased()
        
        for term in queryTerms {
            if lowerTitle.contains(term) {
                finalScore += 0.2
            }
            if lowerContent.contains(term) {
                finalScore += 0.1
            }
        }
        
        // Boost for recent content (if available)
        if let createdAt = result.metadata["created_at"] as? String {
            // Add recency boost (this is a simplified version)
            finalScore += 0.05
        }
        
        // Boost for specific high-value sources
        switch result.source.lowercased() {
        case "mail", "calendar":
            finalScore += 0.1
        case "contacts":
            finalScore += 0.05
        default:
            break
        }
        
        return finalScore
    }
}

// MARK: - Supporting Types

public struct UnifiedSearchResult {
    public let id: String
    public let title: String
    public let content: String
    public let source: String
    public var score: Double
    public let searchPath: SearchPath
    public var metadata: [String: Any]
    
    public func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "content": content,
            "source": source,
            "score": score,
            "search_path": searchPath.rawValue,
            "metadata": metadata
        ]
    }
}

public enum SearchPath: String {
    case enhancedHybrid = "enhanced_hybrid"
    case hybrid = "hybrid"
    case multiDomain = "multi_domain"
    case broadSQL = "broad_sql"
}

private struct SearchPathResult {
    let path: SearchPath
    let results: [UnifiedSearchResult]
    let success: Bool
}