extern crate alloc;
use alloc::string::String;
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};

/// Data for a single circom proof part (snarkjs JSON format).
#[derive(Serialize, Deserialize)]
pub struct PartInput {
    pub vkey_json: String,
    pub proof_json: String,
    pub public_json: String,
}

/// Input bundle for the SP1 aggregator program.
#[derive(Serialize, Deserialize)]
pub struct AggregatorInput {
    pub parts: Vec<PartInput>,
}
