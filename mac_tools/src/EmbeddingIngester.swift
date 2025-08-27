import Foundation
import SQLite3

public enum EmbeddingIngestionError: Error {
    case databaseError(String)
    case embeddingGenerationFailed(String)
    case chunkingFailed(String)
}

public class EmbeddingIngester {
    private let database: Database
    private let embeddingsService: EmbeddingsService
    private let chunkingStrategy: ChunkingStrategy
    private let batchSize: Int
    
    public init(database: Database,
         embeddingsService: EmbeddingsService = EmbeddingsService(),
         chunkingStrategy: ChunkingStrategy = ChunkingStrategy(),
         batchSize: Int = 10) {
        self.database = database
        self.embeddingsService = embeddingsService
        self.chunkingStrategy = chunkingStrategy
        self.batchSize = batchSize
    }
    
    public func ingestAll(force: Bool = false) async throws {
        let startTime = Date()
        var totalDocuments = 0
        var totalChunks = 0
        var totalEmbeddings = 0
        
        print("Starting embedding ingestion...")
        
        let documents = try fetchDocumentsNeedingEmbeddings(force: force)
        totalDocuments = documents.count
        
        print("Found \(totalDocuments) documents needing embeddings")
        
        for batch in documents.chunked(into: batchSize) {
            for document in batch {
                let chunks = try await processDocument(document)
                totalChunks += chunks.count
                totalEmbeddings += chunks.count
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        print("""
            Embedding ingestion complete:
            - Documents processed: \(totalDocuments)
            - Chunks created: \(totalChunks)
            - Embeddings generated: \(totalEmbeddings)
            - Duration: \(String(format: "%.2f", duration))s
            """)
    }
    
    private func fetchDocumentsNeedingEmbeddings(force: Bool) throws -> [(id: String, type: String, content: String)] {
        let sql: String
        if force {
            sql = """
                SELECT id, type, content
                FROM documents
                WHERE content IS NOT NULL AND content != ''
                ORDER BY updated_at DESC
            """
        } else {
            sql = """
                SELECT d.id, d.type, d.content
                FROM documents d
                LEFT JOIN chunks c ON d.id = c.document_id
                WHERE d.content IS NOT NULL 
                  AND d.content != ''
                  AND c.id IS NULL
                ORDER BY d.updated_at DESC
            """
        }
        
        let rows = database.query(sql)
        
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["type"] as? String,
                  let content = row["content"] as? String else {
                return nil
            }
            return (id, type, content)
        }
    }
    
    private func processDocument(_ document: (id: String, type: String, content: String)) async throws -> [EmbeddingChunk] {
        let chunks = chunkDocument(document)
        
        try deleteExistingChunks(for: document.id)
        
        for chunk in chunks {
            try saveChunk(chunk)
            
            let embedding = try await embeddingsService.generateEmbedding(for: chunk.text)
            try saveEmbedding(
                chunkId: chunk.id,
                vector: embedding,
                model: embeddingsService.model
            )
        }
        
        return chunks
    }
    
    private func chunkDocument(_ document: (id: String, type: String, content: String)) -> [EmbeddingChunk] {
        switch document.type {
        case "email":
            return chunkingStrategy.chunkEmail(document.content, documentId: document.id)
        case "event", "calendar":
            return chunkingStrategy.chunkEvent(document.content, documentId: document.id)
        case "note":
            return chunkingStrategy.chunkNote(document.content, documentId: document.id)
        case "message":
            return chunkingStrategy.chunkMessage(document.content, documentId: document.id)
        case "contact":
            return chunkingStrategy.chunkContact(document.content, documentId: document.id)
        case "file", "document":
            return chunkingStrategy.chunkDocument(document.content, documentId: document.id)
        default:
            return chunkingStrategy.chunkDocument(document.content, documentId: document.id)
        }
    }
    
    private func deleteExistingChunks(for documentId: String) throws {
        let sql = "DELETE FROM embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?)"
        if !database.execute(sql, parameters: [documentId]) {
            throw EmbeddingIngestionError.databaseError("Failed to delete existing embeddings for document \(documentId)")
        }
        
        let chunkSql = "DELETE FROM chunks WHERE document_id = ?"
        if !database.execute(chunkSql, parameters: [documentId]) {
            throw EmbeddingIngestionError.databaseError("Failed to delete existing chunks for document \(documentId)")
        }
    }
    
    private func saveChunk(_ chunk: EmbeddingChunk) throws {
        // Use the Database class's existing storeChunks method which is more robust
        if !database.storeChunks([chunk]) {
            throw EmbeddingIngestionError.databaseError("Failed to store chunk \(chunk.id)")
        }
    }
    
    private func saveEmbedding(chunkId: String, vector: [Float], model: EmbeddingModel) throws {
        // Use the Database class's existing storeEmbedding method which is more robust
        if !database.storeEmbedding(chunkId: chunkId, vector: vector, model: model.rawValue) {
            throw EmbeddingIngestionError.databaseError("Failed to store embedding for chunk \(chunkId)")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}