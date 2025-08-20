import Foundation

/// AssistantCore: Week 4 intelligent function calling system
/// Capabilities: tool selection, argument validation, execution, retry with error summarization
public class AssistantCore {
    private let database: Database
    private let llmService: LLMService
    private let toolRegistry: ToolRegistry
    private let maxRetries: Int
    
    public init(database: Database, maxRetries: Int = 3) {
        self.database = database
        self.llmService = LLMService()
        self.toolRegistry = ToolRegistry()
        self.maxRetries = maxRetries
    }
    
    /// Main entry point: process user query and execute appropriate tool
    public func processQuery(_ query: String) async throws -> AssistantResponse {
        let startTime = Date()
        var attempts = 0
        var lastError: Error?
        
        print("🤖 Processing query: '\(query)'")
        
        while attempts < maxRetries {
            attempts += 1
            
            do {
                // Step 1: Choose appropriate tool using LLM reasoning
                let toolSelection = try await selectTool(for: query, attempt: attempts)
                print("🔧 Selected tool: \(toolSelection.toolName)")
                
                // Step 2: Validate arguments against JSON schema
                try validateArguments(toolSelection.toolName, arguments: toolSelection.arguments)
                print("✅ Arguments validated")
                
                // Step 3: Execute tool with validated arguments
                let result = try await executeTool(toolSelection.toolName, arguments: toolSelection.arguments)
                print("🚀 Tool executed successfully")
                
                // Step 4: Return structured result
                let duration = Date().timeIntervalSince(startTime)
                return AssistantResponse(
                    success: true,
                    result: result,
                    toolUsed: toolSelection.toolName,
                    attempts: attempts,
                    duration: duration,
                    error: nil
                )
                
            } catch {
                lastError = error
                print("❌ Attempt \(attempts) failed: \(error)")
                
                // Don't retry for validation errors
                if error is ValidationError {
                    break
                }
                
                if attempts < maxRetries {
                    print("🔄 Retrying with error context...")
                }
            }
        }
        
        // Step 5: Return failure with error summarization
        let errorSummary = summarizeError(lastError ?? AssistantError.maxRetriesExceeded)
        let duration = Date().timeIntervalSince(startTime)
        
        return AssistantResponse(
            success: false,
            result: nil,
            toolUsed: nil,
            attempts: attempts,
            duration: duration,
            error: errorSummary
        )
    }
    
    // MARK: - Step 1: Tool Selection
    
    private func selectTool(for query: String, attempt: Int) async throws -> ToolSelection {
        // Get available tools and their schemas
        let availableTools = toolRegistry.getAvailableTools()
        
        // Build context for LLM
        var context = """
        You are an AI assistant that selects the appropriate tool for user queries.
        Current date: \(ISO8601DateFormatter().string(from: Date()))
        
        Available tools:
        """
        
        for tool in availableTools {
            context += "\n- \(tool.name): \(tool.description)"
            context += "\n  Parameters: \(tool.parameters)"
        }
        
        if attempt > 1 {
            context += "\n\nPrevious attempts failed. Consider alternative approaches."
        }
        
        context += """
        
        User query: \(query)
        
        Respond with JSON only:
        {
            "tool_name": "selected_tool_name",
            "reasoning": "why this tool was chosen",
            "arguments": { "param1": "value1", "param2": "value2" }
        }
        """
        
        let response = try await llmService.generateResponse(prompt: context)
        return try parseToolSelection(response)
    }
    
    private func parseToolSelection(_ response: String) throws -> ToolSelection {
        guard let data = response.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = json["tool_name"] as? String,
              let reasoning = json["reasoning"] as? String,
              let arguments = json["arguments"] as? [String: Any] else {
            throw AssistantError.invalidLLMResponse(response)
        }
        
        return ToolSelection(toolName: toolName, reasoning: reasoning, arguments: arguments)
    }
    
    // MARK: - Step 2: Argument Validation
    
    private func validateArguments(_ toolName: String, arguments: [String: Any]) throws {
        guard let tool = toolRegistry.getTool(toolName) else {
            throw ValidationError.toolNotFound(toolName)
        }
        
        try tool.validateArguments(arguments)
    }
    
    // MARK: - Step 3: Tool Execution  
    
    private func executeTool(_ toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let tool = toolRegistry.getTool(toolName) else {
            throw AssistantError.toolNotFound(toolName)
        }
        
        return try await tool.execute(arguments)
    }
    
    // MARK: - Step 5: Error Summarization
    
    private func summarizeError(_ error: Error) -> String {
        switch error {
        case let validationError as ValidationError:
            return "Validation failed: \(validationError.localizedDescription)"
        case let assistantError as AssistantError:
            return "Assistant error: \(assistantError.localizedDescription)"
        default:
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Data Types

public struct ToolSelection {
    let toolName: String
    let reasoning: String
    let arguments: [String: Any]
}

public struct AssistantResponse {
    public let success: Bool
    public let result: [String: Any]?
    public let toolUsed: String?
    public let attempts: Int
    public let duration: TimeInterval
    public let error: String?
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "success": success,
            "attempts": attempts,
            "duration": duration
        ]
        
        if let result = result {
            dict["result"] = result
        }
        if let toolUsed = toolUsed {
            dict["tool_used"] = toolUsed
        }
        if let error = error {
            dict["error"] = error
        }
        
        return dict
    }
}

// MARK: - Error Types

public enum AssistantError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidLLMResponse(String)
    case maxRetriesExceeded
    
    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Tool not found: \(tool)"
        case .invalidLLMResponse(let response):
            return "Invalid LLM response: \(response)"
        case .maxRetriesExceeded:
            return "Maximum retries exceeded"
        }
    }
}

public enum ValidationError: Error, LocalizedError {
    case toolNotFound(String)
    case missingParameter(String)
    case invalidParameterType(String, expected: String, actual: String)
    case invalidParameterValue(String, String)
    
    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Tool not found: \(tool)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidParameterType(let param, let expected, let actual):
            return "Parameter \(param) expected \(expected), got \(actual)"
        case .invalidParameterValue(let param, let reason):
            return "Invalid value for parameter \(param): \(reason)"
        }
    }
}