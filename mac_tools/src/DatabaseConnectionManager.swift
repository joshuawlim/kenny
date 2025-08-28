import Foundation
import SQLite3

/// Centralized database connection manager to prevent concurrent access issues
/// Implements singleton pattern with connection pooling and operation queuing
public class DatabaseConnectionManager {
    public static let shared = DatabaseConnectionManager()
    
    private var database: Database?
    private let connectionQueue = DispatchQueue(label: "kenny.database.connection.manager", qos: .userInitiated)
    private let operationQueue = OperationQueue()
    private var isInitialized = false
    private let dbPath: String
    
    private init() {
        // Use Kenny database path resolver for consistent path resolution
        self.dbPath = DatabasePathResolver.getKennyDatabasePath()
        
        // Configure operation queue for sequential processing
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        operationQueue.name = "kenny.database.operations"
    }
    
    /// Initialize with custom database path
    public func initialize(customPath: String? = nil) {
        connectionQueue.sync {
            if !isInitialized {
                let finalPath = customPath ?? dbPath
                database = Database(path: finalPath)
                isInitialized = true
                print("DatabaseConnectionManager initialized with path: \(finalPath)")
            }
        }
    }
    
    /// Get the shared database instance (thread-safe)
    public func getDatabase() -> Database? {
        connectionQueue.sync {
            if !isInitialized {
                initialize()
            }
            return database
        }
    }
    
    /// Execute database operation with proper queuing
    public func executeOperation<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        guard let db = getDatabase() else {
            throw DatabaseConnectionError.notInitialized
        }
        
        return try connectionQueue.sync {
            return try operation(db)
        }
    }
    
    /// Execute async database operation with proper queuing
    public func executeAsyncOperation<T>(_ operation: @escaping (Database) async throws -> T) async throws -> T {
        guard let db = getDatabase() else {
            throw DatabaseConnectionError.notInitialized
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            operationQueue.addOperation {
                Task {
                    do {
                        let result = try await operation(db)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    /// Execute multiple operations as a transaction
    public func executeTransaction(_ operations: @escaping (Database) throws -> Void) throws {
        try executeOperation { db in
            _ = db.execute("BEGIN TRANSACTION")
            
            do {
                try operations(db)
                _ = db.execute("COMMIT")
            } catch {
                _ = db.execute("ROLLBACK")
                throw error
            }
        }
    }
    
    /// Get database statistics safely
    public func getDatabaseStats() -> [String: Any] {
        do {
            return try executeOperation { db in
                return db.getStats()
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }
    
    /// Safely close database connection
    public func close() {
        connectionQueue.sync {
            database = nil
            isInitialized = false
            operationQueue.cancelAllOperations()
            print("DatabaseConnectionManager closed")
        }
    }
    
    /// Check if manager is ready for operations
    public var isReady: Bool {
        return connectionQueue.sync {
            return isInitialized && database != nil
        }
    }
    
    /// Get current database path
    public var currentPath: String {
        return connectionQueue.sync {
            return database?.description ?? dbPath
        }
    }
}

/// Errors that can occur with database connection management
public enum DatabaseConnectionError: Error {
    case notInitialized
    case connectionFailed(String)
    case operationTimeout
    case concurrencyViolation
    
    public var localizedDescription: String {
        switch self {
        case .notInitialized:
            return "Database connection manager not initialized"
        case .connectionFailed(let reason):
            return "Database connection failed: \(reason)"
        case .operationTimeout:
            return "Database operation timed out"
        case .concurrencyViolation:
            return "Concurrent database access violation detected"
        }
    }
}

// MARK: - Database Extensions for Connection Manager Integration

extension Database {
    public var description: String {
        return "Database connection"
    }
}