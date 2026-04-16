# SP1 Groth16 Proof Aggregator - zkBridge Light Client

Programa SP1 (zkVM) que verifica las 8 pruebas Groth16/BN254 generadas por el pipeline Circom split y produce una única prueba SP1. Esto reduce 8 verificaciones on-chain a 1 sola.

## Arquitectura

```
┌──────────────────────────────────────────────────┐
│                   SP1 zkVM                       │
│                                                  │
│  part1a (HashToField+Poseidon)  ──→ Groth16 ✓   │
│  part1b (Accumulated pubkey)    ──→ Groth16 ✓   │
│  part1c (Checks+MapToG2)       ──→ Groth16 ✓   │
│  part1d (ClearCofactor 1/2)    ──→ Groth16 ✓   │
│  part1e (ClearCofactor 2/2)    ──→ Groth16 ✓   │
│  part2  (MillerLoop)           ──→ Groth16 ✓   │
│  part3a (FinalExpEasyPart)     ──→ Groth16 ✓   │
│  part3b (FinalExpHardPart)     ──→ Groth16 ✓   │
│                                                  │
│  OUTPUT: 8 pruebas verificadas                   │
└──────────────────┬───────────────────────────────┘
                   ▼
         Una sola prueba SP1
```

## Estructura del código

```
sp1_aggregator/
├── lib/src/lib.rs          # Tipos: AggregatorInput, PartInput (serde)
├── program/src/main.rs     # Guest: parsea JSON snarkjs → arkworks, verifica Groth16
├── script/src/bin/main.rs  # Host: carga archivos, alimenta zkVM, genera proof
├── script/build.rs         # Compila el guest program para RISC-V
└── .env                    # SP1_PROVER=cpu|mock|cuda|network
```

## Requisitos

- Rust (stable)
- [SP1 toolchain v6.0.1](https://docs.succinct.xyz/docs/sp1/getting-started/install): `sp1up --version 6.0.1`
- Go (requerido por `sp1-recursion-gnark-ffi`)
- Artefactos de prueba: cada parte necesita `proof.json`, `public.json`, `vkey.json` en `build_128_one/<part>/`

## Cómo correr

```bash
cd circuits/verify_header/sp1_aggregator/script

# Ejecutar en zkVM sin generar prueba (test rápido, ~7s)
cargo run --release -- ../../build_128_one --execute

# Generar prueba mock (testea pipeline completo, sin compute pesado)
SP1_PROVER=mock cargo run --release -- ../../build_128_one --prove

# Generar prueba real en CPU (necesita 64GB+ RAM)
SP1_PROVER=cpu cargo run --release -- ../../build_128_one --prove

# Generar prueba real con GPU NVIDIA
SP1_PROVER=cuda cargo run --release -- ../../build_128_one --prove

# Usar Succinct Prover Network (cloud)
SP1_PROVER=network NETWORK_PRIVATE_KEY=<key> cargo run --release -- ../../build_128_one --prove

# Solo algunas partes
cargo run --release -- ../../build_128_one --execute --parts part1a,part1b
```

## Métricas obtenidas (2026-04-13)

| Métrica | Valor |
|---------|-------|
| Ciclos SP1 totales (8 partes) | 329,081,393 |
| Tiempo execute (Mac M-series) | 7.4s |
| Ciclos promedio por parte | ~41M |
| rust_verifier nativo (8 partes) | 34ms |

## Fixes aplicados al template original

1. **`program/Cargo.toml`**: `ark-bn254` necesita `features = ["curve"]` para que exporte `Bn254`, `Fq`, `Fr`, `G1Affine`, `G2Affine` en el target RISC-V
2. **`script/src/bin/main.rs`**: 
   - Imports: agregar `ProveRequest` y `ProvingKey` traits para SP1 SDK 6.0.2
   - `output.as_slice()[0..4]` en vez de `output[0..4]` (`SP1PublicValues` no es indexable directamente)
   - Verificación graceful en mock mode (mock proofs no pasan `verify_proof` general)

## Origen de los artefactos de prueba

Los `proof.json`, `public.json`, `vkey.json` en `build_128_one/` provienen del pipeline Circom completo ejecutado en el server (backup en `~/Desktop/zk_metrics_backup/MIERCOLES 8/build_128_one/`). Fueron generados con `run_128_one.sh` que compila circuitos, genera witnesses, trusted setup (zkey), y pruebas Groth16.

## Pendiente

- [ ] Generar prueba SP1 real en server con 64GB+ RAM
- [ ] Opcional: wrappear prueba SP1 (STARK) en Groth16/PLONK para verificación on-chain más barata (`--bin evm --system groth16`)
- [ ] Opcional: benchmarks de ciclos por parte individual para la tesis
