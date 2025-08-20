import Foundation
import ArgumentParser
import EventKit
import OSLog

// MARK: - Logging Infrastructure
struct LogEntry: Codable {
    let tool: String
    let args: [String: AnyCodable]
    let result: AnyCodable?
    let error: String?
    let start_ts: String
    let end_ts: String
    let duration_ms: Int
    let host: String
    let version: String
    let dry_run: Bool
    let confirmed: Bool
}

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else {
            try container.encode(String(describing: value))
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = ""
        }
    }
}

struct Logger {
    static let logPath = "\(NSHomeDirectory())/Library/Logs/Assistant/tools.ndjson"
    
    static func setup() {
        let logDir = "\(NSHomeDirectory())/Library/Logs/Assistant"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }
    
    static func log(_ entry: LogEntry) {
        guard let data = try? JSONEncoder().encode(entry),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        
        let output = jsonString + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(output.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? output.write(toFile: logPath, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Error Handling
struct ErrorOut: Codable {
    struct E: Codable {
        let code: String
        let message: String
        let details: [String: String]?
    }
    let error: E
}

@discardableResult
func printJSON<T: Encodable>(_ value: T) -> Int32 {
    let enc = JSONEncoder()
    enc.outputFormatting = []
    do {
        let data = try enc.encode(value)
        if let s = String(data: data, encoding: .utf8) {
            print(s)
            return 0
        }
    } catch {}
    return 1
}

// MARK: - Dry Run Infrastructure
struct DryRunManager {
    private static let hashFile = "\(NSHomeDirectory())/Library/Application Support/Assistant/.dry_run_hashes"
    
    static func storeDryRunHash(_ hash: String) {
        let timestamp = Date().timeIntervalSince1970
        let entry = "\(hash):\(timestamp)\n"
        try? entry.appendToFile(atPath: hashFile)
    }
    
    static func validateConfirmHash(_ hash: String) -> Bool {
        guard let content = try? String(contentsOfFile: hashFile) else { return false }
        let now = Date().timeIntervalSince1970
        
        for line in content.components(separatedBy: "\n") {
            let parts = line.split(separator: ":")
            if parts.count == 2,
               String(parts[0]) == hash,
               let timestamp = Double(parts[1]),
               now - timestamp < 300 { // 5 minutes
                return true
            }
        }
        return false
    }
}

extension String {
    func appendToFile(atPath path: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            handle.seekToEndOfFile()
            handle.write(self.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try self.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Commands

struct MailListHeaders: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "mail_list_headers",
        abstract: "List mail headers"
    )
    
    @Option(help: "Account name")
    var account: String = "default"
    
    @Option(help: "Since date (ISO8601)")
    var since: String?
    
    @Option(help: "Limit results")
    var limit: Int = 50
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    func run() throws {
        let startTime = Date()
        let args: [String: AnyCodable] = [
            "account": AnyCodable(account),
            "since": AnyCodable(since ?? ""),
            "limit": AnyCodable(limit)
        ]
        
        struct MailHeader: Codable {
            let message_id: String
            let subject: String  
            let from: String
            let date: String
        }
        
        struct MailResult: Codable {
            let headers: [MailHeader]
        }
        
        let result = MailResult(headers: [
            MailHeader(message_id: "1", subject: "Test Email", from: "test@example.com", date: "2024-01-01T12:00:00Z"),
            MailHeader(message_id: "2", subject: "Another Email", from: "another@example.com", date: "2024-01-02T12:00:00Z")
        ])
        
        _ = printJSON(result)
        
        let endTime = Date()
        let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
        
        let logEntry = LogEntry(
            tool: "mail_list_headers",
            args: args,
            result: AnyCodable(result),
            error: nil,
            start_ts: ISO8601DateFormatter().string(from: startTime),
            end_ts: ISO8601DateFormatter().string(from: endTime),
            duration_ms: duration,
            host: ProcessInfo.processInfo.hostName,
            version: "0.0.1",
            dry_run: dryRun,
            confirmed: false
        )
        
        Logger.log(logEntry)
        throw ExitCode.success
    }
}

struct CalendarList: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "calendar_list",
        abstract: "List calendar events"
    )
    
    @Option(help: "From date (ISO8601)")
    var from: String
    
    @Option(help: "To date (ISO8601)")
    var to: String
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    func run() throws {
        let startTime = Date()
        let args: [String: AnyCodable] = [
            "from": AnyCodable(from),
            "to": AnyCodable(to)
        ]
        
        func isISO8601(_ s: String) -> Bool {
            return s.contains("T") && (s.contains("Z") || s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil)
        }
        
        guard isISO8601(from) && isISO8601(to) else {
            let err = ErrorOut(error: .init(code: "ARG_ERROR", message: "from/to must be ISO8601", details: ["from": from, "to": to]))
            _ = printJSON(err)
            
            let endTime = Date()
            let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            let logEntry = LogEntry(
                tool: "calendar_list",
                args: args,
                result: nil,
                error: "ARG_ERROR: from/to must be ISO8601",
                start_ts: ISO8601DateFormatter().string(from: startTime),
                end_ts: ISO8601DateFormatter().string(from: endTime),
                duration_ms: duration,
                host: ProcessInfo.processInfo.hostName,
                version: "0.0.1",
                dry_run: dryRun,
                confirmed: false
            )
            Logger.log(logEntry)
            throw ExitCode(2)
        }
        
        // TODO: Implement real EventKit integration
        struct CalendarResult: Codable {
            let events: [String]
        }
        let result = CalendarResult(events: [])
        _ = printJSON(result)
        
        let endTime = Date()
        let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
        
        let logEntry = LogEntry(
            tool: "calendar_list",
            args: args,
            result: AnyCodable(result),
            error: nil,
            start_ts: ISO8601DateFormatter().string(from: startTime),
            end_ts: ISO8601DateFormatter().string(from: endTime),
            duration_ms: duration,
            host: ProcessInfo.processInfo.hostName,
            version: "0.0.1",
            dry_run: dryRun,
            confirmed: false
        )
        Logger.log(logEntry)
        throw ExitCode.success
    }
}

struct RemindersCreate: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "reminders_create",
        abstract: "Create a reminder"
    )
    
    @Option(help: "Reminder title")
    var title: String
    
    @Option(help: "Due date (ISO8601)")
    var due: String?
    
    @Option(help: "Notes text")
    var notes: String?
    
    @Option(help: "Tags as JSON array")
    var tags: String?
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    @Flag(help: "Confirm execution")
    var confirm: Bool = false
    
    func run() throws {
        let startTime = Date()
        let args: [String: AnyCodable] = [
            "title": AnyCodable(title),
            "due": AnyCodable(due ?? ""),
            "notes": AnyCodable(notes ?? ""),
            "tags": AnyCodable(tags ?? "")
        ]
        
        let operationHash = "\(title):\(due ?? ""):\(notes ?? "")".data(using: .utf8)?.base64EncodedString() ?? ""
        
        if dryRun {
            DryRunManager.storeDryRunHash(operationHash)
            struct DryRunResult: Codable {
                let dry_run: Bool
                let operation_hash: String
                let would_create: WouldCreate
            }
            struct WouldCreate: Codable {
                let title: String
                let due: String
                let notes: String
            }
            let result = DryRunResult(
                dry_run: true,
                operation_hash: operationHash,
                would_create: WouldCreate(title: title, due: due ?? "", notes: notes ?? "")
            )
            _ = printJSON(result)
        } else {
            if confirm {
                guard DryRunManager.validateConfirmHash(operationHash) else {
                    let err = ErrorOut(error: .init(code: "CONFIRM_ERROR", message: "No matching dry-run found", details: ["hash": operationHash]))
                    _ = printJSON(err)
                    throw ExitCode(2)
                }
            }
            
            // TODO: Implement real Reminders integration
            struct CreateResult: Codable {
                let created: Bool
                let reminder_id: String
                let title: String
            }
            let result = CreateResult(
                created: true,
                reminder_id: "reminder_\(UUID().uuidString)",
                title: title
            )
            _ = printJSON(result)
        }
        
        let endTime = Date()
        let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
        
        let logEntry = LogEntry(
            tool: "reminders_create",
            args: args,
            result: AnyCodable(["created": !dryRun]),
            error: nil,
            start_ts: ISO8601DateFormatter().string(from: startTime),
            end_ts: ISO8601DateFormatter().string(from: endTime),
            duration_ms: duration,
            host: ProcessInfo.processInfo.hostName,
            version: "0.0.1",
            dry_run: dryRun,
            confirmed: confirm
        )
        Logger.log(logEntry)
        throw ExitCode.success
    }
}

struct NotesAppend: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "notes_append",
        abstract: "Append text to a note"
    )
    
    @Option(help: "Note ID")
    var noteId: String
    
    @Option(help: "Text to append")
    var text: String
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    @Flag(help: "Confirm execution")
    var confirm: Bool = false
    
    func run() throws {
        let startTime = Date()
        let args: [String: AnyCodable] = [
            "note_id": AnyCodable(noteId),
            "text": AnyCodable(text)
        ]
        
        let operationHash = "\(noteId):\(text)".data(using: .utf8)?.base64EncodedString() ?? ""
        
        if dryRun {
            DryRunManager.storeDryRunHash(operationHash)
            struct NotesDryRunResult: Codable {
                let dry_run: Bool
                let operation_hash: String
                let would_append: WouldAppend
            }
            struct WouldAppend: Codable {
                let note_id: String
                let text: String
            }
            let result = NotesDryRunResult(
                dry_run: true,
                operation_hash: operationHash,
                would_append: WouldAppend(note_id: noteId, text: text)
            )
            _ = printJSON(result)
        } else {
            if confirm {
                guard DryRunManager.validateConfirmHash(operationHash) else {
                    let err = ErrorOut(error: .init(code: "CONFIRM_ERROR", message: "No matching dry-run found", details: ["hash": operationHash]))
                    _ = printJSON(err)
                    throw ExitCode(2)
                }
            }
            
            // TODO: Implement real Notes integration
            struct NotesResult: Codable {
                let appended: Bool
                let note_id: String
                let chars_added: Int
            }
            let result = NotesResult(
                appended: true,
                note_id: noteId,
                chars_added: text.count
            )
            _ = printJSON(result)
        }
        
        let endTime = Date()
        let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
        
        let logEntry = LogEntry(
            tool: "notes_append",
            args: args,
            result: AnyCodable(["appended": !dryRun]),
            error: nil,
            start_ts: ISO8601DateFormatter().string(from: startTime),
            end_ts: ISO8601DateFormatter().string(from: endTime),
            duration_ms: duration,
            host: ProcessInfo.processInfo.hostName,
            version: "0.0.1",
            dry_run: dryRun,
            confirmed: confirm
        )
        Logger.log(logEntry)
        throw ExitCode.success
    }
}

struct FilesMove: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "files_move",
        abstract: "Move files"
    )
    
    @Option(help: "Source path")
    var src: String
    
    @Option(help: "Destination path")
    var dst: String
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    @Flag(help: "Confirm execution")
    var confirm: Bool = false
    
    func run() throws {
        let startTime = Date()
        let args: [String: AnyCodable] = [
            "src": AnyCodable(src),
            "dst": AnyCodable(dst)
        ]
        
        let operationHash = "\(src):\(dst)".data(using: .utf8)?.base64EncodedString() ?? ""
        
        if dryRun {
            DryRunManager.storeDryRunHash(operationHash)
            struct FilesDryRunResult: Codable {
                let dry_run: Bool
                let operation_hash: String
                let would_move: WouldMove
            }
            struct WouldMove: Codable {
                let src: String
                let dst: String
            }
            let result = FilesDryRunResult(
                dry_run: true,
                operation_hash: operationHash,
                would_move: WouldMove(src: src, dst: dst)
            )
            _ = printJSON(result)
        } else {
            if confirm {
                guard DryRunManager.validateConfirmHash(operationHash) else {
                    let err = ErrorOut(error: .init(code: "CONFIRM_ERROR", message: "No matching dry-run found", details: ["hash": operationHash]))
                    _ = printJSON(err)
                    throw ExitCode(2)
                }
            }
            
            // TODO: Implement real file operations
            struct FilesResult: Codable {
                let moved: Bool
                let src: String
                let dst: String
            }
            let result = FilesResult(
                moved: true,
                src: src,
                dst: dst
            )
            _ = printJSON(result)
        }
        
        let endTime = Date()
        let duration = Int((endTime.timeIntervalSince(startTime)) * 1000)
        
        let logEntry = LogEntry(
            tool: "files_move",
            args: args,
            result: AnyCodable(["moved": !dryRun]),
            error: nil,
            start_ts: ISO8601DateFormatter().string(from: startTime),
            end_ts: ISO8601DateFormatter().string(from: endTime),
            duration_ms: duration,
            host: ProcessInfo.processInfo.hostName,
            version: "0.0.1",
            dry_run: dryRun,
            confirmed: confirm
        )
        Logger.log(logEntry)
        throw ExitCode.success
    }
}

@main
struct MacTools: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac_tools",
        abstract: "macOS automation tools with JSON I/O",
        version: "0.0.1",
        subcommands: [
            MailListHeaders.self,
            CalendarList.self,
            RemindersCreate.self,
            NotesAppend.self,
            FilesMove.self
        ]
    )
    
    init() {
        Logger.setup()
    }
}