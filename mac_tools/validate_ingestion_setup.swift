#!/usr/bin/env swift

import Foundation
import SQLite3
import Contacts
import EventKit

print("=== Kenny Ingestion System Validation ===")
print("Date: \(Date())")
print("")

// MARK: - 1. Binary & Permissions Validation
print("1. BINARY & TCC PERMISSIONS")
print("   Current executable: \(CommandLine.arguments[0])")
print("   Process ID: \(ProcessInfo.processInfo.processIdentifier)")
print("   Build path: \(Bundle.main.bundlePath)")

// Check TCC permissions
print("\n   TCC Status:")
print("   - Contacts: \(CNContactStore.authorizationStatus(for: .contacts))")
print("   - Calendar: \(EKEventStore.authorizationStatus(for: .event))")
print("   - Reminders: \(EKEventStore.authorizationStatus(for: .reminder))")

// Check Full Disk Access
let messagesDBPath = "\(NSHomeDirectory())/Library/Messages/chat.db"
if FileManager.default.isReadableFile(atPath: messagesDBPath) {
    print("   - Full Disk Access: ✅ (can read Messages DB)")
} else {
    print("   - Full Disk Access: ❌ (cannot read Messages DB)")
}

// MARK: - 2. Messages Database Validation
print("\n2. MESSAGES DATABASE")
if FileManager.default.fileExists(atPath: messagesDBPath) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: messagesDBPath)
    let size = (attrs?[.size] as? Int64 ?? 0) / 1024 / 1024
    let modDate = attrs?[.modificationDate] as? Date ?? Date()
    print("   - Path: \(messagesDBPath)")
    print("   - Size: \(size) MB")
    print("   - Modified: \(modDate)")
    
    // Check for WAL mode files
    let walPath = messagesDBPath + "-wal"
    let shmPath = messagesDBPath + "-shm"
    print("   - WAL file exists: \(FileManager.default.fileExists(atPath: walPath))")
    print("   - SHM file exists: \(FileManager.default.fileExists(atPath: shmPath))")
    
    // Test database access
    var db: OpaquePointer?
    if sqlite3_open_v2(messagesDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
        // Set busy timeout
        sqlite3_busy_timeout(db, 5000) // 5 seconds
        
        // Check schema
        print("\n   Schema Check:")
        var stmt: OpaquePointer?
        
        // Check message table columns
        if sqlite3_prepare_v2(db, "PRAGMA table_info(message)", -1, &stmt, nil) == SQLITE_OK {
            var columns: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    columns.append(String(cString: name))
                }
            }
            print("   - message columns: \(columns.prefix(10).joined(separator: ", "))...")
            sqlite3_finalize(stmt)
        }
        
        // Test baseline counts
        print("\n   Baseline Counts:")
        
        // 1. Raw message count
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            let count = sqlite3_column_int(stmt, 0)
            print("   - Total messages: \(count)")
            sqlite3_finalize(stmt)
        }
        
        // 2. Messages with text
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message WHERE text IS NOT NULL AND length(text) > 0", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            let count = sqlite3_column_int(stmt, 0)
            print("   - Messages with text: \(count)")
            sqlite3_finalize(stmt)
        }
        
        // 3. Check date range (Mac Absolute Time)
        if sqlite3_prepare_v2(db, "SELECT MIN(date), MAX(date) FROM message WHERE date > 0", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            let minDate = sqlite3_column_double(stmt, 0)
            let maxDate = sqlite3_column_double(stmt, 1)
            
            // Convert from nanoseconds since 2001 to readable dates
            let minUnix = (minDate / 1_000_000_000) + 978307200
            let maxUnix = (maxDate / 1_000_000_000) + 978307200
            
            print("   - Date range: \(Date(timeIntervalSince1970: minUnix)) to \(Date(timeIntervalSince1970: maxUnix))")
            print("   - Raw min: \(minDate) max: \(maxDate)")
            sqlite3_finalize(stmt)
        }
        
        // 4. Test join with handle
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            let count = sqlite3_column_int(stmt, 0)
            print("   - After JOIN handle: \(count)")
            sqlite3_finalize(stmt)
        }
        
        // 5. Test full join chain
        let fullQuery = """
            SELECT COUNT(*) FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        """
        if sqlite3_prepare_v2(db, fullQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            let count = sqlite3_column_int(stmt, 0)
            print("   - After full JOINs: \(count)")
            sqlite3_finalize(stmt)
        }
        
        sqlite3_close(db)
    } else {
        print("   ❌ Cannot open Messages database")
    }
} else {
    print("   ❌ Messages database not found")
}

// MARK: - 3. Contacts Validation
print("\n3. CONTACTS")
let store = CNContactStore()
let status = CNContactStore.authorizationStatus(for: .contacts)

if status == .authorized {
    print("   ✅ Authorized")
    
    // Test minimal enumeration
    let minimalKeys = [CNContactIdentifierKey, CNContactGivenNameKey] as [CNKeyDescriptor]
    let request = CNContactFetchRequest(keysToFetch: minimalKeys)
    
    var count = 0
    var error: Error?
    
    // Use a semaphore to ensure enumeration completes
    let semaphore = DispatchSemaphore(value: 0)
    
    DispatchQueue.global().async {
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                count += 1
                if count >= 10 {
                    stop.pointee = true
                }
            }
        } catch let err {
            error = err
        }
        semaphore.signal()
    }
    
    // Wait for enumeration (with timeout)
    let result = semaphore.wait(timeout: .now() + 5)
    
    if result == .success {
        if let error = error {
            print("   ❌ Enumeration error: \(error)")
        } else {
            print("   ✅ Can enumerate: found \(count) contacts")
        }
    } else {
        print("   ❌ Enumeration timeout - runloop issue?")
    }
} else {
    print("   ❌ Not authorized: \(status)")
}

// MARK: - 4. Process & Runloop Check
print("\n4. PROCESS & RUNLOOP")
print("   - Main thread: \(Thread.isMainThread)")
print("   - RunLoop mode: \(RunLoop.current.currentMode?.rawValue ?? "none")")
print("   - Process will exit: Check if CLI exits before async work completes")

// MARK: - 5. SQLite Safety Recommendations
print("\n5. SQLITE SAFETY")
print("   ⚠️  Recommendations:")
print("   - Use sqlite3_backup API or copy DB files before querying")
print("   - Set busy_timeout for concurrent access")
print("   - Handle WAL mode properly (copy -wal and -shm files)")
print("   - Use transactions for batch inserts")

// MARK: - 6. Automation Permissions
print("\n6. AUTOMATION (AppleScript)")
print("   Check System Settings > Privacy & Security > Automation")
print("   Ensure Terminal/iTerm has toggles for:")
print("   - Mail")
print("   - Notes")
print("   Current apps that can be automated: [requires manual check]")

print("\n=== END VALIDATION ===")