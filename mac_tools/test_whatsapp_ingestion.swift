#!/usr/bin/env swift

import Foundation
import SQLite3

// Add the src directory to import path
import Foundation
import SQLite3

// Simple test script for WhatsApp ingestion
class SimpleWhatsAppTest {
    private var db: OpaquePointer?
    
    init() {
        let dbPath = "kenny_test.db"
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open database")
            exit(1)
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    func testWhatsAppData() {
        // Check if WhatsApp messages database exists
        let whatsappDBPath = "../tools/whatsapp/whatsapp_messages.db"
        
        print("Testing WhatsApp ingestion...")
        print("Looking for WhatsApp database at: \(whatsappDBPath)")
        
        guard FileManager.default.fileExists(atPath: whatsappDBPath) else {
            print("❌ WhatsApp database not found")
            return
        }
        
        print("✅ WhatsApp database found")
        
        // Open WhatsApp database
        var whatsappDB: OpaquePointer?
        if sqlite3_open_v2(whatsappDBPath, &whatsappDB, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("❌ Failed to open WhatsApp database")
            return
        }
        defer { sqlite3_close(whatsappDB) }
        
        // Check schema
        print("\nWhatsApp Database Schema:")
        let schemaQuery = "SELECT name FROM sqlite_master WHERE type='table'"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(whatsappDB, schemaQuery, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let tableName = sqlite3_column_text(stmt, 0) {
                    print("  Table: \(String(cString: tableName))")
                }
            }
        }
        sqlite3_finalize(stmt)
        
        // Count messages
        let messageQuery = "SELECT COUNT(*) FROM messages"
        if sqlite3_prepare_v2(whatsappDB, messageQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = sqlite3_column_int(stmt, 0)
                print("\n📊 Messages in WhatsApp DB: \(count)")
            }
        }
        sqlite3_finalize(stmt)
        
        // Sample some messages
        let sampleQuery = """
            SELECT id, chat_jid, sender, content, timestamp, is_from_me 
            FROM messages 
            ORDER BY timestamp DESC 
            LIMIT 3
        """
        
        print("\nSample Messages:")
        if sqlite3_prepare_v2(whatsappDB, sampleQuery, -1, &stmt, nil) == SQLITE_OK {
            var count = 0
            while sqlite3_step(stmt) == SQLITE_ROW && count < 3 {
                count += 1
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "nil"
                let chatJid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "nil" 
                let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "nil"
                let content = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "nil"
                let timestamp = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "nil"
                let isFromMe = sqlite3_column_int(stmt, 5)
                
                print("  \(count). ID: \(id)")
                print("     Chat: \(chatJid)")
                print("     From: \(sender) (fromMe: \(isFromMe == 1))")
                print("     Content: \(content.prefix(50))...")
                print("     Time: \(timestamp)")
                print("")
            }
        }
        sqlite3_finalize(stmt)
        
        print("✅ WhatsApp data inspection complete")
    }
}

// Run the test
let test = SimpleWhatsAppTest()
test.testWhatsAppData()