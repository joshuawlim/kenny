import Foundation
import SQLite3

struct HybridSearchResult {
    let documentId: String
    let chunkId: String
    let title: String
    let content: String
    let snippet: String
    let score: Float
    let bm25Score: Float
    let embeddingScore: Float
    let sourcePath: String?
    let appSource: String
    let metadata: [String: Any]
}

class HybridSearch {
    private let database: Database
    private let embeddingsService: EmbeddingsService
    private let bm25Weight: Float
    private let embeddingWeight: Float
    
    init(database: Database, 
         embeddingsService: EmbeddingsService,
         bm25Weight: Float = 0.5,
         embeddingWeight: Float = 0.5) {
        self.database = database
        self.embeddingsService = embeddingsService
        self.bm25Weight = bm25Weight
        self.embeddingWeight = embeddingWeight
    }
    
    func search(query: String, limit: Int = 10) async throws -> [HybridSearchResult] {
        let queryEmbedding = try await embeddingsService.generateEmbedding(for: query)
        
        let bm25Results = try searchBM25(query: query, limit: limit * 2)
        
        let embeddingResults = try searchEmbeddings(
            queryVector: queryEmbedding,
            limit: limit * 2
        )
        
        return combineResults(
            bm25Results: bm25Results,
            embeddingResults: embeddingResults,
            limit: limit
        )
    }
    
    private func searchBM25(query: String, limit: Int) throws -> [(String, Float, String)] {
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
            return (id, Float(abs(score)), snippet)
        }
    }
    
    private func searchEmbeddings(queryVector: [Float], limit: Int) throws -> [(String, Float, String)] {
        // For now, return empty results since we need direct database access for blob operations
        // This would need a specialized method in Database class to handle BLOB data
        print("Warning: Embedding search not yet implemented - requires BLOB support")
        return []
    }
    
    private func combineResults(
        bm25Results: [(String, Float, String)],
        embeddingResults: [(String, Float, String)],
        limit: Int
    ) -> [HybridSearchResult] {
        var combinedScores: [String: (bm25: Float, embedding: Float, snippet: String)] = [:]
        
        let maxBM25 = bm25Results.first?.1 ?? 1.0
        let maxEmbedding = embeddingResults.first?.1 ?? 1.0
        
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

