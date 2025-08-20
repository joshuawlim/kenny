import Foundation

/// Tool Registry: JSON schema validation and tool execution interface
/// Maps to existing mac_tools CLI commands with live data integration
public class ToolRegistry {
    private let tools: [String: ToolDefinition]
    private let macToolsPath: String
    
    public init(macToolsPath: String = "/usr/local/bin/mac_tools") {
        self.macToolsPath = macToolsPath
        self.tools = Self.buildToolDefinitions()
    }
    
    public func getAvailableTools() -> [ToolDefinition] {
        return Array(tools.values)
    }
    
    public func getTool(_ name: String) -> ToolDefinition? {
        return tools[name]
    }
    
    // MARK: - Tool Definitions with JSON Schemas
    
    private static func buildToolDefinitions() -> [String: ToolDefinition] {
        return [
            "search_data": ToolDefinition(
                name: "search_data",
                description: "Search across all personal data (emails, contacts, calendar, files, etc.) using hybrid search",
                parameters: [
                    "query": ParameterSchema(type: .string, required: true, description: "Search query"),
                    "limit": ParameterSchema(type: .integer, required: false, description: "Max results (default 10)"),
                    "hybrid": ParameterSchema(type: .boolean, required: false, description: "Use hybrid search (default true)")
                ],
                execute: { args in
                    // This integrates with Week 1-3 database + hybrid search
                    return try await Self.executeSearch(args)
                }
            ),
            
            "list_mail": ToolDefinition(
                name: "list_mail",
                description: "List recent email headers from Mail.app",
                parameters: [
                    "since": ParameterSchema(type: .string, required: false, description: "ISO8601 date filter"),
                    "limit": ParameterSchema(type: .integer, required: false, description: "Max emails (default 50)")
                ],
                execute: { args in
                    return try await Self.executeMacTool("mail_list_headers", args)
                }
            ),
            
            "list_calendar": ToolDefinition(
                name: "list_calendar",
                description: "List calendar events from Calendar.app",
                parameters: [
                    "from": ParameterSchema(type: .string, required: true, description: "Start date (ISO8601)"),
                    "to": ParameterSchema(type: .string, required: true, description: "End date (ISO8601)")
                ],
                execute: { args in
                    return try await Self.executeMacTool("calendar_list", args)
                }
            ),
            
            "create_reminder": ToolDefinition(
                name: "create_reminder",
                description: "Create a reminder in Reminders.app with dry-run support",
                parameters: [
                    "title": ParameterSchema(type: .string, required: true, description: "Reminder title"),
                    "due": ParameterSchema(type: .string, required: false, description: "Due date (ISO8601)"),
                    "notes": ParameterSchema(type: .string, required: false, description: "Additional notes")
                ],
                execute: { args in
                    return try await Self.executeMacTool("reminders_create", args)
                }
            ),
            
            "append_note": ToolDefinition(
                name: "append_note",
                description: "Append text to an existing note in Notes.app",
                parameters: [
                    "note_id": ParameterSchema(type: .string, required: true, description: "Note identifier"),
                    "text": ParameterSchema(type: .string, required: true, description: "Text to append")
                ],
                execute: { args in
                    return try await Self.executeMacTool("notes_append", args)
                }
            ),
            
            "move_file": ToolDefinition(
                name: "move_file", 
                description: "Move files on the filesystem with safety checks",
                parameters: [
                    "src": ParameterSchema(type: .string, required: true, description: "Source file path"),
                    "dst": ParameterSchema(type: .string, required: true, description: "Destination file path")
                ],
                execute: { args in
                    return try await Self.executeMacTool("files_move", args)
                }
            ),
            
            "get_current_time": ToolDefinition(
                name: "get_current_time",
                description: "Get current date and time in various formats",
                parameters: [:],
                execute: { args in
                    let now = Date()
                    return [
                        "current_time": ISO8601DateFormatter().string(from: now),
                        "timestamp": now.timeIntervalSince1970,
                        "formatted": DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .short)
                    ]
                }
            )
        ]
    }
    
    // MARK: - Execution Methods
    
    private static func executeSearch(_ arguments: [String: Any]) async throws -> [String: Any] {
        // Integrate with existing Orchestrator + HybridSearch (Week 3)
        let query = arguments["query"] as? String ?? ""
        let limit = arguments["limit"] as? Int ?? 10
        let useHybrid = arguments["hybrid"] as? Bool ?? true
        
        // Create a database connection and perform search
        let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
        let database = Database(path: dbPath)
        
        if useHybrid {
            // Use hybrid search (BM25 + embeddings)
            let embeddingsService = EmbeddingsService()
            let hybridSearch = HybridSearch(database: database, embeddingsService: embeddingsService)
            
            do {
                let results = try await hybridSearch.search(query: query, limit: limit)
                return [
                    "results": results.map { $0.toDictionary() },
                    "search_type": "hybrid",
                    "count": results.count
                ]
            } catch {
                print("Hybrid search failed, falling back to BM25: \(error)")
                // Fall through to BM25
            }
        }
        
        // Fallback to BM25 search
        let results = database.searchMultiDomain(query, types: [], limit: limit)
        return [
            "results": results.map { $0.toDictionary() },
            "search_type": "bm25", 
            "count": results.count
        ]
    }
    
    private static func executeMacTool(_ toolName: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        // Execute the existing mac_tools CLI with JSON I/O
        var args = ["mac_tools", toolName]
        
        // Convert arguments to CLI parameters
        for (key, value) in arguments {
            args.append("--\(key)")
            args.append(String(describing: value))
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/mac_tools")
        process.arguments = Array(args.dropFirst()) // Remove "mac_tools" from args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        guard process.terminationStatus == 0 else {
            throw ToolExecutionError.processFailed(toolName, output)
        }
        
        // Parse JSON response
        guard let jsonData = output.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ToolExecutionError.invalidOutput(toolName, output)
        }
        
        return result
    }
}

// MARK: - Tool Definition Types

public struct ToolDefinition {
    public let name: String
    public let description: String
    public let parameters: [String: ParameterSchema]
    public let execute: ([String: Any]) async throws -> [String: Any]
    
    public func validateArguments(_ arguments: [String: Any]) throws {
        // Check required parameters
        for (paramName, schema) in parameters {
            if schema.required && arguments[paramName] == nil {
                throw ValidationError.missingParameter(paramName)
            }
            
            if let value = arguments[paramName] {
                try validateParameterType(paramName, value: value, schema: schema)
            }
        }
    }
    
    private func validateParameterType(_ paramName: String, value: Any, schema: ParameterSchema) throws {
        switch schema.type {
        case .string:
            guard value is String else {
                throw ValidationError.invalidParameterType(paramName, expected: "string", actual: String(describing: type(of: value)))
            }
        case .integer:
            guard value is Int else {
                throw ValidationError.invalidParameterType(paramName, expected: "integer", actual: String(describing: type(of: value)))
            }
        case .boolean:
            guard value is Bool else {
                throw ValidationError.invalidParameterType(paramName, expected: "boolean", actual: String(describing: type(of: value)))
            }
        }
    }
}

public struct ParameterSchema {
    public let type: ParameterType
    public let required: Bool
    public let description: String
    
    public init(type: ParameterType, required: Bool, description: String) {
        self.type = type
        self.required = required
        self.description = description
    }
}

public enum ParameterType {
    case string
    case integer
    case boolean
}

// MARK: - Execution Errors

public enum ToolExecutionError: Error, LocalizedError {
    case processFailed(String, String)
    case invalidOutput(String, String)
    
    public var errorDescription: String? {
        switch self {
        case .processFailed(let tool, let output):
            return "Tool \(tool) failed: \(output)"
        case .invalidOutput(let tool, let output):
            return "Tool \(tool) returned invalid JSON: \(output)"
        }
    }
}