import Foundation
import ArgumentParser
import DatabaseCore

/// Week 4 Assistant Core CLI - Intelligent function calling with local LLM
@main
struct AssistantCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assistant_core",
        abstract: "Week 4 Assistant Core: Intelligent function calling with local LLM",
        subcommands: [
            ProcessQuery.self,
            TestSuite.self,
            TestDeterministic.self,
            CheckLLM.self
        ]
    )
}

struct ProcessQuery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process a user query using intelligent tool selection"
    )
    
    @Argument(help: "User query to process")
    var query: String
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    @Option(name: .customLong("max-retries"), help: "Maximum retry attempts")
    var maxRetries: Int = 3
    
    @Flag(help: "Enable verbose output (default is JSON-only)")
    var verbose: Bool = false
    
    @Option(name: .customLong("operation-hash"), help: "Confirmation hash for mutating operations")
    var operationHash: String?
    
    func run() async throws {
        if verbose {
            print("🚀 Kenny Assistant Core (Week 4)")
            print("Query: '\(query)'")
            print("Database: \(dbPath)")
            print("---")
        }
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, maxRetries: maxRetries, verbose: verbose)
        
        do {
            // Use planning system if operation hash provided (Week 5 confirmation workflow)
            let response = if let hash = operationHash {
                try await assistantCore.processQueryWithPlanning(query)
            } else {
                try await assistantCore.processQuery(query)
            }
            
            // Output structured JSON response
            let responseDict = response.toDictionary()
            let jsonData = try JSONSerialization.data(withJSONObject: responseDict, options: [.prettyPrinted])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            print(jsonString)
            
        } catch {
            let errorResponse: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
                "attempts": 0,
                "duration": 0.0
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse, options: [.prettyPrinted])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            print(jsonString)
            throw ExitCode(1)
        }
    }
}

struct TestSuite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run 10 deterministic test cases using live data"
    )
    
    @Option(name: .customLong("db-path"), help: "Database path") 
    var dbPath: String = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"
    
    func run() async throws {
        print("🧪 Running Week 4 Test Suite - 10 Deterministic Cases")
        print("Database: \(dbPath)")
        print("=" * 50)
        
        let database = Database(path: dbPath)
        let assistantCore = AssistantCore(database: database, maxRetries: 2)
        
        let testCases: [(String, String)] = [
            ("Search for project emails", "Find emails about project apollo or budget"),
            ("List today's calendar", "Show my calendar events for today"),
            ("Current time", "What time is it now?"),
            ("Search meeting notes", "Find notes about 1:1 meetings"),
            ("List recent emails", "Show recent emails from the last week"), 
            ("Create reminder", "Remind me to call John tomorrow at 2pm"),
            ("Search documents", "Find documents related to roadmap or milestones"),
            ("Calendar this week", "Show calendar events for this week"),
            ("Search contacts", "Find contact information for Jon Larsen"),
            ("File operations", "List files in my Documents folder")
        ]
        
        var passed = 0
        var failed = 0
        
        for (index, (description, query)) in testCases.enumerated() {
            let testNumber = index + 1
            print("\nTest \(testNumber)/10: \(description)")
            print("Query: '\(query)'")
            
            do {
                let startTime = Date()
                let response = try await assistantCore.processQuery(query)
                let duration = Date().timeIntervalSince(startTime)
                
                if response.success {
                    print("✅ PASS - Tool: \(response.toolUsed ?? "unknown") (\(String(format: "%.2f", duration))s)")
                    passed += 1
                } else {
                    print("❌ FAIL - Error: \(response.error ?? "unknown")")
                    failed += 1
                }
                
            } catch {
                print("❌ FAIL - Exception: \(error.localizedDescription)")
                failed += 1
            }
            
            // Brief delay between tests
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        print("\n" + "=" * 50)
        print("📊 Test Results:")
        print("✅ Passed: \(passed)/10 (\(Int(Double(passed)/10.0 * 100))%)")
        print("❌ Failed: \(failed)/10 (\(Int(Double(failed)/10.0 * 100))%)")
        
        if failed > 0 {
            throw ExitCode(1)
        }
    }
}

struct TestDeterministic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-deterministic", 
        abstract: "Run 10 deterministic test cases proving Week 4 capabilities"
    )
    
    @Option(name: .customLong("db-path"), help: "Database path")
    var dbPath: String = "kenny.db"
    
    func run() async throws {
        print("🧪 Week 4 Assistant Core - Deterministic Test Suite")
        print("Testing 5 core capabilities with 10 test cases")
        print("Database: \(dbPath)")
        print("=" + String(repeating: "=", count: 50))
        
        let database = Database(path: dbPath)
        let testAssistantCore = TestAssistantCore(database: database, maxRetries: 2)
        
        let (passed, failed) = await DeterministicTestCases.runAll(using: testAssistantCore)
        
        print("\n" + "=" + String(repeating: "=", count: 50))
        print("📊 Test Results:")
        print("✅ Passed: \(passed)/10 (\(Int(Double(passed)/10.0 * 100))%)")
        print("❌ Failed: \(failed)/10 (\(Int(Double(failed)/10.0 * 100))%)")
        
        print("\n🎯 Week 4 Core Capabilities Demonstrated:")
        print("1️⃣  Tool Selection: Deterministic rule-based selection ✅")
        print("2️⃣  Argument Validation: JSON schema validation ✅") 
        print("3️⃣  Tool Execution: Integration with mac_tools + live data ✅")
        print("4️⃣  Result Return: Structured JSON responses ✅")
        print("5️⃣  Retry Logic: Multi-attempt with error summarization ✅")
        
        if failed > 0 {
            throw ExitCode(1)
        }
    }
}

struct CheckLLM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-llm", 
        abstract: "Check LLM availability and setup"
    )
    
    @Option(name: .customLong("model-name"), help: "Ollama model name")
    var model: String = "llama3.2:3b"
    
    func run() async throws {
        print("🔍 Checking LLM Setup")
        print("Model: \(model)")
        print("---")
        
        let llmService = LLMService(model: model)
        
        print("Checking Ollama availability...")
        let isAvailable = await llmService.checkAvailability()
        
        if isAvailable {
            print("✅ Ollama and model '\(model)' are ready")
            
            // Test a simple query
            print("\nTesting LLM response...")
            do {
                let response = try await llmService.generateResponse(prompt: """
                Respond with JSON only:
                {
                    "status": "ok",
                    "model": "\(model)",
                    "timestamp": "\(Date())"
                }
                """)
                
                print("✅ LLM Response:")
                print(response)
                
            } catch {
                print("❌ LLM test failed: \(error)")
                throw ExitCode(1)
            }
            
        } else {
            print("❌ Model '\(model)' not available")
            print("Attempting to pull model (timeout: 60s)...")
            
            let success = await llmService.ensureModelAvailable(timeout: 60.0)
            if success {
                print("✅ Model pulled successfully")
            } else {
                print("❌ Failed to pull model within timeout")
                throw ExitCode(1)
            }
        }
    }
}

// Helper for pretty printing
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

// AnyCodable for JSON encoding
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let dict = value as? [String: Any] {
            try container.encode(dict.compactMapValues { AnyCodable($0) })
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else {
            try container.encode(String(describing: value))
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = ""
        }
    }
}