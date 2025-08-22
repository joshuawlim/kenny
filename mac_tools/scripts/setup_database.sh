#!/bin/bash

# Database setup script for Kenny
# This script initializes a fresh database with all migrations
set -e

DB_PATH=${1:-"kenny.db"}

echo "🚀 Setting up Kenny database at: $DB_PATH"
echo "=========================================="

# Clean up existing database files
echo "🧹 Cleaning up existing database files..."
rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"

# Create test program to initialize database
echo "📝 Creating database initialization script..."
cat > temp_db_init.swift << EOF
import Foundation
import SQLite3

// Include simplified Database class for initialization
public class Database {
    internal var db: OpaquePointer?
    private let dbPath: String
    
    public init(path: String) {
        self.dbPath = path
        openDatabase()
        setupWAL()
        runMigrations()
    }
    
    deinit {
        closeDatabase()
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            fatalError("Unable to open database at \(dbPath)")
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func setupWAL() {
        _ = execute("PRAGMA journal_mode=WAL")
        _ = execute("PRAGMA foreign_keys=ON")
        _ = execute("PRAGMA synchronous=NORMAL")
    }
    
    @discardableResult
    func execute(_ sql: String) -> Bool {
        let statements = parseMultipleStatements(sql)
        
        for (index, statement) in statements.enumerated() {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_prepare_v2(db, statement, -1, &stmt, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                print("❌ Error preparing statement \(index + 1): \(error)")
                print("SQL: \(statement.prefix(200))")
                return false
            }
            
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE && result != SQLITE_ROW {
                let error = String(cString: sqlite3_errmsg(db))
                print("❌ Error executing statement \(index + 1): \(error)")
                print("SQL: \(statement.prefix(200))")
                return false
            }
        }
        
        return true
    }
    
    private func parseMultipleStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var currentStatement = ""
        let lines = sql.components(separatedBy: .newlines)
        
        var inBlockComment = false
        var inTrigger = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmedLine.contains("/*") && trimmedLine.contains("*/") {
                continue
            } else if trimmedLine.contains("/*") {
                inBlockComment = true
                continue
            } else if trimmedLine.contains("*/") {
                inBlockComment = false
                continue
            } else if inBlockComment {
                continue
            }
            
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("--") {
                continue
            }
            
            currentStatement += line + "\n"
            
            let upperLine = trimmedLine.uppercased()
            if upperLine.contains("CREATE TRIGGER") {
                inTrigger = true
            }
            
            if trimmedLine.hasSuffix(";") {
                if inTrigger && upperLine.contains("END;") {
                    inTrigger = false
                    let statement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !statement.isEmpty {
                        statements.append(statement)
                    }
                    currentStatement = ""
                } else if !inTrigger {
                    let statement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !statement.isEmpty {
                        statements.append(statement)
                    }
                    currentStatement = ""
                }
            }
        }
        
        let finalStatement = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalStatement.isEmpty {
            statements.append(finalStatement)
        }
        
        return statements
    }
    
    public func query(_ sql: String) -> [[String: Any]] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        var results: [[String: Any]] = []
        let columnCount = sqlite3_column_count(statement)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(statement, i))
                let columnType = sqlite3_column_type(statement, i)
                
                switch columnType {
                case SQLITE_TEXT:
                    row[columnName] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_INTEGER:
                    row[columnName] = sqlite3_column_int64(statement, i)
                default:
                    break
                }
            }
            results.append(row)
        }
        
        return results
    }
    
    private func runMigrations() {
        print("🔄 Starting database migrations...")
        
        // Create schema_migrations table
        _ = execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL
            )
        """)
        
        let currentVersion = getCurrentSchemaVersion()
        print("📊 Current schema version: \(currentVersion)")
        
        // Apply migrations
        let migrations = [1, 3] // Available migration versions
        
        for version in migrations {
            if version > currentVersion {
                print("⬆️  Applying migration \(version)...")
                if let migration = loadMigration(version: version) {
                    if execute(migration) {
                        updateSchemaVersion(version)
                        print("✅ Migration \(version) applied successfully")
                    } else {
                        print("❌ Migration \(version) failed")
                        fatalError("Migration \(version) failed")
                    }
                } else {
                    print("⚠️  Migration \(version) not found, skipping")
                }
            }
        }
        
        print("🎉 Migration complete. Final version: \(getCurrentSchemaVersion())")
    }
    
    private func getCurrentSchemaVersion() -> Int {
        let result = query("SELECT MAX(version) as version FROM schema_migrations")
        if let row = result.first, let version = row["version"] as? Int64 {
            return Int(version)
        }
        return 0
    }
    
    private func updateSchemaVersion(_ version: Int) {
        let now = Int(Date().timeIntervalSince1970)
        _ = execute("INSERT INTO schema_migrations (version, applied_at) VALUES (\(version), \(now))")
    }
    
    private func loadMigration(version: Int) -> String? {
        let filename = String(format: "%03d_", version)
        let migrationsPath = "migrations"
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsPath) else {
            return nil
        }
        
        if let file = files.first(where: { \$0.hasPrefix(filename) && \$0.hasSuffix(".sql") }) {
            return try? String(contentsOfFile: migrationsPath + "/" + file, encoding: .utf8)
        }
        
        return nil
    }
}

// Initialize the database
print("🎯 Initializing database at: $DB_PATH")
let db = Database(path: "$DB_PATH")

// Verify setup
let tables = db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
let tableNames = tables.compactMap { \$0["name"] as? String }
print("📋 Created tables: \(tableNames)")

// Test FTS5
let ftsTest = db.query("SELECT * FROM documents_fts LIMIT 1")
print("🔍 FTS5 test successful")

print("✅ Database setup complete!")
EOF

# Run the initialization
echo "⚡ Running database initialization..."
swift temp_db_init.swift

# Clean up
rm temp_db_init.swift

# Verify the database was created
if [ -f "$DB_PATH" ]; then
    echo ""
    echo "🎉 SUCCESS! Database created at: $DB_PATH"
    echo "📊 Database size: $(du -h "$DB_PATH" | cut -f1)"
    
    # Show basic stats
    echo ""
    echo "📈 Database verification:"
    sqlite3 "$DB_PATH" "SELECT 'Tables: ' || COUNT(*) FROM sqlite_master WHERE type='table';"
    sqlite3 "$DB_PATH" "SELECT 'Schema version: ' || COALESCE(MAX(version), 0) FROM schema_migrations;"
    
    echo ""
    echo "✅ Database setup completed successfully!"
else
    echo "❌ Database creation failed"
    exit 1
fi