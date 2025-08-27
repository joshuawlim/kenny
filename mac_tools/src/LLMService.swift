import Foundation
import os.log

/// LLM Service for local inference with Ollama
/// Designed for tool selection and function calling reasoning
public class LLMService {
    private let ollamaBaseURL: String
    private let model: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    private let logger = Logger(subsystem: "Kenny.LLMService", category: "Service")
    
    public init() {
        let config = ConfigurationManager.shared.llm
        self.ollamaBaseURL = config.endpoint
        self.model = config.model
        self.timeoutInterval = config.timeout
        self.maxRetries = config.maxRetries
    }
    
    /// Legacy initializer for custom configuration (testing/special cases)
    public init(
        ollamaBaseURL: String,
        model: String,
        timeoutInterval: TimeInterval,
        maxRetries: Int
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
                logger.warning("LLM request failed (attempt \(attempt)/\(self.maxRetries)): \(error.localizedDescription)")
                
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
    
    /// Generate a minimal response for warm-up purposes only
    /// Uses the smallest possible request to load the model without wasting resources
    private func generateMinimalResponse() async throws -> String {
        let url = URL(string: "\(ollamaBaseURL)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0 // Shorter timeout for warm-up
        
        // Minimal Ollama chat payload for warm-up
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user", 
                    "content": "Hi"
                ]
            ],
            "stream": false,
            "options": [
                "num_predict": 1,  // Generate only 1 token
                "temperature": 0.0,
                "top_p": 1.0,
                "seed": 42 // Consistent seed for reproducible minimal response
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
        
        // Parse response but don't care about content for warm-up
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse("Could not parse minimal response")
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Warm up the LLM by checking model availability and sending a minimal request
    /// This prevents cold start delays on the first real query
    public func warmUp() async -> Bool {
        do {
            let startTime = Date()
            logger.info("Warming up LLM model '\(self.model)'...")
            
            // First check if model is available (lighter operation)
            guard await checkAvailability() else {
                logger.warning("Model \(self.model) not available for warm-up")
                return false
            }
            
            // Send a minimal request to load the model into memory
            _ = try await generateMinimalResponse()
            
            let duration = Date().timeIntervalSince(startTime)
            logger.info("LLM warmed up successfully in \(String(format: "%.1f", duration))s")
            return true
        } catch {
            logger.error("Failed to warm up LLM: \(error.localizedDescription)")
            return false
        }
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
    
    /// Pull model if not available (with timeout protection)
    /// Returns true if model is available after this call, false if pull failed or timed out
    public func ensureModelAvailable(timeout: TimeInterval = 60.0) async -> Bool {
        // Check if model is already available
        if await checkAvailability() {
            return true // Model already available
        }
        
        logger.info("Pulling model \(self.model) from Ollama (timeout: \(Int(timeout))s)...")
        
        do {
            return try await withThrowingTaskGroup(of: Bool.self) { group in
                // Add the actual pull task
                group.addTask {
                    try await self.performModelPull()
                    return true
                }
                
                // Add timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw LLMError.modelNotAvailable("Model pull timed out after \(Int(timeout))s")
                }
                
                // Return the first result (either success or timeout)
                for try await result in group {
                    group.cancelAll()
                    return result
                }
                
                return false
            }
        } catch {
            logger.error("Failed to ensure model availability: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Perform the actual model pull operation
    private func performModelPull() async throws {
        let url = URL(string: "\(ollamaBaseURL)/api/pull")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300.0 // Network timeout (different from user timeout)
        
        let payload = ["name": model]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LLMError.modelNotAvailable("Failed to pull model \(model)")
        }
        
        logger.info("Model \(self.model) ready")
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