#!/usr/bin/env bash
# =============================================================================
# SP1 Groth16 Aggregator - Proof Generation Script (Docker)
#
# Instala dependencias, verifica artefactos, y genera la prueba SP1 real
# dentro de un container Docker basado en el Dockerfile del proyecto.
#
# Uso:
#   1. Copiar artefactos de prueba al container (ver paso previo abajo)
#   2. chmod +x scripts/sp1_prove_docker.sh
#   3. ./scripts/sp1_prove_docker.sh
#
# Variables de entorno opcionales:
#   SP1_PROVER    - cpu (default), cuda, network, mock
#   NETWORK_PRIVATE_KEY - requerido si SP1_PROVER=network
#   BUILD_DIR     - ruta a los artefactos (default: auto-detect)
#   SKIP_EXECUTE  - 1 para saltar el test de execute
# =============================================================================
set -euo pipefail

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# ─── Detect paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SP1_DIR="$REPO_ROOT/circuits/verify_header/sp1_aggregator"
SCRIPT_CARGO_DIR="$SP1_DIR/script"

# Build dir: user override or auto-detect
if [[ -n "${BUILD_DIR:-}" ]]; then
    BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
else
    BUILD_DIR="$REPO_ROOT/circuits/verify_header/build_128_one"
fi

SP1_PROVER="${SP1_PROVER:-cpu}"
REQUIRED_PARTS=("part1a" "part1b" "part1c" "part1d" "part1e" "part2" "part3a" "part3b")

# ─── System info ────────────────────────────────────────────────────────────
echo "============================================================"
echo " SP1 Groth16 Aggregator - Proof Generation"
echo "============================================================"
echo ""

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
AVAIL_RAM_GB=$((AVAIL_RAM_KB / 1024 / 1024))
NUM_CPUS=$(nproc 2>/dev/null || echo "?")

info "Sistema: ${TOTAL_RAM_GB}GB RAM total, ${AVAIL_RAM_GB}GB disponible, ${NUM_CPUS} CPUs"
info "SP1_PROVER=$SP1_PROVER"
info "BUILD_DIR=$BUILD_DIR"

if [[ "$SP1_PROVER" == "cpu" && "$TOTAL_RAM_GB" -lt 50 ]]; then
    err "RAM insuficiente para prueba CPU: ${TOTAL_RAM_GB}GB (necesitás 64GB+)"
    err "Opciones: usar SP1_PROVER=mock (test), SP1_PROVER=network (cloud), o más RAM"
    exit 1
fi

if [[ "$SP1_PROVER" == "network" && -z "${NETWORK_PRIVATE_KEY:-}" ]]; then
    err "SP1_PROVER=network requiere NETWORK_PRIVATE_KEY"
    err "Registrate en https://docs.succinct.xyz y configurá tu key"
    exit 1
fi

# =============================================================================
# PASO 1: Instalar dependencias
# =============================================================================
echo ""
info "══════════════════════════════════════════════════════════"
info "  PASO 1: Verificar e instalar dependencias"
info "══════════════════════════════════════════════════════════"

# ─── 1a. Rust ───────────────────────────────────────────────────────────────
if command -v rustc &>/dev/null; then
    RUST_VER=$(rustc --version)
    log "Rust ya instalado: $RUST_VER"
else
    info "Instalando Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
    log "Rust instalado: $(rustc --version)"
fi

# Asegurar que cargo está en PATH para el resto del script
export PATH="$HOME/.cargo/bin:$PATH"

# ─── 1b. Go ─────────────────────────────────────────────────────────────────
GO_REQUIRED_MAJOR=1
GO_REQUIRED_MINOR=21

install_go() {
    local GO_VERSION="1.22.5"
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) err "Arquitectura no soportada: $ARCH"; exit 1 ;;
    esac

    info "Instalando Go $GO_VERSION ($ARCH)..."
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz

    # Instalar en home si no tenemos permisos root
    if [[ -w /usr/local ]]; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH="/usr/local/go/bin:$PATH"
    else
        rm -rf "$HOME/go-sdk"
        mkdir -p "$HOME/go-sdk"
        tar -C "$HOME/go-sdk" --strip-components=1 -xzf /tmp/go.tar.gz
        export PATH="$HOME/go-sdk/bin:$PATH"
        export GOROOT="$HOME/go-sdk"
    fi
    rm -f /tmp/go.tar.gz
    log "Go instalado: $(go version)"
}

if command -v go &>/dev/null; then
    GO_VER=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
    GO_MAJOR=$(echo "$GO_VER" | cut -d. -f1)
    GO_MINOR=$(echo "$GO_VER" | cut -d. -f2)
    if [[ "$GO_MAJOR" -ge "$GO_REQUIRED_MAJOR" && "$GO_MINOR" -ge "$GO_REQUIRED_MINOR" ]]; then
        log "Go ya instalado: $(go version)"
    else
        warn "Go $GO_VER es muy viejo (necesitás $GO_REQUIRED_MAJOR.$GO_REQUIRED_MINOR+)"
        install_go
    fi
else
    install_go
fi

# ─── 1c. SP1 toolchain ─────────────────────────────────────────────────────
SP1_REQUIRED_VERSION="6.0.1"

if command -v cargo-prove &>/dev/null; then
    SP1_VER=$(cargo-prove --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    if [[ "$SP1_VER" == "$SP1_REQUIRED_VERSION" ]]; then
        log "SP1 toolchain ya instalado: v$SP1_VER"
    else
        warn "SP1 toolchain v$SP1_VER encontrado, necesitás v$SP1_REQUIRED_VERSION"
        info "Actualizando SP1 toolchain..."
        curl -L https://sp1up.succinct.xyz | bash
        source "$HOME/.bashrc" 2>/dev/null || source "$HOME/.profile" 2>/dev/null || true
        export PATH="$HOME/.sp1/bin:$PATH"
        sp1up --version "$SP1_REQUIRED_VERSION"
        log "SP1 toolchain actualizado a v$SP1_REQUIRED_VERSION"
    fi
else
    info "Instalando SP1 toolchain v$SP1_REQUIRED_VERSION..."
    curl -L https://sp1up.succinct.xyz | bash
    # sp1up se instala en ~/.sp1/bin
    export PATH="$HOME/.sp1/bin:$PATH"
    # Intentar source en caso de que sp1up haya modificado shell config
    source "$HOME/.bashrc" 2>/dev/null || source "$HOME/.profile" 2>/dev/null || true
    sp1up --version "$SP1_REQUIRED_VERSION"
    log "SP1 toolchain instalado: v$SP1_REQUIRED_VERSION"
fi

# Asegurar sp1 en PATH
export PATH="$HOME/.sp1/bin:$PATH"

# ─── 1d. Paquetes del sistema (si tenemos permisos) ─────────────────────────
check_system_deps() {
    local missing=()
    for pkg in pkg-config libssl-dev build-essential; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ -w /var/lib/dpkg ]]; then
            info "Instalando paquetes del sistema: ${missing[*]}"
            apt-get update -qq && apt-get install -y --no-install-recommends "${missing[@]}"
            log "Paquetes instalados"
        else
            warn "Faltan paquetes: ${missing[*]} — no tenés permisos root"
            warn "Si la compilación falla, pedí que el Dockerfile los incluya"
        fi
    fi
}

# Solo en Linux (Docker)
if [[ -f /etc/debian_version ]]; then
    check_system_deps
fi

# =============================================================================
# PASO 2: Verificar artefactos de prueba
# =============================================================================
echo ""
info "══════════════════════════════════════════════════════════"
info "  PASO 2: Verificar artefactos de prueba"
info "══════════════════════════════════════════════════════════"

if [[ ! -d "$BUILD_DIR" ]]; then
    err "BUILD_DIR no existe: $BUILD_DIR"
    err ""
    err "Los artefactos (proof.json, public.json, vkey.json) están gitignored."
    err "Copialos al container. Desde tu Mac:"
    err ""
    err "  # Solo los JSON necesarios (~172KB total):"
    err "  for part in part1a part1b part1c part1d part1e part2 part3a part3b; do"
    err "    docker cp circuits/verify_header/build_128_one/\$part/{proof,public,vkey}.json <container>:/workspace/circuits/verify_header/build_128_one/\$part/"
    err "  done"
    exit 1
fi

MISSING_PARTS=()
MISSING_FILES=()
for part in "${REQUIRED_PARTS[@]}"; do
    part_dir="$BUILD_DIR/$part"
    if [[ ! -d "$part_dir" ]]; then
        MISSING_PARTS+=("$part")
        continue
    fi
    for f in proof.json public.json vkey.json; do
        if [[ ! -f "$part_dir/$f" ]]; then
            MISSING_FILES+=("$part/$f")
        fi
    done
done

if [[ ${#MISSING_PARTS[@]} -gt 0 ]]; then
    err "Faltan directorios de partes: ${MISSING_PARTS[*]}"
    exit 1
fi

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    err "Faltan archivos:"
    for f in "${MISSING_FILES[@]}"; do
        err "  - $f"
    done
    err ""
    err "Copialos desde tu Mac con docker cp"
    exit 1
fi

# Verificar que los JSON no estén vacíos o corruptos
for part in "${REQUIRED_PARTS[@]}"; do
    for f in proof.json public.json vkey.json; do
        fpath="$BUILD_DIR/$part/$f"
        size=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo "0")
        if [[ "$size" -lt 10 ]]; then
            err "Archivo sospechosamente pequeño ($size bytes): $part/$f"
            exit 1
        fi
    done
done

log "8/8 partes con artefactos completos"

# =============================================================================
# PASO 3: Compilar el proyecto
# =============================================================================
echo ""
info "══════════════════════════════════════════════════════════"
info "  PASO 3: Compilar SP1 aggregator"
info "══════════════════════════════════════════════════════════"

cd "$SCRIPT_CARGO_DIR"

info "Compilando (incluye guest program para RISC-V, puede tardar varios minutos)..."
BUILD_START=$(date +%s)

if ! cargo build --release 2>&1 | tee /tmp/sp1_build.log; then
    err "Compilación falló. Últimas líneas del log:"
    tail -30 /tmp/sp1_build.log >&2
    err ""
    err "Problemas comunes:"
    err "  - 'go: command not found' → Go no está en PATH"
    err "  - 'pkg-config' errors → faltan libssl-dev o pkg-config"
    err "  - 'sp1-recursion-gnark-ffi' → necesitás Go 1.21+"
    err "  - OOM durante compilación → cerrá otros procesos"
    exit 1
fi

BUILD_END=$(date +%s)
BUILD_SECS=$((BUILD_END - BUILD_START))
log "Compilación exitosa (${BUILD_SECS}s)"

# =============================================================================
# PASO 4: Test rápido (execute, sin prueba)
# =============================================================================
if [[ "${SKIP_EXECUTE:-0}" != "1" ]]; then
    echo ""
    info "══════════════════════════════════════════════════════════"
    info "  PASO 4: Test rápido (execute, sin generar prueba)"
    info "══════════════════════════════════════════════════════════"

    EXEC_START=$(date +%s)
    if ! cargo run --release -- "$BUILD_DIR" --execute 2>&1 | tee /tmp/sp1_execute.log; then
        err "Execute falló. Esto indica un problema con los artefactos o el programa."
        err "Revisá el log: /tmp/sp1_execute.log"
        err "No tiene sentido intentar generar la prueba si execute falla."
        exit 1
    fi
    EXEC_END=$(date +%s)
    EXEC_SECS=$((EXEC_END - EXEC_START))
    log "Execute OK (${EXEC_SECS}s) — todas las pruebas Groth16 verificadas"
else
    warn "Saltando execute (SKIP_EXECUTE=1)"
fi

# =============================================================================
# PASO 5: Generar prueba SP1 real
# =============================================================================
echo ""
info "══════════════════════════════════════════════════════════"
info "  PASO 5: Generar prueba SP1 ($SP1_PROVER)"
info "══════════════════════════════════════════════════════════"
info ""
info "Esto va a tomar un rato largo con 329M ciclos."
info "La prueba se guardará en: $BUILD_DIR/sp1_aggregated_proof.bin"
info ""

# Configurar RUST_LOG para ver progreso
export RUST_LOG="${RUST_LOG:-info}"

PROVE_START=$(date +%s)

if ! SP1_PROVER="$SP1_PROVER" cargo run --release -- "$BUILD_DIR" --prove 2>&1 | tee /tmp/sp1_prove.log; then
    PROVE_END=$(date +%s)
    PROVE_SECS=$((PROVE_END - PROVE_START))
    err "Generación de prueba falló después de ${PROVE_SECS}s"
    err ""

    # Diagnosticar causa
    if grep -qi "out of memory\|oom\|cannot allocate\|memory allocation" /tmp/sp1_prove.log; then
        err "CAUSA: Out of Memory"
        err "RAM disponible: ${AVAIL_RAM_GB}GB"
        err "Soluciones:"
        err "  - Cerrar otros procesos en el server"
        err "  - Usar SP1_PROVER=network (cloud) para evitar compute local"
        err "  - Aumentar RAM del server/container"
    elif grep -qi "cuda\|gpu\|nvidia" /tmp/sp1_prove.log; then
        err "CAUSA: Error de GPU/CUDA"
        err "Soluciones:"
        err "  - Verificar driver NVIDIA: nvidia-smi"
        err "  - Usar SP1_PROVER=cpu en vez de cuda"
    else
        err "Log completo en /tmp/sp1_prove.log"
        tail -30 /tmp/sp1_prove.log >&2
    fi
    exit 1
fi

PROVE_END=$(date +%s)
PROVE_SECS=$((PROVE_END - PROVE_START))
PROVE_MINS=$((PROVE_SECS / 60))

# =============================================================================
# PASO 6: Verificar resultado
# =============================================================================
echo ""
info "══════════════════════════════════════════════════════════"
info "  RESULTADO"
info "══════════════════════════════════════════════════════════"

PROOF_FILE="$BUILD_DIR/sp1_aggregated_proof.bin"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_SIZE=$(du -h "$PROOF_FILE" | cut -f1)
    log "Prueba SP1 generada exitosamente"
    log "  Archivo:  $PROOF_FILE"
    log "  Tamaño:   $PROOF_SIZE"
    log "  Tiempo:   ${PROVE_MINS}min ${PROVE_SECS}s total"
    log "  Prover:   $SP1_PROVER"
    echo ""
    info "Para copiar la prueba fuera del container:"
    info "  docker cp <container>:$PROOF_FILE ./sp1_aggregated_proof.bin"
else
    err "El archivo de prueba no se generó: $PROOF_FILE"
    err "Revisá el log: /tmp/sp1_prove.log"
    exit 1
fi
