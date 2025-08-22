import Foundation
import ArgumentParser
import DatabaseCore

/// Command-line interface for testing the Orchestrator
@main
struct OrchestratorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchestrator_cli",
        abstract: "Test CLI for Kenny Orchestrator",
        version: "0.1.0",
        subcommands: [
            SearchCommand.self,
            IngestCommand.self,
            StatusCommand.self,
            PlanCommand.self,
            ExecuteCommand.self
        ]
    )
}

// MARK: - Search Command

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search across all data sources"
    )
    
    @Argument(help: "Search query")
    var query: String
    
    @Option(help: "Maximum number of results")
    var limit: Int = 20
    
    @Option(help: "Filter by data types (comma-separated)")
    var types: String = ""
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let typeFilter = types.isEmpty ? [] : types.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let request = UserRequest(
            type: .search,
            parameters: [
                "query": query,
                "limit": limit,
                "types": typeFilter
            ]
        )
        
        do {
            let response = try await orchestrator.processRequest(request)
            printResponse(response)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Ingest Command

struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Ingest data from Apple apps"
    )
    
    @Option(help: "Data sources to ingest (comma-separated)")
    var sources: String = ""
    
    @Flag(name: .customLong("full-sync"), help: "Perform full sync (otherwise incremental)")
    var fullSync: Bool = false
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let sourceFilter = sources.isEmpty ? [] : sources.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let request = UserRequest(
            type: .dataIngest,
            parameters: [
                "sources": sourceFilter,
                "full_sync": fullSync
            ]
        )
        
        do {
            let response = try await orchestrator.processRequest(request)
            printResponse(response)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Status Command

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get system status"
    )
    
    func run() async throws {
        // Use kenny.db in mac_tools directory as source of truth
        let kennyDBPath = "kenny.db"
        let database = Database(path: kennyDBPath)
        let orchestrator = Orchestrator(database: database)
        
        let request = UserRequest(type: .status)
        
        do {
            let response = try await orchestrator.processRequest(request)
            printResponse(response)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Week 5: Planning Commands

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Create an execution plan for a complex query"
    )
    
    @Argument(help: "User query to create a plan for")
    var query: String
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("🧠 Creating execution plan for: '\(query)'")
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, verbose: true)
        
        do {
            let plan = try await assistantCore.createPlan(for: query)
            
            print("📋 Plan created successfully!")
            print("Plan ID: \(plan.id)")
            print("Steps: \(plan.steps.count)")
            print("Risks: \(plan.risks.count)")
            print("Content Origin: \(plan.contentOrigin.rawValue)")
            
            if let hash = plan.operationHash {
                print("Operation Hash: \(hash)")
            }
            
            // Output plan details as JSON
            let jsonData = try JSONSerialization.data(
                withJSONObject: plan.toDictionary(), 
                options: [.prettyPrinted]
            )
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            print(jsonString)
            
        } catch {
            print("❌ Plan creation failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct ExecuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "execute",
        abstract: "Execute a plan by ID with optional confirmation hash"
    )
    
    @Argument(help: "Plan ID to execute")
    var planId: String
    
    @Option(name: .customLong("hash"), help: "User confirmation hash")
    var confirmationHash: String?
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("⚡ Executing plan: \(planId)")
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, verbose: true)
        
        do {
            let response = try await assistantCore.confirmAndExecutePlan(planId, userHash: confirmationHash)
            
            if response.success {
                print("✅ Plan executed successfully!")
            } else {
                print("❌ Plan execution failed: \(response.error ?? "Unknown error")")
            }
            
            // Output execution result as JSON
            let jsonData = try JSONSerialization.data(
                withJSONObject: response.toDictionary(),
                options: [.prettyPrinted]
            )
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            print(jsonString)
            
        } catch {
            print("❌ Plan execution failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Helper Functions

private func printResponse(_ response: UserResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    let responseData: [String: Any] = [
        "success": response.success,
        "type": response.type.rawValue,
        "message": response.message,
        "data": response.data,
        "timestamp": ISO8601DateFormatter().string(from: response.timestamp)
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: responseData, options: [.prettyPrinted, .sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        print("Response: \(response)")
    }
    
    // No need to exit explicitly in async context
}