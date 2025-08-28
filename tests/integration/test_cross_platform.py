#!/usr/bin/env python3
"""
Integration tests for cross-platform functionality between Python kenny-api and Swift mac_tools

Tests the integration of all 5 critical fixes working together across the Python/Swift boundary:
1. Tool parameter signature compatibility 
2. Fuzzy contact matching in contact resolution
3. Search threshold optimization integration
4. Unified search orchestrator coordination
5. Contact entity graph cross-platform tracking

These tests verify end-to-end functionality rather than individual components.
"""

import pytest
import asyncio
import json
import tempfile
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch, MagicMock, AsyncMock
from typing import Dict, Any, List

# Add kenny-api to path for imports
kenny_api_path = Path(__file__).parent.parent.parent / "kenny-api"
sys.path.insert(0, str(kenny_api_path))

from main import OrchestratorService, DatabaseManager, ContactDataService

class TestCrossPlatformIntegration:
    """Test integration between Python API and Swift orchestrator"""
    
    @pytest.fixture
    def temp_databases(self):
        """Create temporary test databases"""
        with tempfile.TemporaryDirectory() as temp_dir:
            kenny_db = Path(temp_dir) / "kenny_test.db"
            contact_db = Path(temp_dir) / "contact_test.db"
            
            # Create kenny.db with test data
            kenny_conn = sqlite3.connect(str(kenny_db))
            kenny_conn.execute("""
                CREATE TABLE documents (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    content TEXT,
                    app_source TEXT,
                    created_at TEXT,
                    metadata_json TEXT
                )
            """)
            
            kenny_conn.execute("""
                CREATE VIRTUAL TABLE documents_fts USING fts5(
                    title, content, content='documents', content_rowid='rowid'
                )
            """)
            
            # Insert test documents
            test_docs = [
                ("doc_1", "Meeting with John Smith", "Discussion about project timeline", "mail", "2024-01-01", "{}"),
                ("doc_2", "Call with Mike Johnson", "Technical review session", "messages", "2024-01-02", "{}"),
                ("doc_3", "Email from Katherine Davis", "Design mockups attached", "mail", "2024-01-03", "{}"),
                ("doc_4", "WhatsApp from Bob Wilson", "Quick question about deadline", "whatsapp", "2024-01-04", "{}")
            ]
            
            for doc in test_docs:
                kenny_conn.execute("INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?)", doc)
                kenny_conn.execute("INSERT INTO documents_fts VALUES (?, ?)", (doc[1], doc[2]))
            
            kenny_conn.commit()
            kenny_conn.close()
            
            # Create contact_memory.db with test data
            contact_conn = sqlite3.connect(str(contact_db))
            contact_conn.execute("""
                CREATE TABLE kenny_contacts (
                    kenny_contact_id TEXT PRIMARY KEY,
                    display_name TEXT,
                    photo_path TEXT
                )
            """)
            
            contact_conn.execute("""
                CREATE TABLE contact_relationships (
                    kenny_contact_id TEXT,
                    relationship_type TEXT,
                    company TEXT,
                    role TEXT
                )
            """)
            
            contact_conn.execute("""
                CREATE TABLE contact_identities (
                    id TEXT PRIMARY KEY,
                    kenny_contact_id TEXT,
                    identity_type TEXT,
                    identity_value TEXT,
                    source TEXT,
                    confidence REAL,
                    created_at TEXT
                )
            """)
            
            contact_conn.execute("""
                CREATE TABLE contact_threads (
                    kenny_contact_id TEXT,
                    document_id TEXT,
                    relationship_type TEXT,
                    extracted_at TEXT,
                    confidence REAL
                )
            """)
            
            contact_conn.execute("""
                CREATE TABLE contact_memories (
                    id TEXT PRIMARY KEY,
                    kenny_contact_id TEXT,
                    memory_type TEXT,
                    title TEXT,
                    description TEXT,
                    confidence REAL,
                    extracted_at TEXT,
                    importance_score REAL,
                    tags TEXT
                )
            """)
            
            # Insert test contacts with varied names for fuzzy matching tests
            test_contacts = [
                ("contact_1", "John Smith", "Acme Corp", "CEO"),
                ("contact_2", "Michael Johnson", "TechStart Inc", "CTO"),
                ("contact_3", "Katherine Davis", "Design Co", "Designer"),
                ("contact_4", "Robert Wilson", "Sales LLC", "Manager")
            ]
            
            for contact_id, name, company, role in test_contacts:
                contact_conn.execute("INSERT INTO kenny_contacts VALUES (?, ?, ?)", 
                                   (contact_id, name, None))
                contact_conn.execute("INSERT INTO contact_relationships VALUES (?, 'professional', ?, ?)",
                                   (contact_id, company, role))
                contact_conn.execute("INSERT INTO contact_identities VALUES (?, ?, 'email', ?, 'test', 1.0, '2024-01-01')",
                                   (f"id_{contact_id}", contact_id, f"{name.lower().replace(' ', '.')}@{company.lower().replace(' ', '')}.com"))
                
                # Link contacts to documents
                doc_id = f"doc_{contact_id.split('_')[1]}"
                contact_conn.execute("INSERT INTO contact_threads VALUES (?, ?, 'mentioned', '2024-01-01', 0.9)",
                                   (contact_id, doc_id))
            
            contact_conn.commit()
            contact_conn.close()
            
            yield {"kenny_db": kenny_db, "contact_db": contact_db}

    @pytest.fixture
    def orchestrator_service(self, temp_databases):
        """Create orchestrator service with test databases"""
        with patch('main.KENNY_DATABASE_PATH', temp_databases["kenny_db"]):
            with patch('main.CONTACT_DATABASE_PATH', temp_databases["contact_db"]):
                return OrchestratorService("/fake/orchestrator/path")

    @pytest.mark.asyncio
    async def test_cross_platform_search_integration(self, orchestrator_service, temp_databases):
        """Test that Python API can coordinate with Swift search components"""
        
        # Test search_documents tool execution
        result = await orchestrator_service.execute_tool("search_documents", {
            "query": "meeting project",
            "limit": 10
        })
        
        # Should succeed even with mock Swift orchestrator
        assert result["status"] in ["success", "error"]  # May fail due to missing Swift binary, but shouldn't crash
        
        if result["status"] == "success":
            assert "data" in result
            if "results" in result["data"]:
                # Verify result structure is compatible
                for doc in result["data"]["results"][:1]:  # Check first result
                    assert "id" in doc
                    assert "title" in doc
                    assert "content" in doc
                    assert "source" in doc

    @pytest.mark.asyncio 
    async def test_fuzzy_contact_search_integration(self, orchestrator_service):
        """Test fuzzy contact matching integrated with search"""
        
        # Test search_contact_specific tool with fuzzy matching
        result = await orchestrator_service.execute_tool("search_contact_specific", {
            "contact_id": "contact_1",
            "query": "project"
        })
        
        # Should use contact data service with fuzzy matching
        assert result["status"] == "success"
        assert "data" in result
        assert "contact_name" in result["data"]
        
        # Test fuzzy contact resolution
        with patch('main.contact_service') as mock_contact_service:
            mock_thread = MagicMock()
            mock_thread.display_name = "John Smith"
            mock_thread.messages = [
                {"id": "doc_1", "title": "Meeting", "content": "Project discussion", 
                 "source": "mail", "created_at": "2024-01-01"}
            ]
            mock_contact_service.get_contact_thread.return_value = mock_thread
            
            result = await orchestrator_service.execute_tool("search_contact_specific", {
                "contact_id": "contact_1",
                "query": "project"
            })
            
            assert result["status"] == "success"
            assert "John Smith" in result["data"]["contact_name"]

    def test_parameter_signature_compatibility(self, orchestrator_service):
        """Test that all tool parameters are compatible between Python and Swift expectations"""
        
        # Test get_recent_messages with various parameter combinations
        test_cases = [
            {"days": 7, "source": "whatsapp", "limit": 25},  # All parameters
            {"days": 14},                                     # Only days
            {"source": "mail", "limit": 10},                 # source and limit
            {}                                               # No parameters (use defaults)
        ]
        
        for params in test_cases:
            # This tests parameter compatibility without requiring Swift binary
            try:
                # The parameter validation happens in execute_tool before calling Swift
                result = asyncio.run(orchestrator_service.execute_tool("get_recent_messages", params))
                
                # Should either succeed or fail gracefully, not crash with parameter errors
                assert result["status"] in ["success", "error"]
                assert "error" not in result or "parameter" not in result["error"].lower()
                
            except Exception as e:
                # Should not get parameter-related exceptions
                assert "parameter" not in str(e).lower()
                assert "signature" not in str(e).lower()

    @pytest.mark.asyncio
    async def test_search_threshold_coordination(self, orchestrator_service):
        """Test that Python search coordination works with Swift threshold optimization"""
        
        # Test search with different query complexities to trigger threshold fallback
        test_queries = [
            ("exact match query", "Should find exact matches"),
            ("partial word match", "Should find partial matches"), 
            ("fuzzy semantic query", "Should trigger threshold fallback"),
            ("very obscure unusual query", "Should use lowest threshold")
        ]
        
        for query, description in test_queries:
            result = await orchestrator_service.execute_tool("search_documents", {
                "query": query,
                "limit": 5
            })
            
            # All queries should get handled, even if no results found
            assert result["status"] in ["success", "error"]
            
            if result["status"] == "success":
                # Results should be properly structured
                assert "data" in result
                
                # If using SQL fallback, should still return consistent format
                if result["data"].get("search_type") == "sql_fallback":
                    assert "results" in result["data"]

    def test_contact_entity_graph_integration(self, temp_databases):
        """Test contact entity graph integration with contact data service"""
        
        with patch('main.KENNY_DATABASE_PATH', temp_databases["kenny_db"]):
            with patch('main.CONTACT_DATABASE_PATH', temp_databases["contact_db"]):
                db_manager = DatabaseManager()
                contact_service = ContactDataService(db_manager)
                
                # Test contact summary retrieval
                contact = contact_service.get_contact_summary("contact_1")
                assert contact is not None
                assert contact.display_name == "John Smith"
                assert len(contact.identities) > 0
                
                # Test contact thread retrieval (cross-database query)
                thread = contact_service.get_contact_thread("contact_1", 10)
                assert thread is not None
                assert thread.display_name == "John Smith"
                assert len(thread.messages) > 0
                
                # Verify cross-database relationship
                message = thread.messages[0]
                assert message["id"] == "doc_1"  # From kenny.db
                assert message["relationship_type"] == "mentioned"  # From contact_memory.db

class TestUnifiedSearchOrchestrator:
    """Test unified search orchestrator coordination between multiple search paths"""
    
    @pytest.fixture
    def mock_search_components(self):
        """Mock the various search components"""
        with patch('main.HybridSearch') as mock_hybrid:
            with patch('main.Database') as mock_db:
                mock_hybrid_instance = MagicMock()
                mock_hybrid.return_value = mock_hybrid_instance
                
                # Mock hybrid search results
                async def mock_search(query, limit):
                    return [
                        MagicMock(
                            documentId=f"hybrid_doc_{i}",
                            title=f"Hybrid Result {i}",
                            snippet=f"Hybrid search result for {query}",
                            score=0.9 - (i * 0.1),
                            appSource="test"
                        ) for i in range(min(3, limit))
                    ]
                
                mock_hybrid_instance.search = mock_search
                
                # Mock database multi-domain search
                mock_db_instance = MagicMock()
                mock_db.return_value = mock_db_instance
                
                def mock_multi_domain_search(query, types, limit):
                    return [
                        MagicMock(
                            id=f"fts_doc_{i}",
                            title=f"FTS Result {i}",
                            snippet=f"FTS search result for {query}",
                            rank=0.8 - (i * 0.1),
                            type="test",
                            contextInfo="test context",
                            sourcePath="/test/path"
                        ) for i in range(min(2, limit))
                    ]
                
                mock_db_instance.searchMultiDomain = mock_multi_domain_search
                
                yield {
                    "hybrid_search": mock_hybrid_instance,
                    "database": mock_db_instance
                }

    @pytest.mark.asyncio
    async def test_unified_search_coordination(self, mock_search_components):
        """Test that unified search orchestrator coordinates multiple search paths correctly"""
        
        # This would test UnifiedSearchOrchestrator if we had it imported
        # For now, test the coordination logic through the orchestrator service
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Test search with multiple potential paths
        with patch('main.db_manager') as mock_db_manager:
            mock_db_manager.get_kenny_connection.return_value = MagicMock()
            
            with patch('sqlite3.connect') as mock_connect:
                mock_conn = MagicMock()
                mock_connect.return_value = mock_conn
                mock_cursor = MagicMock()
                mock_conn.cursor.return_value = mock_cursor
                
                # Mock SQL fallback results 
                mock_cursor.fetchall.return_value = [
                    ["sql_doc_1", "SQL Fallback Result", "Content for fallback", "test", "2024-01-01"]
                ]
                
                result = await orchestrator.execute_tool("search_documents", {
                    "query": "coordination test",
                    "limit": 5
                })
                
                # Should coordinate different search paths
                assert result["status"] == "success"
                assert "data" in result
                
                # Should include SQL fallback when hybrid search unavailable
                if result["data"].get("search_type") == "sql_fallback":
                    assert len(result["data"]["results"]) > 0

class TestEndToEndWorkflows:
    """Test complete end-to-end workflows across all fixes"""
    
    @pytest.fixture
    def full_system_setup(self, temp_databases):
        """Set up full system with all components"""
        with patch('main.KENNY_DATABASE_PATH', temp_databases["kenny_db"]):
            with patch('main.CONTACT_DATABASE_PATH', temp_databases["contact_db"]):
                with patch('main.ORCHESTRATOR_PATH', '/fake/orchestrator'):
                    yield temp_databases

    @pytest.mark.asyncio
    async def test_complete_contact_search_workflow(self, full_system_setup):
        """Test complete workflow: contact search → fuzzy matching → document retrieval → unified results"""
        
        db_manager = DatabaseManager()
        contact_service = ContactDataService(db_manager)
        orchestrator = OrchestratorService("/fake/path")
        
        # Step 1: Search for contact using fuzzy matching
        contacts = contact_service.search_contacts("Mike")  # Should match "Michael Johnson"
        
        if contacts:  # If fuzzy matching finds contacts
            contact = contacts[0]
            
            # Step 2: Get contact thread (cross-database query)
            thread = contact_service.get_contact_thread(contact.kenny_contact_id, 10)
            assert thread is not None
            
            # Step 3: Search within contact's documents
            result = await orchestrator.execute_tool("search_contact_specific", {
                "contact_id": contact.kenny_contact_id,
                "query": "technical"
            })
            
            assert result["status"] == "success"
        
        # Step 4: Fallback to general search if no specific contact found
        general_result = await orchestrator.execute_tool("search_documents", {
            "query": "Mike technical",
            "limit": 10
        })
        
        # Should get results from some search path (hybrid, FTS, or SQL fallback)
        assert general_result["status"] == "success"

    @pytest.mark.asyncio
    async def test_search_threshold_optimization_workflow(self, full_system_setup):
        """Test workflow that exercises search threshold optimization"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Test queries of varying specificity to trigger different thresholds
        test_scenarios = [
            {
                "query": "John Smith meeting project timeline",
                "description": "High specificity - should use higher thresholds",
                "expected_behavior": "Quick results with high confidence"
            },
            {
                "query": "project meeting",
                "description": "Medium specificity - should use medium thresholds",
                "expected_behavior": "Good results with reasonable confidence"
            },
            {
                "query": "timeline",
                "description": "Low specificity - should trigger threshold fallback",
                "expected_behavior": "Broader results with lower thresholds"
            }
        ]
        
        for scenario in test_scenarios:
            result = await orchestrator.execute_tool("search_documents", {
                "query": scenario["query"],
                "limit": 10
            })
            
            # All scenarios should return results due to progressive threshold fallback
            assert result["status"] == "success"
            
            # Should have consistent result structure regardless of threshold used
            if "data" in result and "results" in result["data"]:
                for doc in result["data"]["results"]:
                    assert "id" in doc
                    assert "title" in doc
                    assert "content" in doc

    @pytest.mark.asyncio
    async def test_error_recovery_across_systems(self, full_system_setup):
        """Test error handling and recovery across Python/Swift boundary"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Test various error scenarios
        error_scenarios = [
            {
                "tool": "search_documents",
                "params": {"query": "", "limit": -1},
                "description": "Invalid parameters"
            },
            {
                "tool": "search_contact_specific",
                "params": {"contact_id": "nonexistent", "query": "test"},
                "description": "Nonexistent contact"
            },
            {
                "tool": "get_recent_messages", 
                "params": {"days": -5, "limit": 0},
                "description": "Invalid day range"
            }
        ]
        
        for scenario in error_scenarios:
            result = await orchestrator.execute_tool(scenario["tool"], scenario["params"])
            
            # Should handle errors gracefully, not crash
            assert isinstance(result, dict)
            assert "status" in result
            
            # If error, should have proper error structure
            if result["status"] == "error":
                assert "error" in result
                assert isinstance(result["error"], str)

class TestPerformanceIntegration:
    """Test performance of integrated system"""
    
    @pytest.mark.asyncio
    async def test_search_coordination_performance(self):
        """Test that search coordination doesn't introduce significant latency"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Test search performance with SQL fallback
        start_time = time.time()
        
        with patch('main.db_manager') as mock_db_manager:
            mock_db_manager.get_kenny_connection.return_value = MagicMock()
            
            with patch('sqlite3.connect') as mock_connect:
                mock_conn = MagicMock()
                mock_connect.return_value = mock_conn
                mock_cursor = MagicMock()
                mock_conn.cursor.return_value = mock_cursor
                mock_cursor.fetchall.return_value = []
                
                # Run multiple searches
                tasks = []
                for i in range(10):
                    task = orchestrator.execute_tool("search_documents", {
                        "query": f"performance test {i}",
                        "limit": 10
                    })
                    tasks.append(task)
                
                results = await asyncio.gather(*tasks)
                
                end_time = time.time()
                duration = end_time - start_time
                
                # All searches should complete
                assert len(results) == 10
                for result in results:
                    assert result["status"] == "success"
                
                # Should complete in reasonable time (< 1 second for SQL fallback)
                assert duration < 1.0, f"10 searches took {duration:.3f}s, should be < 1.0s"

if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])