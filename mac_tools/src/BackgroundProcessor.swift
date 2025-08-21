import Foundation
import os.log

/// Week 5: Background processing and job queue system
public class BackgroundProcessor {
    public static let shared = BackgroundProcessor()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "background_processor")
    private let jobQueue = DispatchQueue(label: "background_jobs", qos: .utility, attributes: .concurrent)
    private let serialQueue = DispatchQueue(label: "job_management")
    
    private var activeJobs: [String: AnyBackgroundJob] = [:]
    private var jobHistory: [JobHistoryEntry] = []
    private let maxHistorySize = 1000
    
    private init() {
        // Start periodic cleanup of completed jobs
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupCompletedJobs()
        }
    }
    
    // MARK: - Job Submission
    
    /// Submit a job for background processing
    public func submitJob<T>(_ job: BackgroundJob<T>) -> String {
        let jobId = job.id
        
        serialQueue.sync {
            activeJobs[jobId] = job
            PerformanceMonitor.shared.recordMetric(name: "background_jobs.submitted", value: 1)
        }
        
        os_log("Submitted job %{public}s: %{public}s", log: logger, type: .info, jobId, job.name)
        
        // Execute job asynchronously
        jobQueue.async { [weak self] in
            self?.executeJobAny(job)
        }
        
        return jobId
    }
    
    /// Submit a simple async closure as a background job
    public func submitTask<T>(
        name: String,
        priority: JobPriority = .normal,
        retryPolicy: JobRetryPolicy = .default,
        task: @escaping () async throws -> T
    ) -> String {
        let job = BackgroundJob(
            name: name,
            priority: priority,
            retryPolicy: retryPolicy,
            task: task
        )
        return submitJob(job)
    }
    
    // MARK: - Job Management
    
    public func getJobStatus(_ jobId: String) -> JobStatus? {
        return serialQueue.sync {
            return activeJobs[jobId]?.status
        }
    }
    
    public func cancelJob(_ jobId: String) -> Bool {
        return serialQueue.sync {
            guard let job = activeJobs[jobId] else { return false }
            
            if job.status == .running {
                job.cancel()
                os_log("Cancelled job %{public}s", log: logger, type: .info, jobId)
                return true
            }
            
            return false
        }
    }
    
    public func getActiveJobs() -> [JobInfo] {
        return serialQueue.sync {
            return activeJobs.values.map { job in
                JobInfo(
                    id: job.id,
                    name: job.name,
                    status: job.status,
                    priority: job.priority,
                    submittedAt: job.submittedAt,
                    startedAt: job.startedAt,
                    completedAt: job.completedAt,
                    attempt: job.currentAttempt,
                    maxAttempts: job.retryPolicy.maxAttempts
                )
            }
        }
    }
    
    public func getJobHistory(limit: Int = 100) -> [JobHistoryEntry] {
        return serialQueue.sync {
            return Array(jobHistory.prefix(limit))
        }
    }
    
    // MARK: - Job Execution
    
    private func executeJobAny(_ job: AnyBackgroundJob) {
        let startTime = Date()
        
        // Update job status to running
        serialQueue.sync {
            job.status = .running
            job.startedAt = startTime
        }
        
        os_log("Starting job %{public}s (attempt %{public}d/%{public}d)", 
               log: logger, type: .info, job.id, job.currentAttempt + 1, job.retryPolicy.maxAttempts)
        
        Task {
            do {
                // Execute the job task
                let result = try await job.executeAny()
                
                // Job completed successfully
                let duration = Date().timeIntervalSince(startTime)
                serialQueue.sync {
                    job.status = .completed
                    job.completedAt = Date()
                }
                
                os_log("Job %{public}s completed successfully in %{public}f seconds", 
                       log: logger, type: .info, job.id, duration)
                
                PerformanceMonitor.shared.recordMetric(
                    name: "background_jobs.completed",
                    value: 1,
                    tags: ["job_name": job.name]
                )
                
                PerformanceMonitor.shared.recordMetric(
                    name: "background_jobs.duration",
                    value: duration * 1000,
                    tags: ["job_name": job.name]
                )
                
                addToHistoryAny(job: job, success: true, error: nil)
                
            } catch {
                // Job failed - handle retry logic
                handleJobFailureAny(job, error: error, startTime: startTime)
            }
        }
    }
    
    private func handleJobFailureAny(_ job: AnyBackgroundJob, error: Error, startTime: Date) {
        job.currentAttempt += 1
        
        os_log("Job %{public}s failed (attempt %{public}d/%{public}d): %{public}s",
               log: logger, type: .error, job.id, job.currentAttempt, job.retryPolicy.maxAttempts, error.localizedDescription)
        
        PerformanceMonitor.shared.recordMetric(
            name: "background_jobs.failed",
            value: 1,
            tags: ["job_name": job.name, "attempt": "\(job.currentAttempt)"]
        )
        
        // Check if we should retry
        if job.currentAttempt < job.retryPolicy.maxAttempts && job.retryPolicy.shouldRetry(error) {
            let delay = job.retryPolicy.calculateDelay(for: job.currentAttempt)
            
            os_log("Retrying job %{public}s in %{public}f seconds", 
                   log: logger, type: .info, job.id, delay)
            
            serialQueue.sync {
                job.status = .pending
            }
            
            // Schedule retry
            jobQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.executeJobAny(job)
            }
            
        } else {
            // Max retries exceeded or non-retryable error
            serialQueue.sync {
                job.status = .failed
                job.completedAt = Date()
                job.error = error
            }
            
            os_log("Job %{public}s permanently failed after %{public}d attempts",
                   log: logger, type: .error, job.id, job.currentAttempt)
            
            PerformanceMonitor.shared.recordMetric(
                name: "background_jobs.permanently_failed",
                value: 1,
                tags: ["job_name": job.name]
            )
            
            addToHistoryAny(job: job, success: false, error: error)
        }
    }
    
    // MARK: - Cleanup and History
    
    private func cleanupCompletedJobs() {
        serialQueue.sync {
            let cutoffTime = Date().addingTimeInterval(-3600) // Remove jobs older than 1 hour
            
            let jobsToRemove = activeJobs.compactMap { (jobId, job) -> String? in
                let isCompleted = job.status == .completed || job.status == .failed
                let isOld = (job.completedAt ?? Date.distantPast) < cutoffTime
                return (isCompleted && isOld) ? jobId : nil
            }
            
            for jobId in jobsToRemove {
                activeJobs.removeValue(forKey: jobId)
            }
            
            if !jobsToRemove.isEmpty {
                os_log("Cleaned up %{public}d completed jobs", log: logger, type: .info, jobsToRemove.count)
            }
        }
    }
    
    private func addToHistoryAny(job: AnyBackgroundJob, success: Bool, error: Error?) {
        serialQueue.sync {
            let entry = JobHistoryEntry(
                id: job.id,
                name: job.name,
                submittedAt: job.submittedAt,
                completedAt: job.completedAt ?? Date(),
                success: success,
                attempts: job.currentAttempt,
                error: error?.localizedDescription
            )
            
            jobHistory.insert(entry, at: 0)
            
            // Keep history size under limit
            if jobHistory.count > maxHistorySize {
                jobHistory.removeLast(jobHistory.count - maxHistorySize)
            }
        }
    }
}

// MARK: - Background Job Protocol

public protocol AnyBackgroundJob: AnyObject {
    var id: String { get }
    var name: String { get }
    var status: JobStatus { get set }
    var priority: JobPriority { get }
    var submittedAt: Date { get }
    var startedAt: Date? { get set }
    var completedAt: Date? { get set }
    var currentAttempt: Int { get set }
    var retryPolicy: JobRetryPolicy { get }
    var error: Error? { get set }
    
    func executeAny() async throws -> Any
    func cancel()
}

// MARK: - Background Job

public class BackgroundJob<T>: AnyBackgroundJob {
    public let id: String
    public let name: String
    public let priority: JobPriority
    public let retryPolicy: JobRetryPolicy
    public let submittedAt: Date
    
    public var status: JobStatus = .pending
    public var startedAt: Date?
    public var completedAt: Date?
    public var currentAttempt: Int = 0
    public var result: T?
    public var error: Error?
    
    private let task: () async throws -> T
    private var isCancelled = false
    
    public init(
        name: String,
        priority: JobPriority = .normal,
        retryPolicy: JobRetryPolicy = .default,
        task: @escaping () async throws -> T
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.priority = priority
        self.retryPolicy = retryPolicy
        self.submittedAt = Date()
        self.task = task
    }
    
    public func execute() async throws -> T {
        guard !isCancelled else {
            throw JobError.cancelled
        }
        
        return try await task()
    }
    
    public func executeAny() async throws -> Any {
        return try await execute()
    }
    
    public func cancel() {
        isCancelled = true
        status = .cancelled
    }
}

// MARK: - Supporting Types

public enum JobStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public enum JobPriority: Int, Codable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
}

public struct JobRetryPolicy {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let backoffMultiplier: Double
    public let retryableErrors: [Error.Type]
    
    public static let `default` = JobRetryPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        retryableErrors: []
    )
    
    public static let aggressive = JobRetryPolicy(
        maxAttempts: 5,
        baseDelay: 0.5,
        maxDelay: 60.0,
        backoffMultiplier: 2.0,
        retryableErrors: []
    )
    
    public static let conservative = JobRetryPolicy(
        maxAttempts: 2,
        baseDelay: 5.0,
        maxDelay: 30.0,
        backoffMultiplier: 1.5,
        retryableErrors: []
    )
    
    public func shouldRetry(_ error: Error) -> Bool {
        if retryableErrors.isEmpty {
            // Retry most errors by default, except for validation/user errors
            return !(error is ValidationError || error is JobError)
        }
        
        return retryableErrors.contains { $0 == type(of: error) }
    }
    
    public func calculateDelay(for attempt: Int) -> TimeInterval {
        let delay = baseDelay * pow(backoffMultiplier, Double(attempt))
        return min(delay, maxDelay)
    }
}

public struct JobInfo: Codable {
    public let id: String
    public let name: String
    public let status: JobStatus
    public let priority: JobPriority
    public let submittedAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let attempt: Int
    public let maxAttempts: Int
}

public struct JobHistoryEntry: Codable {
    public let id: String
    public let name: String
    public let submittedAt: Date
    public let completedAt: Date
    public let success: Bool
    public let attempts: Int
    public let error: String?
}

public enum JobError: Error, LocalizedError {
    case cancelled
    case timeout
    case resourceUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Job was cancelled"
        case .timeout:
            return "Job timed out"
        case .resourceUnavailable:
            return "Required resource is unavailable"
        }
    }
}