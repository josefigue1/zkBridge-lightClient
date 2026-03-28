#!/bin/bash
# =============================================================================
# Module: Summary, Clean, Banner
# =============================================================================
# Provides: print_summary, clean_build, print_banner
# Dependencies: 01_platform.sh (colors, logging)
# Required globals: BUILD_DIR, VERIFIER_DIR, PARTS, CIRCUIT_PREFIX, SLOT,
#                   NODE_PATH, NODE_MEM, PIPELINE_LABEL, BANNER_SUBTITLE
# =============================================================================

print_summary() {
    log_header "SUMMARY"

    echo "Configuration:"
    echo "  Mode:       $PIPELINE_LABEL (${#PARTS[@]}-part split)"
    echo "  Build dir:  $BUILD_DIR"
    echo "  Input slot: $SLOT"
    echo "  Node:       $NODE_PATH (max ${NODE_MEM}MB)"
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
}

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

print_banner() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Verify Header - ${PIPELINE_LABEL}${NC}"
    echo -e "${BLUE}║     ${BANNER_SUBTITLE:-}${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}
