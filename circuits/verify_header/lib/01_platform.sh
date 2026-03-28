#!/bin/bash
# =============================================================================
# Module: Platform Detection, Colors, Logging, Timestamps
# =============================================================================
# Provides: PLATFORM, color constants, log_*, check_command, now_ms
# Dependencies: none (must be sourced first)
# =============================================================================

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Platform detection
PLATFORM="unknown"
case "$(uname -s)" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="darwin" ;;
esac

# =============================================================================
# High-Resolution Timestamps (millisecond precision)
# =============================================================================

now_ms() {
    if [ "$PLATFORM" = "linux" ]; then
        echo $(( $(date +%s%N) / 1000000 ))
    elif command -v python3 &>/dev/null; then
        python3 -c "import time; print(int(time.time()*1000))"
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

get_elapsed_ms() {
    local start_ms=$1
    local end_ms=$(now_ms)
    echo $((end_ms - start_ms))
}

get_elapsed_seconds() {
    local start_ms=$1
    local end_ms=$(now_ms)
    echo $(( (end_ms - start_ms) / 1000 ))
}

# =============================================================================
# Logging
# =============================================================================

log_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_step() {
    echo -e "${GREEN}---> $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

log_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

log_info() {
    echo -e "     $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed."
        exit 1
    fi
}
