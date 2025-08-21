import Foundation
import SQLite3
import CryptoKit

// WhatsApp database extraction based on https://github.com/lharries/whatsapp-mcp
class WhatsAppIngester {
    private let database: Database
    private var whatsappDB: OpaquePointer?
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestWhatsApp(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "whatsapp")
        
        // Find WhatsApp database path
        guard let whatsappDBPath = findWhatsAppDatabase() else {
            print("WhatsApp database not found - WhatsApp may not be installed or used")
            return stats
        }
        
        print("Found WhatsApp database at: \(whatsappDBPath)")
        
        // Open WhatsApp database
        guard openWhatsAppDatabase(path: whatsappDBPath) else {
            throw IngestError.dataCorruption
        }
        defer { closeWhatsAppDatabase() }
        
        // Query messages - check for Go bridge database first
        let messages = try queryWhatsAppMessages(isFullSync: isFullSync, since: since)
        print("Found \(messages.count) WhatsApp messages to process")
        
        for messageData in messages {
            await processWhatsAppMessage(messageData, stats: &stats)
        }
        
        print("WhatsApp ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func findWhatsAppDatabase() -> String? {
        // First, try to find the Go bridge database (our WhatsApp logger)
        let bridgePaths = [
            "tools/whatsapp/whatsapp_messages.db",
            "./whatsapp_messages.db",
            "../whatsapp-logger/whatsapp_messages.db"
        ]
        
        for path in bridgePaths {
            if FileManager.default.fileExists(atPath: path) {
                print("Found WhatsApp Go bridge database at: \(path)")
                return path
            }
        }
        
        // Fallback: WhatsApp Desktop native databases
        let possiblePaths = [
            "\(NSHomeDirectory())/Library/Application Support/WhatsApp/Databases/ChatStorage.sqlite",
            "\(NSHomeDirectory())/Library/Containers/WhatsApp/Data/Library/Application Support/WhatsApp/Databases/ChatStorage.sqlite",
            "\(NSHomeDirectory())/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Application Support/WhatsApp/Databases/ChatStorage.sqlite"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                print("Found WhatsApp native database at: \(path)")
                return path
            }
        }
        
        // Try to find any WhatsApp-related databases
        let appSupportPath = "\(NSHomeDirectory())/Library/Application Support"
        if let enumerator = FileManager.default.enumerator(atPath: appSupportPath) {
            for case let file as String in enumerator {
                if file.contains("WhatsApp") && file.hasSuffix(".sqlite") {
                    let fullPath = "\(appSupportPath)/\(file)"
                    if FileManager.default.fileExists(atPath: fullPath) {
                        return fullPath
                    }
                }
            }
        }
        
        return nil
    }
    
    private func openWhatsAppDatabase(path: String) -> Bool {
        let result = sqlite3_open_v2(path, &whatsappDB, SQLITE_OPEN_READONLY, nil)
        if result != SQLITE_OK {
            print("Failed to open WhatsApp database: \(result)")
            return false
        }
        return true
    }
    
    private func closeWhatsAppDatabase() {
        if whatsappDB != nil {
            sqlite3_close(whatsappDB)
            whatsappDB = nil
        }
    }
    
    // Query Go bridge database (messages.db from our WhatsApp logger)
    private func queryBridgeMessages(sinceTimestamp: Double, limit: Int) -> [[String: Any]]? {
        // Check if this database has the Go bridge schema
        var statement: OpaquePointer?
        let testQuery = "SELECT name FROM sqlite_master WHERE type='table' AND name='messages'"
        
        if sqlite3_prepare_v2(whatsappDB, testQuery, -1, &statement, nil) != SQLITE_OK {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_step(statement) != SQLITE_ROW {
            return nil  // No 'messages' table found
        }
        
        print("Detected Go bridge database schema")
        
        // Query the Go bridge schema
        let bridgeQuery = """
            SELECT 
                m.id as message_id,
                m.chat_jid,
                m.sender,
                m.content as text,
                strftime('%s', m.timestamp) as timestamp,
                m.is_from_me,
                m.media_type,
                m.filename,
                m.url,
                COALESCE(c.name, m.chat_jid) as chat_title
            FROM messages m
            LEFT JOIN chats c ON m.chat_jid = c.jid
            WHERE strftime('%s', m.timestamp) > ?
            ORDER BY m.timestamp DESC
            LIMIT ?
        """
        
        var bridgeStatement: OpaquePointer?
        defer { sqlite3_finalize(bridgeStatement) }
        
        if sqlite3_prepare_v2(whatsappDB, bridgeQuery, -1, &bridgeStatement, nil) != SQLITE_OK {
            return nil
        }
        
        sqlite3_bind_double(bridgeStatement, 1, sinceTimestamp)
        sqlite3_bind_int(bridgeStatement, 2, Int32(limit))
        
        var messages: [[String: Any]] = []
        
        while sqlite3_step(bridgeStatement) == SQLITE_ROW {
            var messageData: [String: Any] = [:]
            
            messageData["message_id"] = String(cString: sqlite3_column_text(bridgeStatement, 0))
            messageData["chat_jid"] = String(cString: sqlite3_column_text(bridgeStatement, 1))
            messageData["sender"] = String(cString: sqlite3_column_text(bridgeStatement, 2))
            messageData["text"] = String(cString: sqlite3_column_text(bridgeStatement, 3))
            messageData["timestamp"] = sqlite3_column_double(bridgeStatement, 4)
            messageData["is_from_me"] = sqlite3_column_int(bridgeStatement, 5) != 0
            
            if sqlite3_column_text(bridgeStatement, 6) != nil {
                messageData["media_type"] = String(cString: sqlite3_column_text(bridgeStatement, 6))
            }
            if sqlite3_column_text(bridgeStatement, 7) != nil {
                messageData["filename"] = String(cString: sqlite3_column_text(bridgeStatement, 7))
            }
            if sqlite3_column_text(bridgeStatement, 8) != nil {
                messageData["url"] = String(cString: sqlite3_column_text(bridgeStatement, 8))
            }
            if sqlite3_column_text(bridgeStatement, 9) != nil {
                messageData["chat_title"] = String(cString: sqlite3_column_text(bridgeStatement, 9))
            }
            
            messages.append(messageData)
        }
        
        return messages
    }
    
    private func queryWhatsAppMessages(isFullSync: Bool, since: Date?) throws -> [[String: Any]] {
        let sinceTimestamp = since?.timeIntervalSince1970 ?? 0
        let limit = isFullSync ? 500 : 100
        
        // First check if this is our Go bridge database (has 'messages' table)
        if let result = queryBridgeMessages(sinceTimestamp: sinceTimestamp, limit: limit) {
            return result
        }
        
        // Fallback: Native WhatsApp database schema varies by version
        // Common tables: ZMESSAGE, ZCHAT, ZCONTACT, ZMEDIAITEM
        
        let query = """
            SELECT 
                Z_PK as message_id,
                ZTEXT as text,
                ZTIMESTAMP as timestamp,
                ZISFROMME as is_from_me,
                ZMESSAGETYPE as message_type,
                ZCHAT.ZTITLE as chat_title,
                ZCHAT.Z_PK as chat_id,
                ZCONTACT.ZFULLNAME as contact_name,
                ZCONTACT.ZPHONENUMBER as phone_number
            FROM ZMESSAGE
            LEFT JOIN ZCHAT ON ZMESSAGE.ZCHAT = ZCHAT.Z_PK
            LEFT JOIN ZCONTACT ON ZMESSAGE.ZCONTACT = ZCONTACT.Z_PK
            WHERE ZTIMESTAMP > ?
            ORDER BY ZTIMESTAMP DESC
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(whatsappDB, query, -1, &statement, nil) != SQLITE_OK {
            // Try alternative schema if the above fails
            return try queryWhatsAppMessagesAlternativeSchema(isFullSync: isFullSync, since: since)
        }
        
        sqlite3_bind_double(statement, 1, sinceTimestamp)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var messages: [[String: Any]] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var messageData: [String: Any] = [:]
            
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
        
        return messages
    }
    
    private func queryWhatsAppMessagesAlternativeSchema(isFullSync: Bool, since: Date?) throws -> [[String: Any]] {
        // Alternative schema for different WhatsApp versions
        let sinceTimestamp = since?.timeIntervalSince1970 ?? 0
        let limit = isFullSync ? 500 : 100
        
        let query = """
            SELECT 
                rowid as message_id,
                data as text,
                timestamp,
                from_me as is_from_me,
                key_remote_jid as chat_id
            FROM messages
            WHERE timestamp > ?
            ORDER BY timestamp DESC
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(whatsappDB, query, -1, &statement, nil) == SQLITE_OK else {
            throw IngestError.dataCorruption
        }
        
        sqlite3_bind_double(statement, 1, sinceTimestamp * 1000) // WhatsApp uses milliseconds
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var messages: [[String: Any]] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var messageData: [String: Any] = [:]
            
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
        
        return messages
    }
    
    private func processWhatsAppMessage(_ messageData: [String: Any], stats: inout IngestStats) async {
        let now = Int(Date().timeIntervalSince1970)
        
        // Use message ID and chat ID to ensure unique document IDs
        let messageId = messageData["message_id"] ?? messageData["id"] ?? UUID().uuidString
        let chatJid = (messageData["chat_jid"] as? String) ?? (messageData["chat_id"] as? String) ?? "unknown"
        let cleanChatJid = chatJid.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: ".", with: "_")
        let documentId = "whatsapp_\(messageId)_\(cleanChatJid)"
        
        let text = messageData["text"] as? String ?? ""
        let chatId = messageData["chat_id"] as? String ?? "unknown"
        let chatTitle = messageData["chat_title"] as? String
        let contactName = messageData["contact_name"] as? String
        let phoneNumber = messageData["phone_number"] as? String
        let isFromMe = (messageData["is_from_me"] as? Int64) == 1
        let messageType = messageData["message_type"] as? Int64 ?? 0
        
        // Convert timestamp (varies by WhatsApp version)
        var timestamp = now
        if let ts = messageData["timestamp"] as? Double {
            // Handle different timestamp formats
            if ts > 1000000000000 { // Milliseconds
                timestamp = Int(ts / 1000)
            } else { // Seconds
                timestamp = Int(ts)
            }
        }
        
        // Determine message type
        let messageTypeString = whatsappMessageTypeString(Int(messageType))
        
        // Create searchable content
        var contentParts: [String] = []
        contentParts.append(text)
        if let chatTitle = chatTitle, !chatTitle.isEmpty {
            contentParts.append("Chat: \(chatTitle)")
        }
        if let contactName = contactName, !contactName.isEmpty {
            contentParts.append("Contact: \(contactName)")
        }
        contentParts.append("Type: \(messageTypeString)")
        contentParts.append("From: \(isFromMe ? "Me" : (contactName ?? phoneNumber ?? chatId))")
        
        let searchableContent = contentParts.joined(separator: "\n")
        
        // Ensure all required fields are non-null  
        let validChatTitle = chatTitle?.isEmpty == false ? chatTitle! : nil
        let validContactName = contactName?.isEmpty == false ? contactName! : nil
        
        let title = if isFromMe {
            "WhatsApp to \(validChatTitle ?? validContactName ?? chatId)"
        } else {
            "WhatsApp from \(validContactName ?? validChatTitle ?? chatId)"
        }
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "message",
            "title": title,
            "content": searchableContent,
            "app_source": "WhatsApp",
            "source_id": documentId, // Use unique document ID as source ID 
            "source_path": "whatsapp://chat/\(chatId)",
            "hash": "\(messageId)\(text)".sha256(),
            "created_at": timestamp,
            "updated_at": timestamp,
            "last_seen_at": now,
            "deleted": false
        ]
        
        // DEBUG removed - Database bug fixed
        
        if database.insert("documents", data: docData) {
            let messageSpecificData: [String: Any] = [
                "document_id": documentId,
                "thread_id": chatId,
                "from_contact": isFromMe ? "me" : (contactName ?? phoneNumber ?? chatId),
                "date_sent": timestamp,
                "is_from_me": isFromMe,
                "is_read": true, // Assume read since we're processing it
                "service": "WhatsApp",
                "chat_name": chatTitle ?? NSNull(),
                "has_attachments": messageType != 0
            ]
            
            if database.insert("messages", data: messageSpecificData) {
                stats.itemsCreated += 1
                
                // Try to create relationships with contacts
                if !isFromMe {
                    if let contactId = findContactByPhoneOrName(phoneNumber ?? contactName) {
                        createRelationship(from: contactId, to: documentId, type: "sent_whatsapp_message")
                    }
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
    private func whatsappMessageTypeString(_ type: Int) -> String {
        switch type {
        case 0: return "text"
        case 1: return "image"
        case 2: return "audio"
        case 3: return "video"
        case 4: return "contact"
        case 5: return "location"
        case 6: return "document"
        case 7: return "link"
        case 8: return "gif"
        case 9: return "sticker"
        default: return "unknown"
        }
    }
    
    private func findContactByPhoneOrName(_ identifier: String?) -> String? {
        guard let identifier = identifier else { return nil }
        
        // Try phone number first
        var results = database.query(
            "SELECT document_id FROM contacts WHERE phone_numbers LIKE ?",
            parameters: ["%\(identifier)%"]
        )
        
        if let result = results.first {
            return result["document_id"] as? String
        }
        
        // Try name
        results = database.query(
            "SELECT document_id FROM contacts WHERE full_name LIKE ?",
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
            "strength": 0.9, // WhatsApp messages are high-strength relationships
            "created_at": Int(Date().timeIntervalSince1970)
        ]
        
        database.insert("relationships", data: relationshipData)
    }
}

// SHA256 extension is in Utilities.swift