import Foundation

/// Week 5: Configuration management with environment-based settings
public class ConfigurationManager {
    public static let shared = ConfigurationManager()
    
    private let configuration: Configuration
    public let environment: Environment
    
    private init() {
        self.environment = Environment.detect()
        self.configuration = Configuration.load(for: environment)
    }
    
    // MARK: - Public Configuration Access
    
    public var database: DatabaseConfig { configuration.database }
    public var performance: PerformanceConfig { configuration.performance }
    public var cache: CacheConfig { configuration.cache }
    public var llm: LLMConfig { configuration.llm }
    public var monitoring: MonitoringConfig { configuration.monitoring }
    public var features: FeatureFlags { configuration.features }
    public var search: SearchConfig { configuration.search }
    public var ingestion: IngestionConfig { configuration.ingestion }
    public var operational: OperationalConfig { configuration.operational }
    
    // MARK: - Environment Detection
    
    public enum Environment: String, CaseIterable {
        case development = "development"
        case testing = "testing"
        case staging = "staging"
        case production = "production"
        
        static func detect() -> Environment {
            if let envString = ProcessInfo.processInfo.environment["KENNY_ENV"],
               let env = Environment(rawValue: envString.lowercased()) {
                return env
            }
            
            // Auto-detect based on context
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return .testing
            }
            
            #if DEBUG
            return .development
            #else
            return .production
            #endif
        }
    }
}

// MARK: - Configuration Structure

public struct Configuration {
    public let database: DatabaseConfig
    public let performance: PerformanceConfig
    public let cache: CacheConfig
    public let llm: LLMConfig
    public let monitoring: MonitoringConfig
    public let features: FeatureFlags
    public let search: SearchConfig
    public let ingestion: IngestionConfig
    public let operational: OperationalConfig
    
    static func load(for environment: ConfigurationManager.Environment) -> Configuration {
        switch environment {
        case .development:
            return developmentConfig()
        case .testing:
            return testingConfig()
        case .staging:
            return stagingConfig()
        case .production:
            return productionConfig()
        }
    }
    
    private static func developmentConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: getDefaultDatabasePath(), // Use project-relative path
                connectionPoolSize: 5,
                queryTimeout: 30.0,
                enableWAL: true,
                enableFTS: true,
                maxConnections: 5,
                mmapSize: 268435456, // 256MB
                connectionTimeoutSeconds: 30.0
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 7,
                slowQueryThresholdMs: 1000,
                enableTracing: true,
                criticalOperationThresholdMs: 5000,
                memoryWarningThresholdMB: 512,
                maxDataPoints: 10000
            ),
            cache: CacheConfig(
                enabled: true,
                maxMemoryMB: 100,
                defaultTTLSeconds: 300,
                maxEntries: 1000
            ),
            llm: LLMConfig(
                provider: .ollama,
                model: ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "mistral-small3.1:latest",
                endpoint: "http://localhost:11434",
                timeout: 30.0,
                maxRetries: 3,
                enableFallback: true
            ),
            monitoring: MonitoringConfig(
                enabled: true,
                logLevel: .debug,
                enableStructuredLogging: true,
                metricsEndpoint: nil
            ),
            features: FeatureFlags(
                enableHybridSearch: true,
                enableEmbeddings: true,
                enableRealTimeSync: false,
                enableWebhooks: false,
                enableAdvancedCaching: true,
                safetyStrictness: "medium"
            ),
            search: SearchConfig(
                bm25Weight: 0.5,
                embeddingWeight: 0.5,
                relevanceThreshold: 0.3,
                maxChunkSize: 512,
                chunkOverlap: 50
            ),
            ingestion: IngestionConfig(
                fullSyncDays: 730, // 2 years
                incrementalSyncDays: 30,
                maxBatchSize: 1000,
                maxMessages: nil
            ),
            operational: OperationalConfig(
                maxHistorySize: 1000,
                jobCleanupHours: 1,
                maxDataPoints: 10000,
                cleanupIntervalSeconds: 300,
                embeddingTTLMultiplier: 12
            )
        )
    }
    
    private static func testingConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: ":memory:", // In-memory for tests
                connectionPoolSize: 1,
                queryTimeout: 5.0,
                enableWAL: false,
                enableFTS: true,
                maxConnections: 1,
                mmapSize: 67108864, // 64MB for testing
                connectionTimeoutSeconds: 5.0
            ),
            performance: PerformanceConfig(
                enableMetrics: false,
                metricsRetentionDays: 1,
                slowQueryThresholdMs: 100,
                enableTracing: false,
                criticalOperationThresholdMs: 1000,
                memoryWarningThresholdMB: 128,
                maxDataPoints: 1000
            ),
            cache: CacheConfig(
                enabled: false, // Disable caching in tests for consistency
                maxMemoryMB: 10,
                defaultTTLSeconds: 10,
                maxEntries: 100
            ),
            llm: LLMConfig(
                provider: .mock,
                model: "test-model",
                endpoint: "http://localhost:8080",
                timeout: 5.0,
                maxRetries: 1,
                enableFallback: true
            ),
            monitoring: MonitoringConfig(
                enabled: false,
                logLevel: .warning,
                enableStructuredLogging: true,
                metricsEndpoint: nil
            ),
            features: FeatureFlags(
                enableHybridSearch: true,
                enableEmbeddings: false, // Disable expensive operations in tests
                enableRealTimeSync: false,
                enableWebhooks: false,
                enableAdvancedCaching: false,
                safetyStrictness: "low"
            ),
            search: SearchConfig(
                bm25Weight: 0.5,
                embeddingWeight: 0.5,
                relevanceThreshold: 0.1, // Lower for testing
                maxChunkSize: 256, // Smaller for faster tests
                chunkOverlap: 25
            ),
            ingestion: IngestionConfig(
                fullSyncDays: 7, // Shorter for testing
                incrementalSyncDays: 1,
                maxBatchSize: 100, // Smaller batches
                maxMessages: 1000
            ),
            operational: OperationalConfig(
                maxHistorySize: 100,
                jobCleanupHours: 1,
                maxDataPoints: 1000,
                cleanupIntervalSeconds: 30, // More frequent for tests
                embeddingTTLMultiplier: 2
            )
        )
    }
    
    private static func stagingConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: getDefaultDatabasePath(),
                connectionPoolSize: 10,
                queryTimeout: 15.0,
                enableWAL: true,
                enableFTS: true,
                maxConnections: 10,
                mmapSize: 536870912, // 512MB
                connectionTimeoutSeconds: 15.0
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 30,
                slowQueryThresholdMs: 500,
                enableTracing: true,
                criticalOperationThresholdMs: 2500,
                memoryWarningThresholdMB: 1024,
                maxDataPoints: 50000
            ),
            cache: CacheConfig(
                enabled: true,
                maxMemoryMB: 256,
                defaultTTLSeconds: 600,
                maxEntries: 5000
            ),
            llm: LLMConfig(
                provider: .ollama,
                model: ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "mistral-small3.1:latest",
                endpoint: ProcessInfo.processInfo.environment["OLLAMA_ENDPOINT"] ?? "http://localhost:11434",
                timeout: 45.0,
                maxRetries: 5,
                enableFallback: true
            ),
            monitoring: MonitoringConfig(
                enabled: true,
                logLevel: .info,
                enableStructuredLogging: true,
                metricsEndpoint: ProcessInfo.processInfo.environment["METRICS_ENDPOINT"]
            ),
            features: FeatureFlags(
                enableHybridSearch: true,
                enableEmbeddings: true,
                enableRealTimeSync: true,
                enableWebhooks: true,
                enableAdvancedCaching: true,
                safetyStrictness: "high"
            ),
            search: SearchConfig(
                bm25Weight: 0.4,
                embeddingWeight: 0.6, // Favor embeddings in staging
                relevanceThreshold: 0.4,
                maxChunkSize: 512,
                chunkOverlap: 50
            ),
            ingestion: IngestionConfig(
                fullSyncDays: 365, // 1 year for staging
                incrementalSyncDays: 7,
                maxBatchSize: 500,
                maxMessages: nil
            ),
            operational: OperationalConfig(
                maxHistorySize: 5000,
                jobCleanupHours: 6,
                maxDataPoints: 50000,
                cleanupIntervalSeconds: 600, // 10 minutes
                embeddingTTLMultiplier: 8
            )
        )
    }
    
    private static func productionConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: getDefaultDatabasePath(),
                connectionPoolSize: 20,
                queryTimeout: 10.0,
                enableWAL: true,
                enableFTS: true,
                maxConnections: 20,
                mmapSize: 1073741824, // 1GB
                connectionTimeoutSeconds: 10.0
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 90,
                slowQueryThresholdMs: 300,
                enableTracing: false, // Disable tracing in production for performance
                criticalOperationThresholdMs: 1500,
                memoryWarningThresholdMB: 2048,
                maxDataPoints: 100000
            ),
            cache: CacheConfig(
                enabled: true,
                maxMemoryMB: 512,
                defaultTTLSeconds: 900,
                maxEntries: 10000
            ),
            llm: LLMConfig(
                provider: .ollama,
                model: ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "llama3.2:3b",
                endpoint: ProcessInfo.processInfo.environment["OLLAMA_ENDPOINT"] ?? "http://localhost:11434",
                timeout: 60.0,
                maxRetries: 3,
                enableFallback: true
            ),
            monitoring: MonitoringConfig(
                enabled: true,
                logLevel: .warning,
                enableStructuredLogging: true,
                metricsEndpoint: ProcessInfo.processInfo.environment["METRICS_ENDPOINT"]
            ),
            features: FeatureFlags(
                enableHybridSearch: true,
                enableEmbeddings: true,
                enableRealTimeSync: true,
                enableWebhooks: true,
                enableAdvancedCaching: true,
                safetyStrictness: "paranoid"
            ),
            search: SearchConfig(
                bm25Weight: 0.3,
                embeddingWeight: 0.7, // Heavily favor embeddings in production
                relevanceThreshold: 0.5, // Higher threshold for quality
                maxChunkSize: 1024, // Larger chunks for better context
                chunkOverlap: 100
            ),
            ingestion: IngestionConfig(
                fullSyncDays: 2555, // ~7 years for production
                incrementalSyncDays: 14,
                maxBatchSize: 2000, // Larger batches for efficiency
                maxMessages: nil
            ),
            operational: OperationalConfig(
                maxHistorySize: 50000,
                jobCleanupHours: 24, // Daily cleanup
                maxDataPoints: 100000,
                cleanupIntervalSeconds: 3600, // Hourly cleanup
                embeddingTTLMultiplier: 24 // Long TTL for production
            )
        )
    }
    
    // MARK: - Helper Methods
    
    private static func getDefaultDatabasePath() -> String? {
        // Don't specify a path here - let the DatabaseConfig.getResolvedPath() handle it
        // This allows for proper environment variable and project root detection
        return nil
    }
}

// MARK: - Configuration Structs

public struct DatabaseConfig {
    public let path: String?
    public let connectionPoolSize: Int
    public let queryTimeout: TimeInterval
    public let enableWAL: Bool
    public let enableFTS: Bool
    public let maxConnections: Int
    public let mmapSize: Int // Memory mapping size in bytes
    public let connectionTimeoutSeconds: TimeInterval
    
    /// Get the resolved database path using environment variables and fallbacks
    public func getResolvedPath() -> String {
        // First, check for explicit environment variable override
        if let envPath = ProcessInfo.processInfo.environment["KENNY_DB_PATH"], 
           !envPath.isEmpty {
            return envPath
        }
        
        // If configuration specifies a path, use it
        if let configPath = path, !configPath.isEmpty {
            return configPath
        }
        
        // Use project root detection for fallback
        return resolveProjectDatabasePath()
    }
    
    private func resolveProjectDatabasePath() -> String {
        // Try to find project root through environment variable first
        if let projectRoot = ProcessInfo.processInfo.environment["KENNY_PROJECT_ROOT"], 
           !projectRoot.isEmpty {
            return "\(projectRoot)/mac_tools/kenny.db"
        }
        
        // Try to locate the mac_tools directory from current working directory
        let currentPath = FileManager.default.currentDirectoryPath
        
        // Try multiple search paths to find the correct mac_tools directory
        let candidatePaths = [
            // Current directory if it contains kenny.db
            currentPath + "/kenny.db",
            // Parent directory mac_tools
            currentPath + "/../mac_tools/kenny.db",
            // Direct path if current dir is already mac_tools
            currentPath.hasSuffix("mac_tools") ? currentPath + "/kenny.db" : nil,
            // Traverse up to find Kenny directory
            findKennyProjectRoot(from: currentPath)
        ].compactMap { $0 }
        
        // Find the first existing kenny.db file
        for candidatePath in candidatePaths {
            if FileManager.default.fileExists(atPath: candidatePath) {
                let resolvedPath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
                return resolvedPath
            }
        }
        
        // If no existing database found, create in a default location based on project structure
        if let detectedRoot = findKennyProjectRoot(from: currentPath) {
            return detectedRoot
        }
        
        // Final fallback - create in current directory
        return currentPath + "/kenny.db"
    }
    
    private func findKennyProjectRoot(from startPath: String) -> String? {
        var currentPath = URL(fileURLWithPath: startPath)
        
        // Traverse up the directory tree looking for Kenny project markers
        for _ in 0..<10 { // Prevent infinite loops
            let candidatePaths = [
                currentPath.appendingPathComponent("mac_tools").appendingPathComponent("kenny.db").path,
                currentPath.appendingPathComponent("kenny.db").path
            ]
            
            for candidatePath in candidatePaths {
                let parentDir = URL(fileURLWithPath: candidatePath).deletingLastPathComponent()
                // Check for project markers
                if FileManager.default.fileExists(atPath: parentDir.appendingPathComponent("Package.swift").path) ||
                   FileManager.default.fileExists(atPath: parentDir.appendingPathComponent("Sources").path) ||
                   FileManager.default.fileExists(atPath: parentDir.appendingPathComponent("OrchestratorCLI.swift").path) {
                    return candidatePath
                }
            }
            
            // Move up one level
            let parent = currentPath.deletingLastPathComponent()
            if parent == currentPath { break } // Reached root
            currentPath = parent
        }
        
        return nil
    }
}

public struct PerformanceConfig {
    public let enableMetrics: Bool
    public let metricsRetentionDays: Int
    public let slowQueryThresholdMs: Int
    public let enableTracing: Bool
    public let criticalOperationThresholdMs: Int
    public let memoryWarningThresholdMB: Int
    public let maxDataPoints: Int
}

public struct CacheConfig {
    public let enabled: Bool
    public let maxMemoryMB: Int
    public let defaultTTLSeconds: Int
    public let maxEntries: Int
}

public struct LLMConfig {
    public let provider: LLMProvider
    public let model: String
    public let endpoint: String
    public let timeout: TimeInterval
    public let maxRetries: Int
    public let enableFallback: Bool
    
    public enum LLMProvider: String, CaseIterable {
        case ollama = "ollama"
        case openai = "openai"
        case mock = "mock"
    }
}

public struct MonitoringConfig {
    public let enabled: Bool
    public let logLevel: LogLevel
    public let enableStructuredLogging: Bool
    public let metricsEndpoint: String?
    
    public enum LogLevel: String, CaseIterable {
        case debug = "debug"
        case info = "info"
        case warning = "warning"
        case error = "error"
    }
}

public struct FeatureFlags {
    public let enableHybridSearch: Bool
    public let enableEmbeddings: Bool
    public let enableRealTimeSync: Bool
    public let enableWebhooks: Bool
    public let enableAdvancedCaching: Bool
    public let safetyStrictness: String
}

// MARK: - Additional Configuration Structs

public struct SearchConfig {
    public let bm25Weight: Float
    public let embeddingWeight: Float
    public let relevanceThreshold: Float
    public let maxChunkSize: Int
    public let chunkOverlap: Int
}

public struct IngestionConfig {
    public let fullSyncDays: Int
    public let incrementalSyncDays: Int
    public let maxBatchSize: Int
    public let maxMessages: Int?
}

public struct OperationalConfig {
    public let maxHistorySize: Int
    public let jobCleanupHours: Int
    public let maxDataPoints: Int
    public let cleanupIntervalSeconds: Int
    public let embeddingTTLMultiplier: Int
}