import Foundation

/// Week 5: Configuration management with environment-based settings
public class ConfigurationManager {
    public static let shared = ConfigurationManager()
    
    private let configuration: Configuration
    private let environment: Environment
    
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
                path: nil, // Use default
                connectionPoolSize: 5,
                queryTimeout: 30.0,
                enableWAL: true,
                enableFTS: true
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 7,
                slowQueryThresholdMs: 1000,
                enableTracing: true
            ),
            cache: CacheConfig(
                enabled: true,
                maxMemoryMB: 100,
                defaultTTLSeconds: 300,
                maxEntries: 1000
            ),
            llm: LLMConfig(
                provider: .ollama,
                model: "llama3.2:3b",
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
                enableFTS: true
            ),
            performance: PerformanceConfig(
                enableMetrics: false,
                metricsRetentionDays: 1,
                slowQueryThresholdMs: 100,
                enableTracing: false
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
            )
        )
    }
    
    private static func stagingConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: nil,
                connectionPoolSize: 10,
                queryTimeout: 15.0,
                enableWAL: true,
                enableFTS: true
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 30,
                slowQueryThresholdMs: 500,
                enableTracing: true
            ),
            cache: CacheConfig(
                enabled: true,
                maxMemoryMB: 256,
                defaultTTLSeconds: 600,
                maxEntries: 5000
            ),
            llm: LLMConfig(
                provider: .ollama,
                model: "llama3.2:3b",
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
            )
        )
    }
    
    private static func productionConfig() -> Configuration {
        return Configuration(
            database: DatabaseConfig(
                path: nil,
                connectionPoolSize: 20,
                queryTimeout: 10.0,
                enableWAL: true,
                enableFTS: true
            ),
            performance: PerformanceConfig(
                enableMetrics: true,
                metricsRetentionDays: 90,
                slowQueryThresholdMs: 300,
                enableTracing: false // Disable tracing in production for performance
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
            )
        )
    }
}

// MARK: - Configuration Structs

public struct DatabaseConfig {
    public let path: String?
    public let connectionPoolSize: Int
    public let queryTimeout: TimeInterval
    public let enableWAL: Bool
    public let enableFTS: Bool
}

public struct PerformanceConfig {
    public let enableMetrics: Bool
    public let metricsRetentionDays: Int
    public let slowQueryThresholdMs: Int
    public let enableTracing: Bool
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