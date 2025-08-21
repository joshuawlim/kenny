import Foundation
import os.log

/// Week 5: Unified audit logging system with correlation tracking
public class AuditLogger {
    public static let shared = AuditLogger()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "audit")
    private let auditQueue = DispatchQueue(label: "audit_logging", qos: .utility)
    
    private let auditLogPath: String
    private let orchestratorLogPath: String
    private let toolsLogPath: String
    
    private init() {
        // Setup audit log paths
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("Assistant")
        
        // Create logs directory if needed
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        self.auditLogPath = logsDir.appendingPathComponent("audit.ndjson").path
        self.orchestratorLogPath = logsDir.appendingPathComponent("orchestrator.ndjson").path
        self.toolsLogPath = logsDir.appendingPathComponent("tools.ndjson").path
        
        os_log("Audit logger initialized, logs at: %{public}s", log: logger, type: .info, logsDir.path)
    }
    
    // MARK: - Plan Audit Events
    
    public func logPlanEvent(
        correlationId: String,
        planId: String,
        event: AuditEvent,
        details: String,
        stepIndex: Int? = nil,
        toolName: String? = nil,
        riskLevel: String? = nil,
        contentOrigin: String = "user",
        metadata: [String: Any] = [:]
    ) {
        let entry = AuditEntry(
            timestamp: Date(),
            correlationId: correlationId,
            planId: planId,
            event: event.rawValue,
            details: details,
            stepIndex: stepIndex,
            toolName: toolName,
            riskLevel: riskLevel,
            contentOrigin: contentOrigin,
            userConfirmTimestamp: nil,
            rollbackStatus: nil,
            metadata: metadata
        )
        
        writeAuditEntry(entry, to: .audit)
    }
    
    // MARK: - Tool Execution Events
    
    public func logToolExecution(
        correlationId: String,
        planId: String,
        stepIndex: Int,
        toolName: String,
        arguments: [String: Any],
        isDryRun: Bool,
        result: [String: Any]?,
        error: Error?,
        duration: TimeInterval,
        operationHash: String? = nil
    ) {
        let metadata: [String: Any] = [
            "arguments": arguments,
            "is_dry_run": isDryRun,
            "duration_ms": duration * 1000,
            "operation_hash": operationHash as Any,
            "success": error == nil,
            "error_type": error.map { String(describing: type(of: $0)) } as Any,
            "result_keys": result?.keys.sorted() as Any
        ]
        
        let event: AuditEvent = isDryRun ? .toolDryRun : .toolExecution
        let details = "\(toolName) \(isDryRun ? "dry-run" : "execution") \(error == nil ? "succeeded" : "failed")"
        
        let entry = AuditEntry(
            timestamp: Date(),
            correlationId: correlationId,
            planId: planId,
            event: event.rawValue,
            details: details,
            stepIndex: stepIndex,
            toolName: toolName,
            riskLevel: nil,
            contentOrigin: "system",
            userConfirmTimestamp: nil,
            rollbackStatus: nil,
            metadata: metadata
        )
        
        writeAuditEntry(entry, to: .tools)
    }
    
    // MARK: - User Confirmation Events
    
    public func logUserConfirmation(
        correlationId: String,
        planId: String,
        operationHash: String,
        confirmed: Bool,
        userProvidedHash: String?
    ) {
        let metadata: [String: Any] = [
            "operation_hash": operationHash,
            "user_provided_hash": userProvidedHash as Any,
            "hash_match": userProvidedHash == operationHash
        ]
        
        let event: AuditEvent = confirmed ? .userConfirmed : .userRejected
        let details = "User \(confirmed ? "confirmed" : "rejected") plan execution"
        
        let entry = AuditEntry(
            timestamp: Date(),
            correlationId: correlationId,
            planId: planId,
            event: event.rawValue,
            details: details,
            stepIndex: nil,
            toolName: nil,
            riskLevel: nil,
            contentOrigin: "user",
            userConfirmTimestamp: Date(),
            rollbackStatus: nil,
            metadata: metadata
        )
        
        writeAuditEntry(entry, to: .audit)
    }
    
    // MARK: - Rollback Events
    
    public func logRollbackEvent(
        correlationId: String,
        planId: String,
        rollbackStep: Int,
        rollbackStatus: RollbackStatus,
        details: String,
        error: Error? = nil
    ) {
        let metadata: [String: Any] = [
            "rollback_step": rollbackStep,
            "error": error?.localizedDescription as Any
        ]
        
        let entry = AuditEntry(
            timestamp: Date(),
            correlationId: correlationId,
            planId: planId,
            event: AuditEvent.rollbackExecuted.rawValue,
            details: details,
            stepIndex: rollbackStep,
            toolName: "rollback",
            riskLevel: "high",
            contentOrigin: "system",
            userConfirmTimestamp: nil,
            rollbackStatus: rollbackStatus.rawValue,
            metadata: metadata
        )
        
        writeAuditEntry(entry, to: .audit)
    }
    
    // MARK: - Orchestrator Events
    
    public func logOrchestratorEvent(
        correlationId: String,
        operation: String,
        status: String,
        details: String,
        metadata: [String: Any] = [:]
    ) {
        let entry = OrchestratorEntry(
            timestamp: Date(),
            correlationId: correlationId,
            operation: operation,
            status: status,
            details: details,
            metadata: metadata
        )
        
        writeOrchestratorEntry(entry)
    }
    
    // MARK: - Query Methods
    
    public func getAuditTrail(correlationId: String) -> [AuditEntry] {
        return readAuditEntries(from: .audit)
            .filter { $0.correlationId == correlationId }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    public func getPlanAuditTrail(planId: String) -> [AuditEntry] {
        return readAuditEntries(from: .audit)
            .filter { $0.planId == planId }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    public func getToolExecutionHistory(toolName: String, limit: Int = 100) -> [AuditEntry] {
        return readAuditEntries(from: .tools)
            .filter { $0.toolName == toolName }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Statistics
    
    public func getAuditStatistics(since: Date) -> AuditStatistics {
        let auditEntries = readAuditEntries(from: .audit).filter { $0.timestamp >= since }
        let toolEntries = readAuditEntries(from: .tools).filter { $0.timestamp >= since }
        
        let totalPlans = Set(auditEntries.map { $0.planId }).count
        let completedPlans = auditEntries.filter { $0.event == "plan_completed" }.count
        let failedPlans = auditEntries.filter { $0.event == "plan_failed" }.count
        let totalTools = toolEntries.count
        let dryRunTools = toolEntries.filter { $0.event == "tool_dry_run" }.count
        let rollbacks = auditEntries.filter { $0.event == "rollback_executed" }.count
        
        return AuditStatistics(
            totalPlans: totalPlans,
            completedPlans: completedPlans,
            failedPlans: failedPlans,
            totalToolExecutions: totalTools,
            dryRunExecutions: dryRunTools,
            rollbacksExecuted: rollbacks,
            periodStart: since,
            periodEnd: Date()
        )
    }
    
    // MARK: - Private Methods
    
    private func writeAuditEntry(_ entry: AuditEntry, to logType: LogType) {
        auditQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let jsonData = try JSONEncoder().encode(entry)
                let jsonString = String(data: jsonData, encoding: .utf8)! + "\n"
                
                let path = self.getLogPath(for: logType)
                
                if FileManager.default.fileExists(atPath: path) {
                    let fileHandle = FileHandle(forWritingAtPath: path)
                    fileHandle?.seekToEndOfFile()
                    fileHandle?.write(jsonString.data(using: .utf8)!)
                    fileHandle?.closeFile()
                } else {
                    try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
                }
                
                os_log("Audit entry written: %{public}s", log: self.logger, type: .debug, entry.event)
                
            } catch {
                os_log("Failed to write audit entry: %{public}s", log: self.logger, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func writeOrchestratorEntry(_ entry: OrchestratorEntry) {
        auditQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let jsonData = try JSONEncoder().encode(entry)
                let jsonString = String(data: jsonData, encoding: .utf8)! + "\n"
                
                if FileManager.default.fileExists(atPath: self.orchestratorLogPath) {
                    let fileHandle = FileHandle(forWritingAtPath: self.orchestratorLogPath)
                    fileHandle?.seekToEndOfFile()
                    fileHandle?.write(jsonString.data(using: .utf8)!)
                    fileHandle?.closeFile()
                } else {
                    try jsonString.write(toFile: self.orchestratorLogPath, atomically: true, encoding: .utf8)
                }
                
                os_log("Orchestrator entry written: %{public}s", log: self.logger, type: .debug, entry.operation)
                
            } catch {
                os_log("Failed to write orchestrator entry: %{public}s", log: self.logger, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func readAuditEntries(from logType: LogType) -> [AuditEntry] {
        let path = getLogPath(for: logType)
        
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path) else {
            return []
        }
        
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AuditEntry.self, from: data)
        }
    }
    
    private func getLogPath(for logType: LogType) -> String {
        switch logType {
        case .audit:
            return auditLogPath
        case .tools:
            return toolsLogPath
        case .orchestrator:
            return orchestratorLogPath
        }
    }
}

// MARK: - Data Types

public struct AuditEntry: Codable {
    public let timestamp: Date
    public let correlationId: String
    public let planId: String
    public let event: String
    public let details: String
    public let stepIndex: Int?
    public let toolName: String?
    public let riskLevel: String?
    public let contentOrigin: String
    public let userConfirmTimestamp: Date?
    public let rollbackStatus: String?
    public let metadata: [String: AnyCodable]
    
    init(timestamp: Date, correlationId: String, planId: String, event: String, details: String, stepIndex: Int?, toolName: String?, riskLevel: String?, contentOrigin: String, userConfirmTimestamp: Date?, rollbackStatus: String?, metadata: [String: Any]) {
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.planId = planId
        self.event = event
        self.details = details
        self.stepIndex = stepIndex
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.contentOrigin = contentOrigin
        self.userConfirmTimestamp = userConfirmTimestamp
        self.rollbackStatus = rollbackStatus
        self.metadata = metadata.mapValues { AnyCodable($0) }
    }
}

public struct OrchestratorEntry: Codable {
    public let timestamp: Date
    public let correlationId: String
    public let operation: String
    public let status: String
    public let details: String
    public let metadata: [String: AnyCodable]
    
    init(timestamp: Date, correlationId: String, operation: String, status: String, details: String, metadata: [String: Any]) {
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.operation = operation
        self.status = status
        self.details = details
        self.metadata = metadata.mapValues { AnyCodable($0) }
    }
}

public struct AuditStatistics: Codable {
    public let totalPlans: Int
    public let completedPlans: Int
    public let failedPlans: Int
    public let totalToolExecutions: Int
    public let dryRunExecutions: Int
    public let rollbacksExecuted: Int
    public let periodStart: Date
    public let periodEnd: Date
    
    public var successRate: Double {
        guard totalPlans > 0 else { return 0.0 }
        return Double(completedPlans) / Double(totalPlans)
    }
    
    public var dryRunRate: Double {
        guard totalToolExecutions > 0 else { return 0.0 }
        return Double(dryRunExecutions) / Double(totalToolExecutions)
    }
}

public enum AuditEvent: String, Codable {
    case planCreated = "plan_created"
    case planConfirmed = "plan_confirmed"
    case planExecutionStarted = "plan_execution_started"
    case stepStarted = "step_started"
    case stepCompleted = "step_completed"
    case stepFailed = "step_failed"
    case planCompleted = "plan_completed"
    case planFailed = "plan_failed"
    case userConfirmed = "user_confirmed"
    case userRejected = "user_rejected"
    case rollbackStarted = "rollback_started"
    case rollbackExecuted = "rollback_executed"
    case toolExecution = "tool_execution"
    case toolDryRun = "tool_dry_run"
}

public enum RollbackStatus: String, Codable {
    case success = "success"
    case failed = "failed"
    case partial = "partial"
    case skipped = "skipped"
}

public enum LogType {
    case audit
    case tools
    case orchestrator
}

// Helper type for encoding arbitrary values
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = "unknown"
        }
    }
}