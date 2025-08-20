import Foundation
import OSAKit

class MailIngester {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestMail(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
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
        
        print("Mail ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func createMailScript(isFullSync: Bool, since: Date?) -> String {
        let sinceFilter = if let since = since {
            "and date received of msg > (date \"\\(formatDateForAppleScript(since))\")"
        } else {
            ""
        }
        
        // Limit to recent messages for performance
        let messageLimit = isFullSync ? "500" : "100"
        
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
        
        if database.insert("documents", data: docData) {
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
            
            if database.insert("emails", data: emailSpecificData) {
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