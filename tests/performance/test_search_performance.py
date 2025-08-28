#!/usr/bin/env python3
"""
Performance tests for search algorithms and threshold optimization

Tests performance characteristics of:
1. Fuzzy contact matching at scale
2. Search threshold progressive fallback performance  
3. Cross-platform search coordination overhead
4. Database query optimization effectiveness

These tests ensure fixes don't introduce performance regressions.
"""

import pytest
import time
import sqlite3
import tempfile
import sys
from pathlib import Path
from typing import List, Dict, Any
from unittest.mock import patch, MagicMock
import statistics
import concurrent.futures

# Add kenny-api to path
kenny_api_path = Path(__file__).parent.parent.parent / "kenny-api"
sys.path.insert(0, str(kenny_api_path))

from ollama_kenny import fuzzy_match_name, search_contacts
from main import OrchestratorService

class TestFuzzyMatchingPerformance:
    """Performance tests for fuzzy contact matching"""
    
    @pytest.fixture
    def large_contact_dataset(self):
        """Generate large dataset of varied contact names for performance testing"""
        
        # Common first names with variations
        first_names = [
            "John", "Jon", "Jonathan", "Johnny", "Jack",
            "Michael", "Mike", "Mick", "Mickey", "Mitchell",
            "William", "Will", "Bill", "Billy", "Willie", 
            "James", "Jim", "Jimmy", "Jamie", "Jay",
            "Robert", "Rob", "Bob", "Bobby", "Robbie",
            "David", "Dave", "Davey", "Davis", "Davidson",
            "Christopher", "Chris", "Christie", "Christian",
            "Katherine", "Kate", "Katie", "Kathy", "Catherine",
            "Elizabeth", "Liz", "Lizzie", "Beth", "Betty",
            "Jennifer", "Jen", "Jenny", "Jessica", "Jess"
        ]
        
        # Common last names
        last_names = [
            "Smith", "Johnson", "Williams", "Brown", "Jones",
            "Garcia", "Miller", "Davis", "Rodriguez", "Martinez", 
            "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
            "Thomas", "Taylor", "Moore", "Jackson", "Martin",
            "Lee", "Perez", "Thompson", "White", "Harris"
        ]
        
        # Generate combinations with some variations/typos
        contacts = []
        for first in first_names[:20]:  # Limit for performance
            for last in last_names[:20]:
                contacts.append(f"{first} {last}")
                
                # Add some variations
                if len(contacts) < 800:
                    contacts.append(f"{first.upper()} {last.upper()}")  # Case variation
                    contacts.append(f"{first} {last[:-1]}son")  # Name variation
        
        return contacts[:1000]  # Return exactly 1000 contacts
    
    def test_fuzzy_matching_single_query_performance(self, large_contact_dataset):
        """Test single fuzzy match query performance"""
        
        query = "Mike Johnson"
        target_contacts = large_contact_dataset
        
        # Time single queries
        times = []
        for _ in range(100):  # 100 iterations for averaging
            start_time = time.perf_counter()
            
            # Test against 10 random contacts
            for contact in target_contacts[:10]:
                score = fuzzy_match_name(query, contact)
            
            end_time = time.perf_counter()
            times.append(end_time - start_time)
        
        avg_time = statistics.mean(times)
        max_time = max(times)
        
        # Should average < 1ms per 10 contacts (< 0.1ms per contact)
        assert avg_time < 0.001, f"Average time {avg_time*1000:.3f}ms too slow"
        assert max_time < 0.005, f"Max time {max_time*1000:.3f}ms too slow"
        
        print(f"Fuzzy matching performance: avg={avg_time*1000:.3f}ms, max={max_time*1000:.3f}ms for 10 contacts")

    def test_fuzzy_matching_batch_performance(self, large_contact_dataset):
        """Test batch fuzzy matching performance"""
        
        queries = ["Mike", "John Smith", "Katherine", "Bob Wilson", "Chris"]
        target_contacts = large_contact_dataset
        
        start_time = time.perf_counter()
        
        # Test each query against all contacts  
        total_comparisons = 0
        for query in queries:
            for contact in target_contacts:
                score = fuzzy_match_name(query, contact)
                total_comparisons += 1
        
        end_time = time.perf_counter()
        duration = end_time - start_time
        
        # Should process 5,000 comparisons (5 queries × 1,000 contacts) in < 1 second
        assert duration < 1.0, f"Batch processing took {duration:.3f}s, should be < 1.0s"
        assert total_comparisons == 5000
        
        comparisons_per_second = total_comparisons / duration
        print(f"Batch fuzzy matching: {comparisons_per_second:.0f} comparisons/second")

    @pytest.mark.skipif(not hasattr(sys.modules.get('ollama_kenny', None), 'LEVENSHTEIN_AVAILABLE') or 
                       not sys.modules.get('ollama_kenny', MagicMock()).LEVENSHTEIN_AVAILABLE,
                       reason="Levenshtein not available")
    def test_levenshtein_performance_impact(self, large_contact_dataset):
        """Test performance impact of Levenshtein distance calculations"""
        
        query = "Johnathan Smith"  # Should trigger Levenshtein for "Jonathan Smith"
        similar_contacts = [contact for contact in large_contact_dataset if "John" in contact][:100]
        
        start_time = time.perf_counter()
        
        scores = []
        for contact in similar_contacts:
            score = fuzzy_match_name(query, contact)
            scores.append(score)
        
        end_time = time.perf_counter()
        duration = end_time - start_time
        
        # Even with Levenshtein, should process 100 similar names in < 100ms  
        assert duration < 0.1, f"Levenshtein matching took {duration*1000:.3f}ms, should be < 100ms"
        
        # Should find some high-scoring matches
        high_scores = [s for s in scores if s > 0.8]
        assert len(high_scores) > 0, "Should find some high-scoring Levenshtein matches"
        
        print(f"Levenshtein performance: {duration*1000:.3f}ms for 100 similar names")

class TestSearchThresholdPerformance:
    """Performance tests for search threshold optimization"""
    
    @pytest.fixture
    def large_document_dataset(self):
        """Create large test database for performance testing"""
        with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as tmp_file:
            db_path = tmp_file.name
        
        conn = sqlite3.connect(db_path)
        
        # Create documents table
        conn.execute("""
            CREATE TABLE documents (
                id TEXT PRIMARY KEY,
                title TEXT,
                content TEXT,
                app_source TEXT,
                created_at TEXT,
                metadata_json TEXT
            )
        """)
        
        # Generate test documents
        test_content = [
            "Meeting about project timeline and deliverables",
            "Technical discussion on system architecture", 
            "Design review session with stakeholders",
            "Budget planning for next quarter initiatives",
            "Team building event organization details",
            "Client presentation preparation notes",
            "Code review feedback and improvement suggestions",
            "Marketing campaign strategy and execution plan",
            "Product roadmap discussion and prioritization",
            "Performance optimization analysis and recommendations"
        ]
        
        sources = ["mail", "messages", "whatsapp", "calendar", "contacts"]
        
        # Insert 10,000 test documents
        documents = []
        for i in range(10000):
            content_idx = i % len(test_content)
            source_idx = i % len(sources)
            
            documents.append((
                f"doc_{i:05d}",
                f"Document {i}: {test_content[content_idx][:20]}",
                test_content[content_idx] + f" Document {i} additional content.",
                sources[source_idx],
                f"2024-01-{(i % 28) + 1:02d}",
                "{}"
            ))
        
        conn.executemany("INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?)", documents)
        conn.commit()
        conn.close()
        
        yield db_path
        
        # Cleanup
        Path(db_path).unlink()

    def test_sql_fallback_search_performance(self, large_document_dataset):
        """Test SQL fallback search performance with large dataset"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Test various query complexities
        test_queries = [
            ("meeting", "Single term - high frequency"),
            ("project timeline", "Two terms - medium frequency"),
            ("technical architecture system", "Three terms - lower frequency"),
            ("optimization recommendations analysis", "Three terms - very specific"),
            ("nonexistent unique query terms", "Should return empty results quickly")
        ]
        
        with patch('main.KENNY_DATABASE_PATH', large_document_dataset):
            for query, description in test_queries:
                start_time = time.perf_counter()
                
                # Use SQL fallback search directly
                results = orchestrator._sql_fallback_search(query, 20)
                
                end_time = time.perf_counter()
                duration = end_time - start_time
                
                # Even with 10K documents, should complete in < 100ms
                assert duration < 0.1, f"Query '{query}' took {duration*1000:.3f}ms, should be < 100ms"
                
                print(f"SQL search '{query}': {duration*1000:.3f}ms, {len(results)} results")

    def test_threshold_fallback_progression_performance(self):
        """Test that progressive threshold fallback doesn't cause exponential slowdown"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        # Mock the database queries to simulate threshold fallback behavior
        with patch('main.db_manager') as mock_db_manager:
            mock_conn = MagicMock()
            mock_db_manager.get_kenny_connection.return_value = mock_conn
            mock_conn.__enter__ = lambda self: mock_conn
            mock_conn.__exit__ = lambda self, *args: None
            
            # First few calls return empty (high thresholds), last call returns results
            call_count = 0
            def mock_execute(sql, params):
                nonlocal call_count
                call_count += 1
                if call_count < 3:  # Simulate high threshold failure
                    return []
                else:  # Simulate low threshold success
                    return [
                        ["doc_1", "Test Title", "Test content", "mail", "2024-01-01"],
                        ["doc_2", "Another Title", "More content", "messages", "2024-01-02"]
                    ]
            
            mock_cursor = MagicMock()
            mock_conn.execute.return_value = mock_cursor
            mock_cursor.fetchall = mock_execute
            
            start_time = time.perf_counter()
            
            # This should trigger threshold fallback
            result = orchestrator._sql_fallback_search("complex threshold test query", 10)
            
            end_time = time.perf_counter()
            duration = end_time - start_time
            
            # Should complete quickly even with fallback logic  
            assert duration < 0.05, f"Threshold fallback took {duration*1000:.3f}ms, should be < 50ms"

class TestConcurrencyPerformance:
    """Test performance under concurrent load"""
    
    def test_concurrent_fuzzy_matching(self):
        """Test fuzzy matching performance under concurrent load"""
        
        test_names = [
            ("Mike Johnson", "Michael Johnson"),
            ("Bob Smith", "Robert Smith"),  
            ("Katie Davis", "Katherine Davis"),
            ("Chris Wilson", "Christopher Wilson"),
            ("Dave Brown", "David Brown")
        ] * 10  # 50 total comparisons
        
        def fuzzy_match_worker(name_pair):
            query, full_name = name_pair
            start_time = time.perf_counter()
            score = fuzzy_match_name(query, full_name)
            end_time = time.perf_counter()
            return end_time - start_time, score
        
        # Test sequential performance
        start_time = time.perf_counter()
        sequential_results = [fuzzy_match_worker(pair) for pair in test_names]
        sequential_duration = time.perf_counter() - start_time
        
        # Test concurrent performance
        start_time = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
            concurrent_results = list(executor.map(fuzzy_match_worker, test_names))
        concurrent_duration = time.perf_counter() - start_time
        
        # Concurrent should be faster (or at least not significantly slower)
        speedup_ratio = sequential_duration / concurrent_duration if concurrent_duration > 0 else float('inf')
        
        print(f"Fuzzy matching concurrency: sequential={sequential_duration*1000:.3f}ms, "
              f"concurrent={concurrent_duration*1000:.3f}ms, speedup={speedup_ratio:.2f}x")
        
        # Should not be significantly slower under concurrency
        assert concurrent_duration < sequential_duration * 1.5, \
               "Concurrent performance significantly degraded"

    def test_concurrent_search_operations(self):
        """Test search operations under concurrent load"""
        
        orchestrator = OrchestratorService("/fake/path")
        
        search_queries = [
            "meeting project timeline",
            "technical discussion", 
            "design review",
            "budget planning",
            "team building"
        ]
        
        async def async_search_worker(query):
            start_time = time.perf_counter()
            
            # Mock database for consistent performance testing
            with patch('sqlite3.connect') as mock_connect:
                mock_conn = MagicMock()
                mock_connect.return_value = mock_conn
                mock_cursor = MagicMock()
                mock_conn.cursor.return_value = mock_cursor
                mock_cursor.fetchall.return_value = [
                    ["doc_1", "Test Result", "Test content", "mail", "2024-01-01"]
                ]
                
                result = await orchestrator.execute_tool("search_documents", {
                    "query": query,
                    "limit": 10
                })
                
                end_time = time.perf_counter()
                return end_time - start_time, result["status"]
        
        # Test performance with concurrent async operations
        import asyncio
        
        async def run_concurrent_searches():
            tasks = [async_search_worker(query) for query in search_queries * 4]  # 20 total
            return await asyncio.gather(*tasks)
        
        start_time = time.perf_counter()
        results = asyncio.run(run_concurrent_searches())
        total_duration = time.perf_counter() - start_time
        
        # All should succeed
        assert all(result[1] == "success" for result in results), "Some searches failed"
        
        # Should complete 20 searches in reasonable time
        assert total_duration < 2.0, f"20 concurrent searches took {total_duration:.3f}s, should be < 2.0s"
        
        avg_duration = statistics.mean([result[0] for result in results])
        print(f"Concurrent search performance: {total_duration:.3f}s total, {avg_duration*1000:.3f}ms average")

class TestMemoryPerformance:
    """Test memory usage and garbage collection performance"""
    
    def test_fuzzy_matching_memory_usage(self):
        """Test that fuzzy matching doesn't leak memory"""
        
        import gc
        import psutil
        import os
        
        process = psutil.Process(os.getpid())
        
        # Baseline memory
        gc.collect()
        baseline_memory = process.memory_info().rss
        
        # Run many fuzzy matching operations
        large_dataset = [f"Person {i} Name{i}" for i in range(1000)]
        
        for iteration in range(10):  # 10 iterations of 1000 comparisons each
            for name in large_dataset:
                score = fuzzy_match_name("Person 500", name)
        
        # Force garbage collection
        gc.collect()
        final_memory = process.memory_info().rss
        
        memory_increase = final_memory - baseline_memory
        memory_increase_mb = memory_increase / (1024 * 1024)
        
        # Should not increase memory by more than 50MB for 10,000 operations
        assert memory_increase_mb < 50, f"Memory increased by {memory_increase_mb:.2f}MB"
        
        print(f"Memory usage: baseline={baseline_memory/(1024*1024):.1f}MB, "
              f"final={final_memory/(1024*1024):.1f}MB, increase={memory_increase_mb:.1f}MB")

class TestRegressionPerformance:
    """Test for performance regressions in the fixes"""
    
    def test_no_regression_in_basic_operations(self):
        """Test that fixes don't introduce performance regressions"""
        
        # Baseline operations that should remain fast
        operations = [
            lambda: fuzzy_match_name("John", "John Smith"),
            lambda: fuzzy_match_name("exact match", "exact match"), 
            lambda: fuzzy_match_name("", ""),
            lambda: fuzzy_match_name("a", "b"),
        ]
        
        # Run each operation many times and measure
        for i, operation in enumerate(operations):
            times = []
            for _ in range(1000):
                start = time.perf_counter()
                operation()
                end = time.perf_counter()
                times.append(end - start)
            
            avg_time = statistics.mean(times)
            max_time = max(times)
            
            # Each operation should complete in < 100 microseconds on average
            assert avg_time < 0.0001, f"Operation {i} avg time {avg_time*1000000:.1f}μs too slow"
            assert max_time < 0.001, f"Operation {i} max time {max_time*1000:.3f}ms too slow"
            
            print(f"Operation {i}: avg={avg_time*1000000:.1f}μs, max={max_time*1000000:.1f}μs")

if __name__ == "__main__":
    # Run with benchmarking
    pytest.main([__file__, "-v", "-s", "--benchmark-only", "--benchmark-sort=mean"])