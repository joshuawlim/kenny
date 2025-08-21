import Foundation
import os.log

/// Week 5: Plan → Confirm → Execute workflow with rollback capabilities
public class PlanManager {
    public static let shared = PlanManager()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "plan_manager")
    private let planQueue = DispatchQueue(label: "plan_management", qos: .userInitiated)
    
    private var activePlans: [String: ExecutionPlan] = [:]
    private let planTTL: TimeInterval = 1800 // 30 minutes
    
    private init() {
        // Start periodic cleanup of expired plans
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupExpiredPlans()
        }
    }
    
    // MARK: - Plan Creation
    
    /// Create a new execution plan for a user query
    public func createPlan(for query: String, toolRegistry: ToolRegistry, llmService: LLMService) async throws -> ExecutionPlan {
        let planId = generatePlanId()
        let correlationId = generateCorrelationId()
        
        os_log("Creating plan %{public}s for query: %{public}s", log: logger, type: .info, planId, query)
        
        // Analyze query to determine required steps
        let steps = try await analyzePlanSteps(query: query, toolRegistry: toolRegistry, llmService: llmService, correlationId: correlationId)
        
        // Assess risks for each step
        let risks = assessPlanRisks(steps: steps)
        
        // Generate rollback steps
        let rollbackSteps = generateRollbackSteps(for: steps)
        
        // Determine content origin and trust level
        let contentOrigin = determineContentOrigin(query: query)
        
        let plan = ExecutionPlan(
            id: planId,
            correlationId: correlationId,
            query: query,
            steps: steps,
            risks: risks,
            rollbackSteps: rollbackSteps,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(planTTL),
            status: .pending,
            userConfirmed: false,
            contentOrigin: contentOrigin
        )
        
        // Store plan
        planQueue.sync {
            activePlans[planId] = plan
        }
        
        // Log plan creation
        await logPlanEvent(plan: plan, event: .created, details: "Plan created with \(steps.count) steps")
        
        PerformanceMonitor.shared.recordMetric(name: "plans.created", value: 1)
        
        return plan
    }
    
    // MARK: - Plan Confirmation
    
    /// Confirm a plan for execution
    public func confirmPlan(_ planId: String, userHash: String?) async throws -> ExecutionPlan {
        guard let plan = planQueue.sync(execute: { activePlans[planId] }) else {
            throw PlanError.planNotFound(planId)
        }
        
        guard !plan.isExpired else {
            throw PlanError.planExpired(planId)
        }
        
        guard plan.status == .pending else {
            throw PlanError.invalidPlanState(planId, current: plan.status, expected: .pending)
        }
        
        // Validate user hash if provided (for mutation confirmation)
        if let expectedHash = plan.operationHash, let providedHash = userHash {
            guard expectedHash == providedHash else {
                throw PlanError.hashMismatch(planId, expected: expectedHash, provided: providedHash)
            }
        }
        
        // Update plan status
        planQueue.sync {
            plan.userConfirmed = true
            plan.confirmedAt = Date()
            plan.status = .confirmed
        }
        
        os_log("Plan %{public}s confirmed by user", log: logger, type: .info, planId)
        
        // Log confirmation
        await logPlanEvent(plan: plan, event: .confirmed, details: "User confirmed execution")
        
        PerformanceMonitor.shared.recordMetric(name: "plans.confirmed", value: 1)
        
        return plan
    }
    
    // MARK: - Plan Execution
    
    /// Execute a confirmed plan
    public func executePlan(_ planId: String, toolRegistry: ToolRegistry) async throws -> PlanExecutionResult {
        guard let plan = planQueue.sync(execute: { activePlans[planId] }) else {
            throw PlanError.planNotFound(planId)
        }
        
        guard plan.userConfirmed else {
            throw PlanError.planNotConfirmed(planId)
        }
        
        guard plan.status == .confirmed else {
            throw PlanError.invalidPlanState(planId, current: plan.status, expected: .confirmed)
        }
        
        // Update plan status to executing
        planQueue.sync {
            plan.status = .executing
            plan.executionStartedAt = Date()
        }
        
        os_log("Executing plan %{public}s with %{public}d steps", log: logger, type: .info, planId, plan.steps.count)
        
        await logPlanEvent(plan: plan, event: .executionStarted, details: "Starting execution of \(plan.steps.count) steps")
        
        var results: [PlanStepResult] = []
        var failedStepIndex: Int?
        
        // Execute steps sequentially
        for (index, step) in plan.steps.enumerated() {
            do {
                os_log("Executing step %{public}d: %{public}s", log: logger, type: .info, index + 1, step.toolName)
                
                // Record step start
                planQueue.sync {
                    plan.currentStep = index
                }
                
                await logPlanEvent(plan: plan, event: .stepStarted, details: "Step \(index + 1): \(step.toolName)", stepIndex: index)
                
                // Execute step with correlation ID
                var stepArgs = step.arguments
                stepArgs["_correlation_id"] = plan.correlationId
                stepArgs["_plan_id"] = plan.id
                stepArgs["_step_index"] = index
                
                let result = try await toolRegistry.executeWithCorrelation(
                    toolName: step.toolName,
                    arguments: stepArgs,
                    correlationId: plan.correlationId,
                    planId: plan.id,
                    stepIndex: index
                )
                
                let stepResult = PlanStepResult(
                    stepIndex: index,
                    toolName: step.toolName,
                    arguments: step.arguments,
                    result: result,
                    success: true,
                    error: nil,
                    executedAt: Date()
                )
                
                results.append(stepResult)
                
                await logPlanEvent(plan: plan, event: .stepCompleted, details: "Step \(index + 1) completed successfully", stepIndex: index)
                
                PerformanceMonitor.shared.recordMetric(
                    name: "plan_steps.completed",
                    value: 1,
                    tags: ["tool_name": step.toolName]
                )
                
            } catch {
                // Step failed
                failedStepIndex = index
                
                let stepResult = PlanStepResult(
                    stepIndex: index,
                    toolName: step.toolName,
                    arguments: step.arguments,
                    result: nil,
                    success: false,
                    error: error,
                    executedAt: Date()
                )
                
                results.append(stepResult)
                
                os_log("Step %{public}d failed: %{public}s", log: logger, type: .error, index + 1, error.localizedDescription)
                
                await logPlanEvent(plan: plan, event: .stepFailed, details: "Step \(index + 1) failed: \(error.localizedDescription)", stepIndex: index)
                
                PerformanceMonitor.shared.recordMetric(
                    name: "plan_steps.failed",
                    value: 1,
                    tags: ["tool_name": step.toolName, "error_type": String(describing: type(of: error))]
                )
                
                break // Stop execution on first failure
            }
        }
        
        // Determine final status and handle rollback if needed
        let finalStatus: PlanStatus
        var rollbackResults: [PlanStepResult] = []
        
        if let failedIndex = failedStepIndex {
            finalStatus = .failed
            
            // Execute rollback for completed steps
            os_log("Plan %{public}s failed at step %{public}d, executing rollback", log: logger, type: .error, planId, failedIndex + 1)
            
            await logPlanEvent(plan: plan, event: .rollbackStarted, details: "Rolling back \(failedIndex) completed steps")
            
            rollbackResults = try await executeRollback(plan: plan, completedSteps: failedIndex, toolRegistry: toolRegistry)
            
        } else {
            finalStatus = .completed
        }
        
        // Update plan final status
        planQueue.sync {
            plan.status = finalStatus
            plan.executionCompletedAt = Date()
            plan.results = results
            plan.rollbackResults = rollbackResults
        }
        
        await logPlanEvent(plan: plan, event: .executionCompleted, details: "Plan execution \(finalStatus.rawValue)")
        
        PerformanceMonitor.shared.recordMetric(
            name: "plans.executed",
            value: 1,
            tags: ["status": finalStatus.rawValue]
        )
        
        return PlanExecutionResult(
            planId: plan.id,
            correlationId: plan.correlationId,
            success: finalStatus == .completed,
            results: results,
            rollbackResults: rollbackResults,
            totalSteps: plan.steps.count,
            completedSteps: results.filter { $0.success }.count,
            failedStepIndex: failedStepIndex
        )
    }
    
    // MARK: - Plan Management
    
    public func getPlan(_ planId: String) -> ExecutionPlan? {
        return planQueue.sync { activePlans[planId] }
    }
    
    public func getActivePlans() -> [ExecutionPlan] {
        return planQueue.sync { Array(activePlans.values) }
    }
    
    public func cancelPlan(_ planId: String) -> Bool {
        return planQueue.sync {
            guard let plan = activePlans[planId] else { return false }
            
            if plan.status == .pending || plan.status == .confirmed {
                plan.status = .cancelled
                os_log("Plan %{public}s cancelled", log: logger, type: .info, planId)
                return true
            }
            
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private func generatePlanId() -> String {
        return "plan_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }
    
    private func generateCorrelationId() -> String {
        return "corr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }
    
    private func analyzePlanSteps(query: String, toolRegistry: ToolRegistry, llmService: LLMService, correlationId: String) async throws -> [PlanStep] {
        // For now, create a simple single-step plan
        // In a full implementation, this would use LLM to break down complex queries
        
        let availableTools = toolRegistry.getAvailableTools()
        let isLLMAvailable = await llmService.checkAvailability()
        
        if isLLMAvailable {
            // Use LLM to create multi-step plan
            return try await createLLMPlan(query: query, availableTools: availableTools, llmService: llmService)
        } else {
            // Fallback to simple single-step plan
            return [createSimplePlanStep(query: query, availableTools: availableTools)]
        }
    }
    
    private func createLLMPlan(query: String, availableTools: [ToolDefinition], llmService: LLMService) async throws -> [PlanStep] {
        let context = """
        You are a task planner. Break down this user query into executable steps using available tools.
        
        Available tools:
        \(availableTools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"))
        
        User query: \(query)
        
        Respond with JSON array of steps:
        [
            {
                "tool_name": "tool_name",
                "arguments": {"param": "value"},
                "description": "What this step does",
                "is_mutating": false,
                "requires_confirmation": false
            }
        ]
        """
        
        let response = try await llmService.generateResponse(prompt: context)
        return try parsePlanSteps(response)
    }
    
    private func createSimplePlanStep(query: String, availableTools: [ToolDefinition]) -> PlanStep {
        let lowercaseQuery = query.lowercased()
        
        // Simple heuristics for tool selection
        if lowercaseQuery.contains("search") || lowercaseQuery.contains("find") {
            return PlanStep(
                toolName: "search_data",
                arguments: ["query": query, "limit": 10],
                description: "Search for information",
                isMutating: false,
                requiresConfirmation: false
            )
        } else if lowercaseQuery.contains("calendar") || lowercaseQuery.contains("event") {
            let today = ISO8601DateFormatter().string(from: Date())
            let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
            return PlanStep(
                toolName: "list_calendar",
                arguments: ["from": today, "to": tomorrow],
                description: "List calendar events",
                isMutating: false,
                requiresConfirmation: false
            )
        } else {
            return PlanStep(
                toolName: "search_data",
                arguments: ["query": query, "limit": 10],
                description: "Default search",
                isMutating: false,
                requiresConfirmation: false
            )
        }
    }
    
    private func parsePlanSteps(_ response: String) throws -> [PlanStep] {
        guard let data = response.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlanError.invalidLLMResponse(response)
        }
        
        return try json.map { stepDict in
            guard let toolName = stepDict["tool_name"] as? String,
                  let arguments = stepDict["arguments"] as? [String: Any],
                  let description = stepDict["description"] as? String else {
                throw PlanError.invalidStepFormat(stepDict)
            }
            
            let isMutating = stepDict["is_mutating"] as? Bool ?? false
            let requiresConfirmation = stepDict["requires_confirmation"] as? Bool ?? isMutating
            
            return PlanStep(
                toolName: toolName,
                arguments: arguments,
                description: description,
                isMutating: isMutating,
                requiresConfirmation: requiresConfirmation
            )
        }
    }
    
    private func assessPlanRisks(steps: [PlanStep]) -> [PlanRisk] {
        var risks: [PlanRisk] = []
        
        for (index, step) in steps.enumerated() {
            if step.isMutating {
                risks.append(PlanRisk(
                    stepIndex: index,
                    riskLevel: .high,
                    description: "Mutating operation: \(step.description)",
                    mitigation: "Dry run first, user confirmation required"
                ))
            }
            
            // Add other risk assessment logic
            if step.toolName.contains("delete") || step.toolName.contains("remove") {
                risks.append(PlanRisk(
                    stepIndex: index,
                    riskLevel: .critical,
                    description: "Destructive operation detected",
                    mitigation: "Backup recommended, explicit confirmation required"
                ))
            }
        }
        
        return risks
    }
    
    private func generateRollbackSteps(for steps: [PlanStep]) -> [RollbackStep] {
        // Generate rollback steps for mutating operations
        return steps.enumerated().compactMap { (index, step) in
            guard step.isMutating else { return nil }
            
            return RollbackStep(
                forStepIndex: index,
                description: "Rollback \(step.description)",
                strategy: .manual,
                instructions: "Manual rollback required for \(step.toolName)"
            )
        }
    }
    
    private func executeRollback(plan: ExecutionPlan, completedSteps: Int, toolRegistry: ToolRegistry) async throws -> [PlanStepResult] {
        // Use CompensationManager for proper rollback execution
        let compensationResults = await CompensationManager.shared.executeRollback(
            for: plan,
            failedStepIndex: completedSteps,
            toolRegistry: toolRegistry
        )
        
        // Convert CompensationResults to PlanStepResults
        return compensationResults.map { compensation in
            PlanStepResult(
                stepIndex: compensation.stepIndex,
                toolName: "rollback_\(compensation.toolName)",
                arguments: [:],
                result: compensation.compensationData ?? ["status": compensation.strategy.rawValue],
                success: compensation.success,
                error: compensation.error,
                executedAt: Date()
            )
        }
    }
    
    private func logPlanEvent(plan: ExecutionPlan, event: PlanEvent, details: String, stepIndex: Int? = nil) async {
        // Use unified audit logging system
        let auditEvent: AuditEvent
        switch event {
        case .created:
            auditEvent = .planCreated
        case .confirmed:
            auditEvent = .planConfirmed
        case .executionStarted:
            auditEvent = .planExecutionStarted
        case .stepStarted:
            auditEvent = .stepStarted
        case .stepCompleted:
            auditEvent = .stepCompleted
        case .stepFailed:
            auditEvent = .stepFailed
        case .rollbackStarted:
            auditEvent = .rollbackStarted
        case .rollbackStepCompleted:
            auditEvent = .rollbackExecuted
        case .executionCompleted:
            if plan.status == .completed {
                auditEvent = .planCompleted
            } else {
                auditEvent = .planFailed
            }
        }
        
        let riskLevel = plan.risks.isEmpty ? nil : 
            plan.risks.max(by: { $0.riskLevel.rawValue < $1.riskLevel.rawValue })?.riskLevel.rawValue
        
        AuditLogger.shared.logPlanEvent(
            correlationId: plan.correlationId,
            planId: plan.id,
            event: auditEvent,
            details: details,
            stepIndex: stepIndex,
            toolName: stepIndex.flatMap { plan.steps.indices.contains($0) ? plan.steps[$0].toolName : nil },
            riskLevel: riskLevel,
            contentOrigin: plan.contentOrigin.rawValue
        )
        
        os_log("Plan event: %{public}s - %{public}s", log: logger, type: .info, event.rawValue, details)
    }
    
    private func cleanupExpiredPlans() {
        planQueue.sync {
            let now = Date()
            let expiredPlanIds = activePlans.compactMap { (planId, plan) in
                plan.expiresAt < now ? planId : nil
            }
            
            for planId in expiredPlanIds {
                activePlans.removeValue(forKey: planId)
            }
            
            if !expiredPlanIds.isEmpty {
                os_log("Cleaned up %{public}d expired plans", log: logger, type: .info, expiredPlanIds.count)
            }
        }
    }
    
    // MARK: - Safety Policy
    
    private func determineContentOrigin(query: String) -> ContentOrigin {
        // Analyze query for suspicious patterns
        let suspiciousPatterns = [
            "delete all",
            "drop table",
            "rm -rf",
            "sudo",
            "chmod 777",
            "format",
            "kill -9"
        ]
        
        let lowercaseQuery = query.lowercased()
        
        // Check for suspicious content
        for pattern in suspiciousPatterns {
            if lowercaseQuery.contains(pattern) {
                return .untrusted
            }
        }
        
        // Check for external URLs or scripts
        if lowercaseQuery.contains("http://") || lowercaseQuery.contains("https://") {
            return .external
        }
        
        // For now, assume user origin for direct CLI input
        return .user
    }
}

// MARK: - Data Types

public class ExecutionPlan {
    public let id: String
    public let correlationId: String
    public let query: String
    public let steps: [PlanStep]
    public let risks: [PlanRisk]
    public let rollbackSteps: [RollbackStep]
    public let createdAt: Date
    public let expiresAt: Date
    public let contentOrigin: ContentOrigin
    
    public var status: PlanStatus = .pending
    public var userConfirmed: Bool = false
    public var confirmedAt: Date?
    public var executionStartedAt: Date?
    public var executionCompletedAt: Date?
    public var currentStep: Int?
    public var results: [PlanStepResult] = []
    public var rollbackResults: [PlanStepResult] = []
    
    public var operationHash: String? {
        // Generate hash for mutation confirmation using same scheme as CLISafety
        let mutatingSteps = steps.filter { $0.isMutating }
        guard !mutatingSteps.isEmpty else { return nil }
        
        // Use consistent format: each step as "toolName:sortedArgs", joined with "|"
        let stepHashes = mutatingSteps.map { step in
            // Sort arguments for deterministic hash
            let sortedArgs = step.arguments.sorted(by: { $0.key < $1.key })
            return "\(step.toolName):\(sortedArgs)"
        }
        
        let hashData = stepHashes.joined(separator: "|")
        return hashData.sha256()
    }
    
    public var isExpired: Bool {
        return Date() > expiresAt
    }
    
    init(id: String, correlationId: String, query: String, steps: [PlanStep], risks: [PlanRisk], rollbackSteps: [RollbackStep], createdAt: Date, expiresAt: Date, status: PlanStatus, userConfirmed: Bool, contentOrigin: ContentOrigin) {
        self.id = id
        self.correlationId = correlationId
        self.query = query
        self.steps = steps
        self.risks = risks
        self.rollbackSteps = rollbackSteps
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.userConfirmed = userConfirmed
        self.contentOrigin = contentOrigin
    }
    
    public func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "correlation_id": correlationId,
            "query": query,
            "steps": steps.map { $0.toDictionary() },
            "risks": risks.map { $0.toDictionary() },
            "status": status.rawValue,
            "user_confirmed": userConfirmed,
            "operation_hash": operationHash as Any,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
            "current_step": currentStep as Any,
            "content_origin": contentOrigin.rawValue
        ]
    }
}

public struct PlanStep {
    public let toolName: String
    public let arguments: [String: Any]
    public let description: String
    public let isMutating: Bool
    public let requiresConfirmation: Bool
    
    public func toDictionary() -> [String: Any] {
        return [
            "tool_name": toolName,
            "arguments": arguments,
            "description": description,
            "is_mutating": isMutating,
            "requires_confirmation": requiresConfirmation
        ]
    }
}

public struct PlanRisk {
    public let stepIndex: Int
    public let riskLevel: RiskLevel
    public let description: String
    public let mitigation: String
    
    public func toDictionary() -> [String: Any] {
        return [
            "step_index": stepIndex,
            "risk_level": riskLevel.rawValue,
            "description": description,
            "mitigation": mitigation
        ]
    }
}

public struct RollbackStep {
    public let forStepIndex: Int
    public let description: String
    public let strategy: RollbackStrategy
    public let instructions: String
}

public struct PlanStepResult {
    public let stepIndex: Int
    public let toolName: String
    public let arguments: [String: Any]
    public let result: [String: Any]?
    public let success: Bool
    public let error: Error?
    public let executedAt: Date
}

public struct PlanExecutionResult {
    public let planId: String
    public let correlationId: String
    public let success: Bool
    public let results: [PlanStepResult]
    public let rollbackResults: [PlanStepResult]
    public let totalSteps: Int
    public let completedSteps: Int
    public let failedStepIndex: Int?
    
    public func toDictionary() -> [String: Any] {
        return [
            "plan_id": planId,
            "correlation_id": correlationId,
            "success": success,
            "total_steps": totalSteps,
            "completed_steps": completedSteps,
            "failed_step_index": failedStepIndex as Any,
            "rollback_executed": !rollbackResults.isEmpty
        ]
    }
}

// MARK: - Enums

public enum PlanStatus: String, Codable {
    case pending
    case confirmed
    case executing
    case completed
    case failed
    case cancelled
}

public enum RiskLevel: String, Codable {
    case low
    case medium
    case high
    case critical
}

public enum RollbackStrategy: String, Codable {
    case automatic
    case manual
    case compensating
}

public enum ContentOrigin: String, Codable {
    case user
    case system
    case external
    case untrusted
}

public enum PlanEvent: String {
    case created
    case confirmed
    case executionStarted
    case stepStarted
    case stepCompleted
    case stepFailed
    case rollbackStarted
    case rollbackStepCompleted
    case executionCompleted
}

// MARK: - Errors

public enum PlanError: Error, LocalizedError {
    case planNotFound(String)
    case planExpired(String)
    case planNotConfirmed(String)
    case invalidPlanState(String, current: PlanStatus, expected: PlanStatus)
    case hashMismatch(String, expected: String, provided: String)
    case invalidLLMResponse(String)
    case invalidStepFormat([String: Any])
    
    public var errorDescription: String? {
        switch self {
        case .planNotFound(let id):
            return "Plan not found: \(id)"
        case .planExpired(let id):
            return "Plan expired: \(id)"
        case .planNotConfirmed(let id):
            return "Plan not confirmed: \(id)"
        case .invalidPlanState(let id, let current, let expected):
            return "Invalid plan state for \(id): expected \(expected), got \(current)"
        case .hashMismatch(let id, let expected, let provided):
            return "Hash mismatch for plan \(id): expected \(expected), got \(provided)"
        case .invalidLLMResponse(let response):
            return "Invalid LLM response: \(response)"
        case .invalidStepFormat(let dict):
            return "Invalid step format: \(dict)"
        }
    }
}