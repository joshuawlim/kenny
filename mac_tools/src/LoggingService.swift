import Foundation
import os.log

/// Centralized logging service with rotation, retention, and standardized schemas
public class LoggingService {
    static let shared = LoggingService()
    
    private let logsDirectory: URL
    private let maxFileSize: Int64 = 50 * 1024 * 1024 // 50MB
    private let maxFiles = 10
    private let retentionDays = 30
    
    private let systemLogger = Logger(subsystem: "com.kenny.logging", category: "system")
    private let auditLogger = Logger(subsystem: "com.kenny.logging", category: "audit")
    private let toolsLogger = Logger(subsystem: "com.kenny.logging", category: "tools")
    private let orchestratorLogger = Logger(subsystem: "com.kenny.logging", category: "orchestrator")
    
    private let logQueue = DispatchQueue(label: "com.kenny.logging", qos: .utility)
    
    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.logsDirectory = homeDir.appendingPathComponent(".kenny/logs")
        
        createLogsDirectoryIfNeeded()
        scheduleLogRotation()
        cleanupOldLogs()
    }
    
    private func createLogsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            systemLogger.error("Failed to create logs directory: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Public Logging Methods
    
    public func logSystem(_ level: LogLevel, _ message: String, metadata: [String: Any] = [:]) {
        let entry = createLogEntry(category: "system", level: level, message: message, metadata: metadata)
        writeToFile("system.ndjson", entry: entry)
        
        switch level {
        case .debug:
            systemLogger.debug("\(message)")
        case .info:
            systemLogger.info("\(message)")
        case .warning:
            systemLogger.warning("\(message)")
        case .error:
            systemLogger.error("\(message)")
        case .critical:
            systemLogger.critical("\(message)")
        }
    }
    
    public func logAudit(_ event: String, userId: String = "system", details: [String: Any] = [:]) {
        let metadata: [String: Any] = [
            "event": event,
            "user_id": userId,
            "details": details
        ]
        let entry = createLogEntry(category: "audit", level: .info, message: event, metadata: metadata)
        writeToFile("audit.ndjson", entry: entry)
        auditLogger.info("Audit: \(event) - User: \(userId)")
    }
    
    public func logTool(_ toolName: String, operation: String, result: String, duration: TimeInterval? = nil, metadata: [String: Any] = [:]) {
        var logMetadata = metadata
        logMetadata["tool"] = toolName
        logMetadata["operation"] = operation
        logMetadata["result"] = result
        if let duration = duration {
            logMetadata["duration_ms"] = Int(duration * 1000)
        }
        
        let entry = createLogEntry(category: "tools", level: .info, message: "\(toolName).\(operation): \(result)", metadata: logMetadata)
        writeToFile("tools.ndjson", entry: entry)
        toolsLogger.info("Tool: \(toolName).\(operation) -> \(result)")
    }
    
    public func logOrchestrator(_ operation: String, requestId: String, success: Bool, duration: TimeInterval? = nil, metadata: [String: Any] = [:]) {
        var logMetadata = metadata
        logMetadata["operation"] = operation
        logMetadata["request_id"] = requestId
        logMetadata["success"] = success
        if let duration = duration {
            logMetadata["duration_ms"] = Int(duration * 1000)
        }
        
        let level: LogLevel = success ? .info : .error
        let entry = createLogEntry(category: "orchestrator", level: level, message: "\(operation) [\(requestId)]: \(success ? "SUCCESS" : "FAILED")", metadata: logMetadata)
        writeToFile("orchestrator.ndjson", entry: entry)
        
        if success {
            orchestratorLogger.info("Orchestrator: \(operation) [\(requestId)] -> SUCCESS")
        } else {
            orchestratorLogger.error("Orchestrator: \(operation) [\(requestId)] -> FAILED")
        }
    }
    
    // MARK: - Schema Creation
    
    private func createLogEntry(category: String, level: LogLevel, message: String, metadata: [String: Any]) -> [String: Any] {
        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "category": category,
            "message": message,
            "hostname": ProcessInfo.processInfo.hostName,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "thread_id": pthread_mach_thread_np(pthread_self())
        ]
        
        // Merge metadata
        for (key, value) in metadata {
            entry[key] = value
        }
        
        return entry
    }
    
    // MARK: - File Writing with Rotation
    
    private func writeToFile(_ filename: String, entry: [String: Any]) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fileURL = self.logsDirectory.appendingPathComponent(filename)
            
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: entry, options: [])
                let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
                let logLine = jsonString + "\n"
                
                // Check if rotation is needed
                if self.shouldRotateFile(fileURL) {
                    self.rotateFile(fileURL)
                }
                
                // Append to current file
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    handle.seekToEndOfFile()
                    handle.write(logLine.data(using: .utf8) ?? Data())
                    handle.closeFile()
                } else {
                    try logLine.write(to: fileURL, atomically: false, encoding: .utf8)
                }
                
            } catch {
                self.systemLogger.error("Failed to write log entry: \(error.localizedDescription)")
            }
        }
    }
    
    private func shouldRotateFile(_ fileURL: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            return false
        }
        return fileSize >= maxFileSize
    }
    
    private func rotateFile(_ fileURL: URL) {
        let timestamp = DateFormatter().apply {
            $0.dateFormat = "yyyyMMdd_HHmmss"
        }.string(from: Date())
        
        let rotatedURL = fileURL.appendingPathExtension("\(timestamp).rotated")
        
        do {
            try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
            systemLogger.info("Rotated log file: \(fileURL.lastPathComponent) -> \(rotatedURL.lastPathComponent)")
        } catch {
            systemLogger.error("Failed to rotate log file: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Cleanup and Maintenance
    
    private func cleanupOldLogs() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.retentionDays, to: Date()) ?? Date()
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.creationDateKey])
                
                for fileURL in files {
                    if let attributes = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                       let creationDate = attributes.creationDate,
                       creationDate < cutoffDate {
                        
                        try FileManager.default.removeItem(at: fileURL)
                        self.systemLogger.info("Cleaned up old log file: \(fileURL.lastPathComponent)")
                    }
                }
            } catch {
                self.systemLogger.error("Failed to cleanup old logs: \(error.localizedDescription)")
            }
        }
    }
    
    private func scheduleLogRotation() {
        // Run cleanup every 24 hours
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.cleanupOldLogs()
        }
    }
    
    // MARK: - Public Utilities
    
    public func getLogStats() -> [String: Any] {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.fileSizeKey])
            var totalSize: Int64 = 0
            var fileCount = 0
            
            for fileURL in files {
                if let attributes = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attributes.fileSize {
                    totalSize += Int64(size)
                    fileCount += 1
                }
            }
            
            return [
                "log_directory": logsDirectory.path,
                "total_size_bytes": totalSize,
                "total_size_mb": totalSize / (1024 * 1024),
                "file_count": fileCount,
                "max_file_size_mb": maxFileSize / (1024 * 1024),
                "retention_days": retentionDays
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}

public enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
}

// Extension for convenience
extension DateFormatter {
    func apply(_ closure: (DateFormatter) -> Void) -> DateFormatter {
        closure(self)
        return self
    }
}

// MARK: - Global Logging Functions

public func logSystem(_ level: LogLevel, _ message: String, metadata: [String: Any] = [:]) {
    LoggingService.shared.logSystem(level, message, metadata: metadata)
}

public func logAudit(_ event: String, userId: String = "system", details: [String: Any] = [:]) {
    LoggingService.shared.logAudit(event, userId: userId, details: details)
}

public func logTool(_ toolName: String, operation: String, result: String, duration: TimeInterval? = nil, metadata: [String: Any] = [:]) {
    LoggingService.shared.logTool(toolName, operation: operation, result: result, duration: duration, metadata: metadata)
}

public func logOrchestrator(_ operation: String, requestId: String, success: Bool, duration: TimeInterval? = nil, metadata: [String: Any] = [:]) {
    LoggingService.shared.logOrchestrator(operation, requestId: requestId, success: success, duration: duration, metadata: metadata)
}