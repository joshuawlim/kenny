import Foundation
import os.log

/// Centralized manager for LLM warm-up state and coordination
/// Ensures efficient warm-up with no redundant calls
public actor LLMWarmUpManager {
    public static let shared = LLMWarmUpManager()
    
    private var isWarmUpInProgress = false
    private var warmUpCompleted = false
    private var warmUpTask: Task<Bool, Never>?
    private let logger = Logger(subsystem: "Kenny.LLMWarmUp", category: "WarmUpManager")
    
    private init() {}
    
    /// Check if LLM is already warmed up
    public var isWarmedUp: Bool {
        return warmUpCompleted
    }
    
    /// Warm up the LLM if not already warmed up or in progress
    /// Returns true if warm-up succeeded, false if it failed or was already done
    public func warmUpIfNeeded(llmService: LLMService, showProgress: Bool = true) async -> Bool {
        // If already warmed up, return immediately
        if warmUpCompleted {
            if showProgress {
                print("✅ LLM already warmed up")
            }
            return true
        }
        
        // If warm-up is in progress, wait for it
        if isWarmUpInProgress, let existingTask = warmUpTask {
            if showProgress {
                print("⏳ LLM warm-up already in progress, waiting...")
            }
            return await existingTask.value
        }
        
        // Start new warm-up with atomic operations
        isWarmUpInProgress = true
        let newTask = Task {
            await self.performWarmUp(llmService: llmService, showProgress: showProgress)
        }
        warmUpTask = newTask
        
        return await newTask.value
    }
    
    /// Force a warm-up regardless of current state (for CLI --warm-up-llm flag)
    public func forceWarmUp(llmService: LLMService, showProgress: Bool = true) async -> Bool {
        // Cancel any existing warm-up
        warmUpTask?.cancel()
        
        // Reset state atomically
        isWarmUpInProgress = true
        warmUpCompleted = false
        
        let newTask = Task {
            await self.performWarmUp(llmService: llmService, showProgress: showProgress, isForced: true)
        }
        warmUpTask = newTask
        
        return await newTask.value
    }
    
    private func performWarmUp(llmService: LLMService, showProgress: Bool, isForced: Bool = false) async -> Bool {
        let startTime = Date()
        
        if showProgress {
            if isForced {
                print("🔥 Force warming up LLM...")
            } else {
                print("🔥 Warming up LLM for better performance...")
            }
        }
        
        let success = await llmService.warmUp()
        
        // Update state atomically within the actor
        warmUpCompleted = success
        isWarmUpInProgress = false
        
        if success {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("LLM warm-up completed successfully in \(String(format: "%.1f", duration))s")
            
            if showProgress {
                print("✅ LLM ready for enhanced queries")
            }
        } else {
            logger.warning("LLM warm-up failed")
            
            if showProgress {
                print("⚠️ LLM warm-up failed - AI features may be slower")
            }
        }
        
        return success
    }
    
    /// Reset warm-up state (useful for testing or when model changes)
    public func reset() {
        warmUpTask?.cancel()
        warmUpTask = nil
        isWarmUpInProgress = false
        warmUpCompleted = false
        logger.info("LLM warm-up state reset")
    }
    
    /// Get current warm-up status for debugging
    public var status: WarmUpStatus {
        if warmUpCompleted {
            return .completed
        } else if isWarmUpInProgress {
            return .inProgress
        } else {
            return .notStarted
        }
    }
}

public enum WarmUpStatus: String {
    case notStarted = "not_started"
    case inProgress = "in_progress" 
    case completed = "completed"
    
    public var displayName: String {
        switch self {
        case .notStarted:
            return "Not Started"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        }
    }
}