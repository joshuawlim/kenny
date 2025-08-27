import Foundation

/// Backup integration that preserves comprehensive_ingest.py backup functionality
/// while providing Swift-native backup capabilities
public class BackupIntegration {
    
    private let dbPath: String
    private let toolsPath: String
    
    public init(dbPath: String? = nil) {
        if let customPath = dbPath {
            self.dbPath = customPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, 
                                                     in: .userDomainMask).first!
            let assistantDir = appSupport.appendingPathComponent("Assistant")
            self.dbPath = assistantDir.appendingPathComponent("assistant.db").path
        }
        
        self.toolsPath = "/Users/joshwlim/Documents/Kenny/tools"
    }
    
    /// Create database backup using Python script (preserves existing functionality)
    public func createBackupWithPythonScript() async throws -> BackupResult {
        let backupScript = "\(toolsPath)/db_backup.py"
        
        // Verify backup script exists
        guard FileManager.default.fileExists(atPath: backupScript) else {
            throw BackupError.scriptNotFound(backupScript)
        }
        
        print("Creating database backup using Python script...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [backupScript]
        process.currentDirectoryURL = URL(fileURLWithPath: toolsPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        let startTime = Date()
        
        try process.run()
        process.waitUntilExit()
        
        let duration = Date().timeIntervalSince(startTime)
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        if process.terminationStatus == 0 {
            // Parse backup information from Python script output
            let backupInfo = parseBackupInfo(from: output)
            
            return BackupResult(
                success: true,
                backupPath: backupInfo.path,
                backupSize: backupInfo.sizeInMB,
                duration: duration,
                method: .pythonScript,
                error: nil
            )
        } else {
            return BackupResult(
                success: false,
                backupPath: nil,
                backupSize: 0,
                duration: duration,
                method: .pythonScript,
                error: errorOutput.isEmpty ? "Backup script failed" : errorOutput
            )
        }
    }
    
    /// Create database backup using native Swift functionality
    public func createNativeBackup() throws -> BackupResult {
        let startTime = Date()
        
        // Generate backup filename with timestamp
        let timestamp = DateFormatter.backupTimestamp.string(from: Date())
        let backupDir = "\(NSHomeDirectory())/Library/Application Support/Assistant/backups"
        let backupFilename = "kenny_backup_\(timestamp).db"
        let backupPath = "\(backupDir)/\(backupFilename)"
        
        // Ensure backup directory exists
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        
        print("Creating native Swift backup: \(backupFilename)")
        
        do {
            // Copy database file
            try FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
            
            // Get file size
            let attributes = try FileManager.default.attributesOfItem(atPath: backupPath)
            let sizeInBytes = attributes[.size] as? Int64 ?? 0
            let sizeInMB = Double(sizeInBytes) / (1024 * 1024)
            
            let duration = Date().timeIntervalSince(startTime)
            
            print("✅ Native backup created: \(backupFilename) (\(String(format: "%.2f", sizeInMB))MB)")
            
            return BackupResult(
                success: true,
                backupPath: backupPath,
                backupSize: sizeInMB,
                duration: duration,
                method: .nativeSwift,
                error: nil
            )
            
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            
            return BackupResult(
                success: false,
                backupPath: nil,
                backupSize: 0,
                duration: duration,
                method: .nativeSwift,
                error: error.localizedDescription
            )
        }
    }
    
    /// Create backup using the best available method
    public func createBackup() async throws -> BackupResult {
        // Try Python script first (preserves existing functionality)
        do {
            let result = try await createBackupWithPythonScript()
            if result.success {
                return result
            }
        } catch {
            print("⚠️  Python backup script failed, falling back to native backup: \(error.localizedDescription)")
        }
        
        // Fallback to native Swift backup
        return try createNativeBackup()
    }
    
    /// Check WhatsApp bridge status (from comprehensive_ingest.py)
    public func checkWhatsAppBridgeStatus() async -> WhatsAppBridgeStatus {
        var status = WhatsAppBridgeStatus()
        
        // Check if bridge process is running
        let psResult = await runCommand(["ps", "aux"])
        if psResult.output.contains("kenny_whatsapp_enhanced") {
            status.processRunning = true
        }
        
        // Check bridge database
        let bridgeDBPath = "\(toolsPath)/whatsapp/whatsapp_messages.db"
        if FileManager.default.fileExists(atPath: bridgeDBPath) {
            status.databaseExists = true
            
            // Get message count and recent activity
            if let bridgeInfo = getBridgeDatabaseInfo(path: bridgeDBPath) {
                status.messageCount = bridgeInfo.messageCount
                status.lastMessageTime = bridgeInfo.lastMessageTime
                
                // Check if last message is within 24 hours
                if let lastMessage = bridgeInfo.lastMessageTime {
                    let hoursSinceLastMessage = Date().timeIntervalSince(lastMessage) / 3600
                    status.recentActivity = hoursSinceLastMessage < 24
                }
            }
        }
        
        // Determine overall status
        if status.processRunning && status.databaseExists && status.recentActivity {
            status.overallStatus = .active
        } else if status.processRunning && status.databaseExists {
            status.overallStatus = .runningButStale
        } else {
            status.overallStatus = .inactive
        }
        
        return status
    }
    
    /// Get WhatsApp bridge database information
    private func getBridgeDatabaseInfo(path: String) -> BridgeDatabaseInfo? {
        // This would require SQLite integration to read the bridge database
        // For now, return basic info
        return BridgeDatabaseInfo(messageCount: 0, lastMessageTime: nil)
    }
    
    /// Parse backup information from Python script output
    private func parseBackupInfo(from output: String) -> (path: String?, sizeInMB: Double) {
        var backupPath: String?
        var sizeInMB: Double = 0
        
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("BACKUP_SUMMARY:") {
                // Parse path
                if let pathRange = line.range(of: "path=") {
                    let pathStart = pathRange.upperBound
                    if let pathEnd = line[pathStart...].firstIndex(of: ",") {
                        backupPath = String(line[pathStart..<pathEnd])
                    } else {
                        // Path is at the end of the line
                        let components = line.components(separatedBy: "path=")
                        if components.count > 1 {
                            backupPath = components[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                
                // Parse size
                let sizePattern = #"size=([0-9.]+)MB"#
                if let regex = try? NSRegularExpression(pattern: sizePattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let sizeRange = Range(match.range(at: 1), in: line) {
                    sizeInMB = Double(line[sizeRange]) ?? 0
                }
                
                break
            }
        }
        
        return (backupPath, sizeInMB)
    }
    
    /// Run shell command asynchronously
    private func runCommand(_ arguments: [String]) async -> (output: String, error: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                
                continuation.resume(returning: (output, error, process.terminationStatus))
            } catch {
                continuation.resume(returning: ("", error.localizedDescription, -1))
            }
        }
    }
    
    /// List available backups
    public func listAvailableBackups() -> [BackupInfo] {
        let backupDir = "\(NSHomeDirectory())/Library/Application Support/Assistant/backups"
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: backupDir) else {
            return []
        }
        
        let backupFiles = files.filter { $0.hasPrefix("kenny_backup_") && $0.hasSuffix(".db") }
        
        return backupFiles.compactMap { filename in
            let fullPath = "\(backupDir)/\(filename)"
            
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int64 else {
                return nil
            }
            
            let sizeInMB = Double(size) / (1024 * 1024)
            
            return BackupInfo(
                filename: filename,
                path: fullPath,
                createdAt: modificationDate,
                sizeInMB: sizeInMB
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Data Structures

public struct BackupResult {
    public let success: Bool
    public let backupPath: String?
    public let backupSize: Double // in MB
    public let duration: TimeInterval
    public let method: BackupMethod
    public let error: String?
    
    public var summary: String {
        if success {
            let filename = backupPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
            return "✅ Backup successful: \(filename) (\(String(format: "%.2f", backupSize))MB) in \(String(format: "%.1f", duration))s"
        } else {
            return "❌ Backup failed: \(error ?? "Unknown error")"
        }
    }
}

public enum BackupMethod: String, CaseIterable {
    case pythonScript = "python_script"
    case nativeSwift = "native_swift"
    
    public var displayName: String {
        switch self {
        case .pythonScript: return "Python Script"
        case .nativeSwift: return "Native Swift"
        }
    }
}

public struct WhatsAppBridgeStatus {
    public var processRunning: Bool = false
    public var databaseExists: Bool = false
    public var recentActivity: Bool = false
    public var messageCount: Int = 0
    public var lastMessageTime: Date?
    public var overallStatus: BridgeStatus = .inactive
    
    public var summary: String {
        let statusIcon = overallStatus.icon
        return "\(statusIcon) WhatsApp Bridge: \(overallStatus.displayName) (\(messageCount) messages)"
    }
}

public enum BridgeStatus: String, CaseIterable {
    case active = "active"
    case runningButStale = "running_but_stale"  
    case inactive = "inactive"
    
    public var displayName: String {
        switch self {
        case .active: return "Active"
        case .runningButStale: return "Running but Stale"
        case .inactive: return "Inactive"
        }
    }
    
    public var icon: String {
        switch self {
        case .active: return "🟢"
        case .runningButStale: return "🟡"
        case .inactive: return "🔴"
        }
    }
}

public struct BridgeDatabaseInfo {
    public let messageCount: Int
    public let lastMessageTime: Date?
}

public struct BackupInfo {
    public let filename: String
    public let path: String
    public let createdAt: Date
    public let sizeInMB: Double
}

public enum BackupError: Error {
    case scriptNotFound(String)
    case backupFailed(String)
    case invalidPath(String)
    
    public var localizedDescription: String {
        switch self {
        case .scriptNotFound(let path):
            return "Backup script not found at: \(path)"
        case .backupFailed(let reason):
            return "Backup failed: \(reason)"
        case .invalidPath(let path):
            return "Invalid backup path: \(path)"
        }
    }
}

// MARK: - Extensions

extension DateFormatter {
    static let backupTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}