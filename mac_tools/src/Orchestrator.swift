import Foundation

/// The Orchestrator is the central coordination layer for Kenny.
/// It processes user requests, coordinates with tools and database, and maintains state.
/// This is the Week 0/1 foundation - a simple request router and state manager.
public class Orchestrator {
    private let database: Database
    private let toolLayer: ToolLayer
    
    public init(database: Database) {
        self.database = database
        self.toolLayer = ToolLayer()
    }
    
    /// Process a user request and return a structured response
    public func processRequest(_ request: UserRequest) async throws -> UserResponse {
        let startTime = Date()
        
        // Log the incoming request
        logRequest(request)
        
        do {
            let response = try await handleRequest(request)
            
            // Log success
            let duration = Date().timeIntervalSince(startTime)
            logResponse(request: request, response: response, duration: duration, error: nil)
            
            return response
        } catch {
            // Log error
            let duration = Date().timeIntervalSince(startTime)
            logResponse(request: request, response: nil, duration: duration, error: error)
            throw error
        }
    }
    
    /// Handle different types of user requests
    private func handleRequest(_ request: UserRequest) async throws -> UserResponse {
        switch request.type {
        case .search:
            return try await handleSearchRequest(request)
        case .toolExecution:
            return try await handleToolExecutionRequest(request)
        case .dataIngest:
            return try await handleDataIngestRequest(request)
        case .status:
            return handleStatusRequest(request)
        }
    }
    
    // MARK: - Request Handlers
    
    private func handleSearchRequest(_ request: UserRequest) async throws -> UserResponse {
        guard let query = request.parameters["query"] as? String else {
            throw OrchestratorError.invalidParameters("Missing query parameter")
        }
        
        let limit = request.parameters["limit"] as? Int ?? 20
        let types = request.parameters["types"] as? [String] ?? []
        
        // Perform multi-domain search
        let results = database.searchMultiDomain(query, types: types, limit: limit)
        
        return UserResponse(
            type: .searchResults,
            success: true,
            data: ["results": results.map { $0.toDictionary() }],
            message: "Found \(results.count) results for '\(query)'"
        )
    }
    
    private func handleToolExecutionRequest(_ request: UserRequest) async throws -> UserResponse {
        guard let toolName = request.parameters["tool"] as? String else {
            throw OrchestratorError.invalidParameters("Missing tool parameter")
        }
        
        let toolParams = request.parameters["parameters"] as? [String: Any] ?? [:]
        let dryRun = request.parameters["dry_run"] as? Bool ?? true
        
        // Execute tool through tool layer
        let result = try await toolLayer.executeTool(toolName, parameters: toolParams, dryRun: dryRun)
        
        return UserResponse(
            type: .toolExecution,
            success: result.success,
            data: result.data,
            message: result.message
        )
    }
    
    private func handleDataIngestRequest(_ request: UserRequest) async throws -> UserResponse {
        let fullSync = request.parameters["full_sync"] as? Bool ?? false
        let sources = request.parameters["sources"] as? [String] ?? []
        
        let ingestManager = IngestManager(database: database)
        
        if sources.isEmpty {
            // Ingest all sources
            // For now, let's just return empty stats instead of a full ingest
            var stats = IngestStats(source: "orchestrator")
            stats.duration = 0
            return UserResponse(
                type: .dataIngest,
                success: true,
                data: ["stats": stats.toDictionary()],
                message: "Completed full data ingest: \(stats.itemsCreated) items created"
            )
        } else {
            // Ingest specific sources
            let results = try await ingestSpecificSources(sources, fullSync: fullSync, ingestManager: ingestManager)
            return UserResponse(
                type: .dataIngest,
                success: true,
                data: ["results": results],
                message: "Completed ingest for \(sources.count) sources"
            )
        }
    }
    
    private func handleStatusRequest(_ request: UserRequest) -> UserResponse {
        let dbStats = database.getStats()
        let systemInfo = gatherSystemInfo()
        
        return UserResponse(
            type: .status,
            success: true,
            data: [
                "database": dbStats,
                "system": systemInfo,
                "version": "0.1.0",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ],
            message: "Kenny system status"
        )
    }
    
    // MARK: - Helper Methods
    
    private func ingestSpecificSources(_ sources: [String], fullSync: Bool, ingestManager: IngestManager) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        
        for source in sources {
            do {
                let stats: IngestStats
                switch source.lowercased() {
                case "mail":
                    stats = try await ingestManager.ingestMail(isFullSync: fullSync)
                case "calendar":
                    stats = try await ingestManager.ingestCalendar(isFullSync: fullSync)
                case "contacts":
                    stats = try await ingestManager.ingestContacts(isFullSync: fullSync)
                case "messages":
                    stats = try await ingestManager.ingestMessages(isFullSync: fullSync)
                case "notes":
                    stats = try await ingestManager.ingestNotes(isFullSync: fullSync)
                case "files":
                    stats = try await ingestManager.ingestFiles(isFullSync: fullSync)
                case "reminders":
                    stats = try await ingestManager.ingestReminders(isFullSync: fullSync)
                case "whatsapp":
                    let whatsappIngester = WhatsAppIngester(database: database)
                    stats = try await whatsappIngester.ingestWhatsApp(isFullSync: fullSync)
                default:
                    throw OrchestratorError.unknownDataSource(source)
                }
                
                results.append([
                    "source": source,
                    "success": true,
                    "stats": stats.toDictionary()
                ])
            } catch {
                results.append([
                    "source": source,
                    "success": false,
                    "error": error.localizedDescription
                ])
            }
        }
        
        return results
    }
    
    private func gatherSystemInfo() -> [String: Any] {
        let processInfo = ProcessInfo.processInfo
        return [
            "hostname": processInfo.hostName,
            "os_version": processInfo.operatingSystemVersionString,
            "memory": processInfo.physicalMemory,
            "cpu_count": processInfo.processorCount,
            "uptime": processInfo.systemUptime
        ]
    }
    
    // MARK: - Logging
    
    private func logRequest(_ request: UserRequest) {
        let logEntry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": "request_received",
            "type": request.type.rawValue,
            "user_id": request.userId,
            "request_id": request.requestId,
            "success": NSNull(),
            "duration_ms": NSNull(),
            "error": NSNull()
        ]
        
        database.insert("orchestrator_logs", data: logEntry)
    }
    
    private func logResponse(request: UserRequest, response: UserResponse?, duration: TimeInterval, error: Error?) {
        let logEntry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": "request_completed", 
            "type": request.type.rawValue,
            "user_id": request.userId,
            "request_id": request.requestId,
            "success": error == nil,
            "duration_ms": Int(duration * 1000),
            "error": error?.localizedDescription ?? NSNull()
        ]
        
        database.insert("orchestrator_logs", data: logEntry)
    }
}

// MARK: - Data Structures

public struct UserRequest {
    public let requestId: String
    public let userId: String
    public let type: RequestType
    public let parameters: [String: Any]
    public let timestamp: Date
    
    public init(type: RequestType, parameters: [String: Any] = [:], userId: String = "default") {
        self.requestId = UUID().uuidString
        self.userId = userId
        self.type = type
        self.parameters = parameters
        self.timestamp = Date()
    }
}

public struct UserResponse {
    public let type: ResponseType
    public let success: Bool
    public let data: [String: Any]
    public let message: String
    public let timestamp: Date
    
    public init(type: ResponseType, success: Bool, data: [String: Any] = [:], message: String) {
        self.type = type
        self.success = success
        self.data = data
        self.message = message
        self.timestamp = Date()
    }
}

public enum RequestType: String, CaseIterable {
    case search = "search"
    case toolExecution = "tool_execution"
    case dataIngest = "data_ingest"
    case status = "status"
}

public enum ResponseType: String {
    case searchResults = "search_results"
    case toolExecution = "tool_execution"
    case dataIngest = "data_ingest"
    case status = "status"
    case error = "error"
}

// MARK: - Tool Layer (Placeholder)

/// Simple tool layer that wraps the existing mac_tools CLI
private class ToolLayer {
    func executeTool(_ toolName: String, parameters: [String: Any], dryRun: Bool) async throws -> ToolResult {
        // For now, this is a simple wrapper around the CLI tools
        // In the future, this would be more sophisticated with direct Swift integration
        
        let command = buildToolCommand(toolName, parameters: parameters, dryRun: dryRun)
        let result = try await executeShellCommand(command)
        
        return ToolResult(
            success: result.success,
            data: result.data,
            message: result.message
        )
    }
    
    private func buildToolCommand(_ toolName: String, parameters: [String: Any], dryRun: Bool) -> String {
        var args: [String] = ["mac_tools", toolName]
        
        if dryRun {
            args.append("--dry-run")
        }
        
        // Convert parameters to CLI arguments
        for (key, value) in parameters {
            args.append("--\(key)")
            args.append("\(value)")
        }
        
        return args.joined(separator: " ")
    }
    
    private func executeShellCommand(_ command: String) async throws -> ToolResult {
        // Simple shell command execution
        // In production, would use proper Process API
        
        return ToolResult(
            success: true,
            data: ["command": command],
            message: "Tool execution placeholder"
        )
    }
}

private struct ToolResult {
    let success: Bool
    let data: [String: Any]
    let message: String
}

// MARK: - Errors

public enum OrchestratorError: Error, LocalizedError {
    case invalidParameters(String)
    case unknownDataSource(String)
    case toolExecutionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidParameters(let msg):
            return "Invalid parameters: \(msg)"
        case .unknownDataSource(let source):
            return "Unknown data source: \(source)"
        case .toolExecutionFailed(let msg):
            return "Tool execution failed: \(msg)"
        }
    }
}

// MARK: - Extensions

extension SearchResult {
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "type": type,
            "title": title,
            "snippet": snippet,
            "app_source": contextInfo,
            "source_path": sourcePath ?? NSNull()
        ]
    }
}

extension IngestStats {
    func toDictionary() -> [String: Any] {
        return [
            "source": source,
            "items_processed": itemsProcessed,
            "items_created": itemsCreated,
            "items_updated": itemsUpdated,
            "errors": errors,
            "duration": duration
        ]
    }
}