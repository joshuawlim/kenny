#!/usr/bin/env python3
"""
Kenny API Test Script
Tests the main API endpoints to verify functionality
"""

import requests
import json
import os
import time
import sys

# Configuration
API_KEY = os.getenv("KENNY_API_KEY", "kenny-dev-key-please-change-in-production")
BASE_URL = "http://localhost:8080"

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

def test_health():
    """Test health endpoint"""
    print("🏥 Testing health endpoint...")
    try:
        response = requests.get(f"{BASE_URL}/health", headers=headers)
        if response.status_code == 200:
            data = response.json()
            print(f"✅ Health: {data['status']}")
            print(f"   Kenny DB: {'✅' if data['kenny_db_connected'] else '❌'} ({data['document_count']} docs)")
            print(f"   Contact DB: {'✅' if data['contact_db_connected'] else '❌'} ({data['contact_count']} contacts)")
            return True
        else:
            print(f"❌ Health check failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Health check error: {e}")
        return False

def test_contacts():
    """Test contacts endpoint"""
    print("\n👥 Testing contacts endpoint...")
    try:
        response = requests.get(f"{BASE_URL}/contacts?limit=5", headers=headers)
        if response.status_code == 200:
            data = response.json()
            contacts = data.get("contacts", [])
            print(f"✅ Found {len(contacts)} contacts")
            
            if contacts:
                contact = contacts[0]
                print(f"   Sample: {contact['display_name']} ({len(contact['identities'])} identities)")
                return contact['kenny_contact_id']
            return None
        else:
            print(f"❌ Contacts failed: {response.status_code}")
            return None
    except Exception as e:
        print(f"❌ Contacts error: {e}")
        return None

def test_search():
    """Test search endpoint"""
    print("\n🔍 Testing search endpoint...")
    try:
        # Use GET with query parameters
        response = requests.get(f"{BASE_URL}/search?q=meeting&limit=3", headers=headers)
        if response.status_code == 200:
            data = response.json()
            results = data.get("results", [])
            print(f"✅ Search found {len(results)} results in {data.get('took_ms', 0)}ms")
            
            if results:
                result = results[0]
                print(f"   Top result: {result['title'][:50]}... (score: {result['score']:.2f})")
            
            contact_breakdown = data.get("contact_breakdown", {})
            if contact_breakdown:
                print(f"   Contact breakdown: {len(contact_breakdown)} contacts involved")
            
            return True
        else:
            print(f"❌ Search failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Search error: {e}")
        return False

def test_contact_thread(contact_id):
    """Test contact thread endpoint"""
    if not contact_id:
        return False
        
    print(f"\n💬 Testing contact thread for {contact_id[:8]}...")
    try:
        response = requests.get(f"{BASE_URL}/contacts/{contact_id}/thread?limit=3", headers=headers)
        if response.status_code == 200:
            data = response.json()
            messages = data.get("messages", [])
            print(f"✅ Thread found: {data['display_name']} ({len(messages)} messages)")
            
            if messages:
                recent = messages[0]
                print(f"   Recent: {recent['source']} - {recent['content'][:50]}...")
            
            return True
        elif response.status_code == 404:
            print("⚠️  Contact thread not found (expected for some contacts)")
            return True
        else:
            print(f"❌ Contact thread failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Contact thread error: {e}")
        return False

def test_tools():
    """Test tools endpoint"""
    print("\n🔧 Testing tools endpoint...")
    try:
        response = requests.get(f"{BASE_URL}/tools", headers=headers)
        if response.status_code == 200:
            data = response.json()
            tools = data.get("tools", [])
            print(f"✅ Found {len(tools)} available tools")
            
            for tool in tools[:3]:  # Show first 3
                print(f"   • {tool['name']}: {tool['description'][:60]}...")
            
            return True
        else:
            print(f"❌ Tools failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Tools error: {e}")
        return False

def test_tool_execution():
    """Test tool execution"""
    print("\n⚙️  Testing tool execution...")
    try:
        tool_data = {
            "name": "get_system_status",
            "parameters": {}
        }
        response = requests.post(f"{BASE_URL}/tools/execute", headers=headers, json=tool_data)
        if response.status_code == 200:
            data = response.json()
            status = data.get("status", "unknown")
            print(f"✅ Tool execution: {status}")
            
            if status == "success" and "data" in data:
                result_data = data.get("data", {})
                if "document_count" in result_data:
                    print(f"   Documents: {result_data['document_count']}")
                elif "raw_output" in result_data:
                    print(f"   Output: {result_data['raw_output'][:50]}...")
            
            return True
        else:
            print(f"❌ Tool execution failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Tool execution error: {e}")
        return False

def test_streaming_assistant():
    """Test streaming assistant (basic connection test)"""
    print("\n🤖 Testing streaming assistant connection...")
    try:
        assistant_data = {
            "query": "test query",
            "mode": "search"
        }
        response = requests.post(f"{BASE_URL}/assistant/query", headers=headers, json=assistant_data, stream=True)
        if response.status_code == 200:
            # Just test that we can connect - don't process the full stream
            print("✅ Streaming assistant endpoint accessible")
            response.close()
            return True
        else:
            print(f"❌ Streaming assistant failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Streaming assistant error: {e}")
        return False

def main():
    """Run all tests"""
    print("🧪 Kenny API Test Suite")
    print("=" * 50)
    
    # Test if server is running
    try:
        requests.get(f"{BASE_URL}/health", timeout=5)
    except:
        print("❌ Server not responding. Is it running?")
        print(f"   Start with: cd {os.path.dirname(__file__)} && ./start.sh")
        sys.exit(1)
    
    tests_passed = 0
    total_tests = 7
    
    # Run tests
    if test_health(): tests_passed += 1
    
    contact_id = test_contacts()
    if contact_id: tests_passed += 1
    
    if test_search(): tests_passed += 1
    if test_contact_thread(contact_id): tests_passed += 1
    if test_tools(): tests_passed += 1
    if test_tool_execution(): tests_passed += 1
    if test_streaming_assistant(): tests_passed += 1
    
    # Summary
    print("\n" + "=" * 50)
    print(f"📊 Test Results: {tests_passed}/{total_tests} passed")
    
    if tests_passed == total_tests:
        print("🎉 All tests passed! Kenny API is ready.")
        return 0
    else:
        print(f"⚠️  {total_tests - tests_passed} tests failed. Check the output above.")
        return 1

if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)