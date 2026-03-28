#!/bin/bash
# =============================================================================
# Module: Timing & Metrics System
# =============================================================================
# Provides: init_timing, record_*, format_duration*, save/print timing reports
# Dependencies: 01_platform.sh, 02_monitoring.sh
# Required globals: PARTS, BUILD_DIR, CIRCUIT_PREFIX, NUM_VALIDATORS,
#                   NODE_MEM, NODE_PATH, LOG_DIR, PIPELINE_LABEL
# =============================================================================

TIMING_FILE=""
PIPELINE_START_TIME_MS=""

# Bash 3 compatible associative array helpers (no declare -A)
_sanitize_key() { echo "$1" | sed 's/[^a-zA-Z0-9_]/_/g'; }
aa_set() { eval "__AA_${1}_$(_sanitize_key "$2")=\"$3\""; }
aa_get() { eval "echo \"\${__AA_${1}_$(_sanitize_key "$2")}\""; }

TOTAL_COMPILE_MS=0
TOTAL_WITNESS_MS=0
TOTAL_ZKEY_MS=0
TOTAL_PROOF_MS=0
TOTAL_VERIFY_MS=0

init_timing() {
    PIPELINE_START_TIME_MS=$(now_ms)
    TIMING_FILE="$LOG_DIR/metrics_$(date '+%Y%m%d_%H%M%S').json"

    collect_hw_metadata

    for part in "${PARTS[@]}"; do
        aa_set TIMING_COMPILE_MS "$part" 0
        aa_set TIMING_WITNESS_MS "$part" 0
        aa_set TIMING_ZKEY_MS "$part" 0
        aa_set TIMING_PROOF_MS "$part" 0
        aa_set TIMING_VERIFY_MS "$part" 0
        aa_set CONSTRAINTS_COUNT "$part" 0
        aa_set PROVER_USED "$part" "none"
        aa_set PEAK_RSS_COMPILE "$part" 0
        aa_set PEAK_RSS_WITNESS "$part" 0
        aa_set PEAK_RSS_ZKEY "$part" 0
        aa_set PEAK_RSS_PROOF "$part" 0
        aa_set ARTIFACT_R1CS_BYTES "$part" 0
        aa_set ARTIFACT_ZKEY_BYTES "$part" 0
        aa_set ARTIFACT_WTNS_BYTES "$part" 0
        aa_set ARTIFACT_PROOF_BYTES "$part" 0
        aa_set WITNESS_GENERATOR_TYPE "$part" "unknown"
    done
}

# =============================================================================
# Duration Formatters
# =============================================================================

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local mins=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $mins $secs
    elif [ $mins -gt 0 ]; then
        printf "%dm %ds" $mins $secs
    else
        printf "%ds" $secs
    fi
}

format_duration_ms() {
    local ms=$1
    local seconds=$((ms / 1000))
    local frac=$((ms % 1000))
    local hours=$((seconds / 3600))
    local mins=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %d.%03ds" $hours $mins $secs $frac
    elif [ $mins -gt 0 ]; then
        printf "%dm %d.%03ds" $mins $secs $frac
    else
        printf "%d.%03ds" $secs $frac
    fi
}

# =============================================================================
# Recording Functions
# =============================================================================

record_timing() {
    local phase=$1
    local part=$2
    local ms=$3

    case $phase in
        compile)  aa_set TIMING_COMPILE_MS "$part" "$ms"; TOTAL_COMPILE_MS=$((TOTAL_COMPILE_MS + ms)) ;;
        witness)  aa_set TIMING_WITNESS_MS "$part" "$ms"; TOTAL_WITNESS_MS=$((TOTAL_WITNESS_MS + ms)) ;;
        zkey)     aa_set TIMING_ZKEY_MS "$part" "$ms";    TOTAL_ZKEY_MS=$((TOTAL_ZKEY_MS + ms)) ;;
        proof)    aa_set TIMING_PROOF_MS "$part" "$ms";   TOTAL_PROOF_MS=$((TOTAL_PROOF_MS + ms)) ;;
        verify)   aa_set TIMING_VERIFY_MS "$part" "$ms";  TOTAL_VERIFY_MS=$((TOTAL_VERIFY_MS + ms)) ;;
    esac

    # Auto-save: rewrite full JSON so `tail -f` or `watch cat` can track progress
    [ -n "$TIMING_FILE" ] && save_timing_report 2>/dev/null || true
}

record_constraints() {
    aa_set CONSTRAINTS_COUNT "$1" "$2"
}

record_prover() {
    aa_set PROVER_USED "$1" "$2"
}

record_peak_rss() {
    local phase=$1 part=$2 rss_mb=$3
    case $phase in
        compile) aa_set PEAK_RSS_COMPILE "$part" "$rss_mb" ;;
        witness) aa_set PEAK_RSS_WITNESS "$part" "$rss_mb" ;;
        zkey)    aa_set PEAK_RSS_ZKEY "$part" "$rss_mb" ;;
        proof)   aa_set PEAK_RSS_PROOF "$part" "$rss_mb" ;;
    esac
}

record_artifact_sizes() {
    local part=$1
    local build_dir="$BUILD_DIR/$part"
    local circuit_name="${CIRCUIT_PREFIX}_${part}"

    aa_set ARTIFACT_R1CS_BYTES "$part" "$(get_file_size_bytes "$build_dir/${circuit_name}.r1cs")"
    aa_set ARTIFACT_ZKEY_BYTES "$part" "$(get_file_size_bytes "$build_dir/${circuit_name}.zkey")"
    aa_set ARTIFACT_WTNS_BYTES "$part" "$(get_file_size_bytes "$build_dir/witness.wtns")"
    aa_set ARTIFACT_PROOF_BYTES "$part" "$(get_file_size_bytes "$build_dir/proof.json")"
}

compute_throughput() {
    local constraints=$1 ms=$2
    if [ "$ms" -gt 0 ] && [ "$constraints" -gt 0 ] 2>/dev/null; then
        local whole=$(( constraints * 1000 / ms ))
        local frac=$(( (constraints * 10000 / ms) % 10 ))
        echo "${whole}.${frac}"
    else
        echo "0"
    fi
}

# =============================================================================
# Save JSON Report
# =============================================================================

save_timing_report_partial() {
    log_warn "Pipeline interrupted - saving partial metrics..."
    save_timing_report
}

save_timing_report() {
    local end_ms=$(now_ms)
    local total_ms=$((end_ms - PIPELINE_START_TIME_MS))
    local mem_snapshot=$(get_system_memory_snapshot)

    local total_constraints=0
    for part in "${PARTS[@]}"; do
        total_constraints=$((total_constraints + $(aa_get CONSTRAINTS_COUNT "$part")))
    done

    cat > "$TIMING_FILE" << JSONEOF
{
  "metadata": {
    "timestamp_iso": "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')",
    "script": "$(basename "$0")",
    "git_commit": "$SW_GIT_HASH",
    "validators": $NUM_VALIDATORS,
    "parts": ${#PARTS[@]},
    "label": "${PIPELINE_LABEL:-unknown}",
    "hardware": {
      "cpu_model": "$HW_CPU_MODEL",
      "cpu_cores": $HW_CPU_CORES,
      "ram_total_mb": $HW_RAM_TOTAL_MB,
      "os": "$HW_OS",
      "platform": "$PLATFORM"
    },
    "software": {
      "circom_version": "$SW_CIRCOM",
      "snarkjs_version": "$SW_SNARKJS",
      "node_version": "$SW_NODE",
      "node_max_old_space_mb": $NODE_MEM,
      "node_path": "$NODE_PATH",
      "rapidsnark_available": $([ -n "$(find_rapidsnark 2>/dev/null)" ] && echo "true" || echo "false")
    },
    "ptau_file": "${PTAU_FILE:-null}"
  },
  "summary": {
    "total_wall_time_ms": $total_ms,
    "total_wall_time_formatted": "$(format_duration_ms $total_ms)",
    "total_constraints": $total_constraints,
    "compile_ms": $TOTAL_COMPILE_MS,
    "witness_ms": $TOTAL_WITNESS_MS,
    "zkey_ms": $TOTAL_ZKEY_MS,
    "proof_ms": $TOTAL_PROOF_MS,
    "verify_ms": $TOTAL_VERIFY_MS,
    "system_memory_at_end": $mem_snapshot
  },
  "parts": {
JSONEOF

    local first=1
    for part in "${PARTS[@]}"; do
        [ $first -eq 0 ] && echo "," >> "$TIMING_FILE"
        first=0
        local c=$(aa_get CONSTRAINTS_COUNT "$part")
        local prove_ms=$(aa_get TIMING_PROOF_MS "$part")
        local compile_ms=$(aa_get TIMING_COMPILE_MS "$part")
        record_artifact_sizes "$part"
        cat >> "$TIMING_FILE" << PARTEOF
    "$part": {
      "constraints": $c,
      "prover": "$(aa_get PROVER_USED "$part")",
      "witness_generator": "$(aa_get WITNESS_GENERATOR_TYPE "$part")",
      "timing_ms": {
        "compile": $(aa_get TIMING_COMPILE_MS "$part"),
        "witness": $(aa_get TIMING_WITNESS_MS "$part"),
        "zkey": $(aa_get TIMING_ZKEY_MS "$part"),
        "proof": $prove_ms,
        "verify": $(aa_get TIMING_VERIFY_MS "$part")
      },
      "peak_rss_mb": {
        "compile": $(aa_get PEAK_RSS_COMPILE "$part"),
        "witness": $(aa_get PEAK_RSS_WITNESS "$part"),
        "zkey": $(aa_get PEAK_RSS_ZKEY "$part"),
        "proof": $(aa_get PEAK_RSS_PROOF "$part")
      },
      "artifact_bytes": {
        "r1cs": $(aa_get ARTIFACT_R1CS_BYTES "$part"),
        "zkey": $(aa_get ARTIFACT_ZKEY_BYTES "$part"),
        "witness": $(aa_get ARTIFACT_WTNS_BYTES "$part"),
        "proof": $(aa_get ARTIFACT_PROOF_BYTES "$part")
      },
      "throughput": {
        "compile_constraints_per_sec": $(compute_throughput $c $compile_ms),
        "prove_constraints_per_sec": $(compute_throughput $c $prove_ms)
      }
    }
PARTEOF
    done

    cat >> "$TIMING_FILE" << JSONEOF

  }
}
JSONEOF

    log_info "Metrics report saved to: $TIMING_FILE"
}

# =============================================================================
# Print Console Report
# =============================================================================

print_timing_report() {
    local end_ms=$(now_ms)
    local total_ms=$((end_ms - PIPELINE_START_TIME_MS))

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                  METRICS REPORT                                         ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Total Pipeline Time:${NC} $(format_duration_ms $total_ms)                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Hardware:${NC} $HW_CPU_MODEL ($HW_CPU_CORES cores, ${HW_RAM_TOTAL_MB}MB RAM)                                    ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Phase Totals:${NC}                                                                              ${CYAN}║${NC}"
    printf "${CYAN}║${NC}   %-20s %15s                                                         ${CYAN}║${NC}\n" "Compilation:" "$(format_duration_ms $TOTAL_COMPILE_MS)"
    printf "${CYAN}║${NC}   %-20s %15s                                                         ${CYAN}║${NC}\n" "Witness Gen:" "$(format_duration_ms $TOTAL_WITNESS_MS)"
    printf "${CYAN}║${NC}   %-20s %15s                                                         ${CYAN}║${NC}\n" "Trusted Setup:" "$(format_duration_ms $TOTAL_ZKEY_MS)"
    printf "${CYAN}║${NC}   %-20s %15s                                                         ${CYAN}║${NC}\n" "Proof Gen:" "$(format_duration_ms $TOTAL_PROOF_MS)"
    printf "${CYAN}║${NC}   %-20s %15s                                                         ${CYAN}║${NC}\n" "Verification:" "$(format_duration_ms $TOTAL_VERIFY_MS)"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Per-Part Breakdown:${NC}                                                                        ${CYAN}║${NC}"
    printf "${CYAN}║${NC}   ${BOLD}%-8s %12s %10s %10s %10s %10s %10s %8s${NC}  ${CYAN}║${NC}\n" "Part" "Constraints" "Compile" "Witness" "Zkey" "Proof" "Verify" "PeakRSS"
    echo -e "${CYAN}║${NC}   ──────── ──────────── ────────── ────────── ────────── ────────── ────────── ────────  ${CYAN}║${NC}"

    for part in "${PARTS[@]}"; do
        local max_rss=0
        for phase_rss in $(aa_get PEAK_RSS_COMPILE "$part") $(aa_get PEAK_RSS_WITNESS "$part") $(aa_get PEAK_RSS_ZKEY "$part") $(aa_get PEAK_RSS_PROOF "$part"); do
            [ "$phase_rss" -gt "$max_rss" ] 2>/dev/null && max_rss=$phase_rss
        done
        local rss_display="${max_rss}MB"
        [ "$max_rss" -eq 0 ] && rss_display="--"

        printf "${CYAN}║${NC}   %-8s %12s %10s %10s %10s %10s %10s %8s  ${CYAN}║${NC}\n" \
            "$part" \
            "$(aa_get CONSTRAINTS_COUNT "$part")" \
            "$(format_duration_ms $(aa_get TIMING_COMPILE_MS "$part"))" \
            "$(format_duration_ms $(aa_get TIMING_WITNESS_MS "$part"))" \
            "$(format_duration_ms $(aa_get TIMING_ZKEY_MS "$part"))" \
            "$(format_duration_ms $(aa_get TIMING_PROOF_MS "$part"))" \
            "$(format_duration_ms $(aa_get TIMING_VERIFY_MS "$part"))" \
            "$rss_display"
    done

    echo -e "${CYAN}║${NC}                                                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Artifact Sizes:${NC}                                                                            ${CYAN}║${NC}"
    for part in "${PARTS[@]}"; do
        record_artifact_sizes "$part"
        local r1cs_sz=$(aa_get ARTIFACT_R1CS_BYTES "$part")
        local zkey_sz=$(aa_get ARTIFACT_ZKEY_BYTES "$part")
        local wtns_sz=$(aa_get ARTIFACT_WTNS_BYTES "$part")
        if [ "$r1cs_sz" -gt 0 ] 2>/dev/null || [ "$zkey_sz" -gt 0 ] 2>/dev/null; then
            printf "${CYAN}║${NC}   %-8s  r1cs: %-12s  zkey: %-12s  wtns: %-12s              ${CYAN}║${NC}\n" \
                "$part" "$(format_size $r1cs_sz)" "$(format_size $zkey_sz)" "$(format_size $wtns_sz)"
        fi
    done
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}Prover / Generator Used:${NC}                                                                   ${CYAN}║${NC}"
    for part in "${PARTS[@]}"; do
        if [ "$(aa_get PROVER_USED "$part")" != "none" ] || [ "$(aa_get WITNESS_GENERATOR_TYPE "$part")" != "unknown" ]; then
            printf "${CYAN}║${NC}   %-8s  witness: %-10s  prover: %-10s                                     ${CYAN}║${NC}\n" \
                "$part" "$(aa_get WITNESS_GENERATOR_TYPE "$part")" "$(aa_get PROVER_USED "$part")"
        fi
    done
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}
