import Foundation

/// CLI-level safety enforcement to match assistant safety model
public class CLISafety {
    public static let shared = CLISafety()
    
    private init() {}
    
    /// Operations that require confirmation at CLI level
    private let mutatingOperations: Set<String> = [
        "ingest_full",
        "ingest_incremental", 
        "ingest_embeddings",
        "move_file",
        "delete_file",
        "create_reminder",
        "send_email",
        "create_calendar_event"
    ]
    
    /// Check if operation requires safety confirmation
    public func requiresConfirmation(_ operation: String) -> Bool {
        return mutatingOperations.contains(operation)
    }
    
    /// Generate operation hash for CLI commands (consistent with assistant)
    public func generateOperationHash(operation: String, parameters: [String: Any]) -> String {
        // Use same hash scheme as ToolRegistry and PlanManager
        let operationData = "\(operation):\(parameters.sorted(by: { $0.key < $1.key }))"
        return operationData.sha256()
    }
    
    /// Confirm operation with hash verification
    public func confirmOperation(
        operation: String,
        parameters: [String: Any],
        providedHash: String?
    ) throws {
        let expectedHash = generateOperationHash(operation: operation, parameters: parameters)
        
        if let hash = providedHash {
            guard hash == expectedHash else {
                throw CLISafetyError.hashMismatch(
                    operation: operation,
                    expected: expectedHash,
                    provided: hash
                )
            }
        } else if requiresConfirmation(operation) {
            throw CLISafetyError.confirmationRequired(
                operation: operation,
                expectedHash: expectedHash
            )
        }
    }
    
    /// Show confirmation prompt for CLI users
    public func showConfirmationPrompt(
        operation: String,
        parameters: [String: Any],
        dryRunResult: [String: Any]? = nil
    ) -> String {
        let hash = generateOperationHash(operation: operation, parameters: parameters)
        
        var prompt = """
        
        🔒 CONFIRMATION REQUIRED
        Operation: \(operation)
        Parameters: \(formatParameters(parameters))
        
        """
        
        if let result = dryRunResult {
            prompt += """
            Dry-run preview:
            \(formatDryRunResult(result))
            
            """
        }
        
        prompt += """
        To confirm this operation, re-run with:
        --operation-hash \(hash)
        
        This ensures you've reviewed the operation details.
        """
        
        return prompt
    }
    
    private func formatParameters(_ params: [String: Any]) -> String {
        return params.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
    }
    
    private func formatDryRunResult(_ result: [String: Any]) -> String {
        return result.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

public enum CLISafetyError: Error, LocalizedError {
    case confirmationRequired(operation: String, expectedHash: String)
    case hashMismatch(operation: String, expected: String, provided: String)
    
    public var errorDescription: String? {
        switch self {
        case .confirmationRequired(let operation, let hash):
            return "Operation '\(operation)' requires confirmation. Use --operation-hash \(hash)"
        case .hashMismatch(let operation, let expected, let provided):
            return "Hash mismatch for '\(operation)': expected \(expected), got \(provided)"
        }
    }
}