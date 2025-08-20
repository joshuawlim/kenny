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

// MARK: - Ingest Error
enum IngestError: Error {
    case permissionDenied(String)
    case dataCorruption
    case networkError
}