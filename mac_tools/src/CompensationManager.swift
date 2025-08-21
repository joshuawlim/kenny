import Foundation
import os.log

/// Week 5: Rollback and compensation framework for failed operations
public class CompensationManager {
    public static let shared = CompensationManager()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "compensation")
    private let compensationQueue = DispatchQueue(label: "compensation", qos: .userInitiated)
    
    private var compensationHandlers: [String: CompensationHandler] = [:]
    
    private init() {
        registerDefaultHandlers()
    }
    
    // MARK: - Compensation Registration
    
    /// Register a compensation handler for a specific tool
    public func registerHandler(for toolName: String, handler: @escaping CompensationHandler) {
        compensationQueue.sync {
            compensationHandlers[toolName] = handler
        }
        os_log("Registered compensation handler for tool: %{public}s", log: logger, type: .info, toolName)
    }
    
    // MARK: - Rollback Execution
    
    /// Execute rollback for a failed plan
    public func executeRollback(
        for plan: ExecutionPlan,
        failedStepIndex: Int,
        toolRegistry: ToolRegistry
    ) async -> [CompensationResult] {
        os_log("Starting rollback for plan %{public}s, failed at step %{public}d", 
               log: logger, type: .info, plan.id, failedStepIndex)
        
        var results: [CompensationResult] = []
        
        // Execute rollback for completed steps in reverse order
        for stepIndex in (0..<failedStepIndex).reversed() {
            let step = plan.steps[stepIndex]
            let stepResult = plan.results.first { $0.stepIndex == stepIndex }
            
            do {
                let result = try await executeStepRollback(
                    step: step,
                    stepIndex: stepIndex,
                    originalResult: stepResult,
                    plan: plan,
                    toolRegistry: toolRegistry
                )
                results.append(result)
                
                // Log rollback step completion
                AuditLogger.shared.logRollbackEvent(
                    correlationId: plan.correlationId,
                    planId: plan.id,
                    rollbackStep: stepIndex,
                    rollbackStatus: result.success ? .success : .failed,
                    details: result.message,
                    error: result.error
                )
                
            } catch {
                let result = CompensationResult(
                    stepIndex: stepIndex,
                    toolName: step.toolName,
                    strategy: .failed,
                    success: false,
                    message: "Rollback execution failed: \(error.localizedDescription)",
                    compensationData: nil,
                    error: error
                )
                results.append(result)
                
                AuditLogger.shared.logRollbackEvent(
                    correlationId: plan.correlationId,
                    planId: plan.id,
                    rollbackStep: stepIndex,
                    rollbackStatus: .failed,
                    details: "Rollback failed: \(error.localizedDescription)",
                    error: error
                )
                
                os_log("Rollback failed for step %{public}d: %{public}s", 
                       log: logger, type: .error, stepIndex, error.localizedDescription)
            }
        }
        
        os_log("Rollback completed for plan %{public}s with %{public}d operations", 
               log: logger, type: .info, plan.id, results.count)
        
        return results
    }
    
    // MARK: - Step Rollback Execution
    
    private func executeStepRollback(
        step: PlanStep,
        stepIndex: Int,
        originalResult: PlanStepResult?,
        plan: ExecutionPlan,
        toolRegistry: ToolRegistry
    ) async throws -> CompensationResult {
        
        guard step.isMutating else {
            // Non-mutating operations don't need rollback
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .noActionNeeded,
                success: true,
                message: "Non-mutating operation, no rollback needed",
                compensationData: nil,
                error: nil
            )
        }
        
        // Get compensation handler for this tool
        let handler = compensationQueue.sync { compensationHandlers[step.toolName] }
        
        if let handler = handler {
            // Execute custom compensation logic
            return try await executeCustomCompensation(
                handler: handler,
                step: step,
                stepIndex: stepIndex,
                originalResult: originalResult,
                plan: plan,
                toolRegistry: toolRegistry
            )
        } else {
            // Use generic rollback strategies
            return try await executeGenericRollback(
                step: step,
                stepIndex: stepIndex,
                originalResult: originalResult,
                plan: plan,
                toolRegistry: toolRegistry
            )
        }
    }
    
    private func executeCustomCompensation(
        handler: CompensationHandler,
        step: PlanStep,
        stepIndex: Int,
        originalResult: PlanStepResult?,
        plan: ExecutionPlan,
        toolRegistry: ToolRegistry
    ) async throws -> CompensationResult {
        
        os_log("Executing custom compensation for %{public}s at step %{public}d", 
               log: logger, type: .info, step.toolName, stepIndex)
        
        let context = CompensationContext(
            step: step,
            stepIndex: stepIndex,
            originalResult: originalResult,
            plan: plan,
            correlationId: plan.correlationId
        )
        
        return try await handler(context, toolRegistry)
    }
    
    private func executeGenericRollback(
        step: PlanStep,
        stepIndex: Int,
        originalResult: PlanStepResult?,
        plan: ExecutionPlan,
        toolRegistry: ToolRegistry
    ) async throws -> CompensationResult {
        
        os_log("Executing generic rollback for %{public}s at step %{public}d", 
               log: logger, type: .info, step.toolName, stepIndex)
        
        // Determine rollback strategy based on tool type
        let strategy = determineRollbackStrategy(for: step.toolName, result: originalResult)
        
        switch strategy {
        case .inverseOperation:
            return try await executeInverseOperation(
                step: step,
                stepIndex: stepIndex,
                originalResult: originalResult,
                plan: plan,
                toolRegistry: toolRegistry
            )
            
        case .dataRestore:
            return try await executeDataRestore(
                step: step,
                stepIndex: stepIndex,
                originalResult: originalResult,
                plan: plan
            )
            
        case .manualIntervention:
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .manualIntervention,
                success: false,
                message: "Manual intervention required for rollback",
                compensationData: [
                    "instructions": generateManualRollbackInstructions(step: step, result: originalResult),
                    "original_arguments": step.arguments,
                    "original_result": originalResult?.result as Any
                ],
                error: nil
            )
            
        case .noActionNeeded:
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .noActionNeeded,
                success: true,
                message: "No rollback action needed",
                compensationData: nil,
                error: nil
            )
            
        case .failed:
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .failed,
                success: false,
                message: "Rollback strategy failed",
                compensationData: nil,
                error: CompensationError.strategyNotImplemented(.failed)
            )
        }
    }
    
    private func executeInverseOperation(
        step: PlanStep,
        stepIndex: Int,
        originalResult: PlanStepResult?,
        plan: ExecutionPlan,
        toolRegistry: ToolRegistry
    ) async throws -> CompensationResult {
        
        // Generate inverse operation arguments
        guard let inverseArgs = generateInverseArguments(for: step.toolName, step: step, result: originalResult) else {
            throw CompensationError.noInverseOperation(step.toolName)
        }
        
        let inverseTool = inverseArgs.toolName
        var args = inverseArgs.arguments
        
        // Add correlation metadata
        args["_correlation_id"] = plan.correlationId
        args["_plan_id"] = plan.id
        args["_step_index"] = "\(stepIndex)"
        args["_is_rollback"] = "true"
        
        os_log("Executing inverse operation: %{public}s", log: logger, type: .info, inverseTool)
        
        do {
            let result = try await toolRegistry.executeWithCorrelation(
                toolName: inverseTool,
                arguments: args,
                correlationId: plan.correlationId,
                planId: plan.id,
                stepIndex: stepIndex
            )
            
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .inverseOperation,
                success: true,
                message: "Successfully executed inverse operation: \(inverseTool)",
                compensationData: [
                    "inverse_tool": inverseTool,
                    "inverse_arguments": inverseArgs.arguments,
                    "inverse_result": result
                ],
                error: nil
            )
            
        } catch {
            return CompensationResult(
                stepIndex: stepIndex,
                toolName: step.toolName,
                strategy: .inverseOperation,
                success: false,
                message: "Inverse operation failed: \(error.localizedDescription)",
                compensationData: [
                    "inverse_tool": inverseTool,
                    "inverse_arguments": inverseArgs.arguments
                ],
                error: error
            )
        }
    }
    
    private func executeDataRestore(
        step: PlanStep,
        stepIndex: Int,
        originalResult: PlanStepResult?,
        plan: ExecutionPlan
    ) async throws -> CompensationResult {
        
        // For data restore, we would typically restore from backup
        // This is a placeholder implementation
        
        os_log("Data restore not yet implemented for %{public}s", log: logger, type: .error, step.toolName)
        
        return CompensationResult(
            stepIndex: stepIndex,
            toolName: step.toolName,
            strategy: .dataRestore,
            success: false,
            message: "Data restore strategy not yet implemented",
            compensationData: [
                "restore_instructions": "Manual data restoration required",
                "original_arguments": step.arguments
            ],
            error: CompensationError.strategyNotImplemented(.dataRestore)
        )
    }
    
    // MARK: - Strategy Determination
    
    private func determineRollbackStrategy(for toolName: String, result: PlanStepResult?) -> CompensationStrategy {
        // Determine the best rollback strategy based on tool type and result
        
        switch toolName {
        case "create_reminder":
            return .inverseOperation // Can delete the reminder
        case "send_email":
            return .manualIntervention // Can't unsend email
        case "create_event":
            return .inverseOperation // Can delete the event
        case "run_shortcut":
            return .manualIntervention // Depends on what the shortcut did
        case "update_event":
            return .dataRestore // Need to restore previous state
        default:
            // Generic strategies based on operation type
            if toolName.contains("create") {
                return .inverseOperation
            } else if toolName.contains("update") || toolName.contains("modify") {
                return .dataRestore
            } else if toolName.contains("delete") {
                return .dataRestore
            } else {
                return .manualIntervention
            }
        }
    }
    
    private func generateInverseArguments(for toolName: String, step: PlanStep, result: PlanStepResult?) -> InverseOperation? {
        switch toolName {
        case "create_reminder":
            // Delete the created reminder
            guard let result = result?.result,
                  let reminderId = result["id"] as? String else { return nil }
            return InverseOperation(
                toolName: "delete_reminder",
                arguments: ["id": reminderId]
            )
            
        case "create_event":
            // Delete the created event
            guard let result = result?.result,
                  let eventId = result["id"] as? String else { return nil }
            return InverseOperation(
                toolName: "delete_event",
                arguments: ["id": eventId]
            )
            
        default:
            return nil
        }
    }
    
    private func generateManualRollbackInstructions(step: PlanStep, result: PlanStepResult?) -> String {
        switch step.toolName {
        case "send_email":
            return "Email has been sent and cannot be automatically recalled. Consider sending a follow-up email if needed."
        case "run_shortcut":
            return "Shortcut '\(step.arguments["shortcut_name"] ?? "unknown")' was executed. Review the shortcut's actions and manually reverse any changes if necessary."
        default:
            return "Manual rollback required for \(step.toolName). Review the operation and its results to determine appropriate corrective actions."
        }
    }
    
    // MARK: - Default Handlers
    
    private func registerDefaultHandlers() {
        // Register compensation handlers for common tools
        
        registerHandler(for: "create_reminder") { context, toolRegistry in
            guard let result = context.originalResult?.result,
                  let reminderId = result["id"] as? String else {
                throw CompensationError.missingResultData("reminder_id")
            }
            
            var deleteArgs = ["id": reminderId]
            deleteArgs["_correlation_id"] = context.correlationId
            deleteArgs["_plan_id"] = context.plan.id
            deleteArgs["_step_index"] = "\(context.stepIndex)"
            deleteArgs["_is_rollback"] = "true"
            
            let deleteResult = try await toolRegistry.executeWithCorrelation(
                toolName: "delete_reminder",
                arguments: deleteArgs,
                correlationId: context.correlationId,
                planId: context.plan.id,
                stepIndex: context.stepIndex
            )
            
            return CompensationResult(
                stepIndex: context.stepIndex,
                toolName: context.step.toolName,
                strategy: .inverseOperation,
                success: true,
                message: "Successfully deleted reminder \(reminderId)",
                compensationData: ["deleted_reminder_id": reminderId, "delete_result": deleteResult],
                error: nil
            )
        }
        
        registerHandler(for: "send_email") { context, toolRegistry in
            // Email cannot be unsent, but we can log the attempt
            return CompensationResult(
                stepIndex: context.stepIndex,
                toolName: context.step.toolName,
                strategy: .manualIntervention,
                success: false,
                message: "Email sent - cannot be automatically recalled",
                compensationData: [
                    "sent_email": context.step.arguments,
                    "instructions": "Consider sending a follow-up email or contacting recipients directly if needed"
                ],
                error: nil
            )
        }
    }
}

// MARK: - Data Types

public struct CompensationContext {
    public let step: PlanStep
    public let stepIndex: Int
    public let originalResult: PlanStepResult?
    public let plan: ExecutionPlan
    public let correlationId: String
}

public struct CompensationResult {
    public let stepIndex: Int
    public let toolName: String
    public let strategy: CompensationStrategy
    public let success: Bool
    public let message: String
    public let compensationData: [String: Any]?
    public let error: Error?
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "step_index": stepIndex,
            "tool_name": toolName,
            "strategy": strategy.rawValue,
            "success": success,
            "message": message
        ]
        
        if let data = compensationData {
            dict["compensation_data"] = data
        }
        
        if let error = error {
            dict["error"] = error.localizedDescription
        }
        
        return dict
    }
}

public struct InverseOperation {
    public let toolName: String
    public let arguments: [String: Any]
}

public enum CompensationStrategy: String, Codable {
    case inverseOperation = "inverse_operation"
    case dataRestore = "data_restore"
    case manualIntervention = "manual_intervention"
    case noActionNeeded = "no_action_needed"
    case failed = "failed"
}

public enum CompensationError: Error, LocalizedError {
    case noInverseOperation(String)
    case missingResultData(String)
    case strategyNotImplemented(CompensationStrategy)
    case executionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noInverseOperation(let tool):
            return "No inverse operation defined for tool: \(tool)"
        case .missingResultData(let field):
            return "Missing required result data: \(field)"
        case .strategyNotImplemented(let strategy):
            return "Compensation strategy not implemented: \(strategy.rawValue)"
        case .executionFailed(let reason):
            return "Compensation execution failed: \(reason)"
        }
    }
}

// Compensation handler type alias
public typealias CompensationHandler = (CompensationContext, ToolRegistry) async throws -> CompensationResult