#!/bin/bash

# =============================================================================
# Verify Header 128 Split - MINI Version (8 validators)
# =============================================================================
# This script compiles, generates witnesses, trusted setup, and proofs for
# the 8-part split header verification circuits using MINI (8 validators).
# Use this for testing before running the full 128-validator version.
#
# RAM Requirements (approximate per part):
#   Part 1A: ~1K constraints    - <1GB
#   Part 1B: ~40K constraints   - <1GB
#   Part 1C: ~5-10M constraints - ~15GB
#   Part 1D: ~10-15M constraints- ~20GB
#   Part 1E: ~10-15M constraints- ~20GB
#   Part 2:  ~8M constraints    - ~16GB
#   Part 3A: ~1.5M constraints  - ~3GB
#   Part 3B: ~3.5M constraints  - ~7GB
#   Max peak: ~20GB
#
# Note: Parts 1C through 3B have the same constraints regardless of validator
# count, as the heavy computation (MapToG2, MillerLoop, FinalExp) doesn't
# depend on the number of validators.
#
# Usage:
#   ./run_128_mini.sh                    # Full pipeline (default)
#   ./run_128_mini.sh --compile-only     # Only compile circuits
#   ./run_128_mini.sh --witness-only     # Only generate witnesses
#   ./run_128_mini.sh --zkey-only        # Only generate trusted setup
#   ./run_128_mini.sh --proof-only       # Only generate and verify proofs
#   ./run_128_mini.sh --export-verifiers # Export Solidity verifiers
#   ./run_128_mini.sh --summary          # Print summary of generated files
#   ./run_128_mini.sh --clean            # Remove all build artifacts
#
# Environment Variables:
#   SLOT          - Beacon slot number (default: 6154570)
#   PTAU_FILE     - Path to Powers of Tau file
#   NODE_MEM      - Node.js memory limit in MB (default: 16384)
# =============================================================================

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dashboard library for monitoring (if available)
if [ -f "$SCRIPT_DIR/dashboard_lib.sh" ]; then
    source "$SCRIPT_DIR/dashboard_lib.sh"
    DASHBOARD_AVAILABLE=1
else
    DASHBOARD_AVAILABLE=0
    # Stub functions if dashboard not available
    dashboard_init() { :; }
    dashboard_stage() { :; }
    dashboard_part() { :; }
    dashboard_step() { :; }
    dashboard_constraints() { :; }
    dashboard_complete_part() { :; }
    dashboard_error() { :; }
    dashboard_warning() { :; }
    dashboard_finish() { :; }
    dashboard_log() { :; }
    dashboard_check_memory() { :; }
fi
BUILD_DIR="$SCRIPT_DIR/build_128_mini"
CIRCUIT_PREFIX="verify_header_128_mini"
NUM_VALIDATORS=8

# Parts configuration
PARTS=("part1a" "part1b" "part1c" "part1d" "part1e" "part2" "part3a" "part3b")

# Input configuration
INPUT_DIR="$SCRIPT_DIR/input"
SLOT="${SLOT:-6154570}"

# Output directories
VERIFIER_DIR="$SCRIPT_DIR/verifiers_128_mini"
LOG_DIR="$SCRIPT_DIR/logs"

# Powers of Tau file locations (in order of preference)
PTAU_PATHS=(
    "${PTAU_FILE:-}"
    "$SCRIPT_DIR/pot25_final.ptau"
    "$SCRIPT_DIR/../utils/circom-pairing/circuits/pot25_final.ptau"
    "$SCRIPT_DIR/../../powers_of_tau/powersOfTau28_hez_final_27.ptau"
    "$HOME/ptau/pot25_final.ptau"
)

# Node.js configuration
NODE_MEM="${NODE_MEM:-16384}"
if command -v node &> /dev/null; then
    NODE_PATH="node"
    NODE_OPTS="--max-old-space-size=$NODE_MEM"
else
    echo "ERROR: Node.js not found. Please install Node.js 16+"
    exit 1
fi

# Rapidsnark prover (optional, faster than snarkjs)
RAPIDSNARK_PATHS=(
    "$SCRIPT_DIR/../../rapidsnark/build/prover"
    "/usr/local/bin/rapidsnark"
    "$HOME/rapidsnark/build/prover"
)

# =============================================================================
# Colors for output
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
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

get_elapsed() {
    local start=$1
    local end=$(date +%s)
    local elapsed=$((end - start))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    if [ $mins -gt 0 ]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# =============================================================================
# Input Preparation
# =============================================================================

prepare_input() {
    log_step "Preparing 8-validator MINI input..."

    local full_input="$INPUT_DIR/${SLOT}_input.json"
    local mini_input="$INPUT_DIR/${SLOT}_input_mini.json"

    if [ -f "$mini_input" ]; then
        log_info "Mini input already exists: $mini_input"
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

    // Extract first 8 validators
    const miniInput = {
        signing_root: fullInput.signing_root,
        pubkeys: fullInput.pubkeys.slice(0, 8),
        pubkeybits: fullInput.pubkeybits.slice(0, 8),
        signature: fullInput.signature
    };

    // Validate
    if (miniInput.pubkeys.length !== 8) {
        console.error('ERROR: Could not extract 8 validators');
        process.exit(1);
    }

    fs.writeFileSync('$mini_input', JSON.stringify(miniInput, null, 2));
    console.log('Created MINI input with 8 validators');
    console.log('  signing_root length:', miniInput.signing_root.length);
    console.log('  pubkeys count:', miniInput.pubkeys.length);
    console.log('  pubkeybits count:', miniInput.pubkeybits.filter(b => b === 1).length, 'active');
    "
}

# =============================================================================
# Compilation
# =============================================================================

compile_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_${part}"
    local build_dir="$BUILD_DIR/$part"
    local circom_file="$SCRIPT_DIR/${circuit_name}.circom"

    if [ ! -f "$circom_file" ]; then
        log_error "Circuit file not found: $circom_file"
        dashboard_error "Circuit file not found: $circom_file"
        exit 1
    fi

    if [ -f "$build_dir/${circuit_name}.r1cs" ]; then
        log_info "Part $part already compiled, skipping..."
        dashboard_complete_part
        return 0
    fi

    log_step "Compiling Part $part ($circuit_name)..."
    dashboard_part "$part"
    dashboard_step "Running circom compiler"
    local start=$(date +%s)

    circom "$circom_file" \
        --O1 \
        --r1cs \
        --wasm \
        --sym \
        --output "$build_dir" \
        2>&1 | tee "$LOG_DIR/compile_mini_${part}.log"

    log_info "Compiled in $(get_elapsed $start)"
    dashboard_complete_part
    dashboard_check_memory

    # Show constraint count
    if command -v snarkjs &> /dev/null; then
        log_info "Constraints:"
        snarkjs r1cs info "$build_dir/${circuit_name}.r1cs" 2>/dev/null | grep -E "Constraints|Private|Public|Labels" || true
    fi
}

compile_all() {
    log_header "COMPILING CIRCUITS (MINI - 8 validators - 8 parts)"

    dashboard_init "128-mini" 8
    dashboard_stage "compiling"

    check_command circom

    for part in "${PARTS[@]}"; do
        compile_part "$part"
    done

    echo ""
    log_info "All circuits compiled successfully!"
    dashboard_log "All circuits compiled successfully"
}

# =============================================================================
# Witness Generation
# =============================================================================

# k=7 constant for array indexing
K=7

generate_witness_part1a() {
    local build_dir="$BUILD_DIR/part1a"
    local circuit_name="${CIRCUIT_PREFIX}_part1a"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 1A (HashToField + Poseidon + bitSum)..."

    if [ ! -f "$input_file" ]; then
        log_error "Input file not found: $input_file"
        exit 1
    fi

    local start=$(date +%s)

    cp "$input_file" "$build_dir/input.json"

    $NODE_PATH $NODE_OPTS \
        "$build_dir/${circuit_name}_js/generate_witness.js" \
        "$build_dir/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir/input.json" \
        "$build_dir/witness.wtns"

    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"

    log_info "Part 1A witness generated in $(get_elapsed $start)"
}

generate_witness_part1b() {
    local build_dir="$BUILD_DIR/part1b"
    local circuit_name="${CIRCUIT_PREFIX}_part1b"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 1B (AccumulatedECCAdd)..."

    local start=$(date +%s)

    cp "$input_file" "$build_dir/input.json"

    $NODE_PATH $NODE_OPTS \
        "$build_dir/${circuit_name}_js/generate_witness.js" \
        "$build_dir/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir/input.json" \
        "$build_dir/witness.wtns"

    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"

    log_info "Part 1B witness generated in $(get_elapsed $start)"
}

generate_witness_part1c() {
    local build_dir_1a="$BUILD_DIR/part1a"
    local build_dir_1b="$BUILD_DIR/part1b"
    local build_dir_1c="$BUILD_DIR/part1c"
    local circuit_name="${CIRCUIT_PREFIX}_part1c"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 1C (Checks + MapToG2 core)..."

    if [ ! -f "$build_dir_1a/witness.json" ] || [ ! -f "$build_dir_1b/witness.json" ]; then
        log_error "Part 1A and 1B witnesses required. Run them first."
        exit 1
    fi

    local start=$(date +%s)

    # Extract outputs from Part 1A and 1B
    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1a = JSON.parse(fs.readFileSync('$build_dir_1a/witness.json', 'utf8'));
    const witness1b = JSON.parse(fs.readFileSync('$build_dir_1b/witness.json', 'utf8'));
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));

    // Part 1A output layout (starting at index 1):
    // hash_field[2][2][7] = 28 values (indices 1-28)
    // bitSum (index 29)
    // syncCommitteePoseidon (index 30)
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

    // Part 1B output layout (starting at index 1):
    // aggregated_pubkey[2][7] = 14 values (indices 1-14)
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

    $NODE_PATH $NODE_OPTS \
        "$build_dir_1c/${circuit_name}_js/generate_witness.js" \
        "$build_dir_1c/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_1c/input.json" \
        "$build_dir_1c/witness.wtns"

    snarkjs wtns export json "$build_dir_1c/witness.wtns" "$build_dir_1c/witness.json"

    log_info "Part 1C witness generated in $(get_elapsed $start)"
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

    local start=$(date +%s)

    # Extract R and R_isInfinity from Part 1C
    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1c = JSON.parse(fs.readFileSync('$build_dir_1c/witness.json', 'utf8'));

    // Part 1C output layout (starting at index 1):
    // R[2][2][7] = 28 values (indices 1-28)
    // R_isInfinity (index 29)
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

    const inputPart1d = {
        R: R,
        R_isInfinity: R_isInfinity
    };

    fs.writeFileSync('$build_dir_1d/input.json', JSON.stringify(inputPart1d, null, 2));
    console.log('Created Part 1D input from Part 1C outputs');
    "

    $NODE_PATH $NODE_OPTS \
        "$build_dir_1d/${circuit_name}_js/generate_witness.js" \
        "$build_dir_1d/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_1d/input.json" \
        "$build_dir_1d/witness.wtns"

    snarkjs wtns export json "$build_dir_1d/witness.wtns" "$build_dir_1d/witness.json"

    log_info "Part 1D witness generated in $(get_elapsed $start)"
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

    local start=$(date +%s)

    # Extract intermediate values from Part 1D
    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1c = JSON.parse(fs.readFileSync('$build_dir_1c/witness.json', 'utf8'));
    const witness1d = JSON.parse(fs.readFileSync('$build_dir_1d/witness.json', 'utf8'));

    // Get R and R_isInfinity from Part 1C
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

    // Part 1D output layout (starting at index 1):
    // xP_out[2][2][7] = 28 values (indices 1-28)
    // xP_isInfinity (index 29)
    // psiP_out[2][2][7] = 28 values (indices 30-57)
    // neg_psiPy[2][7] = 14 values (indices 58-71)
    // add1_out[2][2][7] = 28 values (indices 72-99)
    // add1_isInfinity (index 100)

    // Extract psiP
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

    // Extract neg_psiPy
    const neg_psiPy_flat = witness1d.slice(58, 72);
    const neg_psiPy = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        neg_psiPy[i] = neg_psiPy_flat.slice(idx, idx + k);
        idx += k;
    }

    // Extract add1
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
        R: R,
        R_isInfinity: R_isInfinity,
        psiP: psiP,
        neg_psiPy: neg_psiPy,
        add1: add1,
        add1_isInfinity: add1_isInfinity
    };

    fs.writeFileSync('$build_dir_1e/input.json', JSON.stringify(inputPart1e, null, 2));
    console.log('Created Part 1E input from Part 1C and 1D outputs');
    "

    $NODE_PATH $NODE_OPTS \
        "$build_dir_1e/${circuit_name}_js/generate_witness.js" \
        "$build_dir_1e/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_1e/input.json" \
        "$build_dir_1e/witness.wtns"

    snarkjs wtns export json "$build_dir_1e/witness.wtns" "$build_dir_1e/witness.json"

    log_info "Part 1E witness generated in $(get_elapsed $start)"
}

generate_witness_part2() {
    local build_dir_1b="$BUILD_DIR/part1b"
    local build_dir_1e="$BUILD_DIR/part1e"
    local build_dir_2="$BUILD_DIR/part2"
    local circuit_name="${CIRCUIT_PREFIX}_part2"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 2 (MillerLoop)..."

    if [ ! -f "$build_dir_1b/witness.json" ] || [ ! -f "$build_dir_1e/witness.json" ]; then
        log_error "Part 1B and 1E witnesses required. Run them first."
        exit 1
    fi

    local start=$(date +%s)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness1b = JSON.parse(fs.readFileSync('$build_dir_1b/witness.json', 'utf8'));
    const witness1e = JSON.parse(fs.readFileSync('$build_dir_1e/witness.json', 'utf8'));
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));

    // Get aggregated_pubkey from Part 1B
    const agg_flat = witness1b.slice(1, 15);
    const aggregated_pubkey = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        aggregated_pubkey[i] = agg_flat.slice(idx, idx + k);
        idx += k;
    }

    // Part 1E output layout (starting at index 1):
    // Hm_G2[2][2][7] = 28 values (indices 1-28)
    // Hm_isInfinity (index 29)
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

    $NODE_PATH $NODE_OPTS \
        "$build_dir_2/${circuit_name}_js/generate_witness.js" \
        "$build_dir_2/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_2/input.json" \
        "$build_dir_2/witness.wtns"

    snarkjs wtns export json "$build_dir_2/witness.wtns" "$build_dir_2/witness.json"

    log_info "Part 2 witness generated in $(get_elapsed $start)"
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

    local start=$(date +%s)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness2 = JSON.parse(fs.readFileSync('$build_dir_2/witness.json', 'utf8'));

    // Part 2 output: miller_out[6][2][7] = 84 values (indices 1-84)
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

    $NODE_PATH $NODE_OPTS \
        "$build_dir_3a/${circuit_name}_js/generate_witness.js" \
        "$build_dir_3a/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_3a/input.json" \
        "$build_dir_3a/witness.wtns"

    snarkjs wtns export json "$build_dir_3a/witness.wtns" "$build_dir_3a/witness.json"

    log_info "Part 3A witness generated in $(get_elapsed $start)"
}

generate_witness_part3b() {
    local build_dir_3a="$BUILD_DIR/part3a"
    local build_dir_3b="$BUILD_DIR/part3b"
    local circuit_name="${CIRCUIT_PREFIX}_part3b"

    log_step "Generating witness for Part 3B (FinalExpHardPart + verification)..."

    if [ ! -f "$build_dir_3a/witness.json" ]; then
        log_error "Part 3A witness required. Run it first."
        exit 1
    fi

    local start=$(date +%s)

    $NODE_PATH -e "
    const fs = require('fs');
    const k = $K;

    const witness3a = JSON.parse(fs.readFileSync('$build_dir_3a/witness.json', 'utf8'));

    // Part 3A output: easy_out[6][2][7] = 84 values (indices 1-84)
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

    $NODE_PATH $NODE_OPTS \
        "$build_dir_3b/${circuit_name}_js/generate_witness.js" \
        "$build_dir_3b/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_3b/input.json" \
        "$build_dir_3b/witness.wtns"

    snarkjs wtns export json "$build_dir_3b/witness.wtns" "$build_dir_3b/witness.json"

    log_info "Part 3B witness generated in $(get_elapsed $start)"
}

generate_all_witnesses() {
    log_header "GENERATING WITNESSES (MINI 8 parts)"

    dashboard_stage "witness_generation"

    prepare_input
    generate_witness_part1a
    generate_witness_part1b
    generate_witness_part1c
    generate_witness_part1d
    generate_witness_part1e
    generate_witness_part2
    generate_witness_part3a
    generate_witness_part3b

    echo ""
    log_info "All witnesses generated successfully!"
    dashboard_log "All witnesses generated successfully"
}

# =============================================================================
# Trusted Setup (zkey)
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

    local start=$(date +%s)

    # Phase 2 setup
    $NODE_PATH $NODE_OPTS \
        $(which snarkjs) zkey new \
        "$build_dir/${circuit_name}.r1cs" \
        "$PTAU_FILE" \
        "$build_dir/${circuit_name}_0.zkey"

    # Contribute randomness
    $NODE_PATH $(which snarkjs) zkey contribute \
        "$build_dir/${circuit_name}_0.zkey" \
        "$build_dir/${circuit_name}.zkey" \
        -n="128-mini contribution" \
        -e="$(date +%s)$(head -c 32 /dev/urandom | xxd -p)"

    rm -f "$build_dir/${circuit_name}_0.zkey"

    # Export verification key
    $NODE_PATH $(which snarkjs) zkey export verificationkey \
        "$build_dir/${circuit_name}.zkey" \
        "$build_dir/vkey.json"

    log_info "Part $part zkey generated in $(get_elapsed $start)"
}

generate_all_zkeys() {
    log_header "GENERATING TRUSTED SETUP (ZKEYS)"

    dashboard_stage "trusted_setup"

    # Find ptau file
    PTAU_FILE=$(find_ptau)
    if [ -z "$PTAU_FILE" ]; then
        log_error "Powers of Tau file not found!"
        dashboard_error "Powers of Tau file not found"
        log_info "Please download pot25_final.ptau from:"
        log_info "  https://github.com/iden3/snarkjs#7-prepare-phase-2"
        log_info "Or set PTAU_FILE environment variable"
        exit 1
    fi
    log_info "Using ptau: $PTAU_FILE"
    dashboard_log "Using ptau: $PTAU_FILE"

    for part in "${PARTS[@]}"; do
        generate_zkey_part "$part"
    done

    echo ""
    log_info "All zkeys generated successfully!"
    dashboard_log "All zkeys generated successfully"
}

# =============================================================================
# Proof Generation
# =============================================================================

generate_proof_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_${part}"
    local build_dir="$BUILD_DIR/$part"

    log_step "Generating proof for Part $part..."
    local start=$(date +%s)

    local prover=$(find_rapidsnark)
    if [ -n "$prover" ]; then
        log_info "Using rapidsnark for faster proving"
        "$prover" \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    else
        log_info "Using snarkjs (install rapidsnark for faster proving)"
        $NODE_PATH $NODE_OPTS \
            $(which snarkjs) groth16 prove \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    fi

    log_info "Part $part proof generated in $(get_elapsed $start)"
}

verify_proof_part() {
    local part=$1
    local build_dir="$BUILD_DIR/$part"

    log_step "Verifying proof for Part $part..."

    $NODE_PATH $(which snarkjs) groth16 verify \
        "$build_dir/vkey.json" \
        "$build_dir/public.json" \
        "$build_dir/proof.json"
}

generate_all_proofs() {
    log_header "GENERATING PROOFS"

    dashboard_stage "proving"

    for part in "${PARTS[@]}"; do
        generate_proof_part "$part"
    done

    log_header "VERIFYING PROOFS"

    dashboard_stage "verifying"

    for part in "${PARTS[@]}"; do
        verify_proof_part "$part"
    done

    echo ""
    log_info "All proofs generated and verified!"
    dashboard_log "All proofs generated and verified"
}

# =============================================================================
# Export Verifiers
# =============================================================================

export_verifiers() {
    log_header "EXPORTING SOLIDITY VERIFIERS"

    for part in "${PARTS[@]}"; do
        local circuit_name="${CIRCUIT_PREFIX}_${part}"
        local build_dir="$BUILD_DIR/$part"
        local verifier_name="Verifier128Mini_${part}.sol"

        if [ -f "$build_dir/${circuit_name}.zkey" ]; then
            log_step "Exporting verifier for Part $part..."
            $NODE_PATH $(which snarkjs) zkey export solidityverifier \
                "$build_dir/${circuit_name}.zkey" \
                "$VERIFIER_DIR/$verifier_name"
            log_info "Created $VERIFIER_DIR/$verifier_name"

            # Generate calldata
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

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    log_header "SUMMARY"

    echo "Configuration:"
    echo "  Mode:       MINI (8 validators, 8-part split)"
    echo "  Build dir:  $BUILD_DIR"
    echo "  Input slot: $SLOT"
    echo ""

    echo "Circuit Files:"
    for part in "${PARTS[@]}"; do
        local build_dir="$BUILD_DIR/$part"
        local circuit_name="${CIRCUIT_PREFIX}_${part}"
        echo "  Part $part:"
        [ -f "$build_dir/${circuit_name}.r1cs" ] && echo -e "    ${GREEN}✓${NC} r1cs compiled" || echo -e "    ${RED}✗${NC} r1cs"
        [ -f "$build_dir/witness.wtns" ] && echo -e "    ${GREEN}✓${NC} witness generated" || echo -e "    ${RED}✗${NC} witness"
        [ -f "$build_dir/${circuit_name}.zkey" ] && echo -e "    ${GREEN}✓${NC} zkey generated" || echo -e "    ${RED}✗${NC} zkey"
        [ -f "$build_dir/proof.json" ] && echo -e "    ${GREEN}✓${NC} proof generated" || echo -e "    ${RED}✗${NC} proof"
    done

    # Show Part 1A outputs if available
    if [ -f "$BUILD_DIR/part1a/witness.json" ]; then
        echo ""
        echo "Part 1A Outputs (for on-chain verification):"
        $NODE_PATH -e "
        const fs = require('fs');
        const w = JSON.parse(fs.readFileSync('$BUILD_DIR/part1a/witness.json', 'utf8'));
        console.log('  bitSum:                ', w[29]);
        console.log('  syncCommitteePoseidon: ', w[30]);
        "
    fi
}

# =============================================================================
# Clean
# =============================================================================

clean_build() {
    log_header "CLEANING BUILD ARTIFACTS"

    if [ -d "$BUILD_DIR" ]; then
        log_step "Removing $BUILD_DIR..."
        rm -rf "$BUILD_DIR"
    fi

    if [ -d "$VERIFIER_DIR" ]; then
        log_step "Removing $VERIFIER_DIR..."
        rm -rf "$VERIFIER_DIR"
    fi

    log_info "Clean complete!"
}

# =============================================================================
# Main
# =============================================================================

print_banner() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Verify Header - MINI (8 validators, 8-part split)     ║${NC}"
    echo -e "${BLUE}║     For testing before running full 128-validator version ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main() {
    print_banner

    echo "Script:     $SCRIPT_DIR/run_128_mini.sh"
    echo "Build dir:  $BUILD_DIR"
    echo "Node:       $NODE_PATH (max ${NODE_MEM}MB)"
    echo ""

    local mode="${1:-full}"

    ensure_dirs

    case "$mode" in
        --compile-only)
            compile_all
            ;;
        --witness-only)
            generate_all_witnesses
            ;;
        --zkey-only)
            generate_all_zkeys
            ;;
        --proof-only)
            generate_all_proofs
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
            echo "  SLOT       Beacon slot number (default: 6154570)"
            echo "  PTAU_FILE  Path to Powers of Tau file"
            echo "  NODE_MEM   Node.js memory limit in MB (default: 16384)"
            ;;
        --full|*)
            compile_all
            generate_all_witnesses
            generate_all_zkeys
            generate_all_proofs
            export_verifiers
            print_summary
            dashboard_finish
            ;;
    esac

    echo ""
    echo -e "${GREEN}Done!${NC}"
}

# Run with logging
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_128_mini_$(date '+%Y%m%d_%H%M%S').log"
main "$@" 2>&1 | tee "$LOG_FILE"
