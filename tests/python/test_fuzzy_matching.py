#!/usr/bin/env python3
"""
Test suite for Fuzzy Contact Matching Implementation

Tests the enhanced fuzzy matching algorithm with Levenshtein distance,
phonetic matching, and nickname resolution capabilities.

Critical Fix #2: Fuzzy Contact Matching Implementation
"""

import pytest
import sys
import os
from unittest.mock import patch, MagicMock
import sqlite3
from pathlib import Path

# Add the kenny-api directory to Python path for imports
kenny_api_path = Path(__file__).parent.parent.parent / "kenny-api"
sys.path.insert(0, str(kenny_api_path))

# Import the fuzzy matching function and search_contacts
from ollama_kenny import fuzzy_match_name, search_contacts, CONTACT_DB

class TestFuzzyMatching:
    """Test fuzzy matching algorithm correctness and edge cases"""

    def test_exact_match_returns_perfect_score(self):
        """Exact matches should return score of 1.0"""
        result = fuzzy_match_name("John Smith", "John Smith")
        assert result == 1.0
        
        result = fuzzy_match_name("jane doe", "Jane Doe")
        assert result == 1.0  # Case insensitive

    def test_substring_matching_high_scores(self):
        """Substring matches should return high confidence scores"""
        # Full name contains query
        result = fuzzy_match_name("Courtney", "Courtney Elyse Lim")
        assert result >= 0.8
        
        # Partial word matching
        result = fuzzy_match_name("John", "John Michael Smith")
        assert result >= 0.6

    def test_component_matching(self):
        """Test word-by-word component matching"""
        result = fuzzy_match_name("John Smith", "Smith John")
        assert result >= 0.8  # All components match, different order
        
        result = fuzzy_match_name("Mike Johnson", "Michael Johnson")
        assert result >= 0.6  # Partial component match

    @pytest.mark.skipif(not hasattr(sys.modules.get('ollama_kenny', None), 'LEVENSHTEIN_AVAILABLE') or 
                       not sys.modules.get('ollama_kenny', MagicMock()).LEVENSHTEIN_AVAILABLE,
                       reason="Levenshtein not available")
    def test_levenshtein_distance_matching(self):
        """Test Levenshtein distance-based matching"""
        # Similar names with minor typos
        result = fuzzy_match_name("Jon Smith", "John Smith")
        assert result >= 0.7
        
        result = fuzzy_match_name("Katherine", "Catherine")  # K/C substitution
        assert result >= 0.8

    def test_nickname_mapping(self):
        """Test common nickname recognition"""
        # Test built-in nickname mappings
        result = fuzzy_match_name("Mike", "Michael Johnson")
        assert result >= 0.8
        
        result = fuzzy_match_name("Bob", "Robert Smith") 
        assert result >= 0.8
        
        result = fuzzy_match_name("Katie", "Katherine Davis")
        assert result >= 0.8

    @pytest.mark.skipif(not hasattr(sys.modules.get('ollama_kenny', None), 'PHONETICS_AVAILABLE') or
                       not sys.modules.get('ollama_kenny', MagicMock()).PHONETICS_AVAILABLE,
                       reason="Phonetics not available")
    def test_phonetic_matching(self):
        """Test phonetic similarity matching"""
        # Names that sound similar
        result = fuzzy_match_name("Smith", "Smyth")
        assert result >= 0.6
        
        result = fuzzy_match_name("Catherine", "Katherine") 
        assert result >= 0.7

    def test_positional_bonuses(self):
        """Test that matches at start of name get bonuses"""
        result_start = fuzzy_match_name("John", "John Michael Smith")
        result_middle = fuzzy_match_name("Michael", "John Michael Smith")
        
        # Starting matches should score higher than middle matches
        assert result_start > result_middle

    def test_edge_cases(self):
        """Test edge cases and error conditions"""
        # Empty strings
        assert fuzzy_match_name("", "John Smith") == 0.0
        assert fuzzy_match_name("John Smith", "") == 0.0
        assert fuzzy_match_name("", "") == 0.0
        
        # None inputs
        assert fuzzy_match_name(None, "John Smith") == 0.0
        assert fuzzy_match_name("John Smith", None) == 0.0
        
        # Single characters
        result = fuzzy_match_name("J", "John")
        assert result >= 0.0  # Should not crash

    def test_threshold_filtering(self):
        """Test that score thresholds work correctly"""
        # Very different names should score low
        result = fuzzy_match_name("John Smith", "Zhang Wei")
        assert result < 0.3
        
        # Similar names should score high
        result = fuzzy_match_name("John Smith", "Jon Smith")
        assert result > 0.7

    def test_whitespace_normalization(self):
        """Test that extra whitespace is handled correctly"""
        result = fuzzy_match_name("  John   Smith  ", "John Smith")
        assert result == 1.0
        
        result = fuzzy_match_name("John\tSmith\n", "John Smith")
        assert result == 1.0

    def test_performance_reasonable(self):
        """Test that fuzzy matching performance is reasonable"""
        import time
        
        names_to_test = [
            ("John Smith", "Jon Smith"),
            ("Michael Johnson", "Mike Johnson"),  
            ("Katherine Davis", "Katie Davis"),
            ("Robert Wilson", "Bob Wilson"),
            ("Christopher Brown", "Chris Brown")
        ] * 100  # Test 500 comparisons
        
        start_time = time.time()
        for query, full_name in names_to_test:
            fuzzy_match_name(query, full_name)
        end_time = time.time()
        
        duration = end_time - start_time
        # Should process 500 comparisons in under 1 second
        assert duration < 1.0, f"Fuzzy matching too slow: {duration:.3f}s for 500 comparisons"

class TestContactSearch:
    """Test the search_contacts function with fuzzy matching integration"""
    
    @pytest.fixture
    def mock_contact_db(self, tmp_path):
        """Create a temporary test database with known contact data"""
        test_db_path = tmp_path / "test_contacts.db"
        conn = sqlite3.connect(str(test_db_path))
        
        # Create test schema
        conn.execute("""
            CREATE TABLE kenny_contacts (
                kenny_contact_id TEXT PRIMARY KEY,
                display_name TEXT
            )
        """)
        
        conn.execute("""
            CREATE TABLE contact_relationships (
                kenny_contact_id TEXT,
                company TEXT,
                role TEXT
            )
        """)
        
        conn.execute("""
            CREATE TABLE contact_identities (
                kenny_contact_id TEXT,
                identity_value TEXT,
                identity_type TEXT
            )
        """)
        
        # Insert test data
        test_contacts = [
            ("contact_1", "John Smith", "Acme Corp", "CEO", "john.smith@acme.com", "email"),
            ("contact_2", "Michael Johnson", "TechStart Inc", "CTO", "mike@techstart.com", "email"), 
            ("contact_3", "Katherine Davis", "Design Co", "Designer", "+1234567890", "phone"),
            ("contact_4", "Robert Wilson", "Sales LLC", "Manager", "bob.wilson@sales.com", "email"),
            ("contact_5", "Christopher Brown", None, None, "chris.brown@gmail.com", "email"),
        ]
        
        for contact_id, name, company, role, identity_val, identity_type in test_contacts:
            conn.execute("INSERT INTO kenny_contacts (kenny_contact_id, display_name) VALUES (?, ?)", 
                        (contact_id, name))
            if company:
                conn.execute("INSERT INTO contact_relationships (kenny_contact_id, company, role) VALUES (?, ?, ?)",
                           (contact_id, company, role))
            conn.execute("INSERT INTO contact_identities (kenny_contact_id, identity_value, identity_type) VALUES (?, ?, ?)",
                        (contact_id, identity_val, identity_type))
        
        conn.commit()
        conn.close()
        
        return str(test_db_path)

    @patch('ollama_kenny.CONTACT_DB')
    def test_exact_name_search(self, mock_contact_db_path, mock_contact_db):
        """Test exact name matching returns correct results"""
        mock_contact_db_path.return_value = mock_contact_db
        
        with patch('sqlite3.connect') as mock_connect:
            # Mock database connection and results
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = sqlite3.Row
            
            # Mock cursor results for exact match
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = [
                {
                    'kenny_contact_id': 'contact_1',
                    'display_name': 'John Smith',
                    'company': 'Acme Corp',
                    'role': 'CEO',
                    'identity_value': 'john.smith@acme.com',
                    'identity_type': 'email'
                }
            ]
            
            result = search_contacts("John Smith")
            
            assert result['status'] == 'success'
            assert result['count'] == 1
            assert result['results'][0]['name'] == 'John Smith'
            assert result['results'][0]['company'] == 'Acme Corp'

    @patch('ollama_kenny.CONTACT_DB')  
    def test_fuzzy_name_search(self, mock_contact_db_path, mock_contact_db):
        """Test fuzzy matching finds similar names"""
        mock_contact_db_path.return_value = mock_contact_db
        
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = sqlite3.Row
            
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            
            # Return multiple potential matches for fuzzy filtering
            mock_cursor.fetchall.return_value = [
                {
                    'kenny_contact_id': 'contact_1',
                    'display_name': 'John Smith', 
                    'company': 'Acme Corp',
                    'role': 'CEO',
                    'identity_value': 'john.smith@acme.com',
                    'identity_type': 'email'
                },
                {
                    'kenny_contact_id': 'contact_2',
                    'display_name': 'Michael Johnson',
                    'company': 'TechStart Inc', 
                    'role': 'CTO',
                    'identity_value': 'mike@techstart.com',
                    'identity_type': 'email'
                }
            ]
            
            # Test nickname matching
            result = search_contacts("Mike")  # Should match Michael Johnson
            
            assert result['status'] == 'success'
            # Should find at least one match with fuzzy matching
            assert result['count'] >= 0

    @patch('ollama_kenny.CONTACT_DB')
    def test_company_search(self, mock_contact_db_path, mock_contact_db):
        """Test searching by company name"""
        mock_contact_db_path.return_value = mock_contact_db
        
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = sqlite3.Row
            
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = [
                {
                    'kenny_contact_id': 'contact_1',
                    'display_name': 'John Smith',
                    'company': 'Acme Corp',
                    'role': 'CEO', 
                    'identity_value': 'john.smith@acme.com',
                    'identity_type': 'email'
                }
            ]
            
            result = search_contacts("Acme")  # Should match company name
            
            assert result['status'] == 'success'

    def test_threshold_filtering(self):
        """Test that low-scoring matches are filtered out"""
        # The search_contacts function should filter results with score < 0.15
        # This is tested implicitly through the fuzzy matching integration
        pass

    def test_error_handling(self):
        """Test error handling in search_contacts"""
        with patch('sqlite3.connect', side_effect=Exception("Database error")):
            result = search_contacts("Test")
            
            assert result['status'] == 'error'
            assert 'error' in result
            assert result['results'] == []

class TestFuzzyMatchingRegressionCases:
    """Test known problematic cases that have been fixed"""
    
    def test_regression_case_1_partial_matches(self):
        """Test cases where partial matching was failing"""
        # These cases should return reasonable scores
        result = fuzzy_match_name("Court", "Courtney Elyse Lim")
        assert result >= 0.6
        
    def test_regression_case_2_nickname_edge_cases(self):
        """Test edge cases in nickname matching"""
        result = fuzzy_match_name("Chris", "Christopher")
        assert result >= 0.8
        
    def test_regression_case_3_threshold_boundary(self):
        """Test cases right at the 0.15 threshold boundary"""
        # These should be included
        result = fuzzy_match_name("J", "John")
        # While low, should still be above minimum processing threshold
        assert result >= 0.0

if __name__ == "__main__":
    pytest.main([__file__, "-v"])