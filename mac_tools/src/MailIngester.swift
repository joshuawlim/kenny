import Foundation
import OSAKit
import SQLite3

class MailIngester {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestMail(isFullSync: Bool, since: Date? = nil, batchSize: Int = 500, maxMessages: Int = 0) async throws -> IngestStats {
        var stats = IngestStats(source: "mail")
        
        // Try direct database access first, fallback to AppleScript if needed
        do {
            stats = try await ingestMailDirect(isFullSync: isFullSync, since: since, batchSize: batchSize, maxMessages: maxMessages)
            print("Mail ingest (direct): \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
            return stats
        } catch {
            print("Direct database access failed (\(error)), falling back to AppleScript...")
            return try await ingestMailAppleScript(isFullSync: isFullSync, since: since)
        }
    }
    
    private func ingestMailDirect(isFullSync: Bool, since: Date? = nil, batchSize: Int = 500, maxMessages: Int = 0) async throws -> IngestStats {
        var stats = IngestStats(source: "mail")
        print("DEBUG: Starting Mail ingestion (direct database access)...")
        
        // Locate Mail database
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let mailDbPath = "\(homeDir)/Library/Mail/V10/MailData/Envelope Index"
        
        guard FileManager.default.fileExists(atPath: mailDbPath) else {
            throw IngestError.dataCorruption // Mail database not found
        }
        
        // Open Mail database
        var mailDb: OpaquePointer?
        guard sqlite3_open_v2(mailDbPath, &mailDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw IngestError.dataCorruption
        }
        defer { sqlite3_close(mailDb) }
        
        // For full sync, clear existing Mail data
        if isFullSync {
            print("DEBUG: Clearing existing Mail data for full sync...")
            // Delete emails first (referencing documents), then documents
            let deletedEmails = database.execute("DELETE FROM emails WHERE document_id IN (SELECT id FROM documents WHERE app_source = 'Mail')")
            let deletedDocs = database.execute("DELETE FROM documents WHERE app_source = 'Mail'")
            print("DEBUG: Cleared existing Mail data - emails: \(deletedEmails), docs: \(deletedDocs)")
        }
        
        // Build query with joins for complete message data
        let sinceFilter = if let since = since {
            " AND m.date_received > \(Int(since.timeIntervalSince1970))"
        } else {
            ""
        }
        
        let limitClause = maxMessages > 0 ? " LIMIT \(maxMessages)" : ""
        
        let sql = """
            SELECT 
                m.ROWID, m.document_id, s.subject, a.address, a.comment,
                m.date_sent, m.date_received, m.read, m.flagged, 
                mb.url as mailbox_name, m.size
            FROM messages m 
            JOIN subjects s ON m.subject = s.ROWID 
            JOIN addresses a ON m.sender = a.ROWID 
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE m.deleted = 0\(sinceFilter)
            ORDER BY m.date_received DESC\(limitClause)
        """
        
        print("DEBUG: Executing Mail query...")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(mailDb, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(mailDb))
            print("ERROR preparing Mail query: \(error)")
            throw IngestError.dataCorruption
        }
        
        var processedInBatch = 0
        
        print("DEBUG: Processing Mail messages in batches of \(batchSize)...")
        while sqlite3_step(statement) == SQLITE_ROW {
            let documentId = UUID().uuidString
            let now = Int(Date().timeIntervalSince1970)
            
            // Extract data from SQLite result
            let mailRowId = sqlite3_column_int64(statement, 0)
            let originalDocId = sqlite3_column_text(statement, 1)
            let subjectText = sqlite3_column_text(statement, 2)
            let senderAddress = sqlite3_column_text(statement, 3)
            let senderName = sqlite3_column_text(statement, 4)
            let dateSent = sqlite3_column_int64(statement, 5)
            let dateReceived = sqlite3_column_int64(statement, 6)
            let isRead = sqlite3_column_int(statement, 7)
            let isFlagged = sqlite3_column_int(statement, 8)
            let mailboxName = sqlite3_column_text(statement, 9)
            let messageSize = sqlite3_column_int(statement, 10)
            
            // Convert to Swift strings safely
            let subject = subjectText != nil ? String(cString: subjectText!) : "No Subject"
            let sender = senderAddress != nil ? String(cString: senderAddress!) : "Unknown Sender"
            let senderDisplayName = senderName != nil ? String(cString: senderName!) : sender
            let mailbox = mailboxName != nil ? String(cString: mailboxName!) : "Unknown"
            let originalId = originalDocId != nil ? String(cString: originalDocId!) : "mail-\(mailRowId)"
            
            // Create searchable content (metadata only - no message body for now)
            let content = "\(subject) \(senderDisplayName) \(sender)"
            
            let docData: [String: Any] = [
                "id": documentId,
                "type": "email",
                "title": subject,
                "content": content,
                "app_source": "Mail",
                "source_id": originalId,
                "source_path": "message://\(originalId)",
                "hash": "\(originalId)\(subject)\(sender)\(dateReceived)".sha256(),
                "created_at": Int(dateReceived),
                "updated_at": now,
                "last_seen_at": now,
                "deleted": false
            ]
            
            if database.insertOrReplace("documents", data: docData) {
                let emailData: [String: Any] = [
                    "document_id": documentId,
                    "message_id": originalId,
                    "from_address": sender,
                    "from_name": senderDisplayName,
                    "date_sent": Int(dateSent),
                    "date_received": Int(dateReceived),
                    "is_read": isRead == 1,
                    "is_flagged": isFlagged == 1,
                    "mailbox": mailbox
                ]
                
                if database.insertOrReplace("emails", data: emailData) {
                    stats.itemsCreated += 1
                } else {
                    stats.errors += 1
                }
            } else {
                stats.errors += 1
            }
            
            stats.itemsProcessed += 1
            processedInBatch += 1
            
            // Progress reporting
            if stats.itemsProcessed <= 3 || stats.itemsProcessed % 100 == 0 {
                print("DEBUG: Processing email \(stats.itemsProcessed): \(subject) from \(senderDisplayName)")
            }
            
            // Batch commit every batchSize messages
            if processedInBatch >= batchSize {
                print("DEBUG: Completed batch of \(batchSize) messages. Total: \(stats.itemsProcessed)")
                processedInBatch = 0
            }
            
            // Respect maxMessages limit
            if maxMessages > 0 && stats.itemsProcessed >= maxMessages {
                break
            }
        }
        
        print("DEBUG: Mail direct ingestion complete. Processed \(stats.itemsProcessed) messages")
        return stats
    }
    
    private func ingestMailAppleScript(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "mail")
        
        // Check if Mail.app is running
        let runningApps = NSWorkspace.shared.runningApplications
        let mailRunning = runningApps.contains { $0.bundleIdentifier == "com.apple.mail" }
        
        if !mailRunning {
            print("Mail.app not running, attempting to launch...")
            if !NSWorkspace.shared.launchApplication("Mail") {
                throw IngestError.dataCorruption // Can't launch Mail
            }
            // Give Mail time to start
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        
        let script = createMailScript(isFullSync: isFullSync, since: since)
        let result = try await executeAppleScript(script)
        
        if let mailData = parseMailScriptResult(result) {
            for emailData in mailData {
                await processEmailData(emailData, stats: &stats)
            }
        }
        
        print("Mail ingest (AppleScript): \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func createMailScript(isFullSync: Bool, since: Date?) -> String {
        let sinceFilter = if let since = since {
            "and date received of msg > (date \"\\(formatDateForAppleScript(since))\")"
        } else {
            ""
        }
        
        // Increase limits for real data ingestion 
        let messageLimit = isFullSync ? "5000" : "500"  // Match user's data volume
        
        return """
        tell application "Mail"
            set messageList to {}
            set messageCount to 0
            
            repeat with acc in accounts
                if messageCount > \(messageLimit) then exit repeat
                
                repeat with mbox in mailboxes of acc
                    if messageCount > \(messageLimit) then exit repeat
                    
                    try
                        set msgs to messages of mbox
                        repeat with msg in msgs
                            if messageCount > \(messageLimit) then exit repeat
                            
                            try
                                -- Filter by date if needed
                                if true \(sinceFilter) then
                                    set msgData to {¬
                                        id of msg as string, ¬
                                        subject of msg as string, ¬
                                        sender of msg as string, ¬
                                        date received of msg as string, ¬
                                        date sent of msg as string, ¬
                                        content of msg as string, ¬
                                        message id of msg as string, ¬
                                        read status of msg as boolean, ¬
                                        flagged status of msg as boolean, ¬
                                        name of mbox as string, ¬
                                        name of acc as string¬
                                    }
                                    set messageList to messageList & {msgData}
                                    set messageCount to messageCount + 1
                                end if
                            on error
                                -- Skip messages that can't be read
                            end try
                        end repeat
                    on error
                        -- Skip mailboxes that can't be accessed
                    end try
                end repeat
            end repeat
            
            return messageList
        end tell
        """
    }
    
    private func executeAppleScript(_ script: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let osascript = OSAScript(source: script, language: OSALanguage(forName: "AppleScript"))
                var error: NSDictionary?
                
                let result = osascript.executeAndReturnError(&error)
                
                if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }
    
    private func parseMailScriptResult(_ result: String) -> [[String: Any]]? {
        // AppleScript returns a formatted list - need to parse it
        // This is a simplified parser - in production, would need more robust parsing
        var emails: [[String: Any]] = []
        
        // Split result into individual email records
        let lines = result.components(separatedBy: "\n")
        var currentEmail: [String: Any] = [:]
        var fieldIndex = 0
        
        let fields = ["id", "subject", "sender", "date_received", "date_sent", "content", "message_id", "is_read", "is_flagged", "mailbox", "account"]
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            if trimmedLine.starts(with: "{") || trimmedLine.starts(with: "}") {
                if !currentEmail.isEmpty {
                    emails.append(currentEmail)
                    currentEmail = [:]
                    fieldIndex = 0
                }
                continue
            }
            
            // Parse field value
            if fieldIndex < fields.count {
                let fieldName = fields[fieldIndex]
                var value: Any = trimmedLine
                
                // Type conversion based on field
                switch fieldName {
                case "is_read", "is_flagged":
                    value = trimmedLine.lowercased() == "true"
                case "date_received", "date_sent":
                    value = parseDateFromAppleScript(trimmedLine)
                default:
                    value = trimmedLine.replacingOccurrences(of: "\"", with: "")
                }
                
                currentEmail[fieldName] = value
                fieldIndex += 1
            }
        }
        
        if !currentEmail.isEmpty {
            emails.append(currentEmail)
        }
        
        return emails.isEmpty ? nil : emails
    }
    
    private func processEmailData(_ emailData: [String: Any], stats: inout IngestStats) async {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        let subject = emailData["subject"] as? String ?? "No Subject"
        let content = emailData["content"] as? String ?? ""
        let messageId = emailData["message_id"] as? String ?? UUID().uuidString
        
        // Create searchable content
        let sender = emailData["sender"] as? String ?? ""
        let searchContent = "\(subject)\n\(content)\n\(sender)"
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "email",
            "title": subject,
            "content": searchContent,
            "app_source": "Mail",
            "source_id": messageId,
            "source_path": "message://\(messageId)",
            "hash": "\(messageId)\(subject)\(content)".sha256(),
            "created_at": emailData["date_sent"] as? Int ?? now,
            "updated_at": now,
            "last_seen_at": now,
            "deleted": false
        ]
        
        if database.insertOrReplace("documents", data: docData) {
            // Parse sender email and name
            let senderString = sender
            let (fromName, fromEmail) = parseSenderString(senderString)
            
            let emailSpecificData: [String: Any] = [
                "document_id": documentId,
                "message_id": messageId,
                "from_name": fromName ?? NSNull(),
                "from_address": fromEmail ?? NSNull(),
                "date_received": emailData["date_received"] as? Int ?? now,
                "date_sent": emailData["date_sent"] as? Int ?? now,
                "is_read": emailData["is_read"] as? Bool ?? false,
                "is_flagged": emailData["is_flagged"] as? Bool ?? false,
                "mailbox": emailData["mailbox"] as? String ?? NSNull(),
                "snippet": String(content.prefix(200))
            ]
            
            if database.insertOrReplace("emails", data: emailSpecificData) {
                stats.itemsCreated += 1
                
                // Try to create relationships with contacts
                if let contactId = findContactByEmail(fromEmail) {
                    createRelationship(from: contactId, to: documentId, type: "sent_email")
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
    private func formatDateForAppleScript(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        return formatter.string(from: date)
    }
    
    private func parseDateFromAppleScript(_ dateString: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        if let date = formatter.date(from: dateString) {
            return Int(date.timeIntervalSince1970)
        }
        
        // Try alternative formats
        let formatters = [
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss",
            "MMM d, yyyy HH:mm:ss"
        ]
        
        for format in formatters {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return Int(date.timeIntervalSince1970)
            }
        }
        
        return Int(Date().timeIntervalSince1970)
    }
    
    private func parseSenderString(_ sender: String) -> (name: String?, email: String?) {
        // Parse "Name <email@domain.com>" or just "email@domain.com"
        let emailPattern = #"<([^>]+)>"#
        let namePattern = #"^([^<]+)"#
        
        let emailRegex = try? NSRegularExpression(pattern: emailPattern)
        let nameRegex = try? NSRegularExpression(pattern: namePattern)
        
        let range = NSRange(sender.startIndex..., in: sender)
        
        var email: String?
        var name: String?
        
        if let emailMatch = emailRegex?.firstMatch(in: sender, range: range) {
            let emailRange = Range(emailMatch.range(at: 1), in: sender)!
            email = String(sender[emailRange])
        }
        
        if let nameMatch = nameRegex?.firstMatch(in: sender, range: range) {
            let nameRange = Range(nameMatch.range(at: 1), in: sender)!
            name = String(sender[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // If no angle brackets, assume it's just an email
        if email == nil && sender.contains("@") {
            email = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return (name, email)
    }
    
    private func findContactByEmail(_ email: String?) -> String? {
        guard let email = email else { return nil }
        
        let results = database.query(
            "SELECT document_id FROM contacts WHERE emails LIKE ?",
            parameters: ["%\(email)%"]
        )
        
        return results.first?["document_id"] as? String
    }
    
    private func createRelationship(from: String, to: String, type: String) {
        let relationshipData: [String: Any] = [
            "id": UUID().uuidString,
            "from_document_id": from,
            "to_document_id": to,
            "relationship_type": type,
            "strength": 1.0,
            "created_at": Int(Date().timeIntervalSince1970)
        ]
        
        database.insert("relationships", data: relationshipData)
    }
}