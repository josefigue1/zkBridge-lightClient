#!/bin/bash
# =============================================================================
# Module: Path-Finding Utilities & Directory Setup
# =============================================================================
# Provides: find_ptau, find_rapidsnark, ensure_dirs
# Dependencies: 01_platform.sh
# Required globals: PTAU_PATHS, RAPIDSNARK_PATHS, PARTS, BUILD_DIR,
#                   VERIFIER_DIR, LOG_DIR
# =============================================================================

find_ptau() {
    for path in "${PTAU_PATHS[@]}"; do
        if [ -n "$path" ] && [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

find_rapidsnark() {
    for path in "${RAPIDSNARK_PATHS[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

ensure_dirs() {
    for part in "${PARTS[@]}"; do
        mkdir -p "$BUILD_DIR/$part"
    done
    mkdir -p "$VERIFIER_DIR"
    mkdir -p "$LOG_DIR"
}
