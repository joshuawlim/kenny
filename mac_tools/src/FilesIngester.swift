import Foundation
import UniformTypeIdentifiers

class FilesIngester {
    private let database: Database
    private let searchPaths: [String]
    
    init(database: Database, searchPaths: [String]? = nil) {
        self.database = database
        self.searchPaths = searchPaths ?? [
            NSHomeDirectory() + "/Documents",
            NSHomeDirectory() + "/Desktop", 
            NSHomeDirectory() + "/Downloads"
        ]
    }
    
    func ingestFiles(isFullSync: Bool, since: Date? = nil) async throws -> IngestStats {
        var stats = IngestStats(source: "files")
        
        for searchPath in searchPaths {
            print("Scanning files in: \(searchPath)")
            await scanDirectory(searchPath, stats: &stats, isFullSync: isFullSync, since: since)
        }
        
        print("Files ingest: \(stats.itemsProcessed) processed, \(stats.itemsCreated) created, \(stats.errors) errors")
        return stats
    }
    
    private func scanDirectory(_ path: String, stats: inout IngestStats, isFullSync: Bool, since: Date?) async {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: [
                                                        .isDirectoryKey,
                                                        .fileSizeKey,
                                                        .contentModificationDateKey,
                                                        .creationDateKey,
                                                        .contentTypeKey,
                                                        .isHiddenKey
                                                     ],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            stats.errors += 1
            return
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .creationDateKey, .contentTypeKey, .isHiddenKey
                ])
                
                // Skip directories for now
                if resourceValues.isDirectory == true { continue }
                
                // Skip if file was modified before 'since' date (for incremental sync)
                if let since = since, 
                   let modDate = resourceValues.contentModificationDate,
                   modDate < since && !isFullSync {
                    continue
                }
                
                await processFile(fileURL, resourceValues: resourceValues, stats: &stats)
                
            } catch {
                stats.errors += 1
                continue
            }
        }
    }
    
    private func processFile(_ fileURL: URL, resourceValues: URLResourceValues, stats: inout IngestStats) async {
        let documentId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        let filePath = fileURL.path
        let fileName = fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        
        // Check if file already exists (for incremental sync)
        let existingFile = database.query(
            "SELECT id, hash FROM documents WHERE app_source = ? AND source_path = ?",
            parameters: ["Finder", filePath]
        )
        
        // Calculate file hash for change detection
        let currentHash = await calculateFileHash(fileURL)
        
        if let existing = existingFile.first {
            let existingHash = existing["hash"] as? String ?? ""
            if existingHash == currentHash {
                return // File unchanged, skip
            }
            stats.itemsUpdated += 1
        } else {
            stats.itemsCreated += 1
        }
        
        // Extract text content for searchable documents
        let textContent = await extractTextContent(from: fileURL, extension: fileExtension)
        
        // Create searchable content
        var contentParts: [String] = []
        contentParts.append(fileName)
        if let content = textContent, !content.isEmpty {
            contentParts.append(content)
        }
        
        let searchableContent = contentParts.joined(separator: "\n")
        
        let docData: [String: Any] = [
            "id": documentId,
            "type": "file",
            "title": fileName,
            "content": searchableContent,
            "app_source": "Finder",
            "source_id": filePath,
            "source_path": filePath,
            "hash": currentHash,
            "created_at": Int(resourceValues.creationDate?.timeIntervalSince1970 ?? now),
            "updated_at": Int(resourceValues.contentModificationDate?.timeIntervalSince1970 ?? now),
            "last_seen_at": now,
            "deleted": false
        ]
        
        if database.insert("documents", data: docData) {
            let fileData: [String: Any] = [
                "document_id": documentId,
                "file_path": filePath,
                "filename": fileName,
                "file_extension": fileExtension,
                "file_size": resourceValues.fileSize ?? 0,
                "mime_type": resourceValues.contentType?.preferredMIMEType ?? NSNull(),
                "parent_directory": fileURL.deletingLastPathComponent().path,
                "is_directory": false,
                "creation_date": Int(resourceValues.creationDate?.timeIntervalSince1970 ?? now),
                "modification_date": Int(resourceValues.contentModificationDate?.timeIntervalSince1970 ?? now),
                "spotlight_content": textContent ?? NSNull()
            ]
            
            if !database.insert("files", data: fileData) {
                stats.errors += 1
            }
        } else {
            stats.errors += 1
        }
        
        stats.itemsProcessed += 1
    }
    
    private func calculateFileHash(_ fileURL: URL) async -> String {
        do {
            let data = try Data(contentsOf: fileURL)
            return data.sha256Hash()
        } catch {
            // For large files or errors, use file path + modification date as hash
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let modDate = attributes[.modificationDate] as? Date ?? Date()
                return "\(fileURL.path)\(modDate.timeIntervalSince1970)".sha256()
            } catch {
                return fileURL.path.sha256()
            }
        }
    }
    
    private func extractTextContent(from fileURL: URL, extension: String) async -> String? {
        // Extract text content based on file type
        switch extension {
        case "txt", "md", "markdown", "rtf":
            return try? String(contentsOf: fileURL, encoding: .utf8)
            
        case "pdf":
            return await extractPDFText(from: fileURL)
            
        case "docx", "doc":
            return await extractDocumentText(from: fileURL)
            
        case "json":
            if let jsonData = try? Data(contentsOf: fileURL),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData),
               let jsonString = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
               let content = String(data: jsonString, encoding: .utf8) {
                return content
            }
            
        default:
            // For other files, try reading as text (will fail gracefully for binary files)
            return try? String(contentsOf: fileURL, encoding: .utf8)
        }
        
        return nil
    }
    
    private func extractPDFText(from fileURL: URL) async -> String? {
        // Basic PDF text extraction using PDFKit would go here
        // For now, return nil - would need to import PDFKit
        return nil
    }
    
    private func extractDocumentText(from fileURL: URL) async -> String? {
        // Document text extraction would go here
        // Could use Spotlight metadata or third-party libraries
        return nil
    }
}

// MARK: - Data Extensions
extension Data {
    func sha256Hash() -> String {
        #if canImport(CryptoKit)
        import CryptoKit
        let digest = SHA256.hash(data: self)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        import CommonCrypto
        let hash = self.withUnsafeBytes { bytes in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(self.count), &hash)
            return hash
        }
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}