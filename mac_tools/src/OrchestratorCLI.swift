import Foundation
import ArgumentParser
import DatabaseCore

/// Command-line interface for testing the Orchestrator
@main
struct OrchestratorCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchestrator_cli",
        abstract: "Test CLI for Kenny Orchestrator",
        version: "0.1.0",
        subcommands: [
            SearchCommand.self,
            IngestCommand.self,
            StatusCommand.self
        ]
    )
}

// MARK: - Search Command

struct SearchCommand: ParsableCommand {
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
    
    func run() throws {
        let database = Database()
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
        
        Task {
            do {
                let response = try await orchestrator.processRequest(request)
                printResponse(response)
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        
        RunLoop.main.run()
    }
}

// MARK: - Ingest Command

struct IngestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Ingest data from Apple apps"
    )
    
    @Option(help: "Data sources to ingest (comma-separated)")
    var sources: String = ""
    
    @Flag(name: .customLong("full-sync"), help: "Perform full sync (otherwise incremental)")
    var fullSync: Bool = false
    
    func run() throws {
        let database = Database()
        let orchestrator = Orchestrator(database: database)
        
        let sourceFilter = sources.isEmpty ? [] : sources.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let request = UserRequest(
            type: .dataIngest,
            parameters: [
                "sources": sourceFilter,
                "full_sync": fullSync
            ]
        )
        
        Task {
            do {
                let response = try await orchestrator.processRequest(request)
                printResponse(response)
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        
        RunLoop.main.run()
    }
}

// MARK: - Status Command

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get system status"
    )
    
    func run() throws {
        let database = Database()
        let orchestrator = Orchestrator(database: database)
        
        let request = UserRequest(type: .status)
        
        Task {
            do {
                let response = try await orchestrator.processRequest(request)
                printResponse(response)
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        
        RunLoop.main.run()
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
    
    exit(0)
}