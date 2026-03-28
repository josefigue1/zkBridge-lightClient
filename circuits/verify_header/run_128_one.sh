#!/bin/bash

# =============================================================================
# Verify Header 128 Split Circuit - ONE Version (1 validator, 8 parts)
# =============================================================================
# Same structure as run_128_mini.sh, but for exactly 1 validator (b=1) and
# still running the full 8-part design (Part1A..Part3B).
#
# Important behavior for ONE mode:
# - Part 3B uses the ONE circuit variant which computes validity but DOES NOT
#   constrain it to 1, so the pipeline can complete even if the signature is
#   invalid (expected for test inputs).
#
# Usage:
#   ./run_128_one.sh                    # Full pipeline (default)
#   ./run_128_one.sh --compile-only     # Only compile circuits
#   ./run_128_one.sh --witness-only     # Only generate witnesses
#   ./run_128_one.sh --zkey-only        # Only generate trusted setup
#   ./run_128_one.sh --proof-only       # Only generate and verify proofs
#   ./run_128_one.sh --export-verifiers # Export Solidity verifiers
#   ./run_128_one.sh --summary          # Print summary of generated files
#   ./run_128_one.sh --clean            # Remove all build artifacts
#
# Environment Variables:
#   SLOT              - Beacon slot number (default: 6154570)
#   PTAU_FILE         - Path to Powers of Tau file
#   NODE_MEM          - Node.js memory limit in MB (default: 98304)
#   PATCHED_NODE_PATH - Optional path to patched node binary
# =============================================================================

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Pipeline identity (used by lib modules for labels and filenames)
PIPELINE_LABEL="ONE - 1 validator"
BANNER_SUBTITLE="Validity computed (Part3B) but NOT constrained"
VERIFIER_PREFIX="Verifier128One"

BUILD_DIR="$SCRIPT_DIR/build_128_one"
CIRCUIT_PREFIX="verify_header_128_one"
NUM_VALIDATORS=1

PARTS=("part1a" "part1b" "part1c" "part1d" "part1e" "part2" "part3a" "part3b")

INPUT_DIR="$SCRIPT_DIR/input"
SLOT="${SLOT:-6154570}"
INPUT_SUFFIX="_input_one"    # e.g. 6154570_input_one.json

VERIFIER_DIR="$SCRIPT_DIR/verifiers_128_one"
LOG_DIR="$SCRIPT_DIR/logs"

# k=7 constant for BLS12-381 BigInt(n=55, k=7) representation
K=7

# Powers of Tau file locations (in order of preference)
PTAU_PATHS=(
    "${PTAU_FILE:-}"
    "/home_data/mvillagra/tusima-jose/powers_of_tau/powersOfTau28_hez_final_27.ptau"
    "/home/tesis/powers_of_tau/powersOfTau28_hez_final_27.ptau"
    "$SCRIPT_DIR/pot25_final.ptau"
    "$SCRIPT_DIR/../utils/circom-pairing/circuits/pot25_final.ptau"
    "$SCRIPT_DIR/../../powers_of_tau/powersOfTau28_hez_final_27.ptau"
    "$HOME/ptau/pot25_final.ptau"
)

# Node.js configuration
NODE_MEM="${NODE_MEM:-98304}"

is_runnable_node() {
    local p="$1"
    [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] && "$p" --version >/dev/null 2>&1
}

if is_runnable_node "${PATCHED_NODE_PATH:-}"; then
    NODE_PATH="$PATCHED_NODE_PATH"
    NODE_OPTS="--max-old-space-size=$NODE_MEM"
elif is_runnable_node "$SCRIPT_DIR/../../node/out/Release/node"; then
    NODE_PATH="$SCRIPT_DIR/../../node/out/Release/node"
    NODE_OPTS="--max-old-space-size=$NODE_MEM"
elif command -v node &> /dev/null; then
    NODE_PATH="node"
    NODE_OPTS="--max-old-space-size=$NODE_MEM"
else
    echo "ERROR: Node.js not found. Please install Node.js 16+"
    exit 1
fi

RAPIDSNARK_PATHS=(
    "$SCRIPT_DIR/../../rapidsnark/build/prover"
    "/usr/local/bin/rapidsnark"
    "$HOME/rapidsnark/build/prover"
)

# =============================================================================
# Dashboard stubs (replaced if dashboard_lib.sh exists)
# =============================================================================

if [ -f "$SCRIPT_DIR/dashboard_lib.sh" ]; then
    source "$SCRIPT_DIR/dashboard_lib.sh"
else
    dashboard_init() { :; }; dashboard_stage() { :; }; dashboard_part() { :; }
    dashboard_step() { :; }; dashboard_constraints() { :; }
    dashboard_complete_part() { :; }; dashboard_error() { :; }
    dashboard_warning() { :; }; dashboard_finish() { :; }
    dashboard_log() { :; }; dashboard_check_memory() { :; }
fi

# =============================================================================
# Source library modules
# =============================================================================

source "$LIB_DIR/01_platform.sh"
source "$LIB_DIR/02_monitoring.sh"
source "$LIB_DIR/03_metrics.sh"
source "$LIB_DIR/04_helpers.sh"
source "$LIB_DIR/05_compile.sh"
source "$LIB_DIR/06_prove.sh"
source "$LIB_DIR/07_summary.sh"

# =============================================================================
# ONE-Specific: Input Preparation
# =============================================================================

prepare_input() {
    log_step "Preparing ONE-validator input..."

    local full_input="$INPUT_DIR/${SLOT}_input.json"
    local one_input="$INPUT_DIR/${SLOT}${INPUT_SUFFIX}.json"

    if [ -f "$one_input" ]; then
        log_info "ONE input already exists: $one_input"
        return 0
    fi

    if [ ! -f "$full_input" ]; then
        log_error "Full input file not found: $full_input"
        log_info "Please provide an input file with 512 validators"
        exit 1
    fi

    $NODE_PATH -e "
    const fs = require('fs');
    const fullInput = JSON.parse(fs.readFileSync('$full_input', 'utf8'));

    const oneInput = {
      signing_root: fullInput.signing_root,
      pubkeys: fullInput.pubkeys.slice(0, 1),
      pubkeybits: [1],
      signature: fullInput.signature
    };

    if (!Array.isArray(oneInput.pubkeys) || oneInput.pubkeys.length !== 1) {
      console.error('ERROR: Could not extract 1 pubkey');
      process.exit(1);
    }

    fs.writeFileSync('$one_input', JSON.stringify(oneInput, null, 2));
    console.log('Created ONE input with 1 validator');
    console.log('  signing_root length:', oneInput.signing_root.length);
    console.log('  pubkeys count:', oneInput.pubkeys.length);
    console.log('  active bits:', oneInput.pubkeybits.filter(b => b === 1).length);
    "
}

# =============================================================================
# ONE-Specific: Witness Generation (8 parts)
# =============================================================================
# These functions contain the inter-part data wiring specific to the ONE
# variant. The witness layout indices are determined by each circuit's public
# output signals. See ANALYSIS_run_128_one.md Section 2.2 for details.
# =============================================================================

generate_witness_part1a() {
    local build_dir="$BUILD_DIR/part1a"
    local circuit_name="${CIRCUIT_PREFIX}_part1a"
    local input_file="$INPUT_DIR/${SLOT}${INPUT_SUFFIX}.json"

    log_step "Generating witness for Part 1A (HashToField + Poseidon + bitSum)..."

    if [ ! -f "$input_file" ]; then
        log_error "Input file not found: $input_file"
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const full = JSON.parse(fs.readFileSync('$input_file', 'utf8'));
    const input = {
      signing_root: full.signing_root,
      pubkeys: full.pubkeys,
      pubkeybits: full.pubkeybits
    };
    fs.writeFileSync('$build_dir/input.json', JSON.stringify(input, null, 2));
    "

    run_witness_gen "$build_dir" "$circuit_name" "part1a"
    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part1a" "$elapsed_ms"
    log_info "Part 1A witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part1a)MB"
}

generate_witness_part1b() {
    local build_dir="$BUILD_DIR/part1b"
    local circuit_name="${CIRCUIT_PREFIX}_part1b"
    local input_file="$INPUT_DIR/${SLOT}${INPUT_SUFFIX}.json"

    log_step "Generating witness for Part 1B (Accumulated pubkey)..."
    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const full = JSON.parse(fs.readFileSync('$input_file', 'utf8'));
    const input = {
      pubkeys: full.pubkeys,
      pubkeybits: full.pubkeybits
    };
    fs.writeFileSync('$build_dir/input.json', JSON.stringify(input, null, 2));
    "

    run_witness_gen "$build_dir" "$circuit_name" "part1b"
    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part1b" "$elapsed_ms"
    log_info "Part 1B witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part1b)MB"
}

generate_witness_part1c() {
    local build_dir_1a="$BUILD_DIR/part1a"
    local build_dir_1b="$BUILD_DIR/part1b"
    local build_dir_1c="$BUILD_DIR/part1c"
    local circuit_name="${CIRCUIT_PREFIX}_part1c"
    local input_file="$INPUT_DIR/${SLOT}${INPUT_SUFFIX}.json"

    log_step "Generating witness for Part 1C (Checks + MapToG2 core)..."

    if [ ! -f "$build_dir_1a/witness.json" ] || [ ! -f "$build_dir_1b/witness.json" ]; then
        log_error "Part 1A and 1B witnesses required. Run them first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1a = JSON.parse(fs.readFileSync('$build_dir_1a/witness.json', 'utf8'));
    const witness1b = JSON.parse(fs.readFileSync('$build_dir_1b/witness.json', 'utf8'));
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));

    // Part 1A output: hash_field[2][2][7] = 28 values (indices 1-28)
    const hash_field_flat = witness1a.slice(1, 29);
    const hash_field = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        hash_field[i] = [];
        for (let j = 0; j < 2; j++) {
            hash_field[i][j] = hash_field_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    // Part 1B output: aggregated_pubkey[2][7] = 14 values (indices 1-14)
    const agg_flat = witness1b.slice(1, 15);
    const aggregated_pubkey = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        aggregated_pubkey[i] = agg_flat.slice(idx, idx + k);
        idx += k;
    }

    const inputPart1c = {
        aggregated_pubkey: aggregated_pubkey,
        signature: originalInput.signature,
        hash_field: hash_field
    };

    fs.writeFileSync('$build_dir_1c/input.json', JSON.stringify(inputPart1c, null, 2));
    console.log('Created Part 1C input from Part 1A and 1B outputs');
    "

    run_witness_gen "$build_dir_1c" "$circuit_name" "part1c"
    snarkjs wtns export json "$build_dir_1c/witness.wtns" "$build_dir_1c/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part1c" "$elapsed_ms"
    log_info "Part 1C witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part1c)MB"
}

generate_witness_part1d() {
    local build_dir_1c="$BUILD_DIR/part1c"
    local build_dir_1d="$BUILD_DIR/part1d"
    local circuit_name="${CIRCUIT_PREFIX}_part1d"

    log_step "Generating witness for Part 1D (ClearCofactorG2 first half)..."

    if [ ! -f "$build_dir_1c/witness.json" ]; then
        log_error "Part 1C witness required. Run it first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1c = JSON.parse(fs.readFileSync('$build_dir_1c/witness.json', 'utf8'));

    // Part 1C output: R[2][2][7] = 28 values (indices 1-28), R_isInfinity (index 29)
    const R_flat = witness1c.slice(1, 29);
    const R = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        R[i] = [];
        for (let j = 0; j < 2; j++) {
            R[i][j] = R_flat.slice(idx, idx + k);
            idx += k;
        }
    }
    const R_isInfinity = witness1c[29];

    const inputPart1d = { R: R, R_isInfinity: R_isInfinity };

    fs.writeFileSync('$build_dir_1d/input.json', JSON.stringify(inputPart1d, null, 2));
    console.log('Created Part 1D input from Part 1C outputs');
    "

    run_witness_gen "$build_dir_1d" "$circuit_name" "part1d"
    snarkjs wtns export json "$build_dir_1d/witness.wtns" "$build_dir_1d/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part1d" "$elapsed_ms"
    log_info "Part 1D witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part1d)MB"
}

generate_witness_part1e() {
    local build_dir_1c="$BUILD_DIR/part1c"
    local build_dir_1d="$BUILD_DIR/part1d"
    local build_dir_1e="$BUILD_DIR/part1e"
    local circuit_name="${CIRCUIT_PREFIX}_part1e"

    log_step "Generating witness for Part 1E (ClearCofactorG2 second half)..."

    if [ ! -f "$build_dir_1c/witness.json" ] || [ ! -f "$build_dir_1d/witness.json" ]; then
        log_error "Part 1C and 1D witnesses required. Run them first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1c = JSON.parse(fs.readFileSync('$build_dir_1c/witness.json', 'utf8'));
    const witness1d = JSON.parse(fs.readFileSync('$build_dir_1d/witness.json', 'utf8'));

    // R and R_isInfinity from Part 1C
    const R_flat = witness1c.slice(1, 29);
    const R = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        R[i] = [];
        for (let j = 0; j < 2; j++) {
            R[i][j] = R_flat.slice(idx, idx + k);
            idx += k;
        }
    }
    const R_isInfinity = witness1c[29];

    // Part 1D outputs: psiP[2][2][7] (30-57), neg_psiPy[2][7] (58-71),
    //                  add1[2][2][7] (72-99), add1_isInfinity (100)
    const psiP_flat = witness1d.slice(30, 58);
    const psiP = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        psiP[i] = [];
        for (let j = 0; j < 2; j++) {
            psiP[i][j] = psiP_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    const neg_psiPy_flat = witness1d.slice(58, 72);
    const neg_psiPy = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        neg_psiPy[i] = neg_psiPy_flat.slice(idx, idx + k);
        idx += k;
    }

    const add1_flat = witness1d.slice(72, 100);
    const add1 = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        add1[i] = [];
        for (let j = 0; j < 2; j++) {
            add1[i][j] = add1_flat.slice(idx, idx + k);
            idx += k;
        }
    }
    const add1_isInfinity = witness1d[100];

    const inputPart1e = {
        R: R, R_isInfinity: R_isInfinity,
        psiP: psiP, neg_psiPy: neg_psiPy,
        add1: add1, add1_isInfinity: add1_isInfinity
    };

    fs.writeFileSync('$build_dir_1e/input.json', JSON.stringify(inputPart1e, null, 2));
    console.log('Created Part 1E input from Part 1C and 1D outputs');
    "

    run_witness_gen "$build_dir_1e" "$circuit_name" "part1e"
    snarkjs wtns export json "$build_dir_1e/witness.wtns" "$build_dir_1e/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part1e" "$elapsed_ms"
    log_info "Part 1E witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part1e)MB"
}

generate_witness_part2() {
    local build_dir_1b="$BUILD_DIR/part1b"
    local build_dir_1e="$BUILD_DIR/part1e"
    local build_dir_2="$BUILD_DIR/part2"
    local circuit_name="${CIRCUIT_PREFIX}_part2"
    local input_file="$INPUT_DIR/${SLOT}${INPUT_SUFFIX}.json"

    log_step "Generating witness for Part 2 (MillerLoop)..."

    if [ ! -f "$build_dir_1b/witness.json" ] || [ ! -f "$build_dir_1e/witness.json" ]; then
        log_error "Part 1B and 1E witnesses required. Run them first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1b = JSON.parse(fs.readFileSync('$build_dir_1b/witness.json', 'utf8'));
    const witness1e = JSON.parse(fs.readFileSync('$build_dir_1e/witness.json', 'utf8'));
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));

    // aggregated_pubkey from Part 1B: [2][7] = 14 values (indices 1-14)
    const agg_flat = witness1b.slice(1, 15);
    const aggregated_pubkey = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        aggregated_pubkey[i] = agg_flat.slice(idx, idx + k);
        idx += k;
    }

    // Hm_G2 from Part 1E: [2][2][7] = 28 values (indices 1-28)
    const Hm_flat = witness1e.slice(1, 29);
    const Hm_G2 = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        Hm_G2[i] = [];
        for (let j = 0; j < 2; j++) {
            Hm_G2[i][j] = Hm_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    const inputPart2 = {
        aggregated_pubkey: aggregated_pubkey,
        signature: originalInput.signature,
        Hm_G2: Hm_G2
    };

    fs.writeFileSync('$build_dir_2/input.json', JSON.stringify(inputPart2, null, 2));
    console.log('Created Part 2 input from Part 1B and 1E outputs');
    "

    run_witness_gen "$build_dir_2" "$circuit_name" "part2"
    snarkjs wtns export json "$build_dir_2/witness.wtns" "$build_dir_2/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part2" "$elapsed_ms"
    log_info "Part 2 witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part2)MB"
}

generate_witness_part3a() {
    local build_dir_2="$BUILD_DIR/part2"
    local build_dir_3a="$BUILD_DIR/part3a"
    local circuit_name="${CIRCUIT_PREFIX}_part3a"

    log_step "Generating witness for Part 3A (FinalExpEasyPart)..."

    if [ ! -f "$build_dir_2/witness.json" ]; then
        log_error "Part 2 witness required. Run it first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness2 = JSON.parse(fs.readFileSync('$build_dir_2/witness.json', 'utf8'));

    // miller_out from Part 2: [6][2][7] = 84 values (indices 1-84)
    const miller_flat = witness2.slice(1, 85);
    const miller_out = [];
    let idx = 0;
    for (let i = 0; i < 6; i++) {
        miller_out[i] = [];
        for (let j = 0; j < 2; j++) {
            miller_out[i][j] = miller_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    const inputPart3a = { miller_out: miller_out };

    fs.writeFileSync('$build_dir_3a/input.json', JSON.stringify(inputPart3a, null, 2));
    console.log('Created Part 3A input from Part 2 outputs');
    "

    run_witness_gen "$build_dir_3a" "$circuit_name" "part3a"
    snarkjs wtns export json "$build_dir_3a/witness.wtns" "$build_dir_3a/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part3a" "$elapsed_ms"
    log_info "Part 3A witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part3a)MB"
}

generate_witness_part3b() {
    local build_dir_3a="$BUILD_DIR/part3a"
    local build_dir_3b="$BUILD_DIR/part3b"
    local circuit_name="${CIRCUIT_PREFIX}_part3b"

    log_step "Generating witness for Part 3B (FinalExpHardPart + computed validity)..."

    if [ ! -f "$build_dir_3a/witness.json" ]; then
        log_error "Part 3A witness required. Run it first."
        exit 1
    fi

    local start_ms=$(now_ms)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness3a = JSON.parse(fs.readFileSync('$build_dir_3a/witness.json', 'utf8'));

    // easy_out from Part 3A: [6][2][7] = 84 values (indices 1-84)
    const easy_flat = witness3a.slice(1, 85);
    const easy_out = [];
    let idx = 0;
    for (let i = 0; i < 6; i++) {
        easy_out[i] = [];
        for (let j = 0; j < 2; j++) {
            easy_out[i][j] = easy_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    const inputPart3b = { easy_out: easy_out };

    fs.writeFileSync('$build_dir_3b/input.json', JSON.stringify(inputPart3b, null, 2));
    console.log('Created Part 3B input from Part 3A outputs');
    "

    run_witness_gen "$build_dir_3b" "$circuit_name" "part3b"
    snarkjs wtns export json "$build_dir_3b/witness.wtns" "$build_dir_3b/witness.json"

    local elapsed_ms=$(get_elapsed_ms $start_ms)
    record_timing "witness" "part3b" "$elapsed_ms"
    log_info "Part 3B witness generated in $(format_duration_ms $elapsed_ms) | RSS: $(aa_get PEAK_RSS_WITNESS part3b)MB"
}

generate_all_witnesses() {
    log_header "GENERATING WITNESSES ($PIPELINE_LABEL - ${#PARTS[@]} parts)"
    dashboard_stage "witness_generation"

    local phase_start_ms=$(now_ms)
    prepare_input
    generate_witness_part1a
    generate_witness_part1b
    generate_witness_part1c
    generate_witness_part1d
    generate_witness_part1e
    generate_witness_part2
    generate_witness_part3a
    generate_witness_part3b
    local phase_elapsed_ms=$(($(now_ms) - phase_start_ms))

    echo ""
    log_info "All witnesses generated successfully!"
    log_info "Total witness generation time: $(format_duration_ms $phase_elapsed_ms)"
    dashboard_log "All witnesses generated successfully"
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_banner

    echo "Script:     $0"
    echo "Build dir:  $BUILD_DIR"
    echo "Node:       $NODE_PATH (max ${NODE_MEM}MB)"
    echo "Validators: $NUM_VALIDATORS"

    local rapidsnark_path=$(find_rapidsnark)
    if [ -n "$rapidsnark_path" ]; then
        echo "Rapidsnark: $rapidsnark_path"
    else
        echo "Rapidsnark: not found (will use snarkjs)"
    fi
    echo ""

    local mode="${1:-full}"

    ensure_dirs
    init_timing
    trap 'save_timing_report_partial' ERR

    case "$mode" in
        --compile-only)
            compile_all
            print_timing_report
            save_timing_report
            ;;
        --witness-only)
            generate_all_witnesses
            print_timing_report
            save_timing_report
            ;;
        --zkey-only)
            generate_all_zkeys
            print_timing_report
            save_timing_report
            ;;
        --proof-only)
            generate_all_proofs
            print_timing_report
            save_timing_report
            ;;
        --export-verifiers)
            export_verifiers
            ;;
        --summary)
            print_summary
            ;;
        --clean)
            clean_build
            ;;
        --help|-h)
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  --compile-only      Only compile circuits"
            echo "  --witness-only      Only generate witnesses"
            echo "  --zkey-only         Only generate trusted setup"
            echo "  --proof-only        Only generate and verify proofs"
            echo "  --export-verifiers  Export Solidity verifiers"
            echo "  --summary           Print summary of generated files"
            echo "  --clean             Remove all build artifacts"
            echo "  --help              Show this help"
            echo ""
            echo "Environment variables:"
            echo "  SLOT              Beacon slot number (default: 6154570)"
            echo "  PTAU_FILE         Path to Powers of Tau file"
            echo "  NODE_MEM          Node.js memory limit in MB (default: 98304)"
            echo "  PATCHED_NODE_PATH Optional path to patched node binary"
            ;;
        --full|*)
            compile_all
            generate_all_witnesses
            generate_all_zkeys
            generate_all_proofs
            export_verifiers
            print_summary
            print_timing_report
            save_timing_report
            dashboard_finish
            ;;
    esac

    echo ""
    echo -e "${GREEN}Done!${NC}"
}

# Run with logging
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_128_one_$(date '+%Y%m%d_%H%M%S').log"
main "$@" 2>&1 | tee "$LOG_FILE"
