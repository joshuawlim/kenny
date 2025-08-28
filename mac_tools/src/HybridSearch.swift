import Foundation
import SQLite3

public struct HybridSearchResult {
    public let documentId: String
    public let chunkId: String
    public let title: String
    public let content: String
    public let snippet: String
    public let score: Float
    public let bm25Score: Float
    public let embeddingScore: Float
    public let sourcePath: String?
    public let appSource: String
    public let metadata: [String: Any]
    
    public func toDictionary() -> [String: Any] {
        return [
            "document_id": documentId,
            "chunk_id": chunkId,
            "title": title,
            "content": content,
            "snippet": snippet,
            "score": score,
            "bm25_score": bm25Score,
            "embedding_score": embeddingScore,
            "source_path": sourcePath as Any,
            "app_source": appSource,
            "metadata": metadata
        ]
    }
}

public class HybridSearch {
    private let database: Database
    private let embeddingsService: EmbeddingsService
    private let configManager: ConfigurationManager
    private let bm25Weight: Float
    private let embeddingWeight: Float
    
    public init(database: Database, 
         embeddingsService: EmbeddingsService,
         bm25Weight: Float = 0.5,
         embeddingWeight: Float = 0.5) {
        self.database = database
        self.embeddingsService = embeddingsService
        self.configManager = ConfigurationManager.shared
        self.bm25Weight = bm25Weight
        self.embeddingWeight = embeddingWeight
    }
    
    public func search(query: String, limit: Int = 10) async throws -> [HybridSearchResult] {
        return try await PerformanceMonitor.shared.recordAsyncOperation("hybrid_search.search") {
            let queryEmbedding = try await embeddingsService.generateEmbedding(for: query)
        
        let bm25Results = try searchBM25(query: query, limit: limit * 2)
        
        let embeddingResults = try searchEmbeddings(
            queryVector: queryEmbedding,
            limit: limit * 2
        )
        
            return combineResultsWithProgressiveFallback(
                bm25Results: bm25Results,
                embeddingResults: embeddingResults,
                limit: limit
            )
        }
    }
    
    private func searchBM25(query: String, limit: Int) throws -> [(String, Float, String)] {
        // Use document-level search with corrected BM25 scoring
        let sql = """
            SELECT 
                d.id,
                snippet(documents_fts, 0, '<mark>', '</mark>', '...', 30) as snippet,
                bm25(documents_fts) as score
            FROM documents_fts
            JOIN documents d ON documents_fts.rowid = d.rowid
            WHERE documents_fts MATCH ?
            ORDER BY score
            LIMIT ?
        """
        
        let rows = database.query(sql, parameters: [query, limit])
        
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let snippet = row["snippet"] as? String,
                  let score = row["score"] as? Double else {
                return nil
            }
            // BM25 scores from FTS5 are negative (lower is better)
            // Convert to positive scores where higher is better
            return (id, Float(-score), snippet)
        }
    }
    
    private func searchEmbeddings(queryVector: [Float], limit: Int) throws -> [(String, Float, String)] {
        // Use the new database embedding search method
        return database.searchEmbeddings(queryVector: queryVector, limit: limit)
    }
    
    private func combineResultsWithProgressiveFallback(
        bm25Results: [(String, Float, String)],
        embeddingResults: [(String, Float, String)],
        limit: Int
    ) -> [HybridSearchResult] {
        // Progressive thresholds: start high for precision, fall back for recall
        let thresholds: [Float] = [0.4, 0.25, 0.15, 0.05]
        let minResultsForEarlyReturn = max(1, limit / 2)
        
        for threshold in thresholds {
            let results = combineResults(
                bm25Results: bm25Results,
                embeddingResults: embeddingResults,
                threshold: threshold,
                limit: limit
            )
            
            // Return early if we have enough good results
            if results.count >= minResultsForEarlyReturn {
                return results
            }
        }
        
        // Final fallback: return whatever we can find with the lowest threshold
        return combineResults(
            bm25Results: bm25Results,
            embeddingResults: embeddingResults,
            threshold: 0.01, // Very low threshold for maximum recall
            limit: limit
        )
    }
    
    private func combineResults(
        bm25Results: [(String, Float, String)],
        embeddingResults: [(String, Float, String)],
        threshold: Float,
        limit: Int
    ) -> [HybridSearchResult] {
        var combinedScores: [String: (bm25: Float, embedding: Float, snippet: String)] = [:]
        
        // Find max scores for normalization (since results are sorted by score desc)
        // Only normalize if we have actual results, otherwise keep as zero
        let maxBM25 = bm25Results.max { $0.1 < $1.1 }?.1 ?? 0.0
        let maxEmbedding = embeddingResults.max { $0.1 < $1.1 }?.1 ?? 0.0
        
        for (docId, score, snippet) in bm25Results {
            let normalizedScore = maxBM25 > 0 ? score / maxBM25 : 0
            if var existing = combinedScores[docId] {
                existing.bm25 = normalizedScore
                combinedScores[docId] = existing
            } else {
                combinedScores[docId] = (normalizedScore, 0, snippet)
            }
        }
        
        for (docId, score, snippet) in embeddingResults {
            let normalizedScore = maxEmbedding > 0 ? score / maxEmbedding : 0
            if var existing = combinedScores[docId] {
                existing.embedding = normalizedScore
                if existing.snippet.isEmpty {
                    existing.snippet = snippet
                }
                combinedScores[docId] = existing
            } else {
                combinedScores[docId] = (0, normalizedScore, snippet)
            }
        }
        
        let results = combinedScores.compactMap { (docId, scores) -> HybridSearchResult? in
            let combinedScore = (scores.bm25 * bm25Weight) + (scores.embedding * embeddingWeight)
            
            // Use the provided threshold for filtering
            guard combinedScore > threshold else { return nil }
            
            guard let document = try? fetchDocument(id: docId) else { return nil }
            
            return HybridSearchResult(
                documentId: docId,
                chunkId: "",
                title: document.title,
                content: document.content ?? "",
                snippet: scores.snippet,
                score: combinedScore,
                bm25Score: scores.bm25,
                embeddingScore: scores.embedding,
                sourcePath: document.sourcePath,
                appSource: document.appSource,
                metadata: [:]
            )
        }
        
        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
    
    private func fetchDocument(id: String) throws -> (title: String, content: String?, sourcePath: String?, appSource: String) {
        let sql = """
            SELECT title, content, source_path, app_source
            FROM documents
            WHERE id = ?
        """
        
        let rows = database.query(sql, parameters: [id])
        
        guard let row = rows.first,
              let title = row["title"] as? String,
              let appSource = row["app_source"] as? String else {
            throw SearchError.documentNotFound(id)
        }
        
        let content = row["content"] as? String
        let sourcePath = row["source_path"] as? String
        
        return (title, content, sourcePath, appSource)
    }
}

enum SearchError: Error {
    case documentNotFound(String)
    case embeddingGenerationFailed
    case databaseError(String)
}

