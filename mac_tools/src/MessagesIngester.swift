import Foundation
import SQLite3

class MessagesIngester {
    private let database: Database
    private var messagesDB: OpaquePointer?
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestMessages(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "messages")
        print("DEBUG: Starting Messages ingestion...")
        
        // Find Messages database path
        guard let messagesDBPath = findMessagesDatabase() else {
            print("Messages database not found - Messages app may not be set up")
            return stats
        }
        
        print("DEBUG: Found Messages database at: \(messagesDBPath)")
        
        // Check database file info
        let attrs = try? FileManager.default.attributesOfItem(atPath: messagesDBPath)
        let size = (attrs?[.size] as? Int64 ?? 0) / 1024 / 1024
        print("DEBUG: Database size: \(size) MB")
        
        // Open Messages database
        guard openMessagesDatabase(path: messagesDBPath) else {
            print("DEBUG: Failed to open Messages database")
            throw IngestError.dataCorruption
        }
        defer { closeMessagesDatabase() }
        
        print("DEBUG: Successfully opened Messages database")
        
        // For full sync, clear existing Messages data to prevent unique constraint failures
        if isFullSync {
            print("DEBUG: Clearing existing Messages data for full sync...")
            let deletedDocs = database.query("DELETE FROM documents WHERE app_source = 'Messages'")
            let deletedMsgs = database.query("DELETE FROM messages")
            print("DEBUG: Cleared existing Messages data")
        }
        
        // Query messages with detailed logging
        let messages = try queryMessages(isFullSync: isFullSync, since: since)
        print("DEBUG: Found \(messages.count) messages to process (isFullSync: \(isFullSync))")
        
        if messages.isEmpty {
            print("DEBUG: No messages returned from query - checking filters...")
            if let since = since {
                print("DEBUG: Since filter: \(since)")
            }
        }
        
        // Process messages with batching to prevent runloop timeout
        let batchSize = 100
        var processedCount = 0
        
        for i in stride(from: 0, to: messages.count, by: batchSize) {
            let end = min(i + batchSize, messages.count)
            let batch = Array(messages[i..<end])
            
            print("DEBUG: Processing batch \(i/batchSize + 1): messages \(i+1) to \(end)")
            
            for messageData in batch {
                await processMessageData(messageData, stats: &stats)
                processedCount += 1
            }
            
            // Brief pause to prevent overwhelming the system
            if batch.count == batchSize {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
        
        print("DEBUG: Messages ingest complete: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func findMessagesDatabase() -> String? {
        let possiblePaths = [
            "\(NSHomeDirectory())/Library/Messages/chat.db",
            "\(NSHomeDirectory())/Library/Messages/chat.db-wal", // WAL file indicates main DB exists
            "/Users/\(NSUserName())/Library/Messages/chat.db"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) && path.hasSuffix("chat.db") {
                return path
            }
        }
        
        return nil
    }
    
    private func openMessagesDatabase(path: String) -> Bool {
        let result = sqlite3_open_v2(path, &messagesDB, SQLITE_OPEN_READONLY, nil)
        if result != SQLITE_OK {
            print("Failed to open Messages database: \(result)")
            return false
        }
        
        // Set busy timeout for WAL mode concurrency
        sqlite3_busy_timeout(messagesDB, 10000) // 10 seconds
        
        return true
    }
    
    private func closeMessagesDatabase() {
        if messagesDB != nil {
            sqlite3_close(messagesDB)
            messagesDB = nil
        }
    }
    
    private func queryMessages(isFullSync: Bool, since: Date?) throws -> [[String: Any]] {
        // Messages uses nanoseconds since 2001 epoch (978307200 seconds before Unix epoch)
        let sinceTimestamp = if let since = since {
            (since.timeIntervalSince1970 - 978307200) * 1_000_000_000 // Convert to nanoseconds
        } else {
            0.0 // For full sync, start from beginning
        }
        let limit = isFullSync ? 30000 : 1000 // Increase limits to handle real data volumes
        
        print("DEBUG: Query parameters - sinceTimestamp: \(sinceTimestamp), limit: \(limit)")
        print("DEBUG: Since date: \(since?.description ?? "nil")")
        
        // Messages database schema (simplified):
        // message: ROWID, guid, text, handle_id, service, account, date, is_from_me, is_read
        // handle: ROWID, id (phone/email)
        // chat: ROWID, chat_identifier, display_name, service_name
        // chat_message_join: chat_id, message_id
        
        let query = """
            SELECT 
                m.ROWID as message_id,
                m.guid,
                m.text,
                m.attributedBody,
                m.service,
                m.account,
                m.date,
                m.is_from_me,
                m.is_read,
                m.is_delivered,
                m.is_finished,
                m.associated_message_type,
                h.id as handle_id,
                c.chat_identifier,
                c.display_name as chat_name,
                c.service_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.date > ? AND m.associated_message_type = 0
            ORDER BY m.date DESC 
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        print("DEBUG: Preparing SQL query...")
        guard sqlite3_prepare_v2(messagesDB, query, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(messagesDB))
            print("DEBUG: SQL prepare failed: \(error)")
            throw IngestError.dataCorruption
        }
        
        print("DEBUG: Binding parameters...")
        sqlite3_bind_double(statement, 1, sinceTimestamp)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var messages: [[String: Any]] = []
        var rowCount = 0
        
        print("DEBUG: Executing query...")
        while sqlite3_step(statement) == SQLITE_ROW {
            rowCount += 1
            if rowCount <= 3 || rowCount % 1000 == 0 {
                print("DEBUG: Processing message row \(rowCount)")
            }
            var messageData: [String: Any] = [:]
            
            // Extract all columns
            let columnCount = sqlite3_column_count(statement)
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(statement, i))
                
                switch sqlite3_column_type(statement, i) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, i) {
                        messageData[columnName] = String(cString: text)
                    }
                case SQLITE_INTEGER:
                    messageData[columnName] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    messageData[columnName] = sqlite3_column_double(statement, i)
                default:
                    messageData[columnName] = NSNull()
                }
            }
            
            messages.append(messageData)
        }
        
        print("DEBUG: Query complete. Found \(messages.count) messages (processed \(rowCount) rows)")
        return messages
    }
    
    private func processMessageData(_ messageData: [String: Any], stats: inout IngestStats) async {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        // Use attributedBody if available, fallback to text
        let textContent = messageData["attributedBody"] as? String ?? messageData["text"] as? String ?? ""
        let guid = messageData["guid"] as? String ?? UUID().uuidString
        let handleId = messageData["handle_id"] as? String ?? ""
        let service = messageData["service"] as? String ?? "unknown"
        let chatName = messageData["chat_name"] as? String
        let isFromMe = (messageData["is_from_me"] as? Int64) == 1
        
        // Skip empty messages
        if textContent.isEmpty {
            stats.itemsProcessed += 1
            return
        }
        
        // Convert Messages timestamp (nanoseconds since 2001) to Unix timestamp  
        let messagesDate = messageData["date"] as? Double ?? 0
        let unixTimestamp = Int(messagesDate / 1_000_000_000) + 978307200 // Convert nanoseconds to seconds, then add epoch offset
        
        // Create searchable content
        var contentParts: [String] = []
        contentParts.append(textContent)
        if let chatName = chatName, !chatName.isEmpty {
            contentParts.append("Chat: \(chatName)")
        }
        contentParts.append("Service: \(service)")
        contentParts.append("From: \(isFromMe ? "Me" : handleId)")
        
        let searchableContent = contentParts.joined(separator: "\n")
        
        // Determine thread_id (group chats have chat_identifier, 1-on-1 use handle_id)
        let threadId = messageData["chat_identifier"] as? String ?? handleId
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "message",
            "title": isFromMe ? "Message to \(handleId)" : "Message from \(handleId)",
            "content": searchableContent,
            "app_source": "Messages",
            "source_id": guid,
            "source_path": "sms:conversation/\(threadId)",
            "hash": "\(guid)\(textContent)".sha256(),
            "created_at": unixTimestamp,
            "updated_at": unixTimestamp,
            "last_seen_at": now,
            "deleted": false
        ]
        
        if database.insert("documents", data: docData) {
            let messageSpecificData: [String: Any] = [
                "document_id": documentId,
                "thread_id": threadId,
                "from_contact": isFromMe ? "me" : handleId,
                "date_sent": unixTimestamp,
                "is_from_me": isFromMe,
                "is_read": (messageData["is_read"] as? Int64) == 1,
                "service": service,
                "chat_name": chatName ?? NSNull(),
                "has_attachments": false // TODO: Query attachment table
            ]
            
            if database.insert("messages", data: messageSpecificData) {
                stats.itemsCreated += 1
                
                // Try to create relationships with contacts
                if !isFromMe, let contactId = findContactByPhoneOrEmail(handleId) {
                    createRelationship(from: contactId, to: documentId, type: "sent_message")
                }
            } else {
                stats.errors += 1
            }
        } else {
            stats.errors += 1
        }
        
        stats.itemsProcessed += 1
    }
    
    // MARK: - Helper Methods
    private func findContactByPhoneOrEmail(_ identifier: String) -> String? {
        // Try email first
        var results = database.query(
            "SELECT document_id FROM contacts WHERE emails LIKE ?",
            parameters: ["%\(identifier)%"]
        )
        
        if let result = results.first {
            return result["document_id"] as? String
        }
        
        // Try phone number
        results = database.query(
            "SELECT document_id FROM contacts WHERE phone_numbers LIKE ?",
            parameters: ["%\(identifier)%"]
        )
        
        return results.first?["document_id"] as? String
    }
    
    private func createRelationship(from: String, to: String, type: String) {
        let relationshipData: [String: Any] = [
            "id": UUID().uuidString,
            "from_document_id": from,
            "to_document_id": to,
            "relationship_type": type,
            "strength": 0.8,
            "created_at": Int(Date().timeIntervalSince1970)
        ]
        
        database.insert("relationships", data: relationshipData)
    }
}

// SHA256 extension is in Utilities.swift