#!/bin/bash
# =============================================================================
# Module: Witness Generation, Trusted Setup, Proof Generation & Verification
# =============================================================================
# Provides: run_witness_gen, generate_zkey_part, generate_all_zkeys,
#           generate_proof_part, verify_proof_part, generate_all_proofs,
#           export_verifiers
# Dependencies: all previous modules
# Required globals: CIRCUIT_PREFIX, BUILD_DIR, NODE_PATH, NODE_OPTS, NODE_MEM,
#                   PARTS, LOG_DIR, VERIFIER_DIR, VERIFIER_PREFIX
# =============================================================================

# =============================================================================
# Generic Witness Generator (C++ preferred, WASM fallback)
# =============================================================================

run_witness_gen() {
    local build_dir="$1"
    local circuit_name="$2"
    local part_name="$3"
    local cpp_bin="$build_dir/${circuit_name}_cpp/$circuit_name"
    local peak_file="$LOG_DIR/.mem_witness_${part_name:-tmp}"

    if [ -f "$cpp_bin" ] && [ -x "$cpp_bin" ]; then
        log_info "Using C++ witness generator (avoids WASM memory limit)"
        [ -n "$part_name" ] && aa_set WITNESS_GENERATOR_TYPE "$part_name" "cpp"
        "$cpp_bin" "$build_dir/input.json" "$build_dir/witness.wtns" &
        local gen_pid=$!
        start_memory_monitor $gen_pid "$peak_file" 0.5
        wait $gen_pid
        local rss_mb=$(stop_memory_monitor)
        [ -n "$part_name" ] && record_peak_rss "witness" "$part_name" "$rss_mb"
    else
        [ -n "$part_name" ] && aa_set WITNESS_GENERATOR_TYPE "$part_name" "wasm"
        $NODE_PATH $NODE_OPTS \
            "$build_dir/${circuit_name}_js/generate_witness.js" \
            "$build_dir/${circuit_name}_js/${circuit_name}.wasm" \
            "$build_dir/input.json" \
            "$build_dir/witness.wtns" &
        local gen_pid=$!
        start_memory_monitor $gen_pid "$peak_file" 0.5
        wait $gen_pid
        local rss_mb=$(stop_memory_monitor)
        [ -n "$part_name" ] && record_peak_rss "witness" "$part_name" "$rss_mb"
    fi
}

# =============================================================================
# Trusted Setup (zkey generation)
# =============================================================================

generate_zkey_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_${part}"
    local build_dir="$BUILD_DIR/$part"

    if [ -f "$build_dir/${circuit_name}.zkey" ]; then
        log_info "Part $part zkey already exists, skipping..."
        return 0
    fi

    log_step "Generating zkey for Part $part..."
    log_warn "This requires significant RAM and may take a while..."

    local start_ms=$(now_ms)
    local peak_file="$LOG_DIR/.mem_zkey_${part}"

    $NODE_PATH $NODE_OPTS \
        $(which snarkjs) zkey new \
        "$build_dir/${circuit_name}.r1cs" \
        "$PTAU_FILE" \
        "$build_dir/${circuit_name}_0.zkey" &
    local zkey_pid=$!
    start_memory_monitor $zkey_pid "$peak_file" 1
    wait $zkey_pid
    local rss_mb=$(stop_memory_monitor)
    record_peak_rss "zkey" "$part" "$rss_mb"

    $NODE_PATH $(which snarkjs) zkey contribute \
        "$build_dir/${circuit_name}_0.zkey" \
        "$build_dir/${circuit_name}.zkey" \
        -n="${PIPELINE_LABEL} contribution" \
        -e="$(date +%s)$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"

    rm -f "$build_dir/${circuit_name}_0.zkey"

    $NODE_PATH $(which snarkjs) zkey export verificationkey \
        "$build_dir/${circuit_name}.zkey" \
        "$build_dir/vkey.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "zkey" "$part" "$elapsed_ms"
    aa_set ARTIFACT_ZKEY_BYTES "$part" "$(get_file_size_bytes "$build_dir/${circuit_name}.zkey")"
    log_info "Part $part zkey generated in $(format_duration_ms $elapsed_ms) | RSS: ${rss_mb}MB | size: $(format_size $(aa_get ARTIFACT_ZKEY_BYTES "$part"))"
}

generate_all_zkeys() {
    log_header "GENERATING TRUSTED SETUP (ZKEYS)"

    dashboard_stage "trusted_setup"

    PTAU_FILE=$(find_ptau)
    if [ -z "$PTAU_FILE" ]; then
        log_error "Powers of Tau file not found!"
        log_info "Please download pot25_final.ptau from:"
        log_info "  https://github.com/iden3/snarkjs#7-prepare-phase-2"
        log_info "Or set PTAU_FILE environment variable"
        exit 1
    fi
    log_info "Using ptau: $PTAU_FILE"
    dashboard_log "Using ptau: $PTAU_FILE"

    local phase_start_ms=$(now_ms)
    for part in "${PARTS[@]}"; do
        generate_zkey_part "$part"
    done
    local phase_elapsed_ms=$(($(now_ms) - phase_start_ms))

    echo ""
    log_info "All zkeys generated successfully!"
    log_info "Total trusted setup time: $(format_duration_ms $phase_elapsed_ms)"
    dashboard_log "All zkeys generated successfully"
}

# =============================================================================
# Proof Generation & Verification
# =============================================================================

generate_proof_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_${part}"
    local build_dir="$BUILD_DIR/$part"

    log_step "Generating proof for Part $part..."
    local start_ms=$(now_ms)
    local peak_file="$LOG_DIR/.mem_proof_${part}"

    local prover=$(find_rapidsnark)
    if [ -n "$prover" ]; then
        log_info "Using rapidsnark for faster proving"
        record_prover "$part" "rapidsnark"
        "$prover" \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json" &
        local prove_pid=$!
        start_memory_monitor $prove_pid "$peak_file" 0.5
        wait $prove_pid
        local rss_mb=$(stop_memory_monitor)
        record_peak_rss "proof" "$part" "$rss_mb"
    else
        log_info "Using snarkjs (install rapidsnark for faster proving)"
        record_prover "$part" "snarkjs"
        $NODE_PATH $NODE_OPTS \
            $(which snarkjs) groth16 prove \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json" &
        local prove_pid=$!
        start_memory_monitor $prove_pid "$peak_file" 0.5
        wait $prove_pid
        local rss_mb=$(stop_memory_monitor)
        record_peak_rss "proof" "$part" "$rss_mb"
    fi

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "proof" "$part" "$elapsed_ms"
    aa_set ARTIFACT_PROOF_BYTES "$part" "$(get_file_size_bytes "$build_dir/proof.json")"
    log_info "Part $part proof generated in $(format_duration_ms $elapsed_ms) | RSS: ${rss_mb}MB"
}

verify_proof_part() {
    local part=$1
    local build_dir="$BUILD_DIR/$part"

    log_step "Verifying proof for Part $part..."
    local start_ms=$(now_ms)

    $NODE_PATH $(which snarkjs) groth16 verify \
        "$build_dir/vkey.json" \
        "$build_dir/public.json" \
        "$build_dir/proof.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "verify" "$part" "$elapsed_ms"
    log_info "Part $part verified in $(format_duration_ms $elapsed_ms)"
}

generate_all_proofs() {
    log_header "GENERATING PROOFS"
    dashboard_stage "proving"

    local proof_phase_start_ms=$(now_ms)
    for part in "${PARTS[@]}"; do
        generate_proof_part "$part"
    done
    local proof_phase_elapsed_ms=$(($(now_ms) - proof_phase_start_ms))

    log_header "VERIFYING PROOFS"
    dashboard_stage "verifying"

    local verify_phase_start_ms=$(now_ms)
    for part in "${PARTS[@]}"; do
        verify_proof_part "$part"
    done
    local verify_phase_elapsed_ms=$(($(now_ms) - verify_phase_start_ms))

    echo ""
    log_info "All proofs generated and verified!"
    log_info "Total proof generation time: $(format_duration_ms $proof_phase_elapsed_ms)"
    log_info "Total verification time: $(format_duration_ms $verify_phase_elapsed_ms)"
    dashboard_log "All proofs generated and verified"
}

# =============================================================================
# Export Solidity Verifiers
# =============================================================================

export_verifiers() {
    log_header "EXPORTING SOLIDITY VERIFIERS"

    for part in "${PARTS[@]}"; do
        local circuit_name="${CIRCUIT_PREFIX}_${part}"
        local build_dir="$BUILD_DIR/$part"
        local verifier_name="${VERIFIER_PREFIX:-Verifier}_${part}.sol"

        if [ -f "$build_dir/${circuit_name}.zkey" ]; then
            log_step "Exporting verifier for Part $part..."
            $NODE_PATH $(which snarkjs) zkey export solidityverifier \
                "$build_dir/${circuit_name}.zkey" \
                "$VERIFIER_DIR/$verifier_name"
            log_info "Created $VERIFIER_DIR/$verifier_name"

            if [ -f "$build_dir/proof.json" ] && [ -f "$build_dir/public.json" ]; then
                $NODE_PATH $(which snarkjs) zkey export soliditycalldata \
                    "$build_dir/public.json" \
                    "$build_dir/proof.json" \
                    > "$build_dir/calldata.txt"
                log_info "Created $build_dir/calldata.txt"
            fi
        else
            log_warn "zkey for Part $part not found, skipping"
        fi
    done
}
