#!/usr/bin/env python3
"""
Test suite for Tool Parameter Signature Mismatch Fix

Tests parameter compatibility between Python kenny-api functions
and Swift mac_tools orchestrator_cli expected signatures.

Critical Fix #1: Tool Parameter Signature Mismatch Fix
"""

import pytest
import sys
import inspect
from pathlib import Path
from unittest.mock import patch, MagicMock
from typing import Dict, Any

# Add kenny-api to path
kenny_api_path = Path(__file__).parent.parent.parent / "kenny-api"
sys.path.insert(0, str(kenny_api_path))

from main import OrchestratorService
from ollama_kenny import search_documents, search_contacts, get_recent_messages

class TestParameterSignatureCompatibility:
    """Test that Python and Swift tool parameters are compatible"""
    
    def test_get_recent_messages_signature(self):
        """Test get_recent_messages has correct parameter signature"""
        sig = inspect.signature(get_recent_messages)
        params = list(sig.parameters.keys())
        
        # Should have exactly these parameters with defaults
        expected_params = ['days', 'source', 'limit']
        assert params == expected_params
        
        # Check parameter defaults
        assert sig.parameters['days'].default == 7
        assert sig.parameters['source'].default is None  
        assert sig.parameters['limit'].default == 50

    def test_get_recent_messages_parameter_types(self):
        """Test get_recent_messages parameter types are correct"""
        sig = inspect.signature(get_recent_messages)
        
        # days should accept int
        days_param = sig.parameters['days']
        assert days_param.annotation == int or days_param.annotation == inspect.Signature.empty
        
        # source should accept Optional[str] (None or str)
        # limit should accept int

    def test_search_documents_signature(self):
        """Test search_documents has correct parameter signature"""
        sig = inspect.signature(search_documents)
        params = list(sig.parameters.keys())
        
        expected_params = ['query', 'limit', 'source']
        assert params == expected_params
        
        # Check defaults
        assert sig.parameters['limit'].default == 10
        assert sig.parameters['source'].default is None

    def test_search_contacts_signature(self):
        """Test search_contacts has correct parameter signature"""
        sig = inspect.signature(search_contacts)
        params = list(sig.parameters.keys())
        
        expected_params = ['name']
        assert params == expected_params

    def test_orchestrator_execute_tool_compatibility(self):
        """Test that orchestrator execute_tool can handle all function signatures"""
        # Create mock orchestrator service
        mock_db_manager = MagicMock()
        orchestrator = OrchestratorService("/fake/path")
        
        # Test get_recent_messages tool execution
        with patch('main.get_recent_messages') as mock_get_recent:
            mock_get_recent.return_value = {"status": "success", "results": []}
            
            # Test with all parameters
            result = orchestrator.execute_tool("get_recent_messages", {
                "days": 14,
                "source": "whatsapp",
                "limit": 25
            })
            
            # Should call with correct parameters
            mock_get_recent.assert_called_once_with(days=14, source="whatsapp", limit=25)
        
        # Test with partial parameters (should use defaults)
        with patch('main.get_recent_messages') as mock_get_recent:
            mock_get_recent.return_value = {"status": "success", "results": []}
            
            result = orchestrator.execute_tool("get_recent_messages", {
                "days": 7
            })
            
            # Should use defaults for missing parameters
            mock_get_recent.assert_called_once_with(days=7, source=None, limit=50)

class TestToolParameterValidation:
    """Test parameter validation and error handling"""
    
    def test_get_recent_messages_parameter_validation(self):
        """Test get_recent_messages validates parameters correctly"""
        # Valid parameters should work
        result = get_recent_messages(days=7, source="whatsapp", limit=10)
        assert isinstance(result, dict)
        assert 'status' in result
        
        # Invalid days should be handled gracefully
        with patch('sqlite3.connect'):
            result = get_recent_messages(days=0, source=None, limit=10)
            # Should not crash, may return empty results
            assert isinstance(result, dict)

    def test_search_documents_parameter_validation(self):
        """Test search_documents validates parameters correctly"""
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = MagicMock()
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = []
            
            # Valid query should work
            result = search_documents("test query", limit=5, source="mail")
            assert result['status'] == 'success'
            
            # Empty query should be handled
            result = search_documents("", limit=10)
            assert isinstance(result, dict)

    def test_search_contacts_parameter_validation(self):
        """Test search_contacts validates parameters correctly"""
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = MagicMock()
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = []
            
            # Valid name should work
            result = search_contacts("John Smith")
            assert result['status'] == 'success'
            
            # Empty name should be handled gracefully
            result = search_contacts("")
            assert isinstance(result, dict)

class TestCrossSystemCompatibility:
    """Test that Python functions can be called from Swift with expected results"""
    
    @pytest.fixture
    def mock_orchestrator_service(self):
        """Create a mock orchestrator service for testing"""
        return OrchestratorService("/fake/orchestrator/path")

    def test_tool_execution_return_format(self, mock_orchestrator_service):
        """Test that all tools return consistent format for Swift consumption"""
        
        # Test get_recent_messages return format
        with patch('main.get_recent_messages') as mock_func:
            expected_return = {
                "status": "success",
                "count": 5,
                "days": 7,
                "results": [
                    {"title": "Test Message", "content": "Test content", "source": "whatsapp", "created_at": "2024-01-01"}
                ]
            }
            mock_func.return_value = expected_return
            
            result = mock_orchestrator_service.execute_tool("get_recent_messages", {"days": 7})
            
            assert result["status"] == "success"
            assert "data" in result
            assert result["data"]["count"] == 5
            assert isinstance(result["data"]["results"], list)

    def test_error_handling_consistency(self, mock_orchestrator_service):
        """Test that error handling is consistent across all tools"""
        
        # Test database connection error
        with patch('main.get_recent_messages', side_effect=Exception("DB Error")):
            result = mock_orchestrator_service.execute_tool("get_recent_messages", {"days": 7})
            
            assert result["status"] == "error"
            assert "error" in result
            assert isinstance(result["error"], str)

    def test_parameter_passthrough(self, mock_orchestrator_service):
        """Test that parameters are passed through correctly to underlying functions"""
        
        # Test search_documents parameter passthrough
        with patch('main.db_manager') as mock_db:
            mock_db.get_kenny_connection.return_value = MagicMock()
            
            with patch('sqlite3.connect') as mock_connect:
                mock_conn = MagicMock()
                mock_connect.return_value = mock_conn
                mock_conn.row_factory = MagicMock()
                mock_cursor = MagicMock()
                mock_conn.cursor.return_value = mock_cursor
                mock_cursor.fetchall.return_value = []
                
                # Test complex parameter set
                params = {
                    "query": "complex search query",
                    "limit": 25,
                    "sources": "whatsapp,mail,messages"
                }
                
                result = mock_orchestrator_service.execute_tool("search_documents", params)
                
                # Should not crash and should return proper structure
                assert isinstance(result, dict)
                assert "status" in result

class TestParameterDefaultHandling:
    """Test that default parameter handling works correctly"""
    
    def test_get_recent_messages_defaults(self):
        """Test default parameter handling for get_recent_messages"""
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = MagicMock()
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = []
            
            # Call with no parameters - should use all defaults
            result = get_recent_messages()
            
            assert isinstance(result, dict)
            assert result['status'] == 'success'
            assert result['days'] == 7  # Default value
            
            # Verify SQL was called with default values
            # (This tests that the defaults are actually used in the implementation)
            mock_cursor.execute.assert_called()
            sql_call = mock_cursor.execute.call_args[0]
            assert '-7 days' in sql_call[1][0]  # Default days parameter in SQL

    def test_search_documents_defaults(self):
        """Test default parameter handling for search_documents"""
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = MagicMock()
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = []
            
            # Call with only required parameter
            result = search_documents("test query")
            
            assert isinstance(result, dict)
            assert result['status'] == 'success'
            
            # Check that default limit was applied
            sql_call = mock_cursor.execute.call_args[0]
            assert 'LIMIT 10' in sql_call[0]  # Default limit

class TestBackwardCompatibility:
    """Test that changes maintain backward compatibility"""
    
    def test_function_signatures_unchanged(self):
        """Test that core function signatures haven't changed unexpectedly"""
        # get_recent_messages signature
        sig = inspect.signature(get_recent_messages)
        assert len(sig.parameters) == 3  # days, source, limit
        
        # search_documents signature  
        sig = inspect.signature(search_documents)
        assert len(sig.parameters) == 3  # query, limit, source
        
        # search_contacts signature
        sig = inspect.signature(search_contacts)
        assert len(sig.parameters) == 1  # name

    def test_return_format_consistency(self):
        """Test that return formats are consistent"""
        with patch('sqlite3.connect') as mock_connect:
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            mock_conn.row_factory = MagicMock()  
            mock_cursor = MagicMock()
            mock_conn.cursor.return_value = mock_cursor
            mock_cursor.fetchall.return_value = []
            
            # All functions should return dict with 'status' key
            result = get_recent_messages()
            assert isinstance(result, dict) and 'status' in result
            
            result = search_documents("test")
            assert isinstance(result, dict) and 'status' in result
            
            result = search_contacts("test")
            assert isinstance(result, dict) and 'status' in result

if __name__ == "__main__":
    pytest.main([__file__, "-v"])