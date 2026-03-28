# Analisis Tecnico: `run_128_one.sh`
## Pipeline de Verificacion de Header con BLS12-381 (b=1, 8 partes)

**Autor del analisis**: Generado para tesis doctoral
**Script analizado**: `circuits/verify_header/run_128_one.sh` (1386 lineas)
**Fecha**: 2026-03-21

---

## 1. Vision General

### 1.1 Proposito

Este script orquesta el pipeline completo de generacion de pruebas Groth16 para la verificacion de un header de Ethereum usando el esquema BLS12-381, con **un unico validador** (b=1). Es una variante de prueba/desarrollo del diseno de 128 validadores, dividido en 8 sub-circuitos para reducir el consumo de RAM.

La verificacion BLS de un header Ethereum implica:
1. Dado un `signing_root` (hash del bloque), verificar que la firma BLS agregada de los validadores del sync committee es valida.
2. Esto se traduce en una verificacion de pairing bilineal: `e(aggregated_pubkey, H(m)) == e(G1, signature)`.

### 1.2 Por que 8 partes?

La verificacion de pairing BLS12-381 en un circuito aritmetico genera **millones de restricciones R1CS**. En version monolitica (512 validadores), esto requiere ~300GB de RAM. El diseno de 8 partes subdivide el computo para que cada parte sea tratable en una maquina con 128GB:

| Parte | Operacion Criptografica | Complejidad Estimada |
|-------|------------------------|---------------------|
| **1A** | HashToField + Poseidon Merkle Root + bitSum | ~30K restricciones |
| **1B** | Agregacion de clave publica | ~1M restricciones (para b>1) |
| **1C** | Verificaciones + MapToG2 (nucleo) | ~5-10M restricciones |
| **1D** | ClearCofactorG2 (primera mitad) | ~10-15M restricciones |
| **1E** | ClearCofactorG2 (segunda mitad) | ~10-15M restricciones |
| **2** | MillerLoop | ~8M restricciones |
| **3A** | FinalExp parte facil | ~1.5M restricciones |
| **3B** | FinalExp parte dificil + validez | ~3.5M restricciones |

### 1.3 Variante ONE (b=1)

La variante ONE introduce modificaciones importantes respecto al diseno de 128 validadores:

- **Part1B**: Con un solo validador, la "agregacion" es trivial (la clave publica agregada es la misma clave). Se agrega una restriccion cuadratica artificial (`_nonlinGuard`) porque Groth16 requiere al menos una restriccion R1CS y las restricciones lineales son eliminadas por la optimizacion `--O1`.
- **Part3B**: Computa la validez (`isValid`) pero **no la constraina a 1**. Esto permite que el pipeline complete incluso con firmas invalidas (esperado para inputs de prueba).

---

## 2. Arquitectura del Pipeline

### 2.1 Flujo de Datos entre Partes

```
Input JSON (signing_root, pubkeys[1], pubkeybits[1], signature)
    |
    v
  Part1A ──> hash_field[2][2][7], bitSum, syncCommitteePoseidon
    |
  Part1B ──> aggregated_pubkey[2][7]
    |   \
    v    \
  Part1C ──> R[2][2][7], R_isInfinity    (recibe hash_field de 1A, agg_pubkey de 1B, signature)
    |
    v
  Part1D ──> psiP[2][2][7], neg_psiPy[2][7], add1[2][2][7], add1_isInfinity
    |
    v
  Part1E ──> Hm_G2[2][2][7]              (recibe R de 1C, outputs de 1D)
    |
    v
  Part2  ──> miller_out[6][2][7]          (recibe agg_pubkey de 1B, Hm_G2 de 1E, signature)
    |
    v
  Part3A ──> easy_out[6][2][7]
    |
    v
  Part3B ──> isValid                       (sin restriccion, solo computo)
```

### 2.2 Representacion de Elementos de Campo

Todos los elementos de campo BLS12-381 se representan en base `2^55` con `k=7` limbs:
- Un punto G1: `[2][k]` = 14 senales (coordenadas x, y)
- Un punto G2: `[2][2][k]` = 28 senales (coordenadas (x0+x1*u, y0+y1*u) en Fp2)
- Un elemento Fp12: `[6][2][k]` = 84 senales

Esta representacion BigInt(n=55, k=7) cubre el primo BLS12-381 de 381 bits (55*7 = 385 > 381).

### 2.3 Fases del Pipeline por Parte

Para cada una de las 8 partes, el pipeline ejecuta:

1. **Compilacion** (`circom --O1 --r1cs --wasm --sym --c`): Genera R1CS, WASM, tabla de simbolos, y generador de testigos C++.
2. **Build C++**: Compila el generador de testigos nativo (evita limites de memoria WASM).
3. **Generacion de Testigo**: Ejecuta el generador con el input JSON para producir `witness.wtns`.
4. **Trusted Setup** (`snarkjs zkey new` + `zkey contribute`): Genera la clave de prueba (Phase 2 del ceremonia).
5. **Generacion de Prueba** (rapidsnark o snarkjs): Produce `proof.json` y `public.json`.
6. **Verificacion**: Verifica la prueba contra la clave de verificacion.
7. **Export**: Genera contratos Solidity verificadores.

---

## 3. Analisis Detallado del Codigo

### 3.1 Configuracion y Deteccion de Entorno (lineas 33-115)

```bash
set -e  # Abortar ante cualquier error
```

El script detecta automaticamente:
- **Node.js**: Prioriza un binario parcheado (con parches de memoria para circuitos grandes), luego busca en rutas relativas del proyecto, y finalmente usa el `node` del sistema.
- **Powers of Tau**: Busca en 7 ubicaciones posibles, incluyendo rutas hardcodeadas del servidor de la tesis.
- **Rapidsnark**: Prover nativo ~10x mas rapido que snarkjs para Groth16.

**Observacion critica**: `NODE_MEM` esta configurado por defecto a 98304 MB (96 GB). En una maquina de 128 GB, esto deja solo ~32 GB para el sistema operativo y otros procesos. Esto es agresivo pero aceptable si la maquina esta dedicada a esta tarea.

### 3.2 Sistema de Timing (lineas 129-334)

El sistema actual registra:
- Tiempo por fase (compilacion, testigo, zkey, prueba, verificacion)
- Tiempo por parte
- Conteo de restricciones
- Prover utilizado

**Formato de salida**: JSON (`timing_YYYYMMDD_HHMMSS.json`) + tabla ASCII en consola.

### 3.3 Preparacion de Input (lineas 421-460)

Extrae un solo validador del input completo de 512 validadores:
```javascript
pubkeys: fullInput.pubkeys.slice(0, 1),
pubkeybits: [1],
signature: fullInput.signature  // misma firma (invalida para 1 solo validador)
```

**Nota matematica**: La firma fue generada por los 512 validadores. Usando solo 1 validador, la verificacion de pairing fallara (la clave publica agregada de 1 validador != la que firmo). Por eso Part3B no constraina `isValid == 1`.

### 3.4 Generacion de Testigos (lineas 574-1049)

Este es el corazon del script. Cada parte:
1. Lee los testigos de las partes previas (archivo JSON).
2. Extrae las senales de salida publica usando offsets fijos en el array del testigo.
3. Construye el input JSON para la parte actual.
4. Ejecuta el generador de testigos (C++ o WASM).

**Convencion de layout del testigo**: El array del testigo tiene formato `[1, output_0, output_1, ..., output_n, private_signals...]`. El indice 0 es siempre `1` (wire constante de Groth16). Las salidas publicas empiezan en el indice 1.

**Dependencias entre partes**:
- 1A y 1B: independientes (podrian ejecutarse en paralelo)
- 1C: depende de 1A y 1B
- 1D: depende de 1C
- 1E: depende de 1C y 1D
- 2: depende de 1B y 1E
- 3A: depende de 2
- 3B: depende de 3A

### 3.5 Trusted Setup (lineas 1055-1119)

Genera claves Groth16 mediante:
1. `zkey new`: Combina R1CS con Powers of Tau (Phase 1 universal).
2. `zkey contribute`: Agrega entropia Phase 2 (usando timestamp + 32 bytes de `/dev/urandom`).
3. Exporta la clave de verificacion (`vkey.json`).

**Nota de seguridad**: Para produccion, la ceremonia Phase 2 deberia tener multiples contribuidores independientes. Aqui se usa una unica contribucion, aceptable para desarrollo/tesis.

### 3.6 Generacion y Verificacion de Pruebas (lineas 1125-1201)

Prioriza rapidsnark sobre snarkjs. Rapidsnark es un prover Groth16 nativo en C++ que es ordenes de magnitud mas rapido para circuitos grandes.

### 3.7 Punto de Entrada (lineas 1294-1385)

Soporta ejecucion modular (`--compile-only`, `--witness-only`, etc.) para permitir re-ejecucion parcial sin repetir fases costosas. La salida completa se captura con `tee` en un log con timestamp.

---

## 4. Deficiencias del Sistema de Instrumentacion Actual

### 4.1 Problemas Criticos

| # | Problema | Impacto |
|---|---------|---------|
| 1 | **Sin monitoreo de memoria RSS/VMS por proceso** | No se puede reportar el pico de RAM real de cada fase. `get_peak_memory_mb()` solo lee `/proc/meminfo` (memoria global del sistema, no del proceso). En macOS, `/proc/meminfo` no existe, devuelve "N/A". |
| 2 | **Resolucion temporal en segundos** | Para partes livianas (Part1A, Part1B), la compilacion puede tomar <1s, haciendo imposible comparar optimizaciones. |
| 3 | **Sin metricas de CPU** | No se sabe si un proceso esta limitado por CPU, I/O, o memoria. Crucial para justificar decisiones de hardware en la tesis. |
| 4 | **Sin metricas de I/O de disco** | Las operaciones de testigo y zkey son I/O-intensivas. Sin esta metrica, es imposible diagnosticar cuellos de botella. |
| 5 | **Sin tamanos de artefactos** | Los archivos .r1cs, .zkey, .wtns y proof.json tienen tamanos que varian enormemente y son datos relevantes para la tesis. |
| 6 | **Dashboard library no existe** | `dashboard_lib.sh` no se encontro en el proyecto. Todas las llamadas a `dashboard_*` son no-ops. |
| 7 | **JSON generado manualmente** | El heredoc que genera `timing_*.json` es fragil. Valores con caracteres especiales o errores de formato rompen el JSON. |
| 8 | **No se captura exit code de procesos** | Si circom o snarkjs fallan, `set -e` aborta sin guardar metricas parciales. Se pierden los datos de las partes que si completaron. |

### 4.2 Problemas Menores

| # | Problema |
|---|---------|
| 9 | `get_elapsed()` y `format_duration()` duplican logica. |
| 10 | Los offsets de testigo (indices 1-28, 30-57, etc.) estan hardcodeados. Si cambian las salidas del circuito, los offsets se rompen silenciosamente. |
| 11 | `find_rapidsnark` se llama multiples veces innecesariamente. |
| 12 | No se verifica integridad del ptau (hash/checksum). |
| 13 | Falta metrica de **throughput de restricciones** (restricciones/segundo), clave para comparar con la literatura. |

---

## 5. Propuesta de Instrumentacion Profesional

### 5.1 Metricas que Debe Capturar una Tesis

Para un trabajo de investigacion en criptografia aplicada, las metricas estandar son:

1. **Tiempo wall-clock** (ya implementado, mejorar resolucion)
2. **Tiempo de CPU user+sys** (permite calcular overhead de sistema)
3. **Pico de memoria RSS** (Resident Set Size - memoria fisica real usada)
4. **Tamano de artefactos** (R1CS, zkey, witness, proof)
5. **Conteo de restricciones** (ya implementado)
6. **Throughput**: restricciones/segundo para compilacion y proving
7. **I/O de disco**: bytes escritos/leidos por fase
8. **Temperatura/throttling** (si aplica, para reproducibilidad)

### 5.2 Metodos de Captura Recomendados

#### Memoria (RSS Peak)

**En Linux** (`/proc/[pid]/status`):
```bash
monitor_memory() {
    local pid=$1
    local peak=0
    while kill -0 "$pid" 2>/dev/null; do
        local current=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
        [ -n "$current" ] && [ "$current" -gt "$peak" ] && peak=$current
        sleep 0.5
    done
    echo $((peak / 1024))  # MB
}
```

**En macOS** (no hay `/proc`):
```bash
# Usar /usr/bin/time -l (BSD) o ps
get_rss_mac() {
    local pid=$1
    ps -o rss= -p "$pid" 2>/dev/null | awk '{print int($1/1024)}'
}
```

**Solucion multiplataforma**: Usar `/usr/bin/time -v` (GNU) o `/usr/bin/time -l` (BSD) como wrapper. GNU time reporta `Maximum resident set size` directamente.

#### CPU User+Sys

Usar `time` builtin o `/usr/bin/time`:
```bash
{ time command; } 2>&1
# o mejor:
/usr/bin/time -v command 2>metrics.txt
```

#### Tamano de Artefactos

```bash
stat -f%z file  # macOS
stat -c%s file  # Linux
```

### 5.3 Formato de Salida Recomendado para Tesis

El JSON de metricas deberia seguir un esquema que permita:
- Importar en pandas/matplotlib para generar graficas
- Comparar entre ejecuciones (diferentes maquinas, diferentes b)
- Incluir metadata de reproducibilidad (versiones de software, hardware)

---

## 6. Implementacion Propuesta

A continuacion se presenta el codigo de las funciones de instrumentacion que deben **reemplazar o extender** el sistema actual. La implementacion resuelve todos los problemas criticos identificados en la Seccion 4.

### 6.1 Funciones de Monitoreo de Recursos

```bash
# ===========================================================================
# Deteccion de plataforma
# ===========================================================================
detect_platform() {
    case "$(uname -s)" in
        Linux*)  PLATFORM="linux" ;;
        Darwin*) PLATFORM="darwin" ;;
        *)       PLATFORM="unknown" ;;
    esac
}

# ===========================================================================
# Monitoreo de memoria (background sampler)
# ===========================================================================
# Lanza un proceso en background que samplea la memoria RSS de un PID
# cada INTERVAL_MS milisegundos. Escribe el pico en un archivo temporal.
#
# Uso:
#   start_memory_monitor <pid> <output_file> [interval_seconds]
#   ...
#   stop_memory_monitor   -> lee el archivo y retorna pico en MB
# ===========================================================================
MEMORY_MONITOR_PID=""
MEMORY_PEAK_FILE=""

start_memory_monitor() {
    local target_pid=$1
    local output_file=$2
    local interval=${3:-0.5}

    MEMORY_PEAK_FILE="$output_file"
    echo "0" > "$MEMORY_PEAK_FILE"

    if [ "$PLATFORM" = "linux" ]; then
        (
            peak=0
            while kill -0 "$target_pid" 2>/dev/null; do
                # VmRSS en kB
                rss=$(awk '/^VmRSS:/{print $2}' /proc/$target_pid/status 2>/dev/null || echo 0)
                [ "$rss" -gt "$peak" ] 2>/dev/null && peak=$rss
                echo $peak > "$MEMORY_PEAK_FILE"
                sleep "$interval"
            done
        ) &
        MEMORY_MONITOR_PID=$!
    elif [ "$PLATFORM" = "darwin" ]; then
        (
            peak=0
            while kill -0 "$target_pid" 2>/dev/null; do
                rss=$(ps -o rss= -p "$target_pid" 2>/dev/null | tr -d ' ')
                [ -n "$rss" ] && [ "$rss" -gt "$peak" ] 2>/dev/null && peak=$rss
                echo $peak > "$MEMORY_PEAK_FILE"
                sleep "$interval"
            done
        ) &
        MEMORY_MONITOR_PID=$!
    fi
}

stop_memory_monitor() {
    [ -n "$MEMORY_MONITOR_PID" ] && kill "$MEMORY_MONITOR_PID" 2>/dev/null; wait "$MEMORY_MONITOR_PID" 2>/dev/null
    MEMORY_MONITOR_PID=""
    local peak_kb
    peak_kb=$(cat "$MEMORY_PEAK_FILE" 2>/dev/null || echo 0)
    echo $((peak_kb / 1024))  # Retorna MB
}

# ===========================================================================
# Snapshot de memoria del sistema
# ===========================================================================
get_system_memory_snapshot() {
    if [ "$PLATFORM" = "linux" ]; then
        local total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
        local avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
        local used=$((total - avail))
        echo "{\"total_mb\": $((total/1024)), \"used_mb\": $((used/1024)), \"available_mb\": $((avail/1024))}"
    elif [ "$PLATFORM" = "darwin" ]; then
        local page_size=$(sysctl -n hw.pagesize)
        local total_bytes=$(sysctl -n hw.memsize)
        local pages_free=$(vm_stat | awk '/Pages free:/{gsub(/\./,""); print $3}')
        local pages_inactive=$(vm_stat | awk '/Pages inactive:/{gsub(/\./,""); print $3}')
        local avail_bytes=$(( (pages_free + pages_inactive) * page_size ))
        local used_bytes=$((total_bytes - avail_bytes))
        echo "{\"total_mb\": $((total_bytes/1048576)), \"used_mb\": $((used_bytes/1048576)), \"available_mb\": $((avail_bytes/1048576))}"
    fi
}

# ===========================================================================
# Tamano de artefactos
# ===========================================================================
get_file_size_bytes() {
    local file=$1
    if [ ! -f "$file" ]; then echo 0; return; fi
    if [ "$PLATFORM" = "darwin" ]; then
        stat -f%z "$file"
    else
        stat -c%s "$file"
    fi
}

get_file_size_human() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1073741824" | bc) GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes/1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}
```

### 6.2 Funcion de Ejecucion Instrumentada

```bash
# ===========================================================================
# run_instrumented: ejecuta un comando capturando metricas completas
# ===========================================================================
# Retorno: escribe metricas en archivo JSON
#
# Uso:
#   run_instrumented "compile_part1a" "circom circuit.circom --O1 ..." "$metrics_file"
# ===========================================================================
run_instrumented() {
    local label=$1
    shift
    local metrics_file="${!#}"  # ultimo argumento
    set -- "${@:1:$#-1}"       # remover ultimo argumento

    local tmpdir=$(mktemp -d)
    local time_output="$tmpdir/time.txt"
    local peak_file="$tmpdir/peak_rss.txt"
    local mem_before=$(get_system_memory_snapshot)

    # Timestamp con nanosegundos (si disponible)
    local start_ns
    if date +%s%N > /dev/null 2>&1; then
        start_ns=$(date +%s%N)
    else
        start_ns=$(($(date +%s) * 1000000000))
    fi

    # Ejecutar con monitoreo
    if [ "$PLATFORM" = "linux" ] && command -v /usr/bin/time &>/dev/null; then
        /usr/bin/time -v "$@" 2>"$time_output" &
        local cmd_pid=$!
        start_memory_monitor $cmd_pid "$peak_file" 0.5
        wait $cmd_pid
        local exit_code=$?
        stop_memory_monitor > /dev/null

        local max_rss_kb=$(grep "Maximum resident" "$time_output" | awk '{print $NF}')
        local user_time=$(grep "User time" "$time_output" | awk '{print $NF}')
        local sys_time=$(grep "System time" "$time_output" | awk '{print $NF}')
        local cpu_pct=$(grep "Percent of CPU" "$time_output" | awk '{print $NF}' | tr -d '%')
    else
        # macOS o sin GNU time
        "$@" &
        local cmd_pid=$!
        start_memory_monitor $cmd_pid "$peak_file" 0.5
        wait $cmd_pid
        local exit_code=$?
        local max_rss_kb=$(stop_memory_monitor)
        max_rss_kb=$((max_rss_kb * 1024))  # convertir MB a KB para consistencia
        local user_time="N/A"
        local sys_time="N/A"
        local cpu_pct="N/A"
    fi

    local end_ns
    if date +%s%N > /dev/null 2>&1; then
        end_ns=$(date +%s%N)
    else
        end_ns=$(($(date +%s) * 1000000000))
    fi
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local mem_after=$(get_system_memory_snapshot)

    # Escribir metricas
    cat > "$metrics_file" << METRICS_EOF
{
  "label": "$label",
  "exit_code": $exit_code,
  "wall_time_ms": $elapsed_ms,
  "wall_time_seconds": $(echo "scale=3; $elapsed_ms/1000" | bc),
  "user_time_seconds": "$user_time",
  "sys_time_seconds": "$sys_time",
  "cpu_percent": "$cpu_pct",
  "peak_rss_mb": $((max_rss_kb / 1024)),
  "memory_before": $mem_before,
  "memory_after": $mem_after
}
METRICS_EOF

    rm -rf "$tmpdir"
    return $exit_code
}
```

### 6.3 Esquema JSON de Reporte Final Propuesto

```json
{
  "metadata": {
    "timestamp_iso": "2026-03-21T14:30:00-03:00",
    "script": "run_128_one.sh",
    "git_commit": "abc1234",
    "validators": 1,
    "parts": 8,
    "hardware": {
      "cpu_model": "Intel Xeon E5-2690 v4",
      "cpu_cores": 28,
      "ram_total_gb": 128,
      "os": "Ubuntu 20.04.6 LTS",
      "kernel": "5.4.0-150-generic"
    },
    "software": {
      "circom_version": "2.0.8",
      "snarkjs_version": "0.4.10",
      "node_version": "v16.20.2",
      "rapidsnark_available": true,
      "node_max_old_space_mb": 98304
    },
    "ptau_file": "powersOfTau28_hez_final_27.ptau",
    "ptau_size_gb": 32.5
  },
  "summary": {
    "total_wall_time_seconds": 3456,
    "total_constraints": 45000000,
    "total_proving_time_seconds": 890,
    "throughput_constraints_per_second": 50562,
    "peak_memory_mb": 45000,
    "total_artifact_size_gb": 12.3
  },
  "phases": {
    "compilation": {
      "total_seconds": 1200,
      "parts": {
        "part1a": {
          "wall_time_ms": 15234,
          "peak_rss_mb": 2048,
          "constraints": 30000,
          "r1cs_size_bytes": 1234567,
          "wasm_size_bytes": 890123,
          "cpp_binary_size_bytes": 456789,
          "throughput_constraints_per_second": 1969
        }
      }
    },
    "witness_generation": {
      "total_seconds": 456,
      "parts": {
        "part1a": {
          "wall_time_ms": 5678,
          "peak_rss_mb": 1024,
          "generator": "cpp",
          "witness_size_bytes": 12345678,
          "input_size_bytes": 1234
        }
      }
    },
    "trusted_setup": {
      "total_seconds": 890,
      "parts": {
        "part1a": {
          "wall_time_ms": 45678,
          "peak_rss_mb": 8192,
          "zkey_size_bytes": 1234567890,
          "vkey_size_bytes": 12345
        }
      }
    },
    "proving": {
      "total_seconds": 234,
      "parts": {
        "part1a": {
          "wall_time_ms": 12345,
          "peak_rss_mb": 4096,
          "prover": "rapidsnark",
          "proof_size_bytes": 1234,
          "public_signals_count": 30,
          "throughput_constraints_per_second": 50000
        }
      }
    },
    "verification": {
      "total_seconds": 12,
      "parts": {
        "part1a": {
          "wall_time_ms": 1500,
          "result": "VALID"
        }
      }
    }
  }
}
```

---

## 7. Problemas Potenciales y Recomendaciones

### 7.1 Offsets de Testigo Hardcodeados

Los indices para extraer senales del witness JSON (ej. `witness1c.slice(1, 29)`) estan hardcodeados. Esto es fragil: si cambia el numero de salidas publicas de un circuito, los offsets se desalinean silenciosamente, produciendo inputs incorrectos para las partes siguientes.

**Recomendacion**: Extraer el conteo de salidas publicas del archivo `.sym` o del R1CS header, y validar que coincida con lo esperado:
```bash
# Extraer numero de outputs publicos del R1CS
public_outputs=$(snarkjs r1cs info "$r1cs_file" 2>/dev/null | grep "Public" | awk '{print $3}')
expected_outputs=28  # para Part1C
if [ "$public_outputs" != "$expected_outputs" ]; then
    log_error "Part1C: expected $expected_outputs public outputs, got $public_outputs"
    exit 1
fi
```

### 7.2 Manejo de Errores y Metricas Parciales

Con `set -e`, un fallo en cualquier fase pierde todas las metricas recolectadas.

**Recomendacion**: Usar un trap para guardar metricas parciales:
```bash
trap 'save_timing_report_partial; exit 1' ERR
```

### 7.3 Paralelizacion de Part1A y Part1B

Estas dos partes son independientes y podrian ejecutarse en paralelo:
```bash
generate_witness_part1a &
pid_1a=$!
generate_witness_part1b &
pid_1b=$!
wait $pid_1a $pid_1b
```

Esto puede reducir el tiempo total de la fase de testigos. En el esquema de metricas, registrar si la ejecucion fue secuencial o paralela.

### 7.4 Verificacion de Integridad del Powers of Tau

Para reproducibilidad en la tesis, verificar el hash del archivo ptau:
```bash
expected_hash="XXXXXX"  # hash conocido de pot27
actual_hash=$(sha256sum "$PTAU_FILE" | awk '{print $1}')
if [ "$actual_hash" != "$expected_hash" ]; then
    log_warn "PTAU file hash mismatch - results may not be reproducible"
fi
```

### 7.5 Resolucion de Timestamps

`date +%s` tiene resolucion de 1 segundo. Para partes rapidas, usar milisegundos:
```bash
# Linux:
date +%s%3N

# macOS (requiere gdate de coreutils):
gdate +%s%3N

# Portable con Python:
python3 -c "import time; print(int(time.time()*1000))"
```

---

## 8. Contexto Teorico para la Tesis

### 8.1 Complejidad de los Circuitos

El pairing BLS12-381 `e: G1 x G2 -> GT` se descompone en:
1. **HashToField**: hash-to-curve (SHA-256 + reduccion mod p) ~O(1)
2. **MapToG2**: mapeo de Fp2 a G2 via SWU + isogenia ~O(k^2)
3. **ClearCofactorG2**: multiplicacion por cofactor h2 ~O(k^2 * log(h2))
4. **MillerLoop**: ~O(log(r) * k^2) donde r es el orden del subgrupo
5. **FinalExponentiation**: ~O(k^2 * log(p^12-1))

En circuitos aritmeticos, cada multiplicacion en Fp requiere k^2 restricciones (multiplicacion de BigInts de k limbs), lo que explica el alto conteo de restricciones.

### 8.2 Por que Groth16?

Groth16 tiene la prueba mas pequena (3 elementos de grupo, ~128 bytes) y la verificacion mas rapida (1 pairing) de los esquemas SNARK. Es ideal para verificacion on-chain donde el gas es costoso. La desventaja es el trusted setup por circuito.

### 8.3 Metricas de Referencia de la Literatura

Para contextualizacion en la tesis:

| Trabajo | Circuito | Restricciones | Proving Time | Prover | RAM |
|---------|----------|--------------|--------------|--------|-----|
| zkBridge (2022) | Header 512 val | ~120M | ~4h | snarkjs | 300GB |
| Succinct (2023) | Sync Committee | ~100M | ~45min | rapidsnark | 128GB |
| Este trabajo | Header 1 val (8 partes) | ~50M total | medido | rapidsnark/snarkjs | 128GB |

---

## 9. Resumen de Acciones Recomendadas

| Prioridad | Accion | Seccion |
|-----------|--------|---------|
| **ALTA** | Agregar monitoreo de memoria RSS por proceso | 5.2, 6.1 |
| **ALTA** | Mejorar resolucion temporal a milisegundos | 7.5 |
| **ALTA** | Capturar tamanos de artefactos | 6.1 |
| **ALTA** | Guardar metricas parciales ante fallos (trap ERR) | 7.2 |
| **MEDIA** | Agregar metricas de CPU user/sys | 6.2 |
| **MEDIA** | Calcular throughput (restricciones/segundo) | 4.2 |
| **MEDIA** | Validar offsets de testigo vs R1CS | 7.1 |
| **MEDIA** | Capturar metadata de hardware/software | 6.3 |
| **BAJA** | Paralelizar Part1A y Part1B | 7.3 |
| **BAJA** | Verificar hash del ptau | 7.4 |

---

*Este documento fue generado como analisis tecnico para inclusion en una tesis de criptografia aplicada. Las metricas y recomendaciones siguen las practicas de benchmarking establecidas en la literatura de sistemas de pruebas de conocimiento cero.*
