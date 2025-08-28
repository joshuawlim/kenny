#!/bin/bash

# Emergency stop script for Kenny services
echo "🛑 Emergency stop - killing all Kenny services..."

# Kill processes by name/pattern
pkill -f "python3 ollama_kenny.py" 2>/dev/null || true
pkill -f "python3 main.py" 2>/dev/null || true  # Legacy cleanup
pkill -f "next-server" 2>/dev/null || true
pkill -f "npm run dev" 2>/dev/null || true
pkill -f "node.*next" 2>/dev/null || true

# Clean up PID files
rm -f /tmp/kenny-api.pid
rm -f /tmp/kenny-frontend.pid
rm -f /tmp/kenny-ollama.pid

# Kill processes on specific ports
lsof -ti:8080 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true

echo "✅ All Kenny services stopped"

# Show remaining processes (if any)
if pgrep -f "kenny|ollama|next" >/dev/null 2>&1; then
    echo ""
    echo "⚠️  Some processes may still be running:"
    pgrep -f "kenny|ollama|next" -l || true
fi