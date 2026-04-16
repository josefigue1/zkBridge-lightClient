// =============================================================================
// SP1 Host Script: Groth16 Proof Aggregator for zkBridge Light Client
// =============================================================================
// Loads 8 Groth16 proof sets (proof.json, public.json, vkey.json) from the
// circom build directory, feeds them to the SP1 guest program, and either:
//   --execute : runs in the zkVM without generating a proof (fast, for testing)
//   --prove   : generates a single SP1 proof that attests all 8 are valid
// =============================================================================

use std::path::Path;
use std::time::Instant;

use clap::Parser;
use groth16_aggregator_lib::{AggregatorInput, PartInput};
use sp1_sdk::{
    blocking::{Prover, ProverClient, ProveRequest},
    include_elf, Elf, ProvingKey, SP1Stdin,
};

/// The compiled SP1 guest program (RISC-V ELF).
const AGGREGATOR_ELF: Elf = include_elf!("groth16-aggregator-program");

const PARTS: &[&str] = &[
    "part1a", "part1b", "part1c", "part1d", "part1e", "part2", "part3a", "part3b",
];

#[derive(Parser, Debug)]
#[command(author, version, about = "SP1 Groth16 Proof Aggregator for zkBridge")]
struct Args {
    /// Path to the build directory containing part subdirectories
    build_dir: String,

    /// Execute in zkVM without generating a proof (fast, for testing)
    #[arg(long)]
    execute: bool,

    /// Generate an SP1 proof (compressed STARK)
    #[arg(long)]
    prove: bool,

    /// Specific parts to verify (comma-separated, default: all 8)
    #[arg(long, value_delimiter = ',')]
    parts: Option<Vec<String>>,
}

fn load_parts(build_dir: &Path, parts: &[&str]) -> AggregatorInput {
    let mut input = AggregatorInput { parts: vec![] };

    for part in parts {
        let part_dir = build_dir.join(part);

        let vkey_json = std::fs::read_to_string(part_dir.join("vkey.json"))
            .unwrap_or_else(|e| panic!("Cannot read vkey.json for {}: {}", part, e));
        let proof_json = std::fs::read_to_string(part_dir.join("proof.json"))
            .unwrap_or_else(|e| panic!("Cannot read proof.json for {}: {}", part, e));
        let public_json = std::fs::read_to_string(part_dir.join("public.json"))
            .unwrap_or_else(|e| panic!("Cannot read public.json for {}: {}", part, e));

        input.parts.push(PartInput {
            vkey_json,
            proof_json,
            public_json,
        });
        println!("  Loaded {}", part);
    }

    input
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = Args::parse();

    if args.execute == args.prove {
        eprintln!("Error: Specify either --execute or --prove");
        std::process::exit(1);
    }

    let build_dir = Path::new(&args.build_dir);
    if !build_dir.is_dir() {
        eprintln!("Error: '{}' is not a directory", build_dir.display());
        std::process::exit(1);
    }

    let parts: Vec<&str> = match &args.parts {
        Some(p) => p.iter().map(|s| s.as_str()).collect(),
        None => PARTS.to_vec(),
    };

    println!();
    println!("  SP1 Groth16 Aggregator - zkBridge Light Client");
    println!("  ===============================================");
    println!();
    println!("  Loading proofs from: {}", build_dir.display());

    let aggregator_input = load_parts(build_dir, &parts);
    println!("  Loaded {} parts\n", aggregator_input.parts.len());

    let client = ProverClient::from_env();
    let mut stdin = SP1Stdin::new();
    stdin.write(&aggregator_input);

    if args.execute {
        // ─── Execute mode: run in zkVM, no proof ───
        println!("  Mode: EXECUTE (no proof generation)\n");

        let start = Instant::now();
        let (output, report) = client
            .execute(AGGREGATOR_ELF, stdin)
            .run()
            .expect("SP1 execution failed");
        let elapsed = start.elapsed();

        let num_verified = u32::from_le_bytes(output.as_slice()[0..4].try_into().unwrap());

        println!();
        println!("  ─────────────────────────────────────────────");
        println!("  All {} Groth16 proofs verified in SP1 zkVM!", num_verified);
        println!("  Total cycles:    {}", report.total_instruction_count());
        println!("  Execution time:  {:.2?}", elapsed);
        println!("  ─────────────────────────────────────────────");
    } else {
        // ─── Prove mode: generate SP1 proof ───
        println!("  Mode: PROVE (generating compressed SP1 proof)\n");

        let setup_start = Instant::now();
        let pk = client
            .setup(AGGREGATOR_ELF)
            .expect("SP1 setup failed");
        println!("  Setup time: {:.2?}", setup_start.elapsed());

        let prove_start = Instant::now();
        let proof = client
            .prove(&pk, stdin)
            .compressed()
            .run()
            .expect("SP1 proving failed");
        let prove_elapsed = prove_start.elapsed();

        println!("  SP1 proof generated!");
        println!("  Prove time: {:.2?}", prove_elapsed);

        // Verify the SP1 proof (may fail in mock mode)
        let verify_start = Instant::now();
        match client.verify(&proof, pk.verifying_key(), None) {
            Ok(()) => println!("  SP1 proof verified in {:.2?}", verify_start.elapsed()),
            Err(e) => {
                let prover_mode = std::env::var("SP1_PROVER").unwrap_or_default();
                if prover_mode == "mock" {
                    println!("  SP1 mock proof generated (verification skipped in mock mode)");
                } else {
                    panic!("SP1 proof verification failed: {:?}", e);
                }
            }
        }

        // Save proof to disk
        let proof_path = build_dir.join("sp1_aggregated_proof.bin");
        let serialized = bincode::serialize(&proof).expect("Failed to serialize proof");
        std::fs::write(&proof_path, &serialized).expect("Failed to write proof");

        println!();
        println!("  ─────────────────────────────────────────────");
        println!("  SP1 aggregated proof saved to:");
        println!("    {}", proof_path.display());
        println!("  Proof size: {} bytes", serialized.len());
        println!("  ─────────────────────────────────────────────");
    }

    println!();
}
