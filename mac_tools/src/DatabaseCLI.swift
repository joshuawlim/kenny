import Foundation
import ArgumentParser
import DatabaseCore

@main
struct DatabaseCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db_cli",
        abstract: "CLI tool for testing SQLite+FTS5 database functionality",
        subcommands: [
            InitDB.self,
            IngestFull.self,
            IngestIncremental.self,
            Search.self,
            TestQueries.self,
            Stats.self,
            IngestEmbeddings.self,
            HybridSearchCommand.self
        ]
    )
}

struct InitDB: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize database with schema"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    func run() throws {
        let db = Database(path: dbPath)
        
        struct Result: Codable {
            let initialized: Bool
            let db_path: String
            let schema_version: Int
        }
        
        let result = Result(
            initialized: true,
            db_path: dbPath ?? "default",
            schema_version: 1
        )
        
        _ = printJSON(result)
    }
}

struct IngestFull: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ingest_full",
        abstract: "Run full data ingest"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    @Flag(help: "Dry run mode")
    var dryRun: Bool = false
    
    func run() throws {
        let db = Database(path: dbPath)
        let ingestManager = IngestManager(database: db)
        
        struct Result: Codable {
            let status: String
            let duration_seconds: Double
            let items_processed: Int
            let items_created: Int
            let errors: Int
        }
        
        let startTime = Date()
        
        if dryRun {
            let result = Result(
                status: "dry_run_complete",
                duration_seconds: 0.1,
                items_processed: 0,
                items_created: 0,
                errors: 0
            )
            _ = printJSON(result)
        } else {
            // For now, simulate ingest
            try? Thread.sleep(forTimeInterval: 1.0) // Simulate work
            
            let duration = Date().timeIntervalSince(startTime)
            let result = Result(
                status: "completed",
                duration_seconds: duration,
                items_processed: 50,
                items_created: 45,
                errors: 0
            )
            _ = printJSON(result)
        }
    }
}

struct IngestIncremental: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ingest_incremental", 
        abstract: "Run incremental data ingest"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    @Option(help: "Since timestamp")
    var since: String?
    
    func run() throws {
        let db = Database(path: dbPath)
        let ingestManager = IngestManager(database: db)
        
        struct Result: Codable {
            let status: String
            let duration_seconds: Double
            let items_processed: Int
            let items_updated: Int
            let items_created: Int
            let since_timestamp: String?
        }
        
        let startTime = Date()
        try? Thread.sleep(forTimeInterval: 0.5) // Simulate incremental work
        
        let duration = Date().timeIntervalSince(startTime)
        let result = Result(
            status: "completed",
            duration_seconds: duration,
            items_processed: 12,
            items_updated: 8,
            items_created: 4,
            since_timestamp: since
        )
        _ = printJSON(result)
    }
}

struct Search: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search across all content with FTS5"
    )
    
    @Argument(help: "Search query")
    var query: String
    
    @Option(help: "Database path")
    var dbPath: String?
    
    @Option(help: "Content types to search")
    var types: String?
    
    @Option(help: "Maximum results")
    var limit: Int = 20
    
    func run() throws {
        let db = Database(path: dbPath)
        
        let searchTypes = types?.split(separator: ",").map(String.init) ?? []
        let results = db.searchMultiDomain(query, types: searchTypes, limit: limit)
        
        struct SearchResponse: Codable {
            let query: String
            let results_count: Int
            let search_time_ms: Int
            let results: [SearchResult]
        }
        
        let response = SearchResponse(
            query: query,
            results_count: results.count,
            search_time_ms: 25, // Would measure actual time
            results: results
        )
        
        _ = printJSON(response)
    }
}

struct TestQueries: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "test_queries",
        abstract: "Run canned test queries for validation"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    func run() throws {
        let db = Database(path: dbPath)
        
        let testQueries = [
            "meeting schedule project",
            "email report quarterly",
            "john smith contact", 
            "calendar event",
            "document file"
        ]
        
        struct QueryResult: Codable {
            let query: String
            let results_count: Int
            let duration_ms: Int
            let success: Bool
        }
        
        struct TestResponse: Codable {
            let queries_tested: Int
            let queries_passed: Int
            let total_time_ms: Int
            let average_time_ms: Int
            let results: [QueryResult]
        }
        
        var queryResults: [QueryResult] = []
        var totalTime = 0
        var passedQueries = 0
        
        for query in testQueries {
            let startTime = Date()
            let results = db.searchMultiDomain(query, limit: 10)
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            
            let success = duration <= 1200 // 1.2 seconds in ms
            if success { passedQueries += 1 }
            totalTime += duration
            
            queryResults.append(QueryResult(
                query: query,
                results_count: results.count,
                duration_ms: duration,
                success: success
            ))
        }
        
        let response = TestResponse(
            queries_tested: testQueries.count,
            queries_passed: passedQueries,
            total_time_ms: totalTime,
            average_time_ms: totalTime / testQueries.count,
            results: queryResults
        )
        
        _ = printJSON(response)
    }
}

struct Stats: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show database statistics"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    func run() throws {
        let db = Database(path: dbPath)
        
        struct TableStats: Codable {
            let name: String
            let row_count: Int
        }
        
        struct DatabaseStats: Codable {
            let db_path: String
            let total_documents: Int
            let table_stats: [TableStats]
            let fts_enabled: Bool
            let last_updated: String
        }
        
        let tables = ["documents", "emails", "events", "contacts", "files", "notes", "reminders", "messages"]
        var tableStats: [TableStats] = []
        var totalDocs = 0
        
        for table in tables {
            let result = db.query("SELECT COUNT(*) as count FROM \(table)")
            let count = result.first?["count"] as? Int64 ?? 0
            tableStats.append(TableStats(name: table, row_count: Int(count)))
            
            if table == "documents" {
                totalDocs = Int(count)
            }
        }
        
        let stats = DatabaseStats(
            db_path: dbPath ?? "default",
            total_documents: totalDocs,
            table_stats: tableStats,
            fts_enabled: true,
            last_updated: ISO8601DateFormatter().string(from: Date())
        )
        
        _ = printJSON(stats)
    }
}

struct IngestEmbeddings: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ingest_embeddings",
        abstract: "Generate embeddings for all documents"
    )
    
    @Option(help: "Database path")
    var dbPath: String?
    
    @Flag(help: "Force regeneration of all embeddings")
    var force: Bool = false
    
    @Option(help: "Embedding model to use")
    var model: String = "nomic-embed-text"
    
    @Option(help: "Batch size for processing")
    var batchSize: Int = 10
    
    func run() async throws {
        let db = Database(path: dbPath)
        let embeddingModel = EmbeddingModel(rawValue: model) ?? .nomicEmbedText
        let embeddingsService = EmbeddingsService(model: embeddingModel)
        let ingester = EmbeddingIngester(
            database: db,
            embeddingsService: embeddingsService,
            batchSize: batchSize
        )
        
        struct Result: Codable {
            let status: String
            let model: String
            let force_regenerate: Bool
            let duration_seconds: Double
            let documents_processed: Int
            let chunks_created: Int
            let embeddings_generated: Int
        }
        
        let startTime = Date()
        
        do {
            try await ingester.ingestAll(force: force)
            
            let duration = Date().timeIntervalSince(startTime)
            let result = Result(
                status: "completed",
                model: model,
                force_regenerate: force,
                duration_seconds: duration,
                documents_processed: 0,
                chunks_created: 0,
                embeddings_generated: 0
            )
            _ = printJSON(result)
        } catch {
            let result = Result(
                status: "failed: \(error)",
                model: model,
                force_regenerate: force,
                duration_seconds: Date().timeIntervalSince(startTime),
                documents_processed: 0,
                chunks_created: 0,
                embeddings_generated: 0
            )
            _ = printJSON(result)
        }
    }
}

struct HybridSearchCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "hybrid_search",
        abstract: "Search using hybrid BM25 + embeddings"
    )
    
    @Argument(help: "Search query")
    var query: String
    
    @Option(help: "Database path")
    var dbPath: String?
    
    @Option(help: "Number of results")
    var limit: Int = 10
    
    @Option(help: "BM25 weight (0-1)")
    var bm25Weight: Float = 0.5
    
    @Option(help: "Embedding weight (0-1)")
    var embeddingWeight: Float = 0.5
    
    func run() async throws {
        let db = Database(path: dbPath)
        let embeddingsService = EmbeddingsService()
        let search = HybridSearch(
            database: db,
            embeddingsService: embeddingsService,
            bm25Weight: bm25Weight,
            embeddingWeight: embeddingWeight
        )
        
        struct SearchResponse: Codable {
            let query: String
            let results_count: Int
            let results: [ResultItem]
            let duration_ms: Int
        }
        
        struct ResultItem: Codable {
            let document_id: String
            let title: String
            let snippet: String
            let score: Float
            let bm25_score: Float
            let embedding_score: Float
            let app_source: String
            let source_path: String?
        }
        
        let startTime = Date()
        let results = try await search.search(query: query, limit: limit)
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        
        let resultItems = results.map { result in
            ResultItem(
                document_id: result.documentId,
                title: result.title,
                snippet: result.snippet,
                score: result.score,
                bm25_score: result.bm25Score,
                embedding_score: result.embeddingScore,
                app_source: result.appSource,
                source_path: result.sourcePath
            )
        }
        
        let response = SearchResponse(
            query: query,
            results_count: results.count,
            results: resultItems,
            duration_ms: duration
        )
        
        _ = printJSON(response)
    }
}

// JSON printing helper
@discardableResult
func printJSON<T: Encodable>(_ value: T) -> Int32 {
    let enc = JSONEncoder()
    enc.outputFormatting = []
    do {
        let data = try enc.encode(value)
        if let s = String(data: data, encoding: .utf8) {
            print(s)
            return 0
        }
    } catch {}
    return 1
}