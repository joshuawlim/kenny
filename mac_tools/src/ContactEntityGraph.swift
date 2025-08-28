import Foundation
import SQLite3
import os.log

/// Contact Entity Relationship Graph with confidence scoring
/// Tracks relationships between contacts across conversations and platforms
/// Provides cross-platform contact identity resolution
public class ContactEntityGraph {
    private let database: Database
    private let logger = Logger(subsystem: "Kenny.ContactEntityGraph", category: "Graph")
    
    // Configuration
    private let minConfidenceThreshold: Double = 0.6
    private let maxRelationshipAge: TimeInterval = 86400 * 365 // 1 year
    
    public init(database: Database) {
        self.database = database
        setupGraphTables()
    }
    
    // MARK: - Database Schema Setup
    
    private func setupGraphTables() {
        let sql = """
        -- Contact entities with cross-platform identity resolution
        CREATE TABLE IF NOT EXISTS contact_entities (
            entity_id TEXT PRIMARY KEY,
            canonical_name TEXT NOT NULL,
            confidence_score REAL NOT NULL DEFAULT 0.0,
            platforms TEXT, -- JSON array of platforms
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        -- Contact identity mappings across platforms  
        CREATE TABLE IF NOT EXISTS contact_identities (
            identity_id TEXT PRIMARY KEY,
            entity_id TEXT NOT NULL,
            platform TEXT NOT NULL,
            platform_contact_id TEXT NOT NULL,
            display_name TEXT,
            confidence REAL NOT NULL DEFAULT 1.0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (entity_id) REFERENCES contact_entities(entity_id),
            UNIQUE(platform, platform_contact_id)
        );
        
        -- Relationship edges between contact entities
        CREATE TABLE IF NOT EXISTS contact_relationships (
            relationship_id TEXT PRIMARY KEY,
            entity_from TEXT NOT NULL,
            entity_to TEXT NOT NULL,
            relationship_type TEXT NOT NULL, -- communication, collaboration, etc.
            strength_score REAL NOT NULL DEFAULT 0.0,
            frequency_score REAL NOT NULL DEFAULT 0.0,
            recency_score REAL NOT NULL DEFAULT 0.0,
            total_interactions INTEGER DEFAULT 0,
            last_interaction TIMESTAMP,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (entity_from) REFERENCES contact_entities(entity_id),
            FOREIGN KEY (entity_to) REFERENCES contact_entities(entity_id),
            UNIQUE(entity_from, entity_to)
        );
        
        -- Communication events that build relationships
        CREATE TABLE IF NOT EXISTS communication_events (
            event_id TEXT PRIMARY KEY,
            entity_from TEXT,
            entity_to TEXT,
            event_type TEXT NOT NULL, -- email, message, calendar, etc.
            document_id TEXT,
            event_timestamp TIMESTAMP NOT NULL,
            interaction_strength REAL DEFAULT 1.0,
            metadata TEXT, -- JSON
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (entity_from) REFERENCES contact_entities(entity_id),
            FOREIGN KEY (entity_to) REFERENCES contact_entities(entity_id)
        );
        
        -- Indexes for performance
        CREATE INDEX IF NOT EXISTS idx_contact_identities_entity ON contact_identities(entity_id);
        CREATE INDEX IF NOT EXISTS idx_contact_identities_platform ON contact_identities(platform, platform_contact_id);
        CREATE INDEX IF NOT EXISTS idx_relationships_entities ON contact_relationships(entity_from, entity_to);
        CREATE INDEX IF NOT EXISTS idx_communication_events_entities ON communication_events(entity_from, entity_to);
        CREATE INDEX IF NOT EXISTS idx_communication_events_timestamp ON communication_events(event_timestamp);
        """
        
        _ = database.execute(sql)
        logger.info("Contact entity graph tables initialized")
    }
    
    // MARK: - Contact Entity Management
    
    /// Create or update a contact entity with cross-platform identity resolution
    public func upsertContactEntity(
        name: String,
        platform: String,
        platformContactId: String,
        additionalInfo: [String: Any] = [:]
    ) -> String {
        
        // Try to find existing entity through fuzzy matching
        if let existingEntity = findExistingEntity(for: name, platform: platform) {
            // Add new identity to existing entity
            addContactIdentity(
                entityId: existingEntity,
                platform: platform,
                platformContactId: platformContactId,
                displayName: name
            )
            return existingEntity
        }
        
        // Create new entity
        let entityId = UUID().uuidString
        let canonicalName = canonicalizeName(name)
        let platforms = [platform]
        
        let sql = """
        INSERT OR REPLACE INTO contact_entities 
        (entity_id, canonical_name, platforms, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        """
        
        let platformsJson = try? String(data: JSONSerialization.data(withJSONObject: platforms), encoding: .utf8) ?? "[]"
        
        _ = database.execute(sql, parameters: [entityId, canonicalName, platformsJson])
        
        // Add identity mapping
        addContactIdentity(
            entityId: entityId,
            platform: platform,
            platformContactId: platformContactId,
            displayName: name
        )
        
        logger.info("Created contact entity: \(canonicalName) (\(entityId))")
        return entityId
    }
    
    private func addContactIdentity(
        entityId: String,
        platform: String,
        platformContactId: String,
        displayName: String,
        confidence: Double = 1.0
    ) {
        let identityId = UUID().uuidString
        let sql = """
        INSERT OR REPLACE INTO contact_identities
        (identity_id, entity_id, platform, platform_contact_id, display_name, confidence)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        
        _ = database.execute(sql, parameters: [
            identityId, entityId, platform, platformContactId, displayName, confidence
        ])
    }
    
    private func findExistingEntity(for name: String, platform: String) -> String? {
        let canonicalName = canonicalizeName(name)
        
        // First try exact canonical name match
        let exactSql = """
        SELECT entity_id FROM contact_entities 
        WHERE canonical_name = ? 
        ORDER BY confidence_score DESC 
        LIMIT 1
        """
        
        let exactRows = database.query(exactSql, parameters: [canonicalName])
        if let row = exactRows.first, let entityId = row["entity_id"] as? String {
            return entityId
        }
        
        // Try fuzzy matching with existing entities
        let fuzzySql = """
        SELECT ce.entity_id, ce.canonical_name, ci.display_name
        FROM contact_entities ce
        LEFT JOIN contact_identities ci ON ce.entity_id = ci.entity_id
        WHERE ce.confidence_score > ?
        """
        
        let fuzzyRows = database.query(fuzzySql, parameters: [minConfidenceThreshold])
        
        for row in fuzzyRows {
            guard let entityId = row["entity_id"] as? String,
                  let existingCanonical = row["canonical_name"] as? String else { continue }
            
            // Use fuzzy matching from earlier implementation
            let canonicalScore = fuzzy_match_name(canonicalName, existingCanonical)
            
            if let displayName = row["display_name"] as? String {
                let displayScore = fuzzy_match_name(name, displayName)
                if canonicalScore > 0.8 || displayScore > 0.8 {
                    return entityId
                }
            } else if canonicalScore > 0.8 {
                return entityId
            }
        }
        
        return nil
    }
    
    private func canonicalizeName(_ name: String) -> String {
        return name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    // MARK: - Relationship Analysis
    
    /// Record a communication event between entities
    public func recordCommunicationEvent(
        fromEntityId: String?,
        toEntityId: String?,
        eventType: String,
        documentId: String?,
        timestamp: Date = Date(),
        interactionStrength: Double = 1.0,
        metadata: [String: Any] = [:]
    ) {
        guard let fromEntity = fromEntityId, let toEntity = toEntityId else { return }
        
        let eventId = UUID().uuidString
        let metadataJson = try? String(data: JSONSerialization.data(withJSONObject: metadata), encoding: .utf8) ?? "{}"
        
        let sql = """
        INSERT INTO communication_events
        (event_id, entity_from, entity_to, event_type, document_id, event_timestamp, interaction_strength, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        _ = database.execute(sql, parameters: [
            eventId, fromEntity, toEntity, eventType, documentId, timestamp.timeIntervalSince1970, interactionStrength, metadataJson
        ])
        
        // Update relationship strength
        updateRelationshipStrength(from: fromEntity, to: toEntity)
    }
    
    private func updateRelationshipStrength(from entityFrom: String, to entityTo: String) {
        // Calculate relationship metrics
        let metrics = calculateRelationshipMetrics(from: entityFrom, to: entityTo)
        
        let sql = """
        INSERT OR REPLACE INTO contact_relationships
        (relationship_id, entity_from, entity_to, relationship_type, strength_score, frequency_score, recency_score, total_interactions, last_interaction, updated_at)
        VALUES (?, ?, ?, 'communication', ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        """
        
        let relationshipId = "\(entityFrom)-\(entityTo)"
        
        _ = database.execute(sql, parameters: [
            relationshipId, entityFrom, entityTo, 
            metrics.strengthScore, metrics.frequencyScore, metrics.recencyScore,
            metrics.totalInteractions, metrics.lastInteraction?.timeIntervalSince1970 ?? 0
        ])
    }
    
    private func calculateRelationshipMetrics(from entityFrom: String, to entityTo: String) -> RelationshipMetrics {
        let sql = """
        SELECT 
            COUNT(*) as total_interactions,
            MAX(event_timestamp) as last_interaction,
            AVG(interaction_strength) as avg_strength,
            MIN(event_timestamp) as first_interaction
        FROM communication_events
        WHERE (entity_from = ? AND entity_to = ?) OR (entity_from = ? AND entity_to = ?)
        AND event_timestamp > ?
        """
        
        let cutoffTime = Date().timeIntervalSince1970 - maxRelationshipAge
        let rows = database.query(sql, parameters: [entityFrom, entityTo, entityTo, entityFrom, cutoffTime])
        
        guard let row = rows.first,
              let totalInteractions = row["total_interactions"] as? Int,
              let avgStrength = row["avg_strength"] as? Double else {
            return RelationshipMetrics()
        }
        
        let lastInteractionTime = (row["last_interaction"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let firstInteractionTime = (row["first_interaction"] as? Double).map { Date(timeIntervalSince1970: $0) }
        
        // Calculate frequency score (interactions per week)
        let timeSpan = Date().timeIntervalSince(firstInteractionTime ?? Date())
        let weeksSpan = max(timeSpan / (7 * 24 * 3600), 1.0)
        let frequencyScore = min(Double(totalInteractions) / weeksSpan, 10.0) / 10.0
        
        // Calculate recency score (decay over time)
        let daysSinceLastInteraction = lastInteractionTime.map { 
            Date().timeIntervalSince($0) / (24 * 3600) 
        } ?? 365
        let recencyScore = max(0.0, 1.0 - (daysSinceLastInteraction / 30.0)) // 30-day decay
        
        // Combined strength score
        let strengthScore = (avgStrength * 0.4) + (frequencyScore * 0.4) + (recencyScore * 0.2)
        
        return RelationshipMetrics(
            strengthScore: strengthScore,
            frequencyScore: frequencyScore,
            recencyScore: recencyScore,
            totalInteractions: totalInteractions,
            lastInteraction: lastInteractionTime
        )
    }
    
    // MARK: - Query Interface
    
    /// Find related contacts for a given entity
    public func getRelatedContacts(
        for entityId: String,
        limit: Int = 20,
        minStrength: Double = 0.1
    ) -> [ContactRelationship] {
        let sql = """
        SELECT 
            cr.entity_to as related_entity_id,
            ce.canonical_name,
            cr.strength_score,
            cr.frequency_score,
            cr.recency_score,
            cr.total_interactions,
            cr.last_interaction,
            GROUP_CONCAT(ci.display_name, ', ') as display_names,
            GROUP_CONCAT(ci.platform, ', ') as platforms
        FROM contact_relationships cr
        JOIN contact_entities ce ON cr.entity_to = ce.entity_id
        LEFT JOIN contact_identities ci ON ce.entity_id = ci.entity_id
        WHERE cr.entity_from = ? AND cr.strength_score >= ?
        GROUP BY cr.entity_to
        ORDER BY cr.strength_score DESC
        LIMIT ?
        """
        
        let rows = database.query(sql, parameters: [entityId, minStrength, limit])
        
        return rows.compactMap { row in
            guard let relatedEntityId = row["related_entity_id"] as? String,
                  let canonicalName = row["canonical_name"] as? String,
                  let strengthScore = row["strength_score"] as? Double,
                  let frequencyScore = row["frequency_score"] as? Double,
                  let recencyScore = row["recency_score"] as? Double,
                  let totalInteractions = row["total_interactions"] as? Int else {
                return nil
            }
            
            let lastInteractionTime = (row["last_interaction"] as? Double).map { 
                Date(timeIntervalSince1970: $0) 
            }
            
            let displayNames = (row["display_names"] as? String)?.components(separatedBy: ", ") ?? []
            let platforms = (row["platforms"] as? String)?.components(separatedBy: ", ") ?? []
            
            return ContactRelationship(
                entityId: relatedEntityId,
                canonicalName: canonicalName,
                displayNames: displayNames,
                platforms: platforms,
                strengthScore: strengthScore,
                frequencyScore: frequencyScore,
                recencyScore: recencyScore,
                totalInteractions: totalInteractions,
                lastInteraction: lastInteractionTime
            )
        }
    }
    
    /// Find entity ID for a contact name using fuzzy matching
    public func findEntityId(for contactName: String, platform: String? = nil) -> String? {
        return findExistingEntity(for: contactName, platform: platform ?? "unknown")
    }
    
    /// Get all identities for an entity across platforms
    public func getContactIdentities(for entityId: String) -> [ContactIdentity] {
        let sql = """
        SELECT identity_id, platform, platform_contact_id, display_name, confidence
        FROM contact_identities
        WHERE entity_id = ?
        ORDER BY confidence DESC
        """
        
        let rows = database.query(sql, parameters: [entityId])
        
        return rows.compactMap { row in
            guard let identityId = row["identity_id"] as? String,
                  let platform = row["platform"] as? String,
                  let platformContactId = row["platform_contact_id"] as? String,
                  let confidence = row["confidence"] as? Double else {
                return nil
            }
            
            return ContactIdentity(
                identityId: identityId,
                platform: platform,
                platformContactId: platformContactId,
                displayName: row["display_name"] as? String,
                confidence: confidence
            )
        }
    }
}

// MARK: - Support Types

private struct RelationshipMetrics {
    let strengthScore: Double
    let frequencyScore: Double
    let recencyScore: Double
    let totalInteractions: Int
    let lastInteraction: Date?
    
    init(strengthScore: Double = 0.0, frequencyScore: Double = 0.0, recencyScore: Double = 0.0, totalInteractions: Int = 0, lastInteraction: Date? = nil) {
        self.strengthScore = strengthScore
        self.frequencyScore = frequencyScore
        self.recencyScore = recencyScore
        self.totalInteractions = totalInteractions
        self.lastInteraction = lastInteraction
    }
}

public struct ContactRelationship {
    public let entityId: String
    public let canonicalName: String
    public let displayNames: [String]
    public let platforms: [String]
    public let strengthScore: Double
    public let frequencyScore: Double
    public let recencyScore: Double
    public let totalInteractions: Int
    public let lastInteraction: Date?
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "entity_id": entityId,
            "canonical_name": canonicalName,
            "display_names": displayNames,
            "platforms": platforms,
            "strength_score": strengthScore,
            "frequency_score": frequencyScore,
            "recency_score": recencyScore,
            "total_interactions": totalInteractions
        ]
        
        if let lastInteraction = lastInteraction {
            dict["last_interaction"] = ISO8601DateFormatter().string(from: lastInteraction)
        }
        
        return dict
    }
}

public struct ContactIdentity {
    public let identityId: String
    public let platform: String
    public let platformContactId: String
    public let displayName: String?
    public let confidence: Double
    
    public func toDictionary() -> [String: Any] {
        return [
            "identity_id": identityId,
            "platform": platform,
            "platform_contact_id": platformContactId,
            "display_name": displayName as Any,
            "confidence": confidence
        ]
    }
}

// MARK: - Fuzzy Matching Integration

private func fuzzy_match_name(_ query: String, _ fullName: String) -> Double {
    // Simplified version of the fuzzy matching from earlier
    // In a complete implementation, this would import the full fuzzy matching logic
    let queryLower = query.lowercased()
    let nameLower = fullName.lowercased()
    
    if queryLower == nameLower { return 1.0 }
    if nameLower.contains(queryLower) { return 0.8 }
    if queryLower.contains(nameLower) { return 0.7 }
    
    // Basic word overlap scoring
    let queryWords = Set(queryLower.components(separatedBy: .whitespacesAndNewlines))
    let nameWords = Set(nameLower.components(separatedBy: .whitespacesAndNewlines))
    let intersection = queryWords.intersection(nameWords)
    let union = queryWords.union(nameWords)
    
    return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
}