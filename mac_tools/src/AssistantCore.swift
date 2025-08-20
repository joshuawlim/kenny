import Foundation

/// AssistantCore: Week 4 intelligent function calling system
/// Capabilities: tool selection, argument validation, execution, retry with error summarization
public class AssistantCore {
    private let database: Database
    private let llmService: LLMService
    private let toolRegistry: ToolRegistry
    private let maxRetries: Int
    private let verbose: Bool
    
    public init(database: Database, maxRetries: Int = 3, verbose: Bool = false) {
        self.database = database
        self.llmService = LLMService()
        self.toolRegistry = ToolRegistry()
        self.maxRetries = maxRetries
        self.verbose = verbose
    }
    
    /// Main entry point: process user query and execute appropriate tool
    public func processQuery(_ query: String) async throws -> AssistantResponse {
        let startTime = Date()
        var attempts = 0
        var lastError: Error?
        
        if verbose { print("🤖 Processing query: '\(query)'") }
        
        while attempts < maxRetries {
            attempts += 1
            
            do {
                // Step 1: Choose appropriate tool using LLM reasoning
                let toolSelection = try await selectTool(for: query, attempt: attempts)
                if verbose { print("🔧 Selected tool: \(toolSelection.toolName)") }
                
                // Step 2: Validate arguments against JSON schema
                try validateArguments(toolSelection.toolName, arguments: toolSelection.arguments)
                if verbose { print("✅ Arguments validated") }
                
                // Step 3: Execute tool with validated arguments
                let result = try await executeTool(toolSelection.toolName, arguments: toolSelection.arguments)
                if verbose { print("🚀 Tool executed successfully") }
                
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
                if verbose { print("❌ Attempt \(attempts) failed: \(error)") }
                
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
        
        // Check if Ollama is available, fallback to deterministic logic if not
        let isLLMAvailable = await llmService.checkAvailability()
        
        if !isLLMAvailable {
            if verbose { print("⚠️  Ollama not available, using deterministic tool selection") }
            return selectToolDeterministically(for: query, attempt: attempt, availableTools: availableTools)
        }
        
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
    
    /// Deterministic fallback when Ollama is offline (similar to TestAssistantCore logic)
    private func selectToolDeterministically(for query: String, attempt: Int, availableTools: [ToolDefinition]) -> ToolSelection {
        let lowercaseQuery = query.lowercased()
        
        // Time-related queries
        if lowercaseQuery.contains("time") || lowercaseQuery.contains("date") || lowercaseQuery.contains("now") {
            return ToolSelection(
                toolName: "get_current_time",
                reasoning: "Query asks for current time/date",
                arguments: [:]
            )
        }
        
        // Search queries  
        if lowercaseQuery.contains("search") || lowercaseQuery.contains("find") || lowercaseQuery.contains("look") {
            let searchTerm = extractSearchTerm(from: query)
            return ToolSelection(
                toolName: "search_data",
                reasoning: "Query contains search terms",
                arguments: ["query": searchTerm, "limit": 10]
            )
        }
        
        // Calendar queries
        if lowercaseQuery.contains("calendar") || lowercaseQuery.contains("event") || lowercaseQuery.contains("meeting") {
            let today = ISO8601DateFormatter().string(from: Date())
            let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
            return ToolSelection(
                toolName: "list_calendar",
                reasoning: "Query mentions calendar/events",
                arguments: ["from": today, "to": tomorrow]
            )
        }
        
        // Mail queries
        if lowercaseQuery.contains("mail") || lowercaseQuery.contains("email") {
            return ToolSelection(
                toolName: "list_mail",
                reasoning: "Query mentions mail/email",
                arguments: ["limit": 20]
            )
        }
        
        // Reminder queries
        if lowercaseQuery.contains("remind") || lowercaseQuery.contains("reminder") {
            let title = extractReminderTitle(from: query)
            return ToolSelection(
                toolName: "create_reminder",
                reasoning: "Query mentions reminder",
                arguments: ["title": title]
            )
        }
        
        // Default to search
        return ToolSelection(
            toolName: "search_data",
            reasoning: "Default fallback to search",
            arguments: ["query": query, "limit": 10]
        )
    }
    
    private func extractSearchTerm(from query: String) -> String {
        // Simple extraction: remove common search words
        let searchWords = ["search", "find", "look", "for", "about"]
        var cleanQuery = query.lowercased()
        
        for word in searchWords {
            cleanQuery = cleanQuery.replacingOccurrences(of: word, with: "")
        }
        
        return cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractReminderTitle(from query: String) -> String {
        // Extract title after "remind me to" or similar patterns
        let patterns = ["remind me to ", "reminder to ", "create reminder "]
        var title = query.lowercased()
        
        for pattern in patterns {
            if let range = title.range(of: pattern) {
                title = String(title[range.upperBound...])
                break
            }
        }
        
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseToolSelection(_ response: String) throws -> ToolSelection {
        guard let data = response.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = json["tool_name"] as? String,
              let reasoning = json["reasoning"] as? String,
              let arguments = json["arguments"] as? [String: Any] else {
            throw AssistantError.invalidLLMResponse(response)
        }
        
        // Coerce arguments to proper types for validation
        let coercedArguments = coerceArgumentTypes(arguments, for: toolName)
        return ToolSelection(toolName: toolName, reasoning: reasoning, arguments: coercedArguments)
    }
    
    /// Coerce LLM-produced arguments to proper types based on tool schema
    private func coerceArgumentTypes(_ arguments: [String: Any], for toolName: String) -> [String: Any] {
        guard let tool = toolRegistry.getTool(toolName) else {
            return arguments
        }
        
        var coerced: [String: Any] = [:]
        
        for (key, value) in arguments {
            if let paramSchema = tool.parameters[key] {
                coerced[key] = coerceValue(value, to: paramSchema.type)
            } else {
                coerced[key] = value
            }
        }
        
        return coerced
    }
    
    private func coerceValue(_ value: Any, to type: ParameterType) -> Any {
        switch type {
        case .integer:
            if let intValue = value as? Int {
                return intValue
            }
            if let stringValue = value as? String, let intValue = Int(stringValue) {
                return intValue
            }
            if let doubleValue = value as? Double {
                return Int(doubleValue)
            }
        case .boolean:
            if let boolValue = value as? Bool {
                return boolValue
            }
            if let stringValue = value as? String {
                return stringValue.lowercased() == "true" || stringValue == "1"
            }
            if let intValue = value as? Int {
                return intValue != 0
            }
        case .string:
            if let stringValue = value as? String {
                return stringValue
            }
            return String(describing: value)
        }
        
        return value
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