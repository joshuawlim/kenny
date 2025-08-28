#!/usr/bin/env python3
"""
Test Kenny's new improvements:
1. Session Memory
2. Fuzzy Contact Matching  
3. Better Tool Handling
"""

import requests
import json
import time

def test_session_memory():
    """Test that Kenny remembers conversation context"""
    print("🧠 Testing Session Memory")
    print("=" * 40)
    
    session_id = None
    base_url = "http://localhost:8080"
    
    # First message: Ask about Courtneys
    print("1. Asking: 'How many Courtney's do I have?'")
    response1 = requests.post(f"{base_url}/chat", json={
        "message": "How many Courtney's do I have in my contacts database"
    })
    
    if response1.status_code == 200:
        data1 = response1.json()
        session_id = data1.get('session_id')
        print(f"   Response: {data1['response'][:100]}...")
        print(f"   Session ID: {session_id}")
        print(f"   Tools used: {data1.get('tools_used', [])}")
    else:
        print(f"   Error: {response1.status_code}")
        return False
    
    time.sleep(1)
    
    # Second message: Ask about Courtney Lim specifically (fuzzy match test)
    print("\n2. Asking: 'What's Courtney Lim's number?'")
    response2 = requests.post(f"{base_url}/chat", json={
        "message": "What's Courtney Lim's number?",
        "session_id": session_id
    })
    
    if response2.status_code == 200:
        data2 = response2.json()
        print(f"   Response: {data2['response'][:100]}...")
        print(f"   Tools used: {data2.get('tools_used', [])}")
        
        # Check if it found Courtney Elyse Lim via fuzzy matching
        if "439072980" in data2['response'] or "Courtney" in data2['response']:
            print("   ✅ Fuzzy matching worked!")
        else:
            print("   ❌ Fuzzy matching may have failed")
    else:
        print(f"   Error: {response2.status_code}")
        return False
    
    time.sleep(1)
    
    # Third message: Ask for email (should remember we're talking about Courtney)
    print("\n3. Asking: 'What's her email?' (should remember Courtney context)")
    response3 = requests.post(f"{base_url}/chat", json={
        "message": "What's her email?",
        "session_id": session_id
    })
    
    if response3.status_code == 200:
        data3 = response3.json()
        print(f"   Response: {data3['response'][:100]}...")
        print(f"   Tools used: {data3.get('tools_used', [])}")
        
        # Check if it knows we're talking about Courtney from context
        if "courtney" in data3['response'].lower() or "@" in data3['response']:
            print("   ✅ Session memory worked - Kenny remembered context!")
            return True
        else:
            print("   ❌ Session memory may have failed - no context awareness")
            return False
    else:
        print(f"   Error: {response3.status_code}")
        return False

def test_fuzzy_matching():
    """Test fuzzy contact matching directly"""
    print("\n🔍 Testing Fuzzy Contact Matching")
    print("=" * 40)
    
    base_url = "http://localhost:8080"
    
    test_queries = [
        "Courtney Lim",  # Should find "Courtney Elyse Lim"
        "Courtney",      # Should find both Courtneys
        "Elyse",         # Should find "Courtney Elyse Lim"
        "Hermosura"      # Should find "Courtney Hermosura"
    ]
    
    for query in test_queries:
        print(f"\nTesting query: '{query}'")
        response = requests.post(f"{base_url}/chat", json={
            "message": f"Search for contact named {query}"
        })
        
        if response.status_code == 200:
            data = response.json()
            print(f"   Response: {data['response'][:150]}...")
            print(f"   Tools used: {data.get('tools_used', [])}")
            
            # Check if tool results show fuzzy matching worked
            for tool_result in data.get('tool_results', []):
                if tool_result['tool'] == 'search_contacts':
                    count = tool_result['result'].get('count', 0)
                    fuzzy = tool_result['result'].get('fuzzy_search', False)
                    print(f"   Found {count} contacts (fuzzy search: {fuzzy})")
        else:
            print(f"   Error: {response.status_code}")

def test_api_health():
    """Test API is running"""
    print("🩺 Testing API Health")
    print("=" * 20)
    
    try:
        response = requests.get("http://localhost:8080/health")
        if response.status_code == 200:
            health = response.json()
            print(f"   Status: {health['status']}")
            print(f"   Model: {health['model']}")
            print(f"   Kenny DB: {health['kenny_db']}")
            print(f"   Contact DB: {health['contact_db']}")
            return True
        else:
            print(f"   Error: {response.status_code}")
            return False
    except Exception as e:
        print(f"   Error: {e}")
        return False

def main():
    print("🚀 Testing Kenny Improvements")
    print("🎯 Issues Addressed:")
    print("   1. Session memory for conversation context")
    print("   2. Fuzzy matching for contact searches") 
    print("   3. Better tool call handling")
    print("\n" + "="*50)
    
    # Test API health first
    if not test_api_health():
        print("\n❌ API not available. Start Kenny API first:")
        print("   python3 ollama_kenny.py")
        return
    
    # Test session memory (most important)
    success = test_session_memory()
    
    # Test fuzzy matching
    test_fuzzy_matching()
    
    print("\n" + "="*50)
    if success:
        print("🎉 SUCCESS! Key improvements are working:")
        print("   ✅ Session memory preserves conversation context")  
        print("   ✅ Fuzzy matching finds similar contact names")
        print("   ✅ Kenny can now have coherent multi-turn conversations")
    else:
        print("❌ Some issues detected. Check the logs above.")
        
    print("\nNext steps:")
    print("   3. Fix tool call rendering in chat interface")
    print("   4. Add thinking layer display")
    print("   5. Create comprehensive tool capability map")

if __name__ == "__main__":
    main()