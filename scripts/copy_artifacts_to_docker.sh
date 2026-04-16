#!/usr/bin/env bash
# =============================================================================
# Copia solo los artefactos necesarios (proof.json, public.json, vkey.json)
# al container Docker. Solo 172KB en total (~5.7GB menos que copiar todo).
#
# Uso:
#   ./scripts/copy_artifacts_to_docker.sh <container_name_or_id>
#
# Ejemplo:
#   docker run -d --name sp1prover <imagen> sleep infinity
#   ./scripts/copy_artifacts_to_docker.sh sp1prover
#   docker exec -it sp1prover bash
#   ./scripts/sp1_prove_docker.sh
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <container_name_or_id>"
    echo ""
    echo "Ejemplo:"
    echo "  docker run -d --name sp1prover <imagen> sleep infinity"
    echo "  $0 sp1prover"
    exit 1
fi

CONTAINER="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/circuits/verify_header/build_128_one"
DEST_BASE="/workspace/circuits/verify_header/build_128_one"

PARTS=("part1a" "part1b" "part1c" "part1d" "part1e" "part2" "part3a" "part3b")
FILES=("proof.json" "public.json" "vkey.json")

echo "Copiando artefactos al container '$CONTAINER'..."

# Crear directorios en el container
for part in "${PARTS[@]}"; do
    docker exec "$CONTAINER" mkdir -p "$DEST_BASE/$part"
done

# Copiar archivos
COPIED=0
for part in "${PARTS[@]}"; do
    for f in "${FILES[@]}"; do
        src="$BUILD_DIR/$part/$f"
        dest="$DEST_BASE/$part/$f"
        if [[ -f "$src" ]]; then
            docker cp "$src" "$CONTAINER:$dest"
            ((COPIED++))
        else
            echo "WARN: No existe $src"
        fi
    done
done

# Copiar el script y el código SP1
echo "Copiando scripts..."
docker cp "$REPO_ROOT/scripts/sp1_prove_docker.sh" "$CONTAINER:/workspace/scripts/sp1_prove_docker.sh"
docker exec "$CONTAINER" chmod +x /workspace/scripts/sp1_prove_docker.sh

# Copiar código fuente del sp1_aggregator
echo "Copiando sp1_aggregator source..."
docker cp "$REPO_ROOT/circuits/verify_header/sp1_aggregator/" "$CONTAINER:/workspace/circuits/verify_header/sp1_aggregator/"

echo ""
echo "Listo: $COPIED archivos copiados"
echo ""
echo "Siguiente paso:"
echo "  docker exec -it $CONTAINER bash"
echo "  cd /workspace && ./scripts/sp1_prove_docker.sh"
