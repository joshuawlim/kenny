#!/usr/bin/env swift

// Direct test of IngestManager.runFullIngest() to see specific error

import Foundation

let task = Process()
task.launchPath = "/Users/joshwlim/Documents/Kenny/mac_tools/.build/release/db_cli"
task.arguments = ["ingest_full", "--operation-hash", "0c4df3e13cc6ae36b38a21402487e2f8104ba6d7885586249ae6bb325bbdaad3"]

let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe

print("🧪 Testing IngestManager runFullIngest directly...")
task.launch()
task.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
if let output = String(data: data, encoding: .utf8) {
    print("Full output:")
    print(output)
} else {
    print("No output")
}

print("Exit code: \(task.terminationStatus)")

// Also check what's in the database now
print("\n📊 Database state after attempted ingestion:")
let dbTask = Process()
dbTask.launchPath = "/usr/bin/sqlite3"
dbTask.arguments = ["\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db", 
                   "SELECT type, COUNT(*) FROM documents GROUP BY type;"]

let dbPipe = Pipe()
dbTask.standardOutput = dbPipe

dbTask.launch()
dbTask.waitUntilExit()

let dbData = dbPipe.fileHandleForReading.readDataToEndOfFile()
if let dbOutput = String(data: dbData, encoding: .utf8) {
    print(dbOutput)
}