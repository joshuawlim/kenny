#!/usr/bin/env swift

// Debug the exact search query being executed

import Foundation

let dbPath = "\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db"

// This is the exact SQL from Database.swift searchMultiDomain
let sql = """
SELECT d.*, 
       snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as search_snippet,
       bm25(documents_fts) as rank,
       CASE d.type
           WHEN 'email' THEN COALESCE(e.from_name, '') || ' <' || COALESCE(e.from_address, '') || '>'
           WHEN 'event' THEN COALESCE(ev.location, '')
           WHEN 'file' THEN COALESCE(f.parent_directory, '') || '/' || d.title
           ELSE d.app_source
       END as context_info
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
LEFT JOIN emails e ON d.id = e.document_id
LEFT JOIN events ev ON d.id = ev.document_id  
LEFT JOIN files f ON d.id = f.document_id
WHERE documents_fts MATCH ?
ORDER BY rank
LIMIT ?
"""

print("🧪 Testing exact search SQL from Database.swift")
print("============================================")

// Test with parameters just like Swift code does
let task = Process()
task.launchPath = "/usr/bin/sqlite3"
task.arguments = ["-separator", "\t", dbPath, 
                 """
.param set 1 "january 2025"
.param set 2 20
\(sql)
"""]

let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe

task.launch()
task.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
if let output = String(data: data, encoding: .utf8) {
    if output.isEmpty {
        print("❌ No results from parameterized query")
    } else {
        print("✅ Results from parameterized query:")
        print(output)
    }
} else {
    print("❌ No output")
}

print("Exit code: \(task.terminationStatus)")

// Also test simplified version
print("\n🧪 Testing simplified search...")
let simpleTask = Process()
simpleTask.launchPath = "/usr/bin/sqlite3"
simpleTask.arguments = [dbPath, "SELECT d.id, d.title FROM documents_fts JOIN documents d ON documents_fts.rowid = d.rowid WHERE documents_fts MATCH 'january 2025';"]

let simplePipe = Pipe()
simpleTask.standardOutput = simplePipe

simpleTask.launch()
simpleTask.waitUntilExit()

let simpleData = simplePipe.fileHandleForReading.readDataToEndOfFile()
if let simpleOutput = String(data: simpleData, encoding: .utf8) {
    print("Simple query result: \(simpleOutput)")
}