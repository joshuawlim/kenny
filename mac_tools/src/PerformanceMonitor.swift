import Foundation
import os.log

/// Week 5: Performance monitoring and metrics collection
public class PerformanceMonitor {
    public static let shared = PerformanceMonitor()
    
    private let logger = OSLog(subsystem: "com.kenny.mac_tools", category: "performance")
    private let metricsQueue = DispatchQueue(label: "metrics", qos: .utility)
    private var metrics: [String: MetricSeries] = [:]
    private let startTime = Date()
    private let configManager: ConfigurationManager
    
    private init() {
        self.configManager = ConfigurationManager.shared
    }
    
    // MARK: - Metric Collection
    
    public func recordOperation<T>(_ operation: String, block: () throws -> T) rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            recordMetric(name: "\(operation).duration", value: duration * 1000) // Convert to milliseconds
        }
        
        do {
            let result = try block()
            recordMetric(name: "\(operation).success", value: 1)
            return result
        } catch {
            recordMetric(name: "\(operation).error", value: 1)
            throw error
        }
    }
    
    public func recordAsyncOperation<T>(_ operation: String, block: () async throws -> T) async rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            recordMetric(name: "\(operation).duration", value: duration * 1000)
        }
        
        do {
            let result = try await block()
            recordMetric(name: "\(operation).success", value: 1)
            return result
        } catch {
            recordMetric(name: "\(operation).error", value: 1)
            throw error
        }
    }
    
    public func recordMetric(name: String, value: Double, tags: [String: String] = [:]) {
        metricsQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.metrics[name] == nil {
                self.metrics[name] = MetricSeries(name: name)
            }
            
            let dataPoint = DataPoint(timestamp: Date(), value: value, tags: tags)
            self.metrics[name]?.addDataPoint(dataPoint)
            
            // Log high-value metrics using configured thresholds
            let criticalThreshold = Double(self.configManager.performance.criticalOperationThresholdMs)
            let slowThreshold = Double(self.configManager.performance.slowQueryThresholdMs)
            
            if value > criticalThreshold {
                os_log("Slow operation: %{public}s took %.2fms", 
                       log: self.logger, type: .error, name, value)
            } else if value > slowThreshold {
                os_log("Performance warning: %{public}s took %.2fms", 
                       log: self.logger, type: .info, name, value)
            }
        }
    }
    
    // MARK: - System Metrics
    
    public func collectSystemMetrics() {
        metricsQueue.async { [weak self] in
            // Memory usage
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            
            if result == KERN_SUCCESS {
                let memoryUsageMB = Double(info.resident_size) / (1024 * 1024)
                self?.recordMetric(name: "system.memory_usage_mb", value: memoryUsageMB)
            }
            
            // CPU usage (simplified)
            let uptime = Date().timeIntervalSince(self?.startTime ?? Date())
            self?.recordMetric(name: "system.uptime_seconds", value: uptime)
        }
    }
    
    // MARK: - Report Generation
    
    public func generateReport(timeWindow: TimeInterval = 3600) -> PerformanceReport {
        let cutoff = Date().addingTimeInterval(-timeWindow)
        var operationStats: [String: OperationStats] = [:]
        
        metricsQueue.sync {
            for (name, series) in metrics {
                let recentPoints = series.dataPoints.filter { $0.timestamp >= cutoff }
                
                if !recentPoints.isEmpty {
                    let values = recentPoints.map { $0.value }
                    let stats = OperationStats(
                        name: name,
                        count: recentPoints.count,
                        average: values.reduce(0, +) / Double(values.count),
                        p50: percentile(values, 0.5),
                        p95: percentile(values, 0.95),
                        p99: percentile(values, 0.99),
                        min: values.min() ?? 0,
                        max: values.max() ?? 0
                    )
                    operationStats[name] = stats
                }
            }
        }
        
        return PerformanceReport(
            timestamp: Date(),
            timeWindow: timeWindow,
            operationStats: operationStats,
            systemHealth: generateSystemHealth()
        )
    }
    
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
    
    private func generateSystemHealth() -> SystemHealth {
        // Simplified health check
        let memoryMetric = metrics["system.memory_usage_mb"]?.dataPoints.last?.value ?? 0
        let memoryThreshold = Double(configManager.performance.memoryWarningThresholdMB)
        let isHealthy = memoryMetric < memoryThreshold
        
        return SystemHealth(
            isHealthy: isHealthy,
            memoryUsageMB: memoryMetric,
            uptime: Date().timeIntervalSince(startTime),
            activeConnections: metrics.count
        )
    }
    
    // MARK: - Export
    
    public func exportMetricsJSON() -> Data? {
        let report = generateReport()
        return try? JSONEncoder().encode(report)
    }
    
    public func exportPrometheusFormat() -> String {
        var output = ""
        let report = generateReport()
        
        for (_, stats) in report.operationStats {
            output += "# HELP \(stats.name) Operation metrics\\n"
            output += "# TYPE \(stats.name) histogram\\n"
            output += "\(stats.name)_count \(stats.count)\\n"
            output += "\(stats.name)_avg \(stats.average)\\n"
            output += "\(stats.name)_p50 \(stats.p50)\\n"
            output += "\(stats.name)_p95 \(stats.p95)\\n"
            output += "\(stats.name)_p99 \(stats.p99)\\n"
        }
        
        return output
    }
}

// MARK: - Data Structures

public struct DataPoint {
    public let timestamp: Date
    public let value: Double
    public let tags: [String: String]
}

public class MetricSeries {
    public let name: String
    public private(set) var dataPoints: [DataPoint] = []
    private let maxDataPoints: Int
    
    public init(name: String) {
        self.name = name
        self.maxDataPoints = ConfigurationManager.shared.performance.maxDataPoints
    }
    
    public func addDataPoint(_ point: DataPoint) {
        dataPoints.append(point)
        
        // Trim old data points to prevent memory leaks
        if dataPoints.count > maxDataPoints {
            dataPoints.removeFirst(dataPoints.count - maxDataPoints)
        }
    }
}

public struct OperationStats: Codable {
    public let name: String
    public let count: Int
    public let average: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let min: Double
    public let max: Double
}

public struct SystemHealth: Codable {
    public let isHealthy: Bool
    public let memoryUsageMB: Double
    public let uptime: TimeInterval
    public let activeConnections: Int
}

public struct PerformanceReport: Codable {
    public let timestamp: Date
    public let timeWindow: TimeInterval
    public let operationStats: [String: OperationStats]
    public let systemHealth: SystemHealth
}