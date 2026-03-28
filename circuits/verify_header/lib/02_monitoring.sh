#!/bin/bash
# =============================================================================
# Module: Resource Monitoring & Hardware Metadata
# =============================================================================
# Provides: memory monitoring, artifact sizes, hardware metadata collection
# Dependencies: 01_platform.sh (PLATFORM, NODE_PATH)
# =============================================================================

# =============================================================================
# Memory Monitoring (per-process RSS sampling)
# =============================================================================

MEMORY_MONITOR_PID=""
MEMORY_PEAK_FILE=""

start_memory_monitor() {
    local target_pid=$1
    local output_file=$2
    local interval=${3:-0.5}

    MEMORY_PEAK_FILE="$output_file"
    echo "0" > "$MEMORY_PEAK_FILE"

    if [ "$PLATFORM" = "linux" ]; then
        (
            peak=0
            while kill -0 "$target_pid" 2>/dev/null; do
                rss=$(awk '/^VmRSS:/{print $2}' /proc/$target_pid/status 2>/dev/null || echo 0)
                [ "$rss" -gt "$peak" ] 2>/dev/null && peak=$rss
                echo $peak > "$MEMORY_PEAK_FILE"
                sleep "$interval"
            done
        ) &
        MEMORY_MONITOR_PID=$!
    elif [ "$PLATFORM" = "darwin" ]; then
        (
            peak=0
            while kill -0 "$target_pid" 2>/dev/null; do
                rss=$(ps -o rss= -p "$target_pid" 2>/dev/null | tr -d ' ')
                [ -n "$rss" ] && [ "$rss" -gt "$peak" ] 2>/dev/null && peak=$rss
                echo $peak > "$MEMORY_PEAK_FILE"
                sleep "$interval"
            done
        ) &
        MEMORY_MONITOR_PID=$!
    fi
}

stop_memory_monitor() {
    if [ -n "$MEMORY_MONITOR_PID" ]; then
        kill "$MEMORY_MONITOR_PID" 2>/dev/null
        wait "$MEMORY_MONITOR_PID" 2>/dev/null
    fi
    MEMORY_MONITOR_PID=""
    local peak_kb
    peak_kb=$(cat "$MEMORY_PEAK_FILE" 2>/dev/null || echo 0)
    echo $((peak_kb / 1024))
}

get_system_memory_snapshot() {
    if [ "$PLATFORM" = "linux" ]; then
        local total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
        local avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
        echo "{\"total_mb\":$((total/1024)),\"used_mb\":$(((total-avail)/1024)),\"available_mb\":$((avail/1024))}"
    elif [ "$PLATFORM" = "darwin" ]; then
        local total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        local page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local pages_free=$(vm_stat 2>/dev/null | awk '/Pages free:/{gsub(/\./,""); print $3}')
        local pages_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive:/{gsub(/\./,""); print $3}')
        pages_free=${pages_free:-0}
        pages_inactive=${pages_inactive:-0}
        local avail_bytes=$(( (pages_free + pages_inactive) * page_size ))
        echo "{\"total_mb\":$((total_bytes/1048576)),\"used_mb\":$(((total_bytes-avail_bytes)/1048576)),\"available_mb\":$((avail_bytes/1048576))}"
    else
        echo "{\"total_mb\":0,\"used_mb\":0,\"available_mb\":0}"
    fi
}

# =============================================================================
# Artifact Size Tracking
# =============================================================================

get_file_size_bytes() {
    local file=$1
    if [ ! -f "$file" ]; then echo 0; return; fi
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f%z "$file" 2>/dev/null || echo 0
    else
        stat -c%s "$file" 2>/dev/null || echo 0
    fi
}

format_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        local whole=$((bytes / 1073741824))
        local frac=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB" $whole $frac
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        local whole=$((bytes / 1048576))
        local frac=$(( (bytes % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MB" $whole $frac
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        local whole=$((bytes / 1024))
        local frac=$(( (bytes % 1024) * 10 / 1024 ))
        printf "%d.%d KB" $whole $frac
    else
        echo "${bytes} B"
    fi
}

# =============================================================================
# Hardware & Software Metadata
# =============================================================================

# Globals populated by collect_hw_metadata()
HW_CPU_MODEL="unknown"
HW_CPU_CORES=0
HW_RAM_TOTAL_MB=0
HW_OS="unknown"
SW_CIRCOM="unknown"
SW_SNARKJS="unknown"
SW_NODE="unknown"
SW_GIT_HASH="unknown"

collect_hw_metadata() {
    if [ "$PLATFORM" = "linux" ]; then
        HW_CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //')
        HW_CPU_CORES=$(nproc 2>/dev/null || echo 0)
        HW_RAM_TOTAL_MB=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024))
    elif [ "$PLATFORM" = "darwin" ]; then
        HW_CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
        HW_CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
        HW_RAM_TOTAL_MB=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576))
    fi

    HW_OS=$(uname -srm)
    SW_CIRCOM=$(circom --version 2>/dev/null | head -1 || echo "unknown")
    SW_SNARKJS=$(snarkjs --version 2>/dev/null || echo "unknown")
    SW_NODE=$($NODE_PATH --version 2>/dev/null || echo "unknown")
    SW_GIT_HASH=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
}
