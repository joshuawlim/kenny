import Foundation

/// The Orchestrator is the central coordination layer for Kenny.
/// It processes user requests, coordinates with tools and database, and maintains state.
/// This is the Week 0/1 foundation - a simple request router and state manager.
public class Orchestrator {
    private let database: Database
    private let toolLayer: ToolLayer
    private let hybridSearch: HybridSearch?
    private let enhancedSearch: EnhancedHybridSearch?
    
    public init(database: Database, enableHybridSearch: Bool = true) {
        self.database = database
        self.toolLayer = ToolLayer()
        
        // Initialize hybrid search if enabled
        if enableHybridSearch {
            let embeddingsService = EmbeddingsService()
            self.hybridSearch = HybridSearch(database: database, embeddingsService: embeddingsService)
            self.enhancedSearch = EnhancedHybridSearch(database: database, embeddingsService: embeddingsService)
        } else {
            self.hybridSearch = nil
            self.enhancedSearch = nil
        }
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
        case .enhancedSearch:
            return try await handleEnhancedSearchRequest(request)
        case .intentSearch:
            return try await handleIntentSearchRequest(request)
        case .topicSearch:
            return try await handleTopicSearchRequest(request)
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
        let useHybrid = request.parameters["hybrid"] as? Bool ?? true
        
        // Use hybrid search if available and requested
        if useHybrid, let hybridSearch = self.hybridSearch {
            do {
                let hybridResults = try await hybridSearch.search(query: query, limit: limit)
                return UserResponse(
                    type: .searchResults,
                    success: true,
                    data: ["results": hybridResults.map { $0.toDictionary() }, "search_type": "hybrid"],
                    message: "Found \(hybridResults.count) results for '\(query)' using hybrid search"
                )
            } catch {
                print("Hybrid search failed, falling back to BM25: \(error)")
                // Fall through to BM25 search
            }
        }
        
        // Perform traditional multi-domain BM25 search as fallback
        let results = database.searchMultiDomain(query, types: types, limit: limit)
        
        return UserResponse(
            type: .searchResults,
            success: true,
            data: ["results": results.map { $0.toDictionary() }, "search_type": "bm25"],
            message: "Found \(results.count) results for '\(query)' using BM25 search"
        )
    }
    
    private func handleEnhancedSearchRequest(_ request: UserRequest) async throws -> UserResponse {
        guard let query = request.parameters["query"] as? String else {
            throw OrchestratorError.invalidParameters("Missing query parameter")
        }
        
        guard let enhancedSearch = self.enhancedSearch else {
            throw OrchestratorError.serviceNotAvailable("Enhanced search not available")
        }
        
        let limit = request.parameters["limit"] as? Int ?? 20
        let includeSummary = request.parameters["include_summary"] as? Bool ?? true
        let summaryLengthStr = request.parameters["summary_length"] as? String ?? "medium"
        let summaryLength = SummaryLength(rawValue: summaryLengthStr) ?? .medium
        
        do {
            let enhancedResult = try await enhancedSearch.enhancedSearch(
                query: query,
                limit: limit,
                includeSummary: includeSummary,
                summaryLength: summaryLength
            )
            
            return UserResponse(
                type: .enhancedSearchResults,
                success: true,
                data: enhancedResult.toDictionary(),
                message: "Enhanced search completed: \(enhancedResult.results.count) results with \(enhancedResult.enhancedQuery.enhancementMethod.rawValue) query enhancement"
            )
        } catch {
            // Fallback to basic hybrid search
            print("Enhanced search failed, falling back to basic hybrid: \(error)")
            return try await handleSearchRequest(request)
        }
    }
    
    private func handleIntentSearchRequest(_ request: UserRequest) async throws -> UserResponse {
        guard let query = request.parameters["query"] as? String else {
            throw OrchestratorError.invalidParameters("Missing query parameter")
        }
        
        guard let enhancedSearch = self.enhancedSearch else {
            throw OrchestratorError.serviceNotAvailable("Enhanced search not available")
        }
        
        let limit = request.parameters["limit"] as? Int ?? 15
        
        do {
            let intentResult = try await enhancedSearch.intentBasedSearch(
                query: query,
                limit: limit
            )
            
            return UserResponse(
                type: .intentSearchResults,
                success: true,
                data: intentResult.toDictionary(),
                message: "Intent-based search completed: \(intentResult.intent.rawValue) intent with \(intentResult.results.count) results"
            )
        } catch {
            // Fallback to basic search
            print("Intent search failed, falling back to basic search: \(error)")
            return try await handleSearchRequest(request)
        }
    }
    
    private func handleTopicSearchRequest(_ request: UserRequest) async throws -> UserResponse {
        guard let query = request.parameters["query"] as? String else {
            throw OrchestratorError.invalidParameters("Missing query parameter")
        }
        
        guard let enhancedSearch = self.enhancedSearch else {
            throw OrchestratorError.serviceNotAvailable("Enhanced search not available")
        }
        
        let limit = request.parameters["limit"] as? Int ?? 25
        
        do {
            let topicResult = try await enhancedSearch.topicSearch(
                query: query,
                limit: limit
            )
            
            return UserResponse(
                type: .topicSearchResults,
                success: true,
                data: topicResult.toDictionary(),
                message: "Topic-based search completed: \(topicResult.totalResults) results grouped by topics"
            )
        } catch {
            // Fallback to enhanced search without topic grouping
            print("Topic search failed, falling back to enhanced search: \(error)")
            return try await handleEnhancedSearchRequest(request)
        }
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
            // Ingest all sources - run real full ingest
            do {
                try await ingestManager.runFullIngest()
                let combinedStats = IngestStats(source: "orchestrator_full")
                return UserResponse(
                    type: .dataIngest,
                    success: true,
                    data: ["stats": combinedStats.toDictionary()],
                    message: "Completed full data ingest: \(combinedStats.itemsCreated) items created"
                )
            } catch {
                return UserResponse(
                    type: .dataIngest,
                    success: false,
                    data: ["error": error.localizedDescription],
                    message: "Full data ingest failed: \(error.localizedDescription)"
                )
            }
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
        // Use basic logging until LoggingService is properly integrated
        print("[ORCHESTRATOR] Request received: \(request.requestId) - \(request.type.rawValue)")
    }
    
    private func logResponse(request: UserRequest, response: UserResponse?, duration: TimeInterval, error: Error?) {
        let success = error == nil
        // Use basic logging until LoggingService is properly integrated
        let errorMsg = error?.localizedDescription ?? "none"
        print("[ORCHESTRATOR] Request completed: \(request.requestId) - Success: \(success) - Duration: \(Int(duration * 1000))ms - Error: \(errorMsg)")
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
    case enhancedSearch = "enhanced_search"
    case intentSearch = "intent_search"
    case topicSearch = "topic_search"
    case toolExecution = "tool_execution"
    case dataIngest = "data_ingest"
    case status = "status"
}

public enum ResponseType: String {
    case searchResults = "search_results"
    case enhancedSearchResults = "enhanced_search_results"
    case intentSearchResults = "intent_search_results"
    case topicSearchResults = "topic_search_results"
    case toolExecution = "tool_execution"
    case dataIngest = "data_ingest"
    case status = "status"
    case error = "error"
}

// MARK: - Tool Layer (Placeholder)

/// Simple tool layer that wraps the existing mac_tools CLI
private class ToolLayer {
    private let macToolsPath: String
    
    init() {
        self.macToolsPath = Self.findMacToolsPath()
    }
    
    private static func findMacToolsPath() -> String {
        // Priority order: ENV var, .build/release, /usr/local/bin, PATH lookup
        if let envPath = ProcessInfo.processInfo.environment["MAC_TOOLS_PATH"] {
            return envPath
        }
        
        let candidates = [
            "./.build/release/mac_tools",
            "../.build/release/mac_tools",
            "/usr/local/bin/mac_tools"
        ]
        
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        
        return "mac_tools" // Fallback to PATH
    }
    
    func executeTool(_ toolName: String, parameters: [String: Any], dryRun: Bool) async throws -> ToolResult {
        let command = buildToolCommand(toolName, parameters: parameters, dryRun: dryRun)
        let result = try await executeShellCommand(command)
        
        return ToolResult(
            success: result.success,
            data: result.data,
            message: result.message
        )
    }
    
    private func buildToolCommand(_ toolName: String, parameters: [String: Any], dryRun: Bool) -> String {
        var args: [String] = [macToolsPath, toolName]
        
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
        let components = command.split(separator: " ").map(String.init)
        guard !components.isEmpty else {
            throw OrchestratorError.toolExecutionFailed("Empty command")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(components)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            let errorString = String(data: errorData, encoding: .utf8) ?? ""
            
            let success = process.terminationStatus == 0
            
            // Try to parse JSON output from tool
            var responseData: [String: Any] = ["raw_output": outputString]
            if let jsonData = outputString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                responseData = parsed
            }
            
            return ToolResult(
                success: success,
                data: responseData,
                message: success ? "Tool executed successfully" : "Tool execution failed: \(errorString)"
            )
            
        } catch {
            throw OrchestratorError.toolExecutionFailed("Process execution failed: \(error)")
        }
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
    case serviceNotAvailable(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidParameters(let msg):
            return "Invalid parameters: \(msg)"
        case .unknownDataSource(let source):
            return "Unknown data source: \(source)"
        case .toolExecutionFailed(let msg):
            return "Tool execution failed: \(msg)"
        case .serviceNotAvailable(let service):
            return "Service not available: \(service)"
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