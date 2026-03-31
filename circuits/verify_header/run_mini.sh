#!/bin/bash

# =============================================================================
# Verify Header Mini Split Circuit - Build and Proof Generation
# =============================================================================
# This script compiles, generates witnesses, trusted setup, and proofs for
# the 3 split header verification circuits using the MINI version (8 validators).
#
# RAM Requirements (approximate):
#   Part 1: ~7M constraints  - Compile: ~8GB,  Witness: ~4GB, zkey: ~15GB
#   Part 2: ~8M constraints  - Compile: ~10GB, Witness: ~4GB, zkey: ~20GB
#   Part 3: ~5M constraints  - Compile: ~6GB,  Witness: ~3GB, zkey: ~12GB
#   Total peak: ~25GB (can use swap on 16GB machines)
#
# Usage:
#   ./run_mini.sh                    # Full pipeline (default)
#   ./run_mini.sh --compile-only     # Only compile circuits
#   ./run_mini.sh --witness-only     # Only generate witnesses
#   ./run_mini.sh --zkey-only        # Only generate trusted setup
#   ./run_mini.sh --proof-only       # Only generate and verify proofs
#   ./run_mini.sh --export-verifiers # Export Solidity verifiers
#   ./run_mini.sh --summary          # Print summary of generated files
#   ./run_mini.sh --clean            # Remove all build artifacts
#
# Environment Variables:
#   SLOT          - Beacon slot number (default: 6154570)
#   PTAU_FILE     - Path to Powers of Tau file
#   NODE_MEM      - Node.js memory limit in MB (default: 8192)
# =============================================================================

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build_mini"
CIRCUIT_PREFIX="verify_header_mini"
NUM_VALIDATORS=8

# Input configuration
INPUT_DIR="$SCRIPT_DIR/input"
SLOT="${SLOT:-6154570}"

# Output directories
VERIFIER_DIR="$SCRIPT_DIR/verifiers_mini"
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
NODE_MEM="${NODE_MEM:-8192}"
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
    mkdir -p "$BUILD_DIR/part1"
    mkdir -p "$BUILD_DIR/part2"
    mkdir -p "$BUILD_DIR/part3"
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
    log_step "Preparing mini input (8 validators)..."

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
    console.log('Created mini input with 8 validators');
    console.log('  signing_root length:', miniInput.signing_root.length);
    console.log('  pubkeys count:', miniInput.pubkeys.length);
    console.log('  pubkeybits:', miniInput.pubkeybits);
    "
}

# =============================================================================
# Compilation
# =============================================================================

compile_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part}"
    local build_dir="$BUILD_DIR/part${part}"
    local circom_file="$SCRIPT_DIR/${circuit_name}.circom"

    if [ ! -f "$circom_file" ]; then
        log_error "Circuit file not found: $circom_file"
        exit 1
    fi

    if [ -f "$build_dir/${circuit_name}.r1cs" ]; then
        log_info "Part $part already compiled, skipping..."
        return 0
    fi

    log_step "Compiling Part $part ($circuit_name)..."
    local start=$(date +%s)

    circom "$circom_file" \
        --O1 \
        --r1cs \
        --wasm \
        --sym \
        --output "$build_dir" \
        2>&1 | tee "$LOG_DIR/compile_part${part}.log"

    log_info "Compiled in $(get_elapsed $start)"

    # Show constraint count
    if command -v snarkjs &> /dev/null; then
        log_info "Constraints:"
        snarkjs r1cs info "$build_dir/${circuit_name}.r1cs" 2>/dev/null | grep -E "Constraints|Private|Public|Labels" || true
    fi
}

compile_all() {
    log_header "COMPILING CIRCUITS (Mini - 8 validators)"

    check_command circom

    for part in 1 2 3; do
        compile_part $part
    done

    echo ""
    log_info "All circuits compiled successfully!"
}

# =============================================================================
# Witness Generation
# =============================================================================

generate_witness_part1() {
    local build_dir="$BUILD_DIR/part1"
    local circuit_name="${CIRCUIT_PREFIX}_part1"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 1..."

    if [ ! -f "$input_file" ]; then
        log_error "Input file not found: $input_file"
        log_info "Run with --witness-only after preparing input"
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

    log_info "Part 1 witness generated in $(get_elapsed $start)"
}

generate_witness_part2() {
    local build_dir_1="$BUILD_DIR/part1"
    local build_dir_2="$BUILD_DIR/part2"
    local circuit_name="${CIRCUIT_PREFIX}_part2"
    local input_file="$INPUT_DIR/${SLOT}_input_mini.json"

    log_step "Generating witness for Part 2 (chaining from Part 1)..."

    if [ ! -f "$build_dir_1/witness.json" ]; then
        log_error "Part 1 witness not found. Run Part 1 first."
        exit 1
    fi

    local start=$(date +%s)

    # Extract outputs from Part 1 and create Part 2 input
    $NODE_PATH -e "
    const fs = require('fs');
    const k = 7;

    const witness1 = JSON.parse(fs.readFileSync('$build_dir_1/witness.json', 'utf8'));
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));

    // Part 1 output layout (starting at index 1):
    // Hm_G2[2][2][7] = 28 values (indices 1-28)
    // aggregated_pubkey[2][7] = 14 values (indices 29-42)

    // Extract Hm_G2
    const Hm_G2_flat = witness1.slice(1, 29);
    const Hm_G2 = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        Hm_G2[i] = [];
        for (let j = 0; j < 2; j++) {
            Hm_G2[i][j] = Hm_G2_flat.slice(idx, idx + k);
            idx += k;
        }
    }

    // Extract aggregated_pubkey
    const agg_flat = witness1.slice(29, 43);
    const aggregated_pubkey = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        aggregated_pubkey[i] = agg_flat.slice(idx, idx + k);
        idx += k;
    }

    const inputPart2 = {
        aggregated_pubkey: aggregated_pubkey,
        signature: originalInput.signature,
        Hm_G2: Hm_G2
    };

    fs.writeFileSync('$build_dir_2/input.json', JSON.stringify(inputPart2, null, 2));
    console.log('Created Part 2 input from Part 1 outputs');
    "

    $NODE_PATH $NODE_OPTS \
        "$build_dir_2/${circuit_name}_js/generate_witness.js" \
        "$build_dir_2/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_2/input.json" \
        "$build_dir_2/witness.wtns"

    snarkjs wtns export json "$build_dir_2/witness.wtns" "$build_dir_2/witness.json"

    log_info "Part 2 witness generated in $(get_elapsed $start)"
}

generate_witness_part3() {
    local build_dir_2="$BUILD_DIR/part2"
    local build_dir_3="$BUILD_DIR/part3"
    local circuit_name="${CIRCUIT_PREFIX}_part3"

    log_step "Generating witness for Part 3 (chaining from Part 2)..."

    if [ ! -f "$build_dir_2/witness.json" ]; then
        log_error "Part 2 witness not found. Run Part 2 first."
        exit 1
    fi

    local start=$(date +%s)

    # Extract miller_out from Part 2
    $NODE_PATH -e "
    const fs = require('fs');
    const k = 7;

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

    const inputPart3 = { miller_out: miller_out };

    fs.writeFileSync('$build_dir_3/input.json', JSON.stringify(inputPart3, null, 2));
    console.log('Created Part 3 input from Part 2 outputs');
    "

    $NODE_PATH $NODE_OPTS \
        "$build_dir_3/${circuit_name}_js/generate_witness.js" \
        "$build_dir_3/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_3/input.json" \
        "$build_dir_3/witness.wtns"

    snarkjs wtns export json "$build_dir_3/witness.wtns" "$build_dir_3/witness.json"

    log_info "Part 3 witness generated in $(get_elapsed $start)"
}

generate_all_witnesses() {
    log_header "GENERATING WITNESSES"

    prepare_input
    generate_witness_part1
    generate_witness_part2
    generate_witness_part3

    echo ""
    log_info "All witnesses generated successfully!"
}

# =============================================================================
# Trusted Setup (zkey)
# =============================================================================

generate_zkey_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part}"
    local build_dir="$BUILD_DIR/part${part}"

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
        -n="Mini contribution" \
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

    # Find ptau file
    PTAU_FILE=$(find_ptau)
    if [ -z "$PTAU_FILE" ]; then
        log_error "Powers of Tau file not found!"
        log_info "Please download pot25_final.ptau from:"
        log_info "  https://github.com/iden3/snarkjs#7-prepare-phase-2"
        log_info "Or set PTAU_FILE environment variable"
        exit 1
    fi
    log_info "Using ptau: $PTAU_FILE"

    for part in 1 2 3; do
        generate_zkey_part $part
    done

    echo ""
    log_info "All zkeys generated successfully!"
}

# =============================================================================
# Proof Generation
# =============================================================================

generate_proof_part() {
    local part=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part}"
    local build_dir="$BUILD_DIR/part${part}"

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
    local build_dir="$BUILD_DIR/part${part}"

    log_step "Verifying proof for Part $part..."

    $NODE_PATH $(which snarkjs) groth16 verify \
        "$build_dir/vkey.json" \
        "$build_dir/public.json" \
        "$build_dir/proof.json"
}

generate_all_proofs() {
    log_header "GENERATING PROOFS"

    for part in 1 2 3; do
        generate_proof_part $part
    done

    log_header "VERIFYING PROOFS"

    for part in 1 2 3; do
        verify_proof_part $part
    done

    echo ""
    log_info "All proofs generated and verified!"
}

# =============================================================================
# Export Verifiers
# =============================================================================

export_verifiers() {
    log_header "EXPORTING SOLIDITY VERIFIERS"

    for part in 1 2 3; do
        local circuit_name="${CIRCUIT_PREFIX}_part${part}"
        local build_dir="$BUILD_DIR/part${part}"
        local verifier_name="VerifierMiniPart${part}.sol"

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
    echo "  Mode:       MINI (8 validators)"
    echo "  Build dir:  $BUILD_DIR"
    echo "  Input slot: $SLOT"
    echo ""

    echo "Circuit Files:"
    for part in 1 2 3; do
        local build_dir="$BUILD_DIR/part${part}"
        local circuit_name="${CIRCUIT_PREFIX}_part${part}"
        echo "  Part $part:"
        [ -f "$build_dir/${circuit_name}.r1cs" ] && echo -e "    ${GREEN}✓${NC} r1cs compiled" || echo -e "    ${RED}✗${NC} r1cs"
        [ -f "$build_dir/witness.wtns" ] && echo -e "    ${GREEN}✓${NC} witness generated" || echo -e "    ${RED}✗${NC} witness"
        [ -f "$build_dir/${circuit_name}.zkey" ] && echo -e "    ${GREEN}✓${NC} zkey generated" || echo -e "    ${RED}✗${NC} zkey"
        [ -f "$build_dir/proof.json" ] && echo -e "    ${GREEN}✓${NC} proof generated" || echo -e "    ${RED}✗${NC} proof"
    done

    # Show Part 1 outputs if available
    if [ -f "$BUILD_DIR/part1/witness.json" ]; then
        echo ""
        echo "Part 1 Outputs (for on-chain verification):"
        $NODE_PATH -e "
        const fs = require('fs');
        const w = JSON.parse(fs.readFileSync('$BUILD_DIR/part1/witness.json', 'utf8'));
        console.log('  bitSum:                ', w[43]);
        console.log('  syncCommitteePoseidon: ', w[44]);
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
    echo -e "${BLUE}║     Verify Header - Mini Split (8 validators)             ║${NC}"
    echo -e "${BLUE}║     RAM: ~25GB peak (can use swap on 16GB machines)       ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main() {
    print_banner

    echo "Script:     $SCRIPT_DIR/run_mini.sh"
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
            echo "  NODE_MEM   Node.js memory limit in MB (default: 8192)"
            ;;
        --full|*)
            compile_all
            generate_all_witnesses
            generate_all_zkeys
            generate_all_proofs
            export_verifiers
            print_summary
            ;;
    esac

    echo ""
    echo -e "${GREEN}Done!${NC}"
}

# Run with logging
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_mini_$(date '+%Y%m%d_%H%M%S').log"
main "$@" 2>&1 | tee "$LOG_FILE"
