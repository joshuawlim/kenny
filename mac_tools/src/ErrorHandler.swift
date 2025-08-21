import Foundation
import os.log

/// Week 5: Comprehensive error handling and recovery system
public class ErrorHandler {
    public static let shared = ErrorHandler()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "error_handling")
    private var circuitBreakers: [String: CircuitBreaker] = [:]
    private var retryPolicies: [String: RetryPolicy] = [:]
    private let errorQueue = DispatchQueue(label: "error_handling", qos: .utility)
    
    private init() {
        setupDefaultPolicies()
    }
    
    // MARK: - Error Handling with Retry
    
    public func executeWithRetry<T>(
        operation: String,
        policy: RetryPolicy? = nil,
        block: () async throws -> T
    ) async throws -> T {
        let retryPolicy = policy ?? retryPolicies[operation] ?? RetryPolicy.default
        var lastError: Error?
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let result = try await block()
                
                // Reset circuit breaker on success
                circuitBreakers[operation]?.recordSuccess()
                
                if attempt > 1 {
                    PerformanceMonitor.shared.recordMetric(
                        name: "error_recovery.success",
                        value: 1,
                        tags: ["operation": operation, "attempt": "\(attempt)"]
                    )
                }
                
                return result
                
            } catch {
                lastError = error
                
                // Record failure metrics
                PerformanceMonitor.shared.recordMetric(
                    name: "error_handling.failure",
                    value: 1,
                    tags: ["operation": operation, "attempt": "\(attempt)", "error_type": String(describing: type(of: error))]
                )
                
                // Check if we should retry
                if attempt < retryPolicy.maxAttempts && retryPolicy.shouldRetry(error) {
                    let delay = retryPolicy.calculateDelay(for: attempt)
                    
                    os_log("Retrying operation %{public}s after %{public}f seconds (attempt %{public}d/%{public}d): %{public}s",
                           log: logger, type: .info, operation, delay, attempt, retryPolicy.maxAttempts, error.localizedDescription)
                    
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    // Final failure - record circuit breaker failure
                    circuitBreakers[operation]?.recordFailure()
                    break
                }
            }
        }
        
        // All retries exhausted
        let finalError = RetryError.maxAttemptsExceeded(
            operation: operation,
            attempts: retryPolicy.maxAttempts,
            lastError: lastError
        )
        
        os_log("Operation %{public}s failed after %{public}d attempts: %{public}s",
               log: logger, type: .error, operation, retryPolicy.maxAttempts, lastError?.localizedDescription ?? "unknown")
        
        throw finalError
    }
    
    // MARK: - Circuit Breaker Integration
    
    public func executeWithCircuitBreaker<T>(
        operation: String,
        fallback: (() async throws -> T)? = nil,
        block: () async throws -> T
    ) async throws -> T {
        let circuitBreaker = getCircuitBreaker(for: operation)
        
        // Check circuit breaker state
        switch circuitBreaker.state {
        case .open:
            PerformanceMonitor.shared.recordMetric(
                name: "circuit_breaker.open",
                value: 1,
                tags: ["operation": operation]
            )
            
            if let fallback = fallback {
                os_log("Circuit breaker open for %{public}s, using fallback", log: logger, type: .info, operation)
                return try await fallback()
            } else {
                throw CircuitBreakerError.circuitOpen(operation: operation)
            }
            
        case .halfOpen:
            // Allow one request through to test
            os_log("Circuit breaker half-open for %{public}s, testing", log: logger, type: .info, operation)
            
        case .closed:
            // Normal operation
            break
        }
        
        // Execute with circuit breaker tracking
        do {
            let result = try await block()
            circuitBreaker.recordSuccess()
            return result
        } catch {
            circuitBreaker.recordFailure()
            
            // If circuit just opened and we have a fallback, use it
            if circuitBreaker.state == .open, let fallback = fallback {
                os_log("Circuit breaker opened, using fallback for %{public}s", log: logger, type: .default, operation)
                return try await fallback()
            }
            
            throw error
        }
    }
    
    // MARK: - Error Classification and Recovery
    
    public func classifyError(_ error: Error) -> ErrorCategory {
        switch error {
        case is ValidationError:
            return .validation
        case is NetworkError:
            return .network
        case is DatabaseError:
            return .database
        case is ErrorHandlerLLMError:
            return .llm
        case is PermissionError:
            return .permission
        case is ConfigurationError:
            return .configuration
        default:
            return .unknown
        }
    }
    
    public func suggestRecoveryAction(_ error: Error) -> RecoveryAction {
        let category = classifyError(error)
        
        switch category {
        case .validation:
            return .userAction("Please check your input parameters")
        case .network:
            return .retry("Network issue - will retry automatically")
        case .database:
            return .escalate("Database error - please contact support")
        case .llm:
            return .fallback("LLM unavailable - using fallback processing")
        case .permission:
            return .userAction("Please grant the required permissions in System Settings")
        case .configuration:
            return .escalate("Configuration error - please check environment variables")
        case .unknown:
            return .escalate("Unknown error - please contact support")
        }
    }
    
    // MARK: - Setup and Configuration
    
    private func setupDefaultPolicies() {
        // Network operations - aggressive retry
        retryPolicies["network"] = RetryPolicy(
            maxAttempts: 5,
            baseDelay: 1.0,
            maxDelay: 30.0,
            backoffMultiplier: 2.0,
            retryableErrors: [NetworkError.self]
        )
        
        // LLM operations - moderate retry
        retryPolicies["llm"] = RetryPolicy(
            maxAttempts: 3,
            baseDelay: 2.0,
            maxDelay: 15.0,
            backoffMultiplier: 1.5,
            retryableErrors: [ErrorHandlerLLMError.self]
        )
        
        // Database operations - conservative retry
        retryPolicies["database"] = RetryPolicy(
            maxAttempts: 2,
            baseDelay: 0.5,
            maxDelay: 5.0,
            backoffMultiplier: 2.0,
            retryableErrors: [DatabaseError.self]
        )
    }
    
    private func getCircuitBreaker(for operation: String) -> CircuitBreaker {
        if let existing = circuitBreakers[operation] {
            return existing
        }
        
        let circuitBreaker = CircuitBreaker(
            failureThreshold: 5,
            recoveryTimeout: 60.0,
            successThreshold: 3
        )
        
        circuitBreakers[operation] = circuitBreaker
        return circuitBreaker
    }
}

// MARK: - Circuit Breaker

public class CircuitBreaker {
    public enum State {
        case closed
        case open
        case halfOpen
    }
    
    private let failureThreshold: Int
    private let recoveryTimeout: TimeInterval
    private let successThreshold: Int
    
    private var failureCount = 0
    private var successCount = 0
    private var lastFailureTime: Date?
    private var currentState: State = .closed
    
    public var state: State {
        if currentState == .open, let lastFailure = lastFailureTime,
           Date().timeIntervalSince(lastFailure) >= recoveryTimeout {
            currentState = .halfOpen
            successCount = 0
        }
        return currentState
    }
    
    public init(failureThreshold: Int, recoveryTimeout: TimeInterval, successThreshold: Int) {
        self.failureThreshold = failureThreshold
        self.recoveryTimeout = recoveryTimeout
        self.successThreshold = successThreshold
    }
    
    public func recordSuccess() {
        switch currentState {
        case .closed:
            failureCount = 0
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
                currentState = .closed
                failureCount = 0
                successCount = 0
            }
        case .open:
            break // Should not happen
        }
    }
    
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        if failureCount >= failureThreshold {
            currentState = .open
        }
    }
}

// MARK: - Retry Policy

public struct RetryPolicy {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let backoffMultiplier: Double
    public let retryableErrors: [Error.Type]
    
    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 10.0,
        backoffMultiplier: 2.0,
        retryableErrors: []
    )
    
    public func shouldRetry(_ error: Error) -> Bool {
        return retryableErrors.isEmpty || retryableErrors.contains { $0 == type(of: error) }
    }
    
    public func calculateDelay(for attempt: Int) -> TimeInterval {
        let delay = baseDelay * pow(backoffMultiplier, Double(attempt - 1))
        return min(delay, maxDelay)
    }
}

// MARK: - Error Types and Categories

public enum ErrorCategory {
    case validation
    case network
    case database
    case llm
    case permission
    case configuration
    case unknown
}

public enum RecoveryAction {
    case retry(String)
    case fallback(String)
    case userAction(String)
    case escalate(String)
}

public enum RetryError: Error, LocalizedError {
    case maxAttemptsExceeded(operation: String, attempts: Int, lastError: Error?)
    
    public var errorDescription: String? {
        switch self {
        case .maxAttemptsExceeded(let operation, let attempts, let lastError):
            return "Operation '\(operation)' failed after \(attempts) attempts. Last error: \(lastError?.localizedDescription ?? "unknown")"
        }
    }
}

public enum CircuitBreakerError: Error, LocalizedError {
    case circuitOpen(operation: String)
    
    public var errorDescription: String? {
        switch self {
        case .circuitOpen(let operation):
            return "Circuit breaker is open for operation '\(operation)'"
        }
    }
}

// MARK: - Error Type Definitions

public enum NetworkError: Error {
    case connectionFailed
    case timeout
    case invalidResponse
}

public enum DatabaseError: Error {
    case connectionLost
    case timeout
    case constraintViolation
}

public enum ErrorHandlerLLMError: Error {
    case timeout
    case serviceUnavailable
    case invalidResponse
}

public enum PermissionError: Error {
    case accessDenied
    case insufficientPrivileges
}

public enum ConfigurationError: Error {
    case missingEnvironmentVariable
    case invalidConfiguration
}