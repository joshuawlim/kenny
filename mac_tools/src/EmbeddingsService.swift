import Foundation
import SQLite3

public enum EmbeddingModel: String {
    case nomicEmbedText = "nomic-embed-text"
    
    var dimensions: Int {
        switch self {
        case .nomicEmbedText:
            return 768
        }
    }
}

public struct EmbeddingChunk {
    let id: String
    let documentId: String
    let text: String
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let metadata: [String: Any]
}

public struct EmbeddingVector {
    let chunkId: String
    let vector: [Float]
    let model: EmbeddingModel
    let createdAt: Date
}

public class EmbeddingsService {
    let model: EmbeddingModel
    private let ollamaBaseURL: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    private let retryDelay: TimeInterval
    private let backgroundProcessor: BackgroundProcessor
    
    public init(model: EmbeddingModel = .nomicEmbedText, 
                ollamaBaseURL: String = "http://localhost:11434",
                timeoutInterval: TimeInterval = 30.0,
                maxRetries: Int = 3,
                retryDelay: TimeInterval = 1.0) {
        self.model = model
        self.ollamaBaseURL = ollamaBaseURL
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.backgroundProcessor = BackgroundProcessor.shared
    }
    
    /// Schedule embedding generation as a background job
    public func scheduleEmbeddingGeneration(for text: String, priority: JobPriority = .normal) -> String {
        return backgroundProcessor.submitTask(
            name: "generate_embedding",
            priority: priority,
            retryPolicy: .conservative
        ) { [weak self] in
            guard let self = self else { throw JobError.resourceUnavailable }
            return try await self.generateEmbedding(for: text)
        }
    }
    
    public func generateEmbedding(for text: String) async throws -> [Float] {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let result = try await performEmbeddingRequest(text: text)
                return result
            } catch {
                lastError = error
                
                // Don't retry for certain types of errors
                if let embeddingError = error as? EmbeddingError {
                    switch embeddingError {
                    case .invalidResponse, .invalidModel, .chunkingError:
                        throw error // Don't retry these
                    case .apiError, .networkError:
                        break // Continue with retry
                    }
                }
                
                print("Embedding request failed (attempt \(attempt)/\(maxRetries)): \(error)")
                
                if attempt < maxRetries {
                    let delaySeconds = retryDelay * Double(attempt) // Exponential backoff
                    print("Retrying in \(delaySeconds) seconds...")
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? EmbeddingError.networkError("Max retries exceeded")
    }
    
    private func performEmbeddingRequest(text: String) async throws -> [Float] {
        let url = URL(string: "\(ollamaBaseURL)/api/embed")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        
        // Use current 2025 Ollama API format (primary: "input")
        let primaryPayload: [String: Any] = [
            "model": model.rawValue,
            "input": text
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: primaryPayload)
            let result = try await executeRequest(request: request)
            return result
        } catch EmbeddingError.apiError(let message) where message.contains("400") {
            // If 400 error, try legacy format with "prompt" field for backward compatibility
            print("⚠️  Primary format failed with 400, trying legacy format with 'prompt' field")
            
            let legacyPayload: [String: Any] = [
                "model": model.rawValue,
                "prompt": text
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: legacyPayload)
            return try await executeRequest(request: request)
        } catch {
            throw error
        }
    }
    
    private func executeRequest(request: URLRequest) async throws -> [Float] {
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = "HTTP \(httpResponse.statusCode)"
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorData["error"] as? String {
                throw EmbeddingError.apiError("\(errorMessage): \(error)")
            }
            throw EmbeddingError.apiError(errorMessage)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        // Try different response field formats with robust number parsing
        if let embedding = parseEmbeddingArray(from: json?["embedding"]) {
            return embedding
        } else if let embedding = parseEmbeddingArray(from: json?["embeddings"]) {
            // Some providers use "embeddings" (plural)
            return embedding
        } else if let data = json?["data"] as? [[String: Any]],
                  let firstData = data.first,
                  let embedding = parseEmbeddingArray(from: firstData["embedding"]) {
            // OpenAI-style response format
            return embedding
        } else {
            print("⚠️  Unexpected response format: \(json ?? [:])")
            throw EmbeddingError.invalidResponse
        }
    }
    
    private func parseEmbeddingArray(from value: Any?) -> [Float]? {
        // Handle nested array structure from Ollama response
        if let outerArray = value as? [Any], let innerArray = outerArray.first as? [Any] {
            return convertToFloatArray(innerArray)
        }
        
        // Handle direct array
        if let array = value as? [Any] {
            return convertToFloatArray(array)
        }
        
        return nil
    }
    
    private func convertToFloatArray(_ array: [Any]) -> [Float]? {
        var result: [Float] = []
        result.reserveCapacity(array.count)
        
        for item in array {
            let floatValue: Float
            
            if let double = item as? Double {
                floatValue = Float(double)
            } else if let float = item as? Float {
                floatValue = float
            } else if let int = item as? Int {
                floatValue = Float(int)
            } else if let string = item as? String, let double = Double(string) {
                // Handle scientific notation strings
                floatValue = Float(double)
            } else if let number = item as? NSNumber {
                floatValue = number.floatValue
            } else {
                print("⚠️  Failed to parse embedding value: \(item) (type: \(type(of: item)))")
                return nil
            }
            
            result.append(floatValue)
        }
        
        return result
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
    case networkError(String)
    case invalidModel(String)
}

public class ChunkingStrategy {
    let maxChunkSize: Int
    let overlap: Int
    
    public init(maxChunkSize: Int = 512, overlap: Int = 50) {
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
    }
    
    public func chunkEmail(_ content: String, documentId: String) -> [EmbeddingChunk] {
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
    
    public func chunkEvent(_ content: String, documentId: String) -> [EmbeddingChunk] {
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
    
    public func chunkDocument(_ content: String, documentId: String) -> [EmbeddingChunk] {
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
    
    public func chunkNote(_ content: String, documentId: String) -> [EmbeddingChunk] {
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
    
    public func chunkMessage(_ content: String, documentId: String) -> [EmbeddingChunk] {
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