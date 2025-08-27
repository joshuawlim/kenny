import Foundation

/// Week 5: Intelligent caching system for performance optimization
public class CacheManager {
    public static let shared = CacheManager()
    
    private let cache = NSCache<NSString, CacheEntry>()
    private let cacheQueue = DispatchQueue(label: "cache", qos: .utility, attributes: .concurrent)
    private let configManager: ConfigurationManager
    private let defaultTTL: TimeInterval
    
    private init() {
        self.configManager = ConfigurationManager.shared
        
        // Configure cache limits based on environment
        let cacheConfig = configManager.cache
        self.defaultTTL = TimeInterval(cacheConfig.defaultTTLSeconds)
        cache.countLimit = cacheConfig.maxEntries
        cache.totalCostLimit = cacheConfig.maxMemoryMB * 1024 * 1024
        
        // Setup periodic cache cleanup using configured interval
        let cleanupInterval = TimeInterval(configManager.operational.cleanupIntervalSeconds)
        Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.cleanupExpiredEntries()
        }
    }
    
    // MARK: - Generic Caching
    
    public func get<T: Codable>(_ key: String, type: T.Type) -> T? {
        return cacheQueue.sync {
            guard let entry = cache.object(forKey: NSString(string: key)),
                  !entry.isExpired else {
                cache.removeObject(forKey: NSString(string: key))
                return nil
            }
            
            PerformanceMonitor.shared.recordMetric(name: "cache.hit", value: 1, tags: ["key": key])
            return entry.decode(type: type)
        }
    }
    
    public func set<T: Codable>(_ key: String, value: T, ttl: TimeInterval? = nil) {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            do {
                let entry = try CacheEntry(value: value, ttl: ttl ?? self.defaultTTL)
                let cost = entry.estimatedSize
                self.cache.setObject(entry, forKey: NSString(string: key), cost: cost)
                
                PerformanceMonitor.shared.recordMetric(name: "cache.set", value: 1, tags: ["key": key])
            } catch {
                PerformanceMonitor.shared.recordMetric(name: "cache.error", value: 1, tags: ["operation": "set"])
            }
        }
    }
    
    public func remove(_ key: String) {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.cache.removeObject(forKey: NSString(string: key))
        }
    }
    
    private func clearCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.cache.removeAllObjects()
        }
    }
    
    private func cleanupExpiredEntries() {
        // NSCache doesn't provide enumeration, so we rely on lazy cleanup during access
        PerformanceMonitor.shared.recordMetric(name: "cache.cleanup", value: 1)
    }
    
    // MARK: - Specialized Caching Methods
    
    /// Cache search results with query-based invalidation
    public func cacheSearchResults(_ results: [SearchResult], for query: String, ttl: TimeInterval? = nil) {
        let key = "search:\(query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        let actualTTL = ttl ?? TimeInterval(configManager.cache.defaultTTLSeconds)
        set(key, value: results, ttl: actualTTL)
    }
    
    public func getCachedSearchResults(for query: String) -> [SearchResult]? {
        let key = "search:\(query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        return get(key, type: [SearchResult].self)
    }
    
    /// Cache embeddings with longer TTL since they're expensive to compute
    public func cacheEmbedding(_ vector: [Float], for text: String) {
        let key = "embedding:\(text.sha256())"
        let ttl = TimeInterval(configManager.cache.defaultTTLSeconds) * TimeInterval(configManager.operational.embeddingTTLMultiplier)
        set(key, value: vector, ttl: ttl)
    }
    
    public func getCachedEmbedding(for text: String) -> [Float]? {
        let key = "embedding:\(text.sha256())"
        return get(key, type: [Float].self)
    }
    
    /// Cache calendar events with shorter TTL for freshness (using JSON serialization)
    public func cacheCalendarEvents(_ events: [[String: Any]], for dateRange: String) {
        let key = "calendar:\(dateRange)"
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: events)
            set(key, value: jsonData, ttl: 300) // 5 minutes
        } catch {
            PerformanceMonitor.shared.recordMetric(name: "cache.serialization_error", value: 1)
        }
    }
    
    public func getCachedCalendarEvents(for dateRange: String) -> [[String: Any]]? {
        let key = "calendar:\(dateRange)"
        guard let jsonData = get(key, type: Data.self) else { return nil }
        
        do {
            return try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        } catch {
            PerformanceMonitor.shared.recordMetric(name: "cache.deserialization_error", value: 1)
            return nil
        }
    }
    
    /// Cache mail headers with moderate TTL (using JSON serialization)
    public func cacheMailHeaders(_ headers: [[String: Any]], for parameters: String) {
        let key = "mail:\(parameters)"
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: headers)
            set(key, value: jsonData, ttl: 600) // 10 minutes
        } catch {
            PerformanceMonitor.shared.recordMetric(name: "cache.serialization_error", value: 1)
        }
    }
    
    public func getCachedMailHeaders(for parameters: String) -> [[String: Any]]? {
        let key = "mail:\(parameters)"
        guard let jsonData = get(key, type: Data.self) else { return nil }
        
        do {
            return try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        } catch {
            PerformanceMonitor.shared.recordMetric(name: "cache.deserialization_error", value: 1)
            return nil
        }
    }
    
    // MARK: - Cache Statistics
    
    public func getStats() -> CacheStats {
        return cacheQueue.sync {
            return CacheStats(
                totalObjects: cache.countLimit,
                currentObjects: 0, // NSCache doesn't expose current count
                totalCostLimit: cache.totalCostLimit,
                hitRate: calculateHitRate(),
                memoryUsage: estimateMemoryUsage()
            )
        }
    }
    
    private func calculateHitRate() -> Double {
        // This would be tracked with separate counters in a production system
        return 0.75 // Placeholder
    }
    
    private func estimateMemoryUsage() -> Int {
        // This would use actual memory tracking in production
        return 50 * 1024 * 1024 // Placeholder: 50MB
    }
}

// MARK: - Cache Entry

private class CacheEntry: NSObject {
    let data: Data
    let expirationDate: Date
    let estimatedSize: Int
    
    init<T: Codable>(value: T, ttl: TimeInterval) throws {
        self.data = try JSONEncoder().encode(value)
        self.expirationDate = Date().addingTimeInterval(ttl)
        self.estimatedSize = data.count
        super.init()
    }
    
    var isExpired: Bool {
        return Date() > expirationDate
    }
    
    func decode<T: Codable>(type: T.Type) -> T? {
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Supporting Types

public struct CacheStats: Codable {
    public let totalObjects: Int
    public let currentObjects: Int
    public let totalCostLimit: Int
    public let hitRate: Double
    public let memoryUsage: Int
}

// Uses sha256() extension from Utilities.swift