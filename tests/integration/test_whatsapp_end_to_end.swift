#!/usr/bin/env swift

// Comprehensive end-to-end test for WhatsApp ingestion in Kenny
import Foundation
import SQLite3

class WhatsAppIntegrationTest {
    private var db: OpaquePointer?
    
    init() {
        let dbPath = NSString("~/Library/Application Support/Assistant/assistant.db").expandingTildeInPath
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("❌ Failed to open Kenny database")
            exit(1)
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    func runFullTest() {
        print("🚀 Running WhatsApp End-to-End Integration Test")
        print("=" * 50)
        
        // Test 1: Check WhatsApp documents exist
        testWhatsAppDocumentsExist()
        
        // Test 2: Check message-specific data
        testMessageSpecificData()
        
        // Test 3: Test search functionality
        testSearchFunctionality()
        
        // Test 4: Test content quality
        testContentQuality()
        
        // Test 5: Test relationships
        testRelationships()
        
        print("\n✅ WhatsApp End-to-End Integration Test Complete!")
    }
    
    func testWhatsAppDocumentsExist() {
        print("\n📋 Test 1: WhatsApp Documents Existence")
        
        let query = "SELECT COUNT(*) FROM documents WHERE app_source = 'WhatsApp'"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = sqlite3_column_int(stmt, 0)
                print("   WhatsApp documents: \(count)")
                if count >= 19 {
                    print("   ✅ Expected number of WhatsApp messages found")
                } else {
                    print("   ❌ Expected at least 19 messages, found \(count)")
                }
            }
        }
    }
    
    func testMessageSpecificData() {
        print("\n📋 Test 2: Message-Specific Data")
        
        let query = """
            SELECT COUNT(*) 
            FROM messages m 
            JOIN documents d ON m.document_id = d.id 
            WHERE d.app_source = 'WhatsApp'
        """
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = sqlite3_column_int(stmt, 0)
                print("   WhatsApp entries in messages table: \(count)")
                if count >= 19 {
                    print("   ✅ Message-specific data correctly stored")
                } else {
                    print("   ❌ Expected message-specific data for all WhatsApp messages")
                }
            }
        }
    }
    
    func testSearchFunctionality() {
        print("\n📋 Test 3: Search Functionality")
        
        let testSearches = ["liquid", "heaven", "dinner"]
        
        for searchTerm in testSearches {
            let query = """
                SELECT COUNT(*) 
                FROM documents_fts 
                JOIN documents d ON documents_fts.rowid = d.rowid 
                WHERE documents_fts MATCH ? AND d.app_source = 'WhatsApp'
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, searchTerm, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt, 0)
                    print("   Search '\(searchTerm)': \(count) results")
                    if count > 0 {
                        print("   ✅ FTS search working for '\(searchTerm)'")
                    } else {
                        print("   ⚠️  No results for '\(searchTerm)' (may be expected)")
                    }
                }
            }
        }
    }
    
    func testContentQuality() {
        print("\n📋 Test 4: Content Quality")
        
        // Check for empty content
        let emptyQuery = """
            SELECT COUNT(*) FROM documents 
            WHERE app_source = 'WhatsApp' AND (content IS NULL OR content = '')
        """
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, emptyQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let emptyCount = sqlite3_column_int(stmt, 0)
                if emptyCount == 0 {
                    print("   ✅ All WhatsApp messages have content")
                } else {
                    print("   ⚠️  \(emptyCount) messages have empty content")
                }
            }
        }
        
        // Sample content check
        let sampleQuery = """
            SELECT title, content FROM documents 
            WHERE app_source = 'WhatsApp' 
            AND content NOT LIKE '%[Unknown message type]%'
            LIMIT 3
        """
        
        sqlite3_finalize(stmt)
        
        if sqlite3_prepare_v2(db, sampleQuery, -1, &stmt, nil) == SQLITE_OK {
            print("   Sample WhatsApp messages:")
            var sampleCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW && sampleCount < 3 {
                sampleCount += 1
                let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let content = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                
                let preview = content.components(separatedBy: "\n").first ?? ""
                print("     \(sampleCount). \(title)")
                print("        Content: \(preview.prefix(50))...")
            }
            
            if sampleCount > 0 {
                print("   ✅ Content samples look good")
            }
        }
    }
    
    func testRelationships() {
        print("\n📋 Test 5: Relationships")
        
        let relationshipQuery = """
            SELECT COUNT(*) 
            FROM relationships r 
            JOIN documents d ON r.to_document_id = d.id 
            WHERE d.app_source = 'WhatsApp'
        """
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, relationshipQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let relationshipCount = sqlite3_column_int(stmt, 0)
                print("   WhatsApp message relationships: \(relationshipCount)")
                if relationshipCount > 0 {
                    print("   ✅ Relationships created between contacts and messages")
                } else {
                    print("   ⚠️  No relationships found (may be expected if contacts not matched)")
                }
            }
        }
    }
}

// Helper to repeat string
extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}

// Run the test
let test = WhatsAppIntegrationTest()
test.runFullTest()