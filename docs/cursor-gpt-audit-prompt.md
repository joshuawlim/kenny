# Cursor GPT Audit Prompt for Kenny Personal Assistant

## Context
You are auditing the Kenny personal assistant project after critical failures were discovered during Week 5 validation. The system claims to be a "local-first, macOS-native AI management assistant" but fundamental data ingestion and search systems are broken.

## System Overview
Kenny is a Swift-based macOS application designed to:
- Integrate with 8 Apple apps (Mail, Messages, Contacts, Calendar, Files, Notes, Reminders, WhatsApp)
- Ingest user data into SQLite database with FTS5 search
- Provide AI assistant capabilities via orchestration layer
- Maintain local-only processing with no cloud dependencies

## Critical Issues Discovered

### Data Ingestion Failure (99% Failure Rate)
- **Expected**: 5,495+ emails, 30,102+ messages, hundreds of contacts
- **Actual**: 0 emails, 19 messages, 1 event, 0 contacts, 0 files
- **Root Cause**: Date filtering bugs in ingestion code

### Search System Broken (0% Success Rate)  
- All searches return 0 results despite data in database
- Cannot find "Courtney", "Mrs Jacobs", "spa" from visible user data
- Documents inserted with empty titles/content fields

### Database Migration Failures
- "Failed to create basic schema" fatal error
- Cannot initialize clean database or test fixes

## Audit Focus Areas

### 1. Code Quality & Architecture Review
**Examine these key files:**
- `/mac_tools/src/MessagesIngester.swift` - Date filtering logic
- `/mac_tools/src/MailIngester.swift` - AppleScript limitations  
- `/mac_tools/src/Database.swift` - Schema migration system
- `/mac_tools/src/IngestManager.swift` - Orchestration of ingestion
- `/mac_tools/src/DatabaseCLI.swift` - CLI interface and error handling

**Look for:**
- Date/timestamp calculation errors (especially Messages epoch conversion)
- Artificial limits in data processing (e.g., 500/100 message limits)
- Error handling that fails silently
- Database schema conflicts or corruption
- Async/await issues causing crashes

### 2. Data Validation & Testing Gaps
**Assess:**
- How was testing performed that missed 99% data ingestion failure?
- Why were performance claims based on synthetic vs. real data?
- What validation gaps allowed broken search to be considered "working"?
- How can testing be improved to catch real-world failures?

**Check test files and validation scripts for:**
- Use of synthetic vs. real user data
- Realistic data volume testing (1000s vs. dozens of items)
- End-to-end validation coverage
- Search functionality verification

### 3. Requirements vs. Implementation Gap
**Analyze disconnect between:**
- Claimed capabilities ("Full Apple app data extraction") vs. reality (0% success rate)
- Performance benchmarks vs. actual performance with real data
- "Week 1-5 Foundation ✅" status vs. fundamental system failure
- Architecture claims vs. implementation reality

### 4. Fix Implementation Assessment
**Review the implemented but untested fix:**
```swift
// In MessagesIngester.swift - date calculation fix
let sinceTimestamp = if let since = since {
    since.timeIntervalSince1970 - 978307200
} else {
    0.0 // For full sync, start from beginning
}
```

**Evaluate:**
- Is this fix correct for Messages database epoch (2001 vs 1970)?
- Are similar fixes needed in other ingesters?
- What other date/timestamp issues might exist?
- How can the database migration system be repaired?

## Questions to Answer

### Technical Questions
1. **Root Cause Analysis**: What are ALL the reasons ingestion fails? Is it just date filtering?
2. **Search Failure**: Why do documents have empty titles/content? Where in the ingestion pipeline does this break?
3. **Database Issues**: What's causing schema migration failures? How can this be fixed?
4. **Error Handling**: Why do failures happen silently instead of showing clear errors?

### Process Questions  
1. **Testing Methodology**: How did such fundamental failures go undetected through "Week 1-5"?
2. **Validation Strategy**: What testing approach would catch these issues earlier?
3. **Quality Assurance**: What code review processes could prevent date calculation bugs?
4. **Real Data Testing**: How can the project ensure all testing uses actual user data volumes?

### Strategic Questions
1. **Recovery Plan**: What's the most efficient path to fix the foundation?
2. **Architecture Review**: Are there fundamental design flaws beyond implementation bugs?
3. **Timeline Impact**: How does this affect the 10-week roadmap?
4. **Risk Mitigation**: How can similar failures be prevented in Weeks 6-10?

## Deliverables Requested

### 1. Technical Assessment (Priority 1)
- **Root cause analysis** of all ingestion failures
- **Database repair strategy** for schema migration issues  
- **Code fix recommendations** beyond the Messages ingester patch
- **Testing gaps analysis** with improvement recommendations

### 2. Process Improvements (Priority 2)
- **Testing protocol changes** to require real data validation
- **Code review checklist** for data processing components
- **Quality gates** to prevent similar failures reaching "completion"
- **Documentation standards** for accurate capability claims

### 3. Recovery Roadmap (Priority 3)
- **Prioritized fix sequence** for fastest path to working system
- **Validation milestones** with specific success criteria using real user data
- **Risk assessment** for remaining development timeline
- **Go/no-go criteria** for proceeding to Week 6+ features

## Success Criteria for Audit

The audit should result in:
1. **Complete understanding** of why ingestion fails with real data
2. **Actionable fix plan** to restore data ingestion and search
3. **Improved processes** to prevent similar failures
4. **Realistic assessment** of project health and timeline

## Context Files to Review

Key files are in `/Users/joshwlim/Documents/Kenny/`:
- `README.md` - Updated with critical issues
- `CHANGELOG.md` - Week 5 failure documentation  
- `docs/status/week5-critical-issues.md` - Detailed failure analysis
- `mac_tools/src/*.swift` - Source code with ingestion logic
- `mac_tools/Package.swift` - Build configuration

## Expected Outcome

A comprehensive audit report that helps Kenny's development team understand what went wrong, how to fix it efficiently, and how to prevent similar failures in the future. The focus should be on practical, actionable recommendations that restore system functionality with real user data.