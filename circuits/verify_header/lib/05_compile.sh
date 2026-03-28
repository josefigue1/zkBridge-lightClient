#!/bin/bash
# =============================================================================
# Module: Circuit Compilation
# =============================================================================
# Provides: compile_part, compile_all
# Dependencies: 01_platform.sh, 02_monitoring.sh, 03_metrics.sh, 04_helpers.sh
# Required globals: CIRCUIT_PREFIX, BUILD_DIR, SCRIPT_DIR, LOG_DIR, PARTS,
#                   PIPELINE_LABEL, dashboard_*
# =============================================================================

compile_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_${part}"
    local build_dir="$BUILD_DIR/$part"
    local circom_file="$SCRIPT_DIR/${circuit_name}.circom"
    local r1cs_file="$build_dir/${circuit_name}.r1cs"

    if [ ! -f "$circom_file" ]; then
        log_error "Circuit file not found: $circom_file"
        dashboard_error "Circuit file not found: $circom_file"
        exit 1
    fi

    local needs_compile=0
    if [ ! -f "$r1cs_file" ]; then
        needs_compile=1
    elif [ "$circom_file" -nt "$r1cs_file" ]; then
        needs_compile=1
    fi

    if [ $needs_compile -eq 0 ]; then
        log_info "Part $part already compiled, skipping..."
        dashboard_complete_part
        return 0
    fi

    # Invalidate dependent artifacts on recompile
    if [ -f "$r1cs_file" ]; then
        log_info "Circuit source updated; recompiling Part $part..."
        rm -f \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/${circuit_name}_0.zkey" \
            "$build_dir/vkey.json" \
            "$build_dir/proof.json" \
            "$build_dir/public.json" \
            "$build_dir/calldata.txt" \
            "$build_dir/witness.wtns" \
            "$build_dir/witness.json" \
            "$build_dir/input.json" \
            2>/dev/null || true

        rm -f "$r1cs_file" "$build_dir/${circuit_name}.sym" "$build_dir/${circuit_name}.wasm" 2>/dev/null || true
        rm -rf "$build_dir/${circuit_name}_js" 2>/dev/null || true
    fi

    log_step "Compiling Part $part ($circuit_name)..."
    dashboard_part "$part"
    dashboard_step "Running circom compiler"
    local start_ms=$(now_ms)

    circom "$circom_file" \
        --O1 \
        --r1cs \
        --wasm \
        --sym \
        --c \
        --output "$build_dir" \
        2>&1 | tee "$LOG_DIR/compile_${part}.log"

    if [ -d "$build_dir/${circuit_name}_cpp" ]; then
        log_info "Building C++ witness generator (avoids WASM memory limit)..."
        make -C "$build_dir/${circuit_name}_cpp" -j"$(nproc 2>/dev/null || echo 4)" 2>&1 | tee -a "$LOG_DIR/compile_${part}.log" || true
    fi

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "compile" "$part" "$elapsed_ms"
    aa_set ARTIFACT_R1CS_BYTES "$part" "$(get_file_size_bytes "$r1cs_file")"
    log_info "Compiled in $(format_duration_ms $elapsed_ms) | r1cs: $(format_size $(aa_get ARTIFACT_R1CS_BYTES "$part"))"
    dashboard_complete_part
    dashboard_check_memory

    if command -v snarkjs &> /dev/null; then
        log_info "Constraints:"
        local constraints_info=$(snarkjs r1cs info "$r1cs_file" 2>/dev/null)
        echo "$constraints_info" | grep -E "Constraints|Private|Public|Labels" || true
        local num_constraints=$(echo "$constraints_info" | grep "Constraints:" | awk '{print $3}')
        if [ -n "$num_constraints" ]; then
            record_constraints "$part" "$num_constraints"
        fi
    fi
}

compile_all() {
    log_header "COMPILING CIRCUITS (${PIPELINE_LABEL} - ${#PARTS[@]} parts)"

    dashboard_init "${PIPELINE_LABEL}" ${#PARTS[@]}
    dashboard_stage "compiling"

    check_command circom

    local phase_start_ms=$(now_ms)
    for part in "${PARTS[@]}"; do
        compile_part "$part"
    done
    local phase_elapsed_ms=$(($(now_ms) - phase_start_ms))

    echo ""
    log_info "All circuits compiled successfully!"
    log_info "Total compilation time: $(format_duration_ms $phase_elapsed_ms)"
    dashboard_log "All circuits compiled successfully"
}
