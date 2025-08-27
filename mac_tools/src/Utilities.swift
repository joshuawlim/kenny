import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - String Extensions
extension String {
    func sha256() -> String {
        let data = self.data(using: .utf8) ?? Data()
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        let hash = data.withUnsafeBytes { bytes in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

// MARK: - Data Extensions
extension Data {
    func sha256Hash() -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: self)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        let hash = self.withUnsafeBytes { bytes in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(self.count), &hash)
            return hash
        }
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

// IngestStats moved to IngestManager.swift to avoid duplication

// MARK: - Database Path Resolution
/// Utility class to resolve database paths consistently across all components using ConfigurationManager
public class DatabasePathResolver {
    
    /// Get the absolute path to the Kenny database using ConfigurationManager
    /// This method ensures the database is always created/accessed at the same location
    /// using the centralized configuration system
    public static func getKennyDatabasePath(customPath: String? = nil) -> String {
        if let custom = customPath, !custom.isEmpty {
            // If custom path is provided, resolve it to absolute path
            if custom.hasPrefix("/") {
                return custom // Already absolute
            } else {
                return URL(fileURLWithPath: custom, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                    .standardizedFileURL.path
            }
        }
        
        // Use ConfigurationManager for path resolution
        let resolvedPath = ConfigurationManager.shared.database.getResolvedPath()
        print("Using Kenny database path from ConfigurationManager: \(resolvedPath)")
        return resolvedPath
    }
    
    /// Validate that the database path points to a reasonable location
    public static func validateDatabasePath(_ path: String) -> Bool {
        // The path should point to kenny.db or be :memory: for tests
        let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL
        
        // Allow :memory: for testing
        if path == ":memory:" {
            return true
        }
        
        // Should end with kenny.db and be an absolute path
        return resolvedPath.lastPathComponent == "kenny.db" && path.hasPrefix("/")
    }
    
    /// Debug information about current path resolution
    public static func debugPathResolution() {
        print("=== Kenny Database Path Resolution Debug ===")
        print("Environment: \(ConfigurationManager.shared.environment.rawValue)")
        print("Current working directory: \(FileManager.default.currentDirectoryPath)")
        
        let resolvedPath = getKennyDatabasePath()
        print("Resolved Kenny database path: \(resolvedPath)")
        print("Path validation: \(validateDatabasePath(resolvedPath) ? "✅ VALID" : "❌ INVALID")")
        print("Database exists: \(FileManager.default.fileExists(atPath: resolvedPath) ? "✅ YES" : "❌ NO")")
        
        // Show environment variables that might affect path resolution
        if let envPath = ProcessInfo.processInfo.environment["KENNY_DB_PATH"] {
            print("KENNY_DB_PATH environment variable: \(envPath)")
        }
        if let projectRoot = ProcessInfo.processInfo.environment["KENNY_PROJECT_ROOT"] {
            print("KENNY_PROJECT_ROOT environment variable: \(projectRoot)")
        }
        
        // Show configuration details
        let config = ConfigurationManager.shared.database
        print("Configuration database path: \(config.path ?? "nil (using resolver)")")
        print("============================================")
    }
}

// MARK: - Ingest Error
enum IngestError: Error {
    case permissionDenied(String)
    case dataCorruption
    case networkError
}