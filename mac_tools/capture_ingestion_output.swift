#!/usr/bin/env swift

import Foundation

print("=== Capturing Full Ingestion Output ===")

let task = Process()
task.launchPath = "/usr/bin/swift"
task.arguments = [
    "run", "db_cli", "ingest_full",
    "--operation-hash", "0c4df3e13cc6ae36b38a21402487e2f8104ba6d7885586249ae6bb325bbdaad3"
]
task.currentDirectoryPath = "/Users/joshwlim/Documents/Kenny/mac_tools"

let outputPipe = Pipe()
let errorPipe = Pipe()
task.standardOutput = outputPipe
task.standardError = errorPipe

print("Starting process...")
task.launch()
task.waitUntilExit()

let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

print("\n=== STDOUT ===")
if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
    print(output)
} else {
    print("(No stdout output)")
}

print("\n=== STDERR ===")  
if let error = String(data: errorData, encoding: .utf8), !error.isEmpty {
    print(error)
} else {
    print("(No stderr output)")
}

print("\n=== Process Exit Code: \(task.terminationStatus) ===")

print("\nThis will show us exactly what's happening during ingestion.")