import Foundation
import SQLite3

enum EmbeddingModel: String {
    case nomicEmbedText = "nomic-embed-text"
    
    var dimensions: Int {
        switch self {
        case .nomicEmbedText:
            return 768
        }
    }
}

struct EmbeddingChunk {
    let id: String
    let documentId: String
    let text: String
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let metadata: [String: Any]
}

struct EmbeddingVector {
    let chunkId: String
    let vector: [Float]
    let model: EmbeddingModel
    let createdAt: Date
}

class EmbeddingsService {
    let model: EmbeddingModel
    private let ollamaBaseURL: String
    
    init(model: EmbeddingModel = .nomicEmbedText, ollamaBaseURL: String = "http://localhost:11434") {
        self.model = model
        self.ollamaBaseURL = ollamaBaseURL
    }
    
    func generateEmbedding(for text: String) async throws -> [Float] {
        let url = URL(string: "\(ollamaBaseURL)/api/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "model": model.rawValue,
            "prompt": text
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmbeddingError.apiError("Failed to generate embedding")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let embedding = json?["embedding"] as? [Double] else {
            throw EmbeddingError.invalidResponse
        }
        
        return embedding.map { Float($0) }
    }
    
    func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var embeddings: [[Float]] = []
        
        for text in texts {
            let embedding = try await generateEmbedding(for: text)
            embeddings.append(embedding)
        }
        
        return embeddings
    }
    
    func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
    
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        let dotProduct = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let magnitudeA = sqrt(a.reduce(0) { $0 + $1 * $1 })
        let magnitudeB = sqrt(b.reduce(0) { $0 + $1 * $1 })
        
        guard magnitudeA > 0 && magnitudeB > 0 else { return 0 }
        return dotProduct / (magnitudeA * magnitudeB)
    }
}

enum EmbeddingError: Error {
    case apiError(String)
    case invalidResponse
    case chunkingError(String)
}

class ChunkingStrategy {
    let maxChunkSize: Int
    let overlap: Int
    
    init(maxChunkSize: Int = 512, overlap: Int = 50) {
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
    }
    
    func chunkEmail(_ content: String, documentId: String) -> [EmbeddingChunk] {
        var chunks: [EmbeddingChunk] = []
        
        let components = content.components(separatedBy: "\n\n")
        var currentText = ""
        var chunkIndex = 0
        var currentOffset = 0
        
        for component in components {
            if currentText.count + component.count > maxChunkSize && !currentText.isEmpty {
                chunks.append(EmbeddingChunk(
                    id: "\(documentId)_chunk_\(chunkIndex)",
                    documentId: documentId,
                    text: currentText,
                    chunkIndex: chunkIndex,
                    startOffset: currentOffset,
                    endOffset: currentOffset + currentText.count,
                    metadata: ["type": "email", "index": chunkIndex]
                ))
                
                currentOffset += currentText.count - overlap
                currentText = String(currentText.suffix(overlap)) + "\n\n" + component
                chunkIndex += 1
            } else {
                currentText += (currentText.isEmpty ? "" : "\n\n") + component
            }
        }
        
        if !currentText.isEmpty {
            chunks.append(EmbeddingChunk(
                id: "\(documentId)_chunk_\(chunkIndex)",
                documentId: documentId,
                text: currentText,
                chunkIndex: chunkIndex,
                startOffset: currentOffset,
                endOffset: currentOffset + currentText.count,
                metadata: ["type": "email", "index": chunkIndex]
            ))
        }
        
        return chunks
    }
    
    func chunkEvent(_ content: String, documentId: String) -> [EmbeddingChunk] {
        return [EmbeddingChunk(
            id: "\(documentId)_chunk_0",
            documentId: documentId,
            text: content,
            chunkIndex: 0,
            startOffset: 0,
            endOffset: content.count,
            metadata: ["type": "event"]
        )]
    }
    
    func chunkDocument(_ content: String, documentId: String) -> [EmbeddingChunk] {
        var chunks: [EmbeddingChunk] = []
        let paragraphs = content.components(separatedBy: "\n\n")
        var currentText = ""
        var chunkIndex = 0
        var currentOffset = 0
        
        for paragraph in paragraphs {
            if currentText.count + paragraph.count > maxChunkSize && !currentText.isEmpty {
                chunks.append(EmbeddingChunk(
                    id: "\(documentId)_chunk_\(chunkIndex)",
                    documentId: documentId,
                    text: currentText,
                    chunkIndex: chunkIndex,
                    startOffset: currentOffset,
                    endOffset: currentOffset + currentText.count,
                    metadata: ["type": "document", "index": chunkIndex]
                ))
                
                currentOffset += currentText.count - overlap
                currentText = String(currentText.suffix(overlap)) + "\n\n" + paragraph
                chunkIndex += 1
            } else {
                currentText += (currentText.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        
        if !currentText.isEmpty {
            chunks.append(EmbeddingChunk(
                id: "\(documentId)_chunk_\(chunkIndex)",
                documentId: documentId,
                text: currentText,
                chunkIndex: chunkIndex,
                startOffset: currentOffset,
                endOffset: currentOffset + currentText.count,
                metadata: ["type": "document", "index": chunkIndex]
            ))
        }
        
        return chunks
    }
    
    func chunkNote(_ content: String, documentId: String) -> [EmbeddingChunk] {
        if content.count <= maxChunkSize {
            return [EmbeddingChunk(
                id: "\(documentId)_chunk_0",
                documentId: documentId,
                text: content,
                chunkIndex: 0,
                startOffset: 0,
                endOffset: content.count,
                metadata: ["type": "note"]
            )]
        }
        
        return chunkDocument(content, documentId: documentId)
    }
    
    func chunkMessage(_ content: String, documentId: String) -> [EmbeddingChunk] {
        return [EmbeddingChunk(
            id: "\(documentId)_chunk_0",
            documentId: documentId,
            text: content,
            chunkIndex: 0,
            startOffset: 0,
            endOffset: content.count,
            metadata: ["type": "message"]
        )]
    }
}