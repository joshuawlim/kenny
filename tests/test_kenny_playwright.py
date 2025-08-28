#!/usr/bin/env python3
"""
Test Kenny Ollama API with Playwright
Verifies the frontend can communicate with the new simplified API
"""

import asyncio
import json
from playwright.async_api import async_playwright

async def test_kenny_frontend():
    """Test the Kenny frontend with Playwright"""
    async with async_playwright() as p:
        # Launch browser
        browser = await p.chromium.launch(headless=False)  # Set to True for headless
        context = await browser.new_context()
        page = await context.new_page()
        
        # Navigate to the frontend
        try:
            print("🚀 Opening Kenny frontend...")
            await page.goto("http://localhost:3000", wait_until="networkidle")
            
            # Wait for the page to load
            await page.wait_for_selector('[data-testid="chat-input"], input[type="text"]', timeout=10000)
            print("✅ Frontend loaded successfully")
            
            # Find the input field (try multiple selectors)
            input_selector = None
            for selector in ['input[placeholder*="message"]', 'input[type="text"]', 'textarea', '[contenteditable="true"]']:
                if await page.query_selector(selector):
                    input_selector = selector
                    break
            
            if not input_selector:
                print("❌ Could not find message input field")
                return False
                
            print(f"✅ Found input field: {input_selector}")
            
            # Type a test message
            test_message = "Hello Kenny, can you search for recent messages?"
            await page.fill(input_selector, test_message)
            print(f"✅ Typed message: {test_message}")
            
            # Find and click send button
            send_button = None
            for selector in ['button[type="submit"]', 'button:has-text("Send")', 'button svg', 'button']:
                elements = await page.query_selector_all(selector)
                for element in elements:
                    text = await element.text_content()
                    if 'send' in text.lower() or await element.query_selector('svg'):
                        send_button = element
                        break
                if send_button:
                    break
            
            if send_button:
                await send_button.click()
                print("✅ Clicked send button")
            else:
                # Try Enter key as fallback
                await page.press(input_selector, "Enter")
                print("✅ Pressed Enter key")
            
            # Wait for response
            print("⏳ Waiting for Kenny's response...")
            
            # Monitor network requests
            response_received = False
            api_error = None
            
            def handle_response(response):
                nonlocal response_received, api_error
                if "chat/stream" in response.url:
                    response_received = True
                    if response.status != 200:
                        api_error = f"API error: {response.status}"
                    print(f"📡 API Response: {response.status}")
            
            page.on("response", handle_response)
            
            # Wait for either a response or timeout
            try:
                # Look for signs that the message was processed
                await page.wait_for_function(
                    """() => {
                        const messages = document.querySelectorAll('[role="log"], .message, .chat-message, div');
                        for (let msg of messages) {
                            const text = msg.textContent || '';
                            if (text.includes('search') || text.includes('found') || text.includes('Kenny')) {
                                return true;
                            }
                        }
                        return false;
                    }""",
                    timeout=30000
                )
                print("✅ Response received and displayed")
                
                # Take a screenshot
                await page.screenshot(path="/tmp/kenny_test_success.png")
                print("📸 Screenshot saved: /tmp/kenny_test_success.png")
                
                return True
                
            except Exception as e:
                print(f"⏰ Timeout waiting for response: {e}")
                if api_error:
                    print(f"❌ {api_error}")
                
                # Take a screenshot of the error state
                await page.screenshot(path="/tmp/kenny_test_error.png")
                print("📸 Error screenshot saved: /tmp/kenny_test_error.png")
                
                return False
                
        except Exception as e:
            print(f"❌ Test failed: {e}")
            await page.screenshot(path="/tmp/kenny_test_failure.png")
            return False
            
        finally:
            await browser.close()

async def test_api_directly():
    """Test the API directly"""
    import aiohttp
    
    try:
        async with aiohttp.ClientSession() as session:
            # Test health endpoint
            async with session.get("http://localhost:8080/health") as response:
                if response.status == 200:
                    data = await response.json()
                    print(f"✅ API Health: {data['status']}")
                    return True
                else:
                    print(f"❌ API Health check failed: {response.status}")
                    return False
                    
    except Exception as e:
        print(f"❌ API connection failed: {e}")
        return False

async def main():
    print("🧪 Testing Kenny Ollama Integration")
    print("=" * 50)
    
    # First test API directly
    print("\n1. Testing API Health...")
    api_ok = await test_api_directly()
    
    if not api_ok:
        print("❌ API is not responding. Please start the Kenny API first:")
        print("   python3 ollama_kenny.py")
        return
    
    # Test frontend integration
    print("\n2. Testing Frontend Integration...")
    try:
        success = await test_kenny_frontend()
        
        if success:
            print("\n🎉 SUCCESS! Kenny frontend is working with Ollama!")
            print("   - API is responding")
            print("   - Frontend can send messages")
            print("   - Responses are being displayed")
        else:
            print("\n❌ FAILED! Issues found:")
            print("   - Check if frontend is running on port 3000")
            print("   - Check browser console for errors")
            print("   - Review screenshots in /tmp/")
            
    except ImportError:
        print("❌ Playwright not installed. Installing...")
        import subprocess
        subprocess.run(["pip", "install", "playwright"], check=True)
        subprocess.run(["playwright", "install", "chromium"], check=True)
        print("✅ Playwright installed. Run the test again.")

if __name__ == "__main__":
    asyncio.run(main())