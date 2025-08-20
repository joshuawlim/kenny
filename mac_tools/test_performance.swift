#!/usr/bin/env swift

import Foundation
import SQLite3

// Performance test harness for SQLite+FTS5 system
// Tests: Full ingest ≤5min, incremental ≤30s, search queries

class PerformanceTest {
    private let database: Database
    private let ingestManager: IngestManager
    
    init() {
        let testDBPath = "/tmp/assistant_perf_test.db"
        
        // Remove existing test DB
        try? FileManager.default.removeItem(atPath: testDBPath)
        
        self.database = Database(path: testDBPath)
        self.ingestManager = IngestManager(database: database)
        
        print("Performance test initialized with test database: \(testDBPath)")
    }
    
    func runAllTests() async {
        print("=== Personal Assistant Performance Tests ===\n")
        
        await testFullIngest()
        await testIncrementalIngest()
        await testSearchPerformance()
        await testConcurrentSearch()
        
        print("\n=== Performance Tests Complete ===")
    }
    
    // Test 1: Full ingest should complete in ≤5 minutes
    private func testFullIngest() async {
        print("🔄 Testing full ingest performance...")
        
        let startTime = Date()
        
        do {
            try await ingestManager.runFullIngest()
            
            let duration = Date().timeIntervalSince(startTime)
            let minutes = duration / 60.0
            
            if minutes <= 5.0 {
                print("✅ Full ingest: \(String(format: "%.2f", minutes))min (≤5min target)")
            } else {
                print("❌ Full ingest: \(String(format: "%.2f", minutes))min (EXCEEDED 5min target)")
            }
            
            // Check data quality
            let counts = getTableCounts()
            print("   Data ingested: \(counts)")
            
        } catch {
            print("❌ Full ingest failed: \(error)")
        }
    }
    
    // Test 2: Incremental ingest should complete in ≤30 seconds
    private func testIncrementalIngest() async {
        print("\n🔄 Testing incremental ingest performance...")
        
        // Wait a moment then run incremental
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        let startTime = Date()
        
        do {
            try await ingestManager.runIncrementalIngest()
            
            let duration = Date().timeIntervalSince(startTime)
            
            if duration <= 30.0 {
                print("✅ Incremental ingest: \(String(format: "%.2f", duration))s (≤30s target)")
            } else {
                print("❌ Incremental ingest: \(String(format: "%.2f", duration))s (EXCEEDED 30s target)")
            }
            
        } catch {
            print("❌ Incremental ingest failed: \(error)")
        }
    }
    
    // Test 3: Search query performance
    private func testSearchPerformance() async {
        print("\n🔍 Testing search performance...")
        
        let testQueries = [
            "meeting schedule project",
            "email report quarterly", 
            "john smith contact",
            "calendar event tomorrow",
            "document file pdf"
        ]
        
        var totalTime: TimeInterval = 0
        var successCount = 0
        
        for (index, query) in testQueries.enumerated() {
            let startTime = Date()
            
            let results = database.searchMultiDomain(query, limit: 20)
            
            let duration = Date().timeIntervalSince(startTime)
            totalTime += duration
            
            if duration <= 1.2 {
                print("✅ Query \(index + 1): \(String(format: "%.3f", duration))s (\(results.count) results)")
                successCount += 1
            } else {
                print("❌ Query \(index + 1): \(String(format: "%.3f", duration))s (SLOW - >1.2s)")
            }
        }
        
        let avgTime = totalTime / Double(testQueries.count)
        print("📊 Average query time: \(String(format: "%.3f", avgTime))s")
        print("📊 Queries within 1.2s limit: \(successCount)/\(testQueries.count)")
    }
    
    // Test 4: Concurrent search performance
    private func testConcurrentSearch() async {
        print("\n⚡ Testing concurrent search performance...")
        
        let concurrentQueries = Array(repeating: "project meeting email", count: 10)
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for (index, query) in concurrentQueries.enumerated() {
                group.addTask {
                    let queryStart = Date()
                    let results = self.database.searchMultiDomain(query, limit: 10)
                    let queryDuration = Date().timeIntervalSince(queryStart)
                    print("   Concurrent query \(index + 1): \(String(format: "%.3f", queryDuration))s (\(results.count) results)")
                }
            }
        }
        
        let totalDuration = Date().timeIntervalSince(startTime)
        print("✅ 10 concurrent queries completed in \(String(format: "%.3f", totalDuration))s")
    }
    
    // Helper methods
    private func getTableCounts() -> [String: Int] {
        let tables = ["documents", "emails", "events", "contacts", "files", "notes", "reminders", "messages"]
        var counts: [String: Int] = [:]
        
        for table in tables {
            let result = database.query("SELECT COUNT(*) as count FROM \(table)")
            if let row = result.first, let count = row["count"] as? Int64 {
                counts[table] = Int(count)
            }
        }
        
        return counts
    }
    
    private func seedTestData() {
        print("🌱 Seeding test data for performance testing...")
        
        // Create larger dataset for realistic performance testing
        let startTime = Date()
        
        // Generate test emails (simulate larger mailbox)
        for i in 1...1000 {
            let docId = UUID().uuidString
            let now = Int(Date().timeIntervalSince1970)
            
            let docData: [String: Any] = [
                "id": docId,
                "type": "email",
                "title": "Test Email \(i) - Project Update Meeting Schedule",
                "content": "This is test email content \(i) with various keywords like project, meeting, schedule, quarterly report, and other business terms.",
                "app_source": "Mail",
                "source_id": "test-\(i)@example.com",
                "source_path": "message://test-\(i)",
                "hash": "test-hash-\(i)",
                "created_at": now - (i * 3600), // Spread over time
                "updated_at": now,
                "last_seen_at": now,
                "deleted": false
            ]
            
            database.insert("documents", data: docData)
            
            let emailData: [String: Any] = [
                "document_id": docId,
                "message_id": "test-\(i)@example.com",
                "from_name": "Test Sender \(i)",
                "from_address": "sender\(i)@example.com", 
                "date_received": now - (i * 3600),
                "is_read": i % 2 == 0,
                "snippet": "Test email snippet \(i)"
            ]
            
            database.insert("emails", data: emailData)
        }
        
        let seedDuration = Date().timeIntervalSince(startTime)
        print("🌱 Test data seeded in \(String(format: "%.2f", seedDuration))s")
    }
}

// Run the performance tests
Task {
    let perfTest = PerformanceTest()
    await perfTest.runAllTests()
    exit(0)
}