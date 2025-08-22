#!/usr/bin/env swift

// Test script for bulk Messages ingestion with configurable batch processing
// Usage: swift test_bulk_messages_ingestion.swift

import Foundation

func runBulkTest() {
    print("=======================================")
    print("Kenny - Bulk Messages Ingestion Test")
    print("=======================================")
    
    // Test configurations to run
    let testConfigs = [
        (batchSize: 100, maxMessages: 500, description: "Small batch test"),
        (batchSize: 500, maxMessages: 1000, description: "Medium batch test"),
        (batchSize: 1000, maxMessages: 2000, description: "Large batch test")
    ]
    
    for (index, config) in testConfigs.enumerated() {
        print("\n🧪 Test \(index + 1): \(config.description)")
        print("   Batch size: \(config.batchSize)")
        print("   Max messages: \(config.maxMessages)")
        print("   Expected batches: ~\(config.maxMessages / config.batchSize)")
        
        let startTime = Date()
        
        // Run dry-run first
        print("\n   Step 1: Dry run...")
        let dryRunProcess = Process()
        dryRunProcess.executableURL = URL(fileURLWithPath: "./db_cli")
        dryRunProcess.arguments = [
            "ingest_messages_only",
            "--db-path", "kenny_test.db",
            "--batch-size", "\(config.batchSize)",
            "--max-messages", "\(config.maxMessages)",
            "--dry-run"
        ]
        
        let dryRunPipe = Pipe()
        dryRunProcess.standardOutput = dryRunPipe
        dryRunProcess.standardError = dryRunPipe
        
        do {
            try dryRunProcess.run()
            dryRunProcess.waitUntilExit()
            
            let dryRunData = dryRunPipe.fileHandleForReading.readDataToEndOfFile()
            let dryRunOutput = String(data: dryRunData, encoding: .utf8) ?? ""
            print("   Dry run output:")
            print("   \(dryRunOutput)")
            
            // Extract confirmation hash from dry run output
            if let hashLine = dryRunOutput.components(separatedBy: "\n").first(where: { $0.contains("--operation-hash") }) {
                let hashPattern = "operation-hash ([a-f0-9]+)"
                if let regex = try? NSRegularExpression(pattern: hashPattern),
                   let match = regex.firstMatch(in: hashLine, range: NSRange(hashLine.startIndex..., in: hashLine)),
                   let hashRange = Range(match.range(at: 1), in: hashLine) {
                    let confirmationHash = String(hashLine[hashRange])
                    
                    print("\n   Step 2: Running actual ingestion...")
                    
                    // Run actual ingestion with confirmation hash
                    let actualProcess = Process()
                    actualProcess.executableURL = URL(fileURLWithPath: "./db_cli")
                    actualProcess.arguments = [
                        "ingest_messages_only",
                        "--db-path", "kenny_test.db",
                        "--batch-size", "\(config.batchSize)",
                        "--max-messages", "\(config.maxMessages)",
                        "--operation-hash", confirmationHash
                    ]
                    
                    let actualPipe = Pipe()
                    actualProcess.standardOutput = actualPipe
                    actualProcess.standardError = actualPipe
                    
                    try actualProcess.run()
                    actualProcess.waitUntilExit()
                    
                    let actualData = actualPipe.fileHandleForReading.readDataToEndOfFile()
                    let actualOutput = String(data: actualData, encoding: .utf8) ?? ""
                    
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("   ✅ Test completed in \(String(format: "%.2f", elapsed))s")
                    
                    // Parse and display results
                    if let jsonStart = actualOutput.range(of: "{"),
                       let jsonEnd = actualOutput.range(of: "}", options: .backwards) {
                        let jsonString = String(actualOutput[jsonStart.lowerBound...jsonEnd.upperBound])
                        if let jsonData = jsonString.data(using: .utf8),
                           let result = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                            print("   Results:")
                            print("     Status: \(result["status"] ?? "unknown")")
                            print("     Items processed: \(result["items_processed"] ?? 0)")
                            print("     Items created: \(result["items_created"] ?? 0)")
                            print("     Errors: \(result["errors"] ?? 0)")
                            print("     Duration: \(result["duration_seconds"] ?? 0)s")
                        }
                    }
                    
                    print("   Full output:")
                    print("   \(actualOutput)")
                } else {
                    print("   ❌ Could not extract confirmation hash")
                }
            } else {
                print("   ❌ Could not find confirmation hash in dry run output")
            }
            
        } catch {
            print("   ❌ Test failed: \(error)")
        }
        
        print("   " + String(repeating: "-", count: 50))
    }
    
    print("\n✅ All bulk ingestion tests completed!")
    print("📊 Check kenny_test.db for ingested data")
    print("🔍 Use db_cli search commands to verify results")
}

// Run the test
runBulkTest()