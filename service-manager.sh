#!/bin/bash

# Kenny Service Manager
# Manages all Kenny services: API, Frontend, and Ollama

set -e

KENNY_ROOT="/Users/joshwlim/Documents/Kenny"
KENNY_API_DIR="$KENNY_ROOT/kenny-api"
FRONTEND_DIR="$KENNY_ROOT/v0-kenny-frontend"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# PID files for tracking services
API_PID_FILE="/tmp/kenny-api.pid"
FRONTEND_PID_FILE="/tmp/kenny-frontend.pid"
OLLAMA_PID_FILE="/tmp/kenny-ollama.pid"

print_status() {
    echo -e "${BLUE}📊 Kenny Services Status:${NC}"
    echo ""
    
    # Check Kenny API
    if check_service_running "$API_PID_FILE" "ollama_kenny.py"; then
        echo -e "  ${GREEN}✅ Kenny Ollama API${NC} - Running on port 8080"
    else
        echo -e "  ${RED}❌ Kenny Ollama API${NC} - Stopped"
    fi
    
    # Check Frontend
    if check_service_running "$FRONTEND_PID_FILE" "next-server"; then
        echo -e "  ${GREEN}✅ Frontend${NC} - Running on port 3000"
    else
        echo -e "  ${RED}❌ Frontend${NC} - Stopped"
    fi
    
    # Check Ollama
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Ollama${NC} - Running on port 11434"
    else
        echo -e "  ${RED}❌ Ollama${NC} - Stopped"
    fi
    
    echo ""
}

check_service_running() {
    local pid_file="$1"
    local process_name="$2"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if pgrep -f "$process_name" | grep -q "^$pid$"; then
                return 0
            fi
        fi
        # Clean up stale PID file
        rm -f "$pid_file"
    fi
    return 1
}

stop_all() {
    echo -e "${YELLOW}🛑 Stopping all Kenny services...${NC}"
    
    # Stop Kenny API
    if check_service_running "$API_PID_FILE" "ollama_kenny.py"; then
        echo "Stopping Kenny API..."
        kill $(cat "$API_PID_FILE") 2>/dev/null || true
        rm -f "$API_PID_FILE"
    fi
    
    # Stop Frontend
    if check_service_running "$FRONTEND_PID_FILE" "next-server"; then
        echo "Stopping Frontend..."
        kill $(cat "$FRONTEND_PID_FILE") 2>/dev/null || true
        rm -f "$FRONTEND_PID_FILE"
    fi
    
    # Stop Ollama (if managed by us)
    if [ -f "$OLLAMA_PID_FILE" ]; then
        echo "Stopping Ollama..."
        kill $(cat "$OLLAMA_PID_FILE") 2>/dev/null || true
        rm -f "$OLLAMA_PID_FILE"
    fi
    
    # Force kill any remaining processes
    pkill -f "python3 ollama_kenny.py" 2>/dev/null || true
    pkill -f "python3 main.py" 2>/dev/null || true  # Legacy cleanup
    pkill -f "next-server" 2>/dev/null || true
    
    echo -e "${GREEN}✅ All services stopped${NC}"
}

start_ollama() {
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Ollama already running${NC}"
        return
    fi
    
    echo -e "${BLUE}🤖 Starting Ollama...${NC}"
    nohup ollama serve > /tmp/ollama.log 2>&1 &
    echo $! > "$OLLAMA_PID_FILE"
    
    # Wait for Ollama to be ready
    for i in {1..30}; do
        if curl -s http://localhost:11434/api/version >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Ollama started on port 11434${NC}"
            return
        fi
        sleep 1
    done
    
    echo -e "${RED}❌ Ollama failed to start${NC}"
}

start_api() {
    if check_service_running "$API_PID_FILE" "ollama_kenny.py"; then
        echo -e "${GREEN}✅ Kenny API already running${NC}"
        return
    fi
    
    echo -e "${BLUE}🚀 Starting Kenny Ollama API...${NC}"
    cd "$KENNY_API_DIR"
    
    # Check if Ollama is running
    if ! curl -s http://localhost:11434/api/version >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Ollama not running. Starting Ollama first...${NC}"
        start_ollama
        sleep 3
    fi
    
    # Start new Ollama-based API in background
    nohup python3 ollama_kenny.py > /tmp/kenny-api.log 2>&1 &
    echo $! > "$API_PID_FILE"
    
    # Wait for API to be ready
    for i in {1..30}; do
        if curl -s http://localhost:8080/health >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Kenny Ollama API started on port 8080${NC}"
            return
        fi
        sleep 1
    done
    
    echo -e "${RED}❌ Kenny API failed to start${NC}"
}

start_frontend() {
    if check_service_running "$FRONTEND_PID_FILE" "next-server"; then
        echo -e "${GREEN}✅ Frontend already running${NC}"
        return
    fi
    
    echo -e "${BLUE}🌐 Starting Frontend...${NC}"
    cd "$FRONTEND_DIR"
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        echo "Installing frontend dependencies..."
        npm install
    fi
    
    # Start frontend in background
    nohup npm run dev > /tmp/kenny-frontend.log 2>&1 &
    echo $! > "$FRONTEND_PID_FILE"
    
    # Wait for frontend to be ready
    for i in {1..30}; do
        if curl -s http://localhost:3000 >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Frontend started on port 3000${NC}"
            return
        fi
        sleep 1
    done
    
    echo -e "${RED}❌ Frontend failed to start${NC}"
}

start_all() {
    echo -e "${BLUE}🚀 Starting all Kenny services...${NC}"
    echo ""
    
    start_ollama
    sleep 2
    start_api
    sleep 2
    start_frontend
    
    echo ""
    print_status
    
    echo -e "${GREEN}🌟 All services started!${NC}"
    echo ""
    echo -e "${BLUE}📱 Access points:${NC}"
    echo "   Frontend: http://localhost:3000"
    echo "   API: http://localhost:8080"
    echo "   Ollama: http://localhost:11434"
}

open_terminals() {
    echo -e "${BLUE}🖥️  Opening service terminals...${NC}"
    
    # Stop services first if running
    stop_all
    sleep 2
    
    # Open three terminals with services
    osascript <<EOF
tell application "Terminal"
    do script "cd '$KENNY_API_DIR' && echo '🚀 Kenny Ollama API Terminal' && echo 'Starting in 3 seconds...' && sleep 3 && python3 ollama_kenny.py"
    do script "cd '$FRONTEND_DIR' && echo '🌐 Frontend Terminal' && echo 'Starting in 5 seconds...' && sleep 5 && npm run dev"
    do script "echo '🤖 Ollama Terminal' && echo 'Starting Ollama in 7 seconds...' && sleep 7 && ollama serve"
    activate
end tell
EOF
    
    echo -e "${GREEN}✅ Terminals opened${NC}"
    echo "Services will start automatically in separate terminals"
}

show_logs() {
    echo -e "${BLUE}📜 Service Logs:${NC}"
    echo ""
    
    echo -e "${YELLOW}=== Kenny API Logs ===${NC}"
    tail -20 /tmp/kenny-api.log 2>/dev/null || echo "No API logs found"
    
    echo ""
    echo -e "${YELLOW}=== Frontend Logs ===${NC}"
    tail -20 /tmp/kenny-frontend.log 2>/dev/null || echo "No Frontend logs found"
    
    echo ""
    echo -e "${YELLOW}=== Ollama Logs ===${NC}"
    tail -20 /tmp/ollama.log 2>/dev/null || echo "No Ollama logs found"
}

usage() {
    echo "Kenny Service Manager"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start       - Start all services in background"
    echo "  stop        - Stop all services"
    echo "  restart     - Restart all services"
    echo "  status      - Show service status"
    echo "  terminals   - Open three terminals for manual service management"
    echo "  logs        - Show recent logs from all services"
    echo "  help        - Show this help message"
    echo ""
}

case "${1:-status}" in
    start)
        start_all
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 3
        start_all
        ;;
    status)
        print_status
        ;;
    terminals)
        open_terminals
        ;;
    logs)
        show_logs
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo ""
        usage
        exit 1
        ;;
esac