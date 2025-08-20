import Foundation

/// LLM Service for local inference with Ollama
/// Designed for tool selection and function calling reasoning
public class LLMService {
    private let ollamaBaseURL: String
    private let model: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    
    public init(
        ollamaBaseURL: String = "http://localhost:11434",
        model: String = "llama3.2:3b",
        timeoutInterval: TimeInterval = 30.0,
        maxRetries: Int = 2
    ) {
        self.ollamaBaseURL = ollamaBaseURL
        self.model = model
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
    }
    
    /// Generate response using Ollama chat completion API
    public func generateResponse(prompt: String) async throws -> String {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let response = try await performChatRequest(prompt: prompt)
                return response
            } catch {
                lastError = error
                print("LLM request failed (attempt \(attempt)/\(maxRetries)): \(error)")
                
                if attempt < maxRetries {
                    let delaySeconds = Double(attempt) * 1.0 // Linear backoff
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? LLMError.maxRetriesExceeded
    }
    
    private func performChatRequest(prompt: String) async throws -> String {
        let url = URL(string: "\(ollamaBaseURL)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        
        // Ollama chat format
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a helpful AI assistant that responds with JSON only when requested. Be precise and follow instructions exactly."
                ],
                [
                    "role": "user", 
                    "content": prompt
                ]
            ],
            "stream": false,
            "options": [
                "temperature": 0.1,  // Low temperature for consistent tool selection
                "top_p": 0.9
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = "HTTP \(httpResponse.statusCode)"
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorData["error"] as? String {
                throw LLMError.apiError("\(errorMessage): \(error)")
            }
            throw LLMError.apiError(errorMessage)
        }
        
        // Parse Ollama chat response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse("Could not parse chat response")
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Check if Ollama is available and model is loaded
    public func checkAvailability() async -> Bool {
        do {
            let url = URL(string: "\(ollamaBaseURL)/api/tags")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return false
            }
            
            // Check if our model is available
            return models.contains { model in
                if let name = model["name"] as? String {
                    return name.hasPrefix(self.model)
                }
                return false
            }
        } catch {
            return false
        }
    }
    
    /// Pull model if not available (blocking operation)
    public func ensureModelAvailable() async throws {
        if await checkAvailability() {
            return // Model already available
        }
        
        print("📥 Pulling model \(model) from Ollama...")
        
        let url = URL(string: "\(ollamaBaseURL)/api/pull")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300.0 // 5 minutes for model download
        
        let payload = ["name": model]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LLMError.modelNotAvailable("Failed to pull model \(model)")
        }
        
        print("✅ Model \(model) ready")
    }
}

// MARK: - Error Types

public enum LLMError: Error, LocalizedError {
    case apiError(String)
    case networkError(String)  
    case invalidResponse(String)
    case modelNotAvailable(String)
    case maxRetriesExceeded
    
    public var errorDescription: String? {
        switch self {
        case .apiError(let message):
            return "LLM API error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .modelNotAvailable(let message):
            return "Model not available: \(message)"
        case .maxRetriesExceeded:
            return "Maximum retries exceeded"
        }
    }
}