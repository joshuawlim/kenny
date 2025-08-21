import Foundation

/// Tool Registry: JSON schema validation and tool execution interface
/// Maps to existing mac_tools CLI commands with live data integration
public class ToolRegistry {
    private var tools: [String: ToolDefinition]
    private let macToolsPath: String
    
    public init(macToolsPath: String? = nil) {
        self.macToolsPath = macToolsPath ?? Self.findMacToolsPath()
        self.tools = [:]
        self.tools = self.buildToolDefinitions()
    }
    
    private static func findMacToolsPath() -> String {
        // Priority order: ENV var, /usr/local/bin, .build/release, PATH lookup
        if let envPath = ProcessInfo.processInfo.environment["MAC_TOOLS_PATH"] {
            return envPath
        }
        
        let candidates = [
            "/usr/local/bin/mac_tools",
            "./.build/release/mac_tools",
            "../.build/release/mac_tools",
            "../../.build/release/mac_tools"
        ]
        
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        
        // Fallback to PATH lookup
        return "mac_tools"
    }
    
    public func getAvailableTools() -> [ToolDefinition] {
        return Array(tools.values)
    }
    
    public func getTool(_ name: String) -> ToolDefinition? {
        return tools[name]
    }
    
    /// Execute tool with correlation tracking for plan workflow
    public func executeWithCorrelation(toolName: String, arguments: [String: Any], correlationId: String, planId: String, stepIndex: Int) async throws -> [String: Any] {
        guard let tool = tools[toolName] else {
            throw ToolExecutionError.processFailed(toolName, "Tool not found")
        }
        
        // Add correlation metadata to arguments
        var enhancedArgs = arguments
        enhancedArgs["_correlation_id"] = correlationId
        enhancedArgs["_plan_id"] = planId
        enhancedArgs["_step_index"] = stepIndex
        
        // Execute the tool
        return try await tool.execute(enhancedArgs)
    }
    
    // MARK: - Tool Definitions with JSON Schemas
    
    private func buildToolDefinitions() -> [String: ToolDefinition] {
        return [
            "search_data": ToolDefinition(
                name: "search_data",
                description: "Search across all personal data (emails, contacts, calendar, files, etc.) using hybrid search",
                parameters: [
                    "query": ParameterSchema(type: .string, required: true, description: "Search query"),
                    "limit": ParameterSchema(type: .integer, required: false, description: "Max results (default 10)"),
                    "hybrid": ParameterSchema(type: .boolean, required: false, description: "Use hybrid search (default true)")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("search_data", "Tool registry not available") }
                    // This integrates with Week 1-3 database + hybrid search
                    return try await self.executeSearch(args)
                }
            ),
            
            "list_mail": ToolDefinition(
                name: "list_mail",
                description: "List recent email headers from Mail.app",
                parameters: [
                    "since": ParameterSchema(type: .string, required: false, description: "ISO8601 date filter"),
                    "limit": ParameterSchema(type: .integer, required: false, description: "Max emails (default 50)")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("mail_list_headers", "Tool registry not available") }
                    return try await self.executeMacTool("mail_list_headers", args)
                }
            ),
            
            "list_calendar": ToolDefinition(
                name: "list_calendar",
                description: "List calendar events from Calendar.app",
                parameters: [
                    "from": ParameterSchema(type: .string, required: true, description: "Start date (ISO8601)"),
                    "to": ParameterSchema(type: .string, required: true, description: "End date (ISO8601)")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("calendar_list", "Tool registry not available") }
                    return try await self.executeMacTool("calendar_list", args)
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
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("reminders_create", "Tool registry not available") }
                    return try await self.executeMacTool("reminders_create", args)
                }
            ),
            
            "delete_reminder": ToolDefinition(
                name: "delete_reminder",
                description: "Delete a reminder from Reminders.app",
                parameters: [
                    "id": ParameterSchema(type: .string, required: true, description: "Reminder ID to delete")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("reminders_delete", "Tool registry not available") }
                    return try await self.executeMacTool("reminders_delete", args)
                }
            ),
            
            "delete_event": ToolDefinition(
                name: "delete_event", 
                description: "Delete an event from Calendar.app",
                parameters: [
                    "id": ParameterSchema(type: .string, required: true, description: "Event ID to delete")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("calendar_delete", "Tool registry not available") }
                    return try await self.executeMacTool("calendar_delete", args)
                }
            ),
            
            "append_note": ToolDefinition(
                name: "append_note",
                description: "Append text to an existing note in Notes.app",
                parameters: [
                    "note_id": ParameterSchema(type: .string, required: true, description: "Note identifier"),
                    "text": ParameterSchema(type: .string, required: true, description: "Text to append")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("notes_append", "Tool registry not available") }
                    return try await self.executeMacTool("notes_append", args)
                }
            ),
            
            "move_file": ToolDefinition(
                name: "move_file", 
                description: "Move files on the filesystem with safety checks",
                parameters: [
                    "src": ParameterSchema(type: .string, required: true, description: "Source file path"),
                    "dst": ParameterSchema(type: .string, required: true, description: "Destination file path")
                ],
                execute: { [weak self] args in
                    guard let self = self else { throw ToolExecutionError.processFailed("files_move", "Tool registry not available") }
                    return try await self.executeMacTool("files_move", args)
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
    
    private func executeSearch(_ arguments: [String: Any]) async throws -> [String: Any] {
        // Integrate with existing Orchestrator + HybridSearch (Week 3)
        let query = arguments["query"] as? String ?? ""
        let limit = arguments["limit"] as? Int ?? 10
        let useHybrid = arguments["hybrid"] as? Bool ?? true
        
        // Check cache first
        if let cachedResults = CacheManager.shared.getCachedSearchResults(for: query) {
            PerformanceMonitor.shared.recordMetric(name: "search.cache_hit", value: 1)
            return [
                "results": cachedResults.map { $0.toDictionary() },
                "search_type": "cached",
                "count": cachedResults.count
            ]
        }
        
        // Create a database connection and perform search
        let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
        let database = Database(path: dbPath)
        
        if useHybrid {
            // Use hybrid search (BM25 + embeddings)
            let embeddingsService = EmbeddingsService()
            let hybridSearch = HybridSearch(database: database, embeddingsService: embeddingsService)
            
            do {
                let results = try await hybridSearch.search(query: query, limit: limit)
                let hasEmbeddingResults = results.contains { $0.embeddingScore > 0.0 }
                let searchResults = results.map { hybridResult -> SearchResult in
                    return SearchResult(
                        id: hybridResult.documentId,
                        type: hybridResult.appSource,
                        title: hybridResult.title,
                        snippet: hybridResult.snippet,
                        contextInfo: hybridResult.sourcePath ?? "",
                        rank: Double(hybridResult.score),
                        sourcePath: hybridResult.sourcePath
                    )
                }
                
                // Cache the results
                CacheManager.shared.cacheSearchResults(searchResults, for: query)
                
                return [
                    "results": searchResults.map { $0.toDictionary() },
                    "search_type": hasEmbeddingResults ? "hybrid" : "bm25_only",
                    "count": searchResults.count
                ]
            } catch {
                // Silently fall back to BM25 (could add verbose flag later)
                // Fall through to BM25
            }
        }
        
        // Fallback to BM25 search
        let results = database.searchMultiDomain(query, types: [], limit: limit)
        
        // Cache BM25 results too
        CacheManager.shared.cacheSearchResults(results, for: query, ttl: 30) // Shorter TTL for fallback
        
        return [
            "results": results.map { $0.toDictionary() },
            "search_type": "bm25", 
            "count": results.count
        ]
    }
    
    private func executeMacTool(_ toolName: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        // Check if this is a mutating operation and enforce dry-run safety
        let isMutating = isMutatingTool(toolName)
        let hasConfirm = arguments["confirm"] as? Bool == true
        let hasDryRun = arguments["dry_run"] as? Bool == true
        
        // Safety enforcement: Mutating tools must use dry-run first, then confirm
        if isMutating && !hasConfirm && !hasDryRun {
            // Force dry-run for first call to mutating tools
            var safeArgs = arguments
            safeArgs["dry_run"] = true
            return try await executeMacToolWithArgs(toolName, safeArgs, isDryRun: true)
        }
        
        if isMutating && hasConfirm && !hasDryRun {
            // This is a confirm call - verify operation hash if provided
            if let expectedHash = arguments["operation_hash"] as? String,
               let planId = arguments["_plan_id"] as? String {
                // In a full implementation, we'd verify the hash matches the planned operation
                // For now, we'll log the confirmation
                print("🔒 Confirmed mutating operation \(toolName) with hash \(expectedHash) for plan \(planId)")
            }
        }
        
        return try await executeMacToolWithArgs(toolName, arguments, isDryRun: hasDryRun)
    }
    
    private func executeMacToolWithArgs(_ toolName: String, _ arguments: [String: Any], isDryRun: Bool) async throws -> [String: Any] {
        // Execute the existing mac_tools CLI with JSON I/O
        var args = ["mac_tools", toolName]
        
        // Convert arguments to CLI parameters with proper kebab-case and boolean handling
        for (key, value) in arguments {
            // Skip internal correlation parameters
            if key.hasPrefix("_") { continue }
            
            // Convert underscore_case to kebab-case
            let kebabKey = key.replacingOccurrences(of: "_", with: "-")
            
            // Handle boolean values as flags
            if let boolValue = value as? Bool {
                if boolValue {
                    args.append("--\(kebabKey)")
                }
                // Don't add anything for false boolean values
            } else {
                args.append("--\(kebabKey)")
                args.append(String(describing: value))
            }
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.macToolsPath)
        process.arguments = Array(args.dropFirst()) // Remove "mac_tools" from args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        let startTime = Date()
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startTime)
        
        var executionError: Error?
        var result: [String: Any]?
        
        if process.terminationStatus != 0 {
            executionError = ToolExecutionError.processFailed(toolName, output)
        } else {
            // Parse JSON response
            if let jsonData = output.data(using: .utf8),
               let parsedResult = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                result = parsedResult
            } else {
                executionError = ToolExecutionError.invalidOutput(toolName, output)
                result = ["error": "Invalid JSON output", "raw_output": output]
            }
        }
        
        // Log tool execution to audit trail
        if let correlationId = arguments["_correlation_id"] as? String,
           let planId = arguments["_plan_id"] as? String,
           let stepIndex = arguments["_step_index"] as? Int {
            
            let operationHash = isDryRun && isMutatingTool(toolName) ? 
                "\(toolName):\(arguments.filter { !$0.key.hasPrefix("_") })".sha256() : nil
            
            AuditLogger.shared.logToolExecution(
                correlationId: correlationId,
                planId: planId,
                stepIndex: stepIndex,
                toolName: toolName,
                arguments: arguments.filter { !$0.key.hasPrefix("_") },
                isDryRun: isDryRun,
                result: result,
                error: executionError,
                duration: duration,
                operationHash: operationHash
            )
        }
        
        // Throw error if execution failed
        if let error = executionError {
            throw error
        }
        
        guard var enhancedResult = result else {
            throw ToolExecutionError.invalidOutput(toolName, "No result available")
        }
        
        // Enhance result with safety metadata
        enhancedResult["was_dry_run"] = isDryRun
        enhancedResult["is_mutating"] = isMutatingTool(toolName)
        
        if isDryRun && isMutatingTool(toolName) {
            // Generate operation hash for confirmation
            let operationData = "\(toolName):\(arguments.filter { !$0.key.hasPrefix("_") })"
            enhancedResult["operation_hash"] = operationData.sha256()
            enhancedResult["requires_confirmation"] = true
        }
        
        return enhancedResult
    }
    
    /// Determine if a tool performs mutating operations
    private func isMutatingTool(_ toolName: String) -> Bool {
        let mutatingTools = [
            "create_reminder",
            "delete_reminder",
            "send_email", 
            "run_shortcut",
            "create_event",
            "delete_event",
            "update_event"
        ]
        
        // Check for mutating keywords in tool name
        let mutatingKeywords = ["create", "delete", "update", "send", "run", "execute", "modify", "write"]
        
        return mutatingTools.contains(toolName) || 
               mutatingKeywords.contains { toolName.lowercased().contains($0) }
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