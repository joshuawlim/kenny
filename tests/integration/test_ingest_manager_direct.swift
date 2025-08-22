#!/usr/bin/env swift

// Test calling IngestManager directly
import Foundation

// Since we can't easily import the IngestManager module, let's test if 
// the db_cli calendar ingestion is working by running it with debug output

print("🔍 Testing db_cli calendar ingestion directly...")

// Check what happens when we run just calendar ingestion (if such option exists)
let task = Process()
task.launchPath = "/Users/joshwlim/Documents/Kenny/.build/release/db_cli"
task.arguments = ["ingest_full"]  // We'll see the output

let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe

print("Starting db_cli ingest_full...")
task.launch()
task.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
if let output = String(data: data, encoding: .utf8) {
    print("Output:")
    print(output)
}

print("Exit code: \(task.terminationStatus)")

// Now check database state
print("\n🔍 Checking database after ingestion...")
let checkTask = Process()
checkTask.launchPath = "/usr/bin/sqlite3"
checkTask.arguments = ["\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db", 
                      "SELECT COUNT(*) FROM documents WHERE type='event';"]

let checkPipe = Pipe()
checkTask.standardOutput = checkPipe

checkTask.launch()
checkTask.waitUntilExit()

let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
if let checkOutput = String(data: checkData, encoding: .utf8) {
    let count = checkOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    print("Event documents in database: \(count)")
}

// Also check events table
let eventsTask = Process()
eventsTask.launchPath = "/usr/bin/sqlite3"
eventsTask.arguments = ["\(NSHomeDirectory())/Library/Application Support/Assistant/assistant.db", 
                       "SELECT COUNT(*) FROM events;"]

let eventsPipe = Pipe()
eventsTask.standardOutput = eventsPipe

eventsTask.launch()
eventsTask.waitUntilExit()

let eventsData = eventsPipe.fileHandleForReading.readDataToEndOfFile()
if let eventsOutput = String(data: eventsData, encoding: .utf8) {
    let count = eventsOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    print("Events table entries: \(count)")
}