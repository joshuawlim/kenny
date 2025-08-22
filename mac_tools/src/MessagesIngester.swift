import Foundation
import SQLite3
import CommonCrypto

struct MessagesIngestionResult {
    let discovered: Int
    let inserted: Int
    let failed: Int
    let elapsedMs: Int64
    let firstTimestamp: Date?
    let lastTimestamp: Date?
    let batchesProcessed: Int
    let lastSuccessfulBatch: Int
    let errors: [String]
}

struct BatchProcessingConfig {
    let batchSize: Int
    let maxMessages: Int?
    let enableDetailedLogging: Bool
    let continueOnBatchFailure: Bool
    
    static let `default` = BatchProcessingConfig(
        batchSize: 500,
        maxMessages: nil,
        enableDetailedLogging: true,
        continueOnBatchFailure: true
    )
}

class MessagesIngester {
    private let database: Database
    private var messagesDB: OpaquePointer?
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestMessagesFromChatDB(config: BatchProcessingConfig = .default) -> MessagesIngestionResult {
        let startTime = Date()
        var discovered = 0
        var inserted = 0
        var failed = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var batchesProcessed = 0
        var lastSuccessfulBatch = 0
        var errors: [String] = []
        
        let messagesDbPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath
        
        // Open Messages database read-only
        var sourceDb: OpaquePointer?
        if sqlite3_open_v2(messagesDbPath, &sourceDb, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("[MessagesIngester] Cannot open Messages database at \(messagesDbPath)")
            return MessagesIngestionResult(discovered: 0, inserted: 0, failed: 0, elapsedMs: 0, firstTimestamp: nil, lastTimestamp: nil, batchesProcessed: 0, lastSuccessfulBatch: 0, errors: [])
        }
        
        defer { sqlite3_close(sourceDb) }
        
        // First, ensure chats table is populated
        insertChats(from: sourceDb)
        
        // Main query to extract messages with joins
        // Build query with optional limit
        let limitClause = config.maxMessages != nil ? "LIMIT \(config.maxMessages!)" : ""
        
        let query = """
            SELECT 
                m.ROWID as message_id,
                m.text,
                m.date,
                m.is_from_me,
                h.id as handle_id,
                c.ROWID as chat_rowid,
                c.chat_identifier,
                c.display_name,
                c.service_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.text IS NOT NULL AND length(m.text) > 0
            ORDER BY m.date ASC
            \(limitClause)
        """
        
        if config.enableDetailedLogging {
            print("[MessagesIngester] Query: \(query)")
            print("[MessagesIngester] Batch size: \(config.batchSize), Max messages: \(config.maxMessages?.description ?? "unlimited")")
        }
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(sourceDb, query, -1, &stmt, nil) != SQLITE_OK {
            print("[MessagesIngester] Failed to prepare query: \(String(cString: sqlite3_errmsg(sourceDb)))")
            return MessagesIngestionResult(discovered: 0, inserted: 0, failed: 0, elapsedMs: 0, firstTimestamp: nil, lastTimestamp: nil, batchesProcessed: 0, lastSuccessfulBatch: 0, errors: [])
        }
        
        defer { sqlite3_finalize(stmt) }
        
        var messageBatch: [(chatId: Int64?, sender: String?, text: String, sentAt: Int64, service: String?, threadTitle: String?, hash: String)] = []
        var messagesInCurrentBatch = 0
        
        // Process results with robust batch handling
        while sqlite3_step(stmt) == SQLITE_ROW {
            discovered += 1
            
            do {
                // Extract fields
                let text = String(cString: sqlite3_column_text(stmt, 1))
                let appleTime = sqlite3_column_int64(stmt, 2)
                let isFromMe = sqlite3_column_int(stmt, 3) == 1
                let handleId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let chatRowId = sqlite3_column_int64(stmt, 5)
                let chatIdentifier = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let displayName = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let serviceName = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "iMessage"
                
                // Convert Apple absolute time to Unix timestamp
                let sentAt = convertAppleTimeToUnix(appleTime)
                let messageDate = Date(timeIntervalSince1970: TimeInterval(sentAt))
                
                // Track first and last timestamps
                if firstTimestamp == nil || messageDate < firstTimestamp! {
                    firstTimestamp = messageDate
                }
                if lastTimestamp == nil || messageDate > lastTimestamp! {
                    lastTimestamp = messageDate
                }
                
                // Determine sender
                let sender = isFromMe ? "Me" : (handleId ?? "Unknown")
                
                // Determine thread title
                let threadTitle = displayName ?? chatIdentifier ?? "Unknown Chat"
                
                // Validate message data
                guard !text.isEmpty else {
                    if config.enableDetailedLogging && discovered <= 10 {
                        print("[MessagesIngester] Skipping empty message \(discovered)")
                    }
                    continue
                }
                
                // Create hash for deduplication
                let hashInput = "\(text)-\(sentAt)-\(sender ?? "")-\(chatRowId)"
                let hash = sha256Hash(hashInput)
                
                // Add to batch
                messageBatch.append((
                    chatId: chatRowId,
                    sender: sender,
                    text: text,
                    sentAt: sentAt,
                    service: serviceName,
                    threadTitle: threadTitle,
                    hash: hash
                ))
                
                messagesInCurrentBatch += 1
                
                // Process batch if full
                if messageBatch.count >= config.batchSize {
                    let batchResult = processBatch(messageBatch, batchNumber: batchesProcessed + 1, config: config)
                    inserted += batchResult.inserted
                    failed += batchResult.failed
                    batchesProcessed += 1
                    
                    if batchResult.success {
                        lastSuccessfulBatch = batchesProcessed
                        if config.enableDetailedLogging {
                            print("[MessagesIngester] Batch \(batchesProcessed) successful: \(batchResult.inserted) inserted, \(batchResult.failed) failed")
                        }
                    } else {
                        let errorMsg = "Batch \(batchesProcessed) failed: \(batchResult.errorMessage ?? "Unknown error")"
                        errors.append(errorMsg)
                        print("[MessagesIngester] ❌ \(errorMsg)")
                        
                        if !config.continueOnBatchFailure {
                            break
                        }
                    }
                    
                    messageBatch.removeAll()
                    messagesInCurrentBatch = 0
                }
                
            } catch {
                let errorMsg = "Error processing message \(discovered): \(error.localizedDescription)"
                errors.append(errorMsg)
                failed += 1
                
                if config.enableDetailedLogging {
                    print("[MessagesIngester] ❌ \(errorMsg)")
                }
                
                if !config.continueOnBatchFailure {
                    break
                }
            }
        }
        
        // Process remaining batch
        if !messageBatch.isEmpty {
            let batchResult = processBatch(messageBatch, batchNumber: batchesProcessed + 1, config: config)
            inserted += batchResult.inserted
            failed += batchResult.failed
            batchesProcessed += 1
            
            if batchResult.success {
                lastSuccessfulBatch = batchesProcessed
                if config.enableDetailedLogging {
                    print("[MessagesIngester] Final batch \(batchesProcessed) successful: \(batchResult.inserted) inserted, \(batchResult.failed) failed")
                }
            } else {
                let errorMsg = "Final batch \(batchesProcessed) failed: \(batchResult.errorMessage ?? "Unknown error")"
                errors.append(errorMsg)
                print("[MessagesIngester] ❌ \(errorMsg)")
            }
        }
        
        // Create minimal indices
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_messages_id ON messages(id)")
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_messages_sent_at ON messages(sent_at)")
        _ = database.execute("CREATE INDEX IF NOT EXISTS idx_chats_id ON chats(id)")
        
        let elapsedMs = Int64(Date().timeIntervalSince(startTime) * 1000)
        
        // Log comprehensive summary
        print("[MessagesIngester] ============ INGESTION COMPLETE ============")
        print("[MessagesIngester] Discovered: \(discovered), Inserted: \(inserted), Failed: \(failed)")
        print("[MessagesIngester] Batches processed: \(batchesProcessed), Last successful: \(lastSuccessfulBatch)")
        print("[MessagesIngester] Batch size: \(config.batchSize), Continue on failure: \(config.continueOnBatchFailure)")
        
        if !errors.isEmpty {
            print("[MessagesIngester] Errors encountered: \(errors.count)")
            for (index, error) in errors.enumerated() {
                print("[MessagesIngester]   \(index + 1). \(error)")
            }
        }
        
        if let first = firstTimestamp, let last = lastTimestamp {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            print("[MessagesIngester] Date range: \(formatter.string(from: first)) to \(formatter.string(from: last))")
        }
        print("[MessagesIngester] Execution time: \(elapsedMs)ms")
        print("[MessagesIngester] ================================================")
        
        return MessagesIngestionResult(
            discovered: discovered,
            inserted: inserted,
            failed: failed,
            elapsedMs: elapsedMs,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            batchesProcessed: batchesProcessed,
            lastSuccessfulBatch: lastSuccessfulBatch,
            errors: errors
        )
    }
    
    // Keep legacy method for compatibility
    func ingestMessages(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "messages")
        print("[Messages] Starting ingestion (isFullSync: \(isFullSync))")
        
        // Find Messages database path
        guard let messagesDBPath = findMessagesDatabase() else {
            print("[Messages] Database not found - Messages app may not be set up")
            return stats
        }
        
        print("[Messages] Found database at: \(messagesDBPath)")
        
        // Check database file info
        let attrs = try? FileManager.default.attributesOfItem(atPath: messagesDBPath)
        let size = (attrs?[.size] as? Int64 ?? 0) / 1024 / 1024
        print("[Messages] Database size: \(size) MB")
        
        // Open Messages database
        guard openMessagesDatabase(path: messagesDBPath) else {
            print("[Messages] Failed to open database")
            throw IngestError.dataCorruption
        }
        defer { closeMessagesDatabase() }
        
        print("[Messages] Successfully opened database")
        
        // For full sync, clear existing Messages data to prevent unique constraint failures
        if isFullSync {
            print("[Messages] Clearing existing data for full sync...")
            _ = database.execute("DELETE FROM messages")
            _ = database.execute("DELETE FROM documents WHERE app_source = 'Messages'")
            print("[Messages] Cleared existing data")
        }
        
        // Query messages with TEST LIMIT
        print("[Messages] Querying messages...")
        let messages = try queryMessages(isFullSync: isFullSync, since: since)
        print("[Messages] Query returned \(messages.count) messages")
        
        if messages.isEmpty {
            print("[Messages] No messages to process")
            return stats
        }
        
        // Process all messages (or configured limit)
        let messagesToProcess = messages
        print("[Messages] Processing \(messagesToProcess.count) messages")
        
        // Process messages in batches with transaction batching  
        let batchSize = 500 // Use larger batch size for bulk testing
        var totalProcessed = 0
        var totalCreated = 0
        var totalErrors = 0
        
        for i in stride(from: 0, to: messagesToProcess.count, by: batchSize) {
            let end = min(i + batchSize, messagesToProcess.count)
            let batch = Array(messagesToProcess[i..<end])
            
            print("[Messages] Processing batch \(i/batchSize + 1): messages \(i+1) to \(end)")
            
            // Process batch in a single transaction
            let (processed, created, errors) = await processBatchWithTransaction(batch)
            totalProcessed += processed
            totalCreated += created
            totalErrors += errors
            
            print("[Messages] Batch complete: \(processed) processed, \(created) created, \(errors) errors")
        }
        
        stats.itemsProcessed = totalProcessed
        stats.itemsCreated = totalCreated
        stats.errors = totalErrors
        
        print("[Messages] Ingestion complete: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    // New batch processing method with transaction
    private func processBatchWithTransaction(_ messages: [[String: Any]]) async -> (processed: Int, created: Int, errors: Int) {
        var processed = 0
        var created = 0
        var errors = 0
        
        // Start transaction
        _ = database.execute("BEGIN TRANSACTION")
        
        for messageData in messages {
            let documentId = UUID().uuidString
            let now = Int(Date().timeIntervalSince1970)
            
            // DEBUG: Print raw message data for first few messages
            if processed < 2 {
                print("[Messages] RAW MESSAGE DATA:")
                for (key, value) in messageData {
                    print("  \(key): '\(value)' (type: \(type(of: value)))")
                }
            }
            
            // Extract data with CORRECTED data types
            let textContent = messageData["text"] as? String ?? ""  // Start with text field only
            let guid = messageData["guid"] as? String ?? UUID().uuidString
            let handleIdInt = messageData["handle_id"] as? Int64 ?? 0  // FIX: handle_id is INTEGER
            let service = messageData["service"] as? String ?? "unknown"
            let isFromMe = (messageData["is_from_me"] as? Int64) == 1
            
            // Look up actual handle (phone/email) from handle_id
            let handleId = lookupHandle(handleIdInt: handleIdInt)
            
            processed += 1
            
            print("[Messages] Processing message \(processed):")
            print("  guid: \(guid)")
            print("  handleIdInt: \(handleIdInt) -> handleId: '\(handleId)'")
            print("  text: '\(textContent)' (length: \(textContent.count))")
            print("  isFromMe: \(isFromMe)")
            print("  service: \(service)")
            
            // Skip empty messages (but log them)
            if textContent.isEmpty {
                print("[Messages] SKIPPING: Empty text content")
                continue
            }
            
            // Convert Messages timestamp to Unix timestamp
            let messagesDate = messageData["date"] as? Double ?? 0
            let unixTimestamp = Int(messagesDate / 1_000_000_000) + 978307200
            
            // Create searchable content
            var contentParts: [String] = []
            contentParts.append(textContent)
            contentParts.append("Service: \(service)")
            contentParts.append("From: \(isFromMe ? "Me" : handleId)")
            
            let searchableContent = contentParts.joined(separator: "\n")
            
            // Determine thread_id (simplified for now)
            let threadId = handleId  // Use handleId as thread for 1-on-1 conversations
            
            // Insert document
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
            
            if processed <= 2 {
                print("[Messages] INSERTING DOCUMENT: \(documentId)")
                print("  title: '\(docData["title"] ?? "nil")'")
                print("  content length: \(searchableContent.count)")
            }
            
            if database.insert("documents", data: docData) {
                // Insert message-specific data
                let messageSpecificData: [String: Any] = [
                    "document_id": documentId,
                    "thread_id": threadId,
                    "from_contact": isFromMe ? "me" : handleId,
                    "date_sent": unixTimestamp,
                    "is_from_me": isFromMe,
                    "is_read": (messageData["is_read"] as? Int64) == 1,
                    "service": service,
                    "chat_name": NSNull(),
                    "has_attachments": false
                ]
                
                if database.insert("messages", data: messageSpecificData) {
                    if processed <= 2 {
                        print("[Messages] ✅ Message \(processed) inserted: '\(textContent.prefix(30))...'")
                    }
                    created += 1
                } else {
                    print("[Messages] ❌ Message insert failed for \(processed)")
                    errors += 1
                }
            } else {
                print("[Messages] ❌ Document insert failed for \(processed)")
                errors += 1
            }
        }
        
        // Commit transaction
        _ = database.execute("COMMIT")
        
        return (processed, created, errors)
    }
    
    // MARK: - Handle Lookup
    
    private func lookupHandle(handleIdInt: Int64) -> String {
        guard handleIdInt > 0, let messagesDB = messagesDB else {
            return "unknown"
        }
        
        let query = "SELECT id FROM handle WHERE ROWID = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(messagesDB, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, handleIdInt)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let handleCStr = sqlite3_column_text(stmt, 0) {
                    return String(cString: handleCStr)
                }
            }
        }
        
        return "handle_\(handleIdInt)"  // Fallback
    }
    
    // MARK: - New Chat Management
    
    private func insertChats(from sourceDb: OpaquePointer?) {
        let query = """
            SELECT DISTINCT 
                c.ROWID,
                c.chat_identifier,
                c.display_name,
                c.service_name
            FROM chat c
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(sourceDb, query, -1, &stmt, nil) != SQLITE_OK {
            print("[MessagesIngester] Failed to prepare chats query")
            return
        }
        
        defer { sqlite3_finalize(stmt) }
        
        _ = database.execute("BEGIN TRANSACTION")
        
        let insertSql = """
            INSERT INTO chats (id, chat_identifier, display_name, service_name)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(chat_identifier, service_name) DO UPDATE SET
                display_name = excluded.display_name
        """
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chatId = sqlite3_column_int64(stmt, 0)
            let identifier = String(cString: sqlite3_column_text(stmt, 1))
            let displayName = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let service = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "iMessage"
            
            // Need to use prepared statement for parameters
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(database.db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(insertStmt, 1, chatId)
                sqlite3_bind_text(insertStmt, 2, identifier, -1, nil)
                if let name = displayName {
                    sqlite3_bind_text(insertStmt, 3, name, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 3)
                }
                sqlite3_bind_text(insertStmt, 4, service, -1, nil)
                sqlite3_step(insertStmt)
                sqlite3_finalize(insertStmt)
            }
        }
        
        _ = database.execute("COMMIT")
    }
    
    // MARK: - Time Conversion
    
    private func convertAppleTimeToUnix(_ appleTime: Int64) -> Int64 {
        // Apple uses nanoseconds since 2001-01-01, Unix uses seconds since 1970-01-01
        // The difference is 978307200 seconds
        let appleEpochOffset: Int64 = 978307200
        
        // Check if this looks like nanoseconds (very large number)
        if appleTime > 1_000_000_000_000 {
            // Convert nanoseconds to seconds first
            return (appleTime / 1_000_000_000) + appleEpochOffset
        } else {
            // Already in seconds
            return appleTime + appleEpochOffset
        }
    }
    
    // MARK: - Batch Processing
    
    private struct BatchResult {
        let inserted: Int
        let failed: Int
        let success: Bool
        let errorMessage: String?
    }
    
    private func processBatch(_ messages: [(chatId: Int64?, sender: String?, text: String, sentAt: Int64, service: String?, threadTitle: String?, hash: String)], batchNumber: Int, config: BatchProcessingConfig) -> BatchResult {
        let startTime = Date()
        var inserted = 0
        var failed = 0
        var errorMessage: String?
        
        if config.enableDetailedLogging {
            print("[MessagesIngester] Processing batch \(batchNumber) with \(messages.count) messages...")
        }
        
        do {
            // Start transaction for entire batch
            if !database.execute("BEGIN TRANSACTION") {
                throw NSError(domain: "MessagesIngester", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to begin transaction"])
            }
            
            let sql = """
                INSERT INTO messages (document_id, thread_id, from_contact, date_sent, is_from_me, is_read, service, chat_name, has_attachments)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id) DO NOTHING
            """
            
            for (index, message) in messages.enumerated() {
                var insertStmt: OpaquePointer?
                defer { sqlite3_finalize(insertStmt) }
                
                guard sqlite3_prepare_v2(database.db, sql, -1, &insertStmt, nil) == SQLITE_OK else {
                    let error = String(cString: sqlite3_errmsg(database.db))
                    throw NSError(domain: "MessagesIngester", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare statement: \(error)"])
                }
                
                // Bind parameters with validation
                if let chatId = message.chatId {
                    sqlite3_bind_int64(insertStmt, 1, chatId)
                } else {
                    sqlite3_bind_null(insertStmt, 1)
                }
                
                if let sender = message.sender {
                    sqlite3_bind_text(insertStmt, 2, sender, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 2)
                }
                
                sqlite3_bind_text(insertStmt, 3, message.text, -1, nil)
                sqlite3_bind_int64(insertStmt, 4, message.sentAt)
                
                if let service = message.service {
                    sqlite3_bind_text(insertStmt, 5, service, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 5)
                }
                
                if let threadTitle = message.threadTitle {
                    sqlite3_bind_text(insertStmt, 6, threadTitle, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 6)
                }
                
                sqlite3_bind_text(insertStmt, 7, message.hash, -1, nil)
                
                let stepResult = sqlite3_step(insertStmt)
                if stepResult == SQLITE_DONE {
                    inserted += 1
                    if config.enableDetailedLogging && (index < 5 || index % 100 == 0) {
                        print("[MessagesIngester]   Message \(index + 1)/\(messages.count): '\(message.text.prefix(50))...' ✅")
                    }
                } else if stepResult == SQLITE_CONSTRAINT {
                    // Duplicate (ON CONFLICT), not an error
                    if config.enableDetailedLogging && index < 5 {
                        print("[MessagesIngester]   Message \(index + 1)/\(messages.count): duplicate (skipped)")
                    }
                } else {
                    failed += 1
                    let error = String(cString: sqlite3_errmsg(database.db))
                    if config.enableDetailedLogging || failed <= 5 {
                        print("[MessagesIngester]   Message \(index + 1)/\(messages.count): Failed - \(error)")
                    }
                }
            }
            
            // Commit transaction
            if !database.execute("COMMIT") {
                throw NSError(domain: "MessagesIngester", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to commit transaction"])
            }
            
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            if config.enableDetailedLogging {
                print("[MessagesIngester] Batch \(batchNumber) complete: \(inserted) inserted, \(failed) failed in \(elapsedMs)ms")
            }
            
            return BatchResult(inserted: inserted, failed: failed, success: true, errorMessage: nil)
            
        } catch {
            // Rollback on any error
            _ = database.execute("ROLLBACK")
            errorMessage = error.localizedDescription
            
            print("[MessagesIngester] ❌ Batch \(batchNumber) failed: \(errorMessage!)")
            
            return BatchResult(inserted: 0, failed: messages.count, success: false, errorMessage: errorMessage)
        }
    }
    
    // MARK: - New Database Operations
    
    private func insertMessageBatch(_ messages: [(chatId: Int64?, sender: String?, text: String, sentAt: Int64, service: String?, threadTitle: String?, hash: String)]) -> Int {
        let sql = """
            INSERT INTO messages (chat_id, sender, text, sent_at, service, thread_title, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO NOTHING
        """
        
        var inserted = 0
        
        _ = database.execute("BEGIN TRANSACTION")
        
        for message in messages {
            // Use prepared statement for parameters
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(database.db, sql, -1, &insertStmt, nil) == SQLITE_OK {
                // Bind parameters
                if let chatId = message.chatId {
                    sqlite3_bind_int64(insertStmt, 1, chatId)
                } else {
                    sqlite3_bind_null(insertStmt, 1)
                }
                
                if let sender = message.sender {
                    sqlite3_bind_text(insertStmt, 2, sender, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 2)
                }
                
                sqlite3_bind_text(insertStmt, 3, message.text, -1, nil)
                sqlite3_bind_int64(insertStmt, 4, message.sentAt)
                
                if let service = message.service {
                    sqlite3_bind_text(insertStmt, 5, service, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 5)
                }
                
                if let threadTitle = message.threadTitle {
                    sqlite3_bind_text(insertStmt, 6, threadTitle, -1, nil)
                } else {
                    sqlite3_bind_null(insertStmt, 6)
                }
                
                sqlite3_bind_text(insertStmt, 7, message.hash, -1, nil)
                
                if sqlite3_step(insertStmt) == SQLITE_DONE {
                    inserted += 1
                }
                sqlite3_finalize(insertStmt)
            }
        }
        
        _ = database.execute("COMMIT")
        
        return inserted
    }
    
    // MARK: - Utilities
    
    private func sha256Hash(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
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
        print("CRASH-DEBUG: queryMessages entry")
        fflush(stdout)
        // Messages uses nanoseconds since 2001 epoch (978307200 seconds before Unix epoch)
        let sinceTimestamp = if let since = since {
            (since.timeIntervalSince1970 - 978307200) * 1_000_000_000 // Convert to nanoseconds
        } else {
            0.0 // For full sync, start from beginning
        }
        // Use reasonable limits for bulk processing - REMOVED HARD LIMIT for full 30K ingestion
        let limit = isFullSync ? 50000 : 1000 // Increased to 50K to capture all messages
        
        print("DEBUG: Query parameters - sinceTimestamp: \(sinceTimestamp), limit: \(limit)")
        print("DEBUG: Since date: \(since?.description ?? "nil")")
        
        // Messages database schema (simplified):
        // message: ROWID, guid, text, handle_id, service, account, date, is_from_me, is_read
        // handle: ROWID, id (phone/email)
        // chat: ROWID, chat_identifier, display_name, service_name
        // chat_message_join: chat_id, message_id
        
        // SIMPLIFIED QUERY: First get messages, then look up handles/chats separately for better performance
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
                m.handle_id,
                m.associated_message_type
            FROM message m
            WHERE m.date > ? AND m.associated_message_type = 0
            ORDER BY m.date ASC 
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
        print("DEBUG: sinceTimestamp = \(sinceTimestamp), limit = \(limit)")
        sqlite3_bind_double(statement, 1, sinceTimestamp)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var messages: [[String: Any]] = []
        var rowCount = 0
        
        print("DEBUG: Executing query (expecting up to \(limit) rows)...")
        fflush(stdout)
        
        // FIXED: Loop through ALL results, not just the first one
        while sqlite3_step(statement) == SQLITE_ROW {
            rowCount += 1
            if rowCount <= 3 || rowCount % 1000 == 0 {
                print("DEBUG: Reading row \(rowCount)")
            }
            var messageData: [String: Any] = [:]
            
            // Extract all columns
            let columnCount = sqlite3_column_count(statement)
            if rowCount == 1 {
                print("DEBUG: Column count: \(columnCount)")
            }
            
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(statement, i))
                let columnType = sqlite3_column_type(statement, i)
                
                switch columnType {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, i) {
                        let value = String(cString: text)
                        messageData[columnName] = value
                        if rowCount <= 3 {
                            print("DEBUG: \(columnName) (TEXT): '\(value)'")
                        }
                    }
                case SQLITE_INTEGER:
                    let value = sqlite3_column_int64(statement, i)
                    messageData[columnName] = value
                    if rowCount <= 3 {
                        print("DEBUG: \(columnName) (INTEGER): \(value)")
                    }
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(statement, i)
                    messageData[columnName] = value
                    if rowCount <= 3 {
                        print("DEBUG: \(columnName) (FLOAT): \(value)")
                    }
                case SQLITE_BLOB:
                    if rowCount <= 3 {
                        let blobSize = sqlite3_column_bytes(statement, i)
                        print("DEBUG: \(columnName) (BLOB): \(blobSize) bytes - SKIPPING")
                    }
                    // Don't extract BLOB to avoid issues for now
                default:
                    if rowCount <= 3 {
                        print("DEBUG: \(columnName) (NULL/OTHER): skipped")
                    }
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
        
        // DEBUG: Print raw message data to see what we're getting
        if stats.itemsProcessed < 3 {
            print("DEBUG: Raw messageData keys: \(messageData.keys)")
            for (key, value) in messageData {
                print("DEBUG: \(key) = '\(value)' (type: \(type(of: value)))")
            }
        }
        
        // Extract data with safe fallbacks for missing keys (NULL values)
        // Use attributedBody if available (modern Messages), fallback to text
        let textContent = messageData["attributedBody"] as? String ?? messageData["text"] as? String ?? ""
        let guid = messageData["guid"] as? String ?? UUID().uuidString  
        let handleId = messageData["handle_id"] as? String ?? ""
        let service = messageData["service"] as? String ?? "unknown"
        let chatName = messageData["chat_name"] as? String
        let isFromMe = (messageData["is_from_me"] as? Int64) == 1
        
        // DEBUG: Print extracted values
        if stats.itemsProcessed < 3 {
            print("DEBUG: Extracted textContent: '\(textContent)' (length: \(textContent.count))")
            print("DEBUG: Extracted guid: '\(guid)'")
            print("DEBUG: Extracted handleId: '\(handleId)'")
            print("DEBUG: Extracted service: '\(service)'")
            print("DEBUG: Will skip due to empty content: \(textContent.isEmpty)")
        }
        
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
        
        print("DEBUG: About to insert document with data: \(docData)")
        fflush(stdout)
        print("CRASH-DEBUG: Calling database.insert for documents...")
        fflush(stdout)
        let documentInsertResult = database.insert("documents", data: docData)
        print("DEBUG: Document insert result: \(documentInsertResult)")
        fflush(stdout)
        if documentInsertResult {
            print("DEBUG: Document insert succeeded")
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
            
            print("DEBUG: About to insert message with data: \(messageSpecificData)")
            fflush(stdout)
            print("CRASH-DEBUG: Calling database.insert for messages...")
            fflush(stdout)
            let messageInsertResult = database.insert("messages", data: messageSpecificData)
            print("DEBUG: Message insert result: \(messageInsertResult)")
            fflush(stdout)
            if messageInsertResult {
                print("DEBUG: Message insert succeeded")
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