import Foundation
import OSAKit

class NotesIngester {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func ingestNotes(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "notes")
        
        // Check if Notes.app is accessible
        let runningApps = NSWorkspace.shared.runningApplications
        let notesRunning = runningApps.contains { $0.bundleIdentifier == "com.apple.Notes" }
        
        if !notesRunning {
            print("Notes.app not running, attempting to launch...")
            if !NSWorkspace.shared.launchApplication("Notes") {
                throw IngestError.dataCorruption // Can't launch Notes
            }
            // Give Notes time to start
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        let script = createNotesScript(isFullSync: isFullSync, since: since)
        let result = try await executeAppleScript(script)
        
        if let notesData = parseNotesScriptResult(result) {
            for noteData in notesData {
                await processNoteData(noteData, stats: &stats)
            }
        }
        
        print("Notes ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func createNotesScript(isFullSync: Bool, since: Date?) -> String {
        let sinceFilter = if let since = since {
            "and modification date of note > (date \"\\(formatDateForAppleScript(since))\")"
        } else {
            ""
        }
        
        // Limit notes for performance
        let noteLimit = isFullSync ? "200" : "50"
        
        return """
        tell application "Notes"
            set notesList to {}
            set noteCount to 0
            
            repeat with acc in accounts
                if noteCount > \(noteLimit) then exit repeat
                
                repeat with folder in folders of acc
                    if noteCount > \(noteLimit) then exit repeat
                    
                    try
                        repeat with note in notes of folder
                            if noteCount > \(noteLimit) then exit repeat
                            
                            try
                                -- Filter by modification date if needed
                                if true \(sinceFilter) then
                                    set noteData to {¬
                                        id of note as string, ¬
                                        name of note as string, ¬
                                        body of note as string, ¬
                                        creation date of note as string, ¬
                                        modification date of note as string, ¬
                                        name of folder as string, ¬
                                        name of acc as string, ¬
                                        password protected of note as boolean¬
                                    }
                                    set notesList to notesList & {noteData}
                                    set noteCount to noteCount + 1
                                end if
                            on error
                                -- Skip notes that can't be read (e.g., protected notes)
                            end try
                        end repeat
                    on error
                        -- Skip folders that can't be accessed
                    end try
                end repeat
            end repeat
            
            return notesList
        end tell
        """
    }
    
    private func executeAppleScript(_ script: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let osascript = OSAScript(source: script, language: OSALanguage(forName: "AppleScript"))
                var error: NSDictionary?
                
                let result = osascript?.executeAndReturnError(&error)
                
                if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }
    
    private func parseNotesScriptResult(_ result: String) -> [[String: Any]]? {
        // Parse AppleScript result format
        var notes: [[String: Any]] = []
        
        let lines = result.components(separatedBy: "\n")
        var currentNote: [String: Any] = [:]
        var fieldIndex = 0
        
        let fields = ["id", "name", "body", "creation_date", "modification_date", "folder", "account", "password_protected"]
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            if trimmedLine.starts(with: "{") || trimmedLine.starts(with: "}") {
                if !currentNote.isEmpty {
                    notes.append(currentNote)
                    currentNote = [:]
                    fieldIndex = 0
                }
                continue
            }
            
            // Parse field value
            if fieldIndex < fields.count {
                let fieldName = fields[fieldIndex]
                var value: Any = trimmedLine.replacingOccurrences(of: "\"", with: "")
                
                // Type conversion based on field
                switch fieldName {
                case "password_protected":
                    value = trimmedLine.lowercased().contains("true")
                case "creation_date", "modification_date":
                    value = parseDateFromAppleScript(trimmedLine)
                default:
                    break
                }
                
                currentNote[fieldName] = value
                fieldIndex += 1
            }
        }
        
        if !currentNote.isEmpty {
            notes.append(currentNote)
        }
        
        return notes.isEmpty ? nil : notes
    }
    
    private func processNoteData(_ noteData: [String: Any], stats: inout IngestStats) async {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        let title = noteData["name"] as? String ?? "Untitled Note"
        let body = noteData["body"] as? String ?? ""
        let noteId = noteData["id"] as? String ?? UUID().uuidString
        
        // Create searchable content (title + body)
        let searchableContent = "\(title)\n\(body)"
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "note",
            "title": title,
            "content": searchableContent,
            "app_source": "Notes",
            "source_id": noteId,
            "source_path": "mobilenotes://note/\(noteId)",
            "hash": "\(noteId)\(title)\(body)".sha256(),
            "created_at": noteData["creation_date"] as? Int ?? now,
            "updated_at": noteData["modification_date"] as? Int ?? now,
            "last_seen_at": now,
            "deleted": false
        ]
        
        if database.insert("documents", data: docData) {
            let noteSpecificData: [String: Any] = [
                "document_id": documentId,
                "folder": noteData["folder"] as? String ?? NSNull(),
                "is_locked": noteData["password_protected"] as? Bool ?? false,
                "modification_date": noteData["modification_date"] as? Int ?? now,
                "creation_date": noteData["creation_date"] as? Int ?? now,
                "snippet": String(body.prefix(200)),
                "word_count": body.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            ]
            
            if database.insert("notes", data: noteSpecificData) {
                stats.itemsCreated += 1
                
                // Create relationships with contacts if email addresses found in note
                let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
                let regex = try? NSRegularExpression(pattern: emailPattern, options: .caseInsensitive)
                let range = NSRange(body.startIndex..., in: body)
                
                regex?.enumerateMatches(in: body, range: range) { match, _, _ in
                    if let matchRange = Range(match!.range, in: body) {
                        let email = String(body[matchRange])
                        if let contactId = findContactByEmail(email) {
                            createRelationship(from: contactId, to: documentId, type: "mentioned_in_note")
                        }
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
    
    private func findContactByEmail(_ email: String) -> String? {
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
            "strength": 0.5,
            "created_at": Int(Date().timeIntervalSince1970)
        ]
        
        database.insert("relationships", data: relationshipData)
    }
}

// MARK: - String Extension (if not already defined)
extension String {
    func sha256() -> String {
        let data = self.data(using: .utf8) ?? Data()
        #if canImport(CryptoKit)
        import CryptoKit
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        import CommonCrypto
        let hash = data.withUnsafeBytes { bytes in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}