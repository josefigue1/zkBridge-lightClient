// =============================================================================
// SP1 Guest Program: Groth16 Proof Aggregator for zkBridge Light Client
// =============================================================================
// Verifies 8 Groth16/BN254 proofs (from circom/snarkjs) inside the SP1 zkVM.
// The resulting SP1 proof attests that all 8 proofs are valid.
// =============================================================================

#![no_main]
sp1_zkvm::entrypoint!(main);

use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G2Affine};
use ark_groth16::{Groth16, Proof, VerifyingKey};
use ark_snark::SNARK;
use core::str::FromStr;
use groth16_aggregator_lib::AggregatorInput;
use serde_json::Value;

// =============================================================================
// snarkjs JSON -> arkworks type parsers
// =============================================================================

fn parse_fq(val: &Value) -> Fq {
    let s = match val {
        Value::String(s) => s.as_str(),
        _ => panic!("Expected string for Fq"),
    };
    Fq::from_str(s).expect("Invalid Fq")
}

fn parse_fr(val: &Value) -> Fr {
    let s = match val {
        Value::String(s) => s.as_str(),
        _ => panic!("Expected string for Fr"),
    };
    Fr::from_str(s).expect("Invalid Fr")
}

fn parse_fq2(val: &Value) -> Fq2 {
    let arr = val.as_array().expect("Expected array for Fq2");
    Fq2::new(parse_fq(&arr[0]), parse_fq(&arr[1]))
}

fn parse_g1(val: &Value) -> G1Affine {
    let arr = val.as_array().expect("Expected array for G1");
    G1Affine::new_unchecked(parse_fq(&arr[0]), parse_fq(&arr[1]))
}

fn parse_g2(val: &Value) -> G2Affine {
    let arr = val.as_array().expect("Expected array for G2");
    G2Affine::new_unchecked(parse_fq2(&arr[0]), parse_fq2(&arr[1]))
}

// =============================================================================
// Groth16 verification from snarkjs JSON
// =============================================================================

fn verify_snarkjs_proof(vkey_json: &str, proof_json: &str, public_json: &str) -> bool {
    // Parse proof
    let pdata: Value = serde_json::from_str(proof_json).expect("Invalid proof JSON");
    let proof = Proof::<Bn254> {
        a: parse_g1(&pdata["pi_a"]),
        b: parse_g2(&pdata["pi_b"]),
        c: parse_g1(&pdata["pi_c"]),
    };

    // Parse public inputs
    let pub_data: Value = serde_json::from_str(public_json).expect("Invalid public JSON");
    let public_inputs: Vec<Fr> = pub_data
        .as_array()
        .expect("public.json must be array")
        .iter()
        .map(parse_fr)
        .collect();

    // Parse verification key
    let vk_data: Value = serde_json::from_str(vkey_json).expect("Invalid vkey JSON");
    let ic: Vec<G1Affine> = vk_data["IC"]
        .as_array()
        .expect("IC must be array")
        .iter()
        .map(parse_g1)
        .collect();

    let vk = VerifyingKey::<Bn254> {
        alpha_g1: parse_g1(&vk_data["vk_alpha_1"]),
        beta_g2: parse_g2(&vk_data["vk_beta_2"]),
        gamma_g2: parse_g2(&vk_data["vk_gamma_2"]),
        delta_g2: parse_g2(&vk_data["vk_delta_2"]),
        gamma_abc_g1: ic,
    };

    // Verify
    Groth16::<Bn254>::verify(&vk, &public_inputs, &proof)
        .expect("Groth16 verification computation error")
}

// =============================================================================
// Main: verify all parts, commit result
// =============================================================================

pub fn main() {
    let input = sp1_zkvm::io::read::<AggregatorInput>();
    let num_parts = input.parts.len() as u32;

    println!("cycle-tracker-start: total_verification");

    for (i, part) in input.parts.iter().enumerate() {
        println!("cycle-tracker-start: part_{}", i);
        let valid = verify_snarkjs_proof(&part.vkey_json, &part.proof_json, &part.public_json);
        println!("cycle-tracker-end: part_{}", i);

        assert!(valid, "Proof part {} FAILED verification", i);
    }

    println!("cycle-tracker-end: total_verification");

    // Commit: number of successfully verified proofs
    sp1_zkvm::io::commit_slice(&num_parts.to_le_bytes());
}
